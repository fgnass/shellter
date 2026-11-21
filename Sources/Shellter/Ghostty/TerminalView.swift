// Keyboard, IME and mouse handling in this file is adapted from the Ghostty
// macOS app (https://github.com/ghostty-org/ghostty), MIT License,
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors.

import AppKit
import Carbon
import GhosttyKit

/// An AppKit view that hosts one libghostty surface.
final class TerminalView: NSView {
    private(set) var surface: ghostty_surface_t?
    weak var eventHandler: TerminalEventHandler?
    var cellSize = NSSize(width: 8, height: 16)
    let search = TerminalSearch()

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var trackingArea: NSTrackingArea?
    private var mouseCursor: NSCursor = .iBeam
    private(set) var focused = false

    static func from(userdata: UnsafeMutableRawPointer?) -> TerminalView? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// `command` replaces the login shell; `env` adds variables for it.
    init(workingDirectory: String?, initialInput: String? = nil,
         command: String? = nil, env: [String: String] = [:]) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        guard let app = GhosttyApp.shared.app else { return }

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.context = GHOSTTY_SURFACE_CONTEXT_TAB

        let wd = workingDirectory.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        // C strings for the env vars; they must live until ghostty_surface_new returns.
        var envVars = env.map { ghostty_env_var_s(key: strdup($0.key), value: strdup($0.value)) }
        defer {
            for v in envVars {
                free(UnsafeMutablePointer(mutating: v.key))
                free(UnsafeMutablePointer(mutating: v.value))
            }
        }
        surface = (wd ?? "").withCString { wdPtr in
            (initialInput ?? "").withCString { inPtr in
                (command ?? "").withCString { cmdPtr in
                    envVars.withUnsafeMutableBufferPointer { envPtr in
                        if wd != nil { cfg.working_directory = wdPtr }
                        if initialInput != nil { cfg.initial_input = inPtr }
                        if command != nil { cfg.command = cmdPtr }
                        if !envPtr.isEmpty {
                            cfg.env_vars = envPtr.baseAddress
                            cfg.env_var_count = envPtr.count
                        }
                        return ghostty_surface_new(app, &cfg)
                    }
                }
            }
        }
        if surface == nil { NSLog("Shellter: ghostty_surface_new failed") }
        registerForDrops()
    }

    /// Inserts text as a paste (bracketed paste, with Ghostty's paste protection).
    func pasteText(_ text: String) {
        guard let surface else { return }
        let len = text.utf8CString.count - 1
        guard len > 0 else { return }
        text.withCString { ghostty_surface_paste_text(surface, $0, UInt(len)) }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func destroy() {
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    deinit { destroy() }

    // MARK: Info

    var foregroundPID: pid_t? {
        guard let surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        return pid > 0 ? pid_t(pid) : nil
    }

    var ttyName: String? {
        guard let surface else { return nil }
        let s = ghostty_surface_tty_name(surface)
        defer { ghostty_string_free(s) }
        guard let ptr = s.ptr, s.len > 0 else { return nil }
        return String(data: Data(bytes: ptr, count: Int(s.len)), encoding: .utf8)
    }

    var processExited: Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    var needsConfirmQuit: Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    func requestClose() {
        guard let surface else { return }
        ghostty_surface_request_close(surface)
    }

    // MARK: Layout / focus

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    private func updateScale() {
        guard let window else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()

        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let fb = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, fb.width / frame.width, fb.height / frame.height)
        if let screen = window.screen,
           let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            ghostty_surface_set_display_id(surface, id)
        }
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let scaled = convertToBacking(bounds.size)
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
    }

    func setVisible(_ visible: Bool) {
        isHidden = !visible
        if let surface { ghostty_surface_set_occlusion(surface, visible) }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { setFocused(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { setFocused(false) }
        return ok
    }

    private func setFocused(_ f: Bool) {
        focused = f
        if let surface { ghostty_surface_set_focus(surface, f) }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways, .cursorUpdate],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) { mouseCursor.set() }

    func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: cursor = .arrow
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: cursor = .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_CELL: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: cursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: cursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: cursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_E_RESIZE, GHOSTTY_MOUSE_SHAPE_W_RESIZE: cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE,
             GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE: cursor = .resizeUpDown
        default: cursor = .arrow
        }
        mouseCursor = cursor
        let apply = { [weak self] in
            guard let self, let window = self.window else { return }
            let p = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if self.bounds.contains(p) { cursor.set() }
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, p.x, frame.height - p.y, Self.mods(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        if !focused { window?.makeFirstResponder(self) }
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface,
              ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags))
        else { return super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface,
              ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags))
        else { return super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, Self.button(event.buttonNumber), Self.mods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, Self.button(event.buttonNumber), Self.mods(event.modifierFlags))
    }

    private static func button(_ n: Int) -> ghostty_input_mouse_button_e {
        switch n {
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_FOUR
        case 4: return GHOSTTY_MOUSE_FIVE
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func mouseEntered(with event: NSEvent) { sendMousePos(event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }

        var momentum: Int32 = 0
        switch event.momentumPhase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        let mods: Int32 = (precise ? 1 : 0) | (momentum << 1)
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    // MARK: Keyboard

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(m)
    }

    private static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var f = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { f.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { f.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { f.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { f.insert(.command) }
        return f
    }

    private func keyEvent(_ event: NSEvent, _ action: ghostty_input_action_e,
                          translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var k = ghostty_input_key_s()
        k.action = action
        k.keycode = UInt32(event.keyCode)
        k.text = nil
        k.composing = false
        k.mods = Self.mods(event.modifierFlags)
        k.consumed_mods = Self.mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        k.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []),
           let cp = chars.unicodeScalars.first {
            k.unshifted_codepoint = cp.value
        }
        return k
    }

    private static func characters(_ event: NSEvent) -> String? {
        guard let chars = event.characters else { return nil }
        if chars.count == 1, let s = chars.unicodeScalars.first {
            if s.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if s.value >= 0xF700 && s.value <= 0xF8FF { return nil }
        }
        return chars
    }

    @discardableResult
    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent,
                           translationEvent: NSEvent? = nil, text: String? = nil,
                           composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var k = keyEvent(event, action, translationMods: translationEvent?.modifierFlags)
        k.composing = composing
        if let text, !text.isEmpty, let first = text.unicodeScalars.first, first.value >= 0x20 || text.count > 1 {
            return text.withCString { ptr in
                k.text = ptr
                return ghostty_surface_key(surface, k)
            }
        }
        return ghostty_surface_key(surface, k)
    }

    private func committedText(_ action: ghostty_input_action_e, _ text: String) {
        guard let surface else { return }
        var k = ghostty_input_key_s()
        k.action = action
        k.mods = GHOSTTY_MODS_NONE
        k.consumed_mods = GHOSTTY_MODS_NONE
        text.withCString { ptr in
            k.text = ptr
            _ = ghostty_surface_key(surface, k)
        }
    }

    private static func isControlWhileComposing(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text, text.unicodeScalars.count == 1,
              let s = text.unicodeScalars.first else { return false }
        return s.value < 0x20
    }

    private static var keyboardLayoutID: String? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }
        eventHandler?.terminalDidReceiveInput(self)

        // Translate mods for configs like macos-option-as-alt.
        let tmods = Self.flags(ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if tmods.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        // Reuse the original event when possible: some IMEs (e.g. Korean) need that.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedBefore = markedText.length > 0
        let layoutBefore = markedBefore ? nil : Self.keyboardLayoutID
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        // An input method switched the layout: do not send the key.
        if !markedBefore && layoutBefore != Self.keyboardLayoutID { return }

        syncPreedit(clearIfNeeded: markedBefore)
        let composing = markedText.length > 0 || markedBefore

        if markedBefore, let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.isControlWhileComposing(text, composing: composing) {
                committedText(action, text)
            }
            if [125, 124, 126].contains(event.keyCode) ||
                (event.keyCode == 123 && !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])) {
                keyAction(action, event: event, translationEvent: translationEvent)
            }
            return
        }

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.isControlWhileComposing(text, composing: composing) {
                keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            if Self.isControlWhileComposing(event.characters, composing: composing) { return }
            keyAction(action, event: event, translationEvent: translationEvent,
                      text: Self.characters(translationEvent), composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let mods = Self.mods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let raw = event.modifierFlags.rawValue
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        keyAction(action, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused, let surface else { return false }

        // Shellter's own menu shortcuts (tabs, sidebar, copy/paste) win.
        if event.modifierFlags.contains(.command), let menu = NSApp.mainMenu,
           menu.performKeyEquivalent(with: event) {
            return true
        }

        // Then Ghostty keybindings from the user's config.
        var k = keyEvent(event, GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr in
            k.text = ptr
            return ghostty_surface_key_is_binding(surface, k, &flags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let final = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode) else { return false }
        keyDown(with: final)
        return true
    }

    // MARK: Menu actions

    @objc func copy(_ sender: Any?) { performBinding("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { performBinding("paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { performBinding("select_all") }

    func performBinding(_ action: String) {
        guard let surface else { return }
        let len = action.utf8.count
        action.withCString { _ = ghostty_surface_binding_action(surface, $0, UInt(len)) }
    }
}

// MARK: - NSTextInputClient

extension TerminalView: NSTextInputClient {
    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSAttributedString(string: String(cString: text.text))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(origin: frame.origin, size: .zero) }
        var x: Double = 0, y: Double = 0
        var w: Double = cellSize.width, h: Double = cellSize.height
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        if range.length == 0, w > 0 {
            w = 0
            x += cellSize.width * Double(range.location + range.length)
        }
        let viewRect = NSRect(x: x, y: frame.height - y, width: w, height: max(h, cellSize.height))
        let winRect = convert(viewRect, to: nil)
        return window?.convertToScreen(winRect) ?? winRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        unmarkText()
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }
        if !chars.isEmpty { committedText(GHOSTTY_ACTION_PRESS, chars) }
    }

    override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8.count
            str.withCString { ghostty_surface_preedit(surface, $0, UInt(len)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}
