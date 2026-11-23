import Combine
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var layout = SidebarSettings.shared
    @ObservedObject private var projectColors = ProjectColors.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var dropTargeted = false
    /// The item that the user drags inside the sidebar.
    @State private var dragging: SidebarDragItem?
    /// The drop zones under a dragged sidebar item, with the project of each zone.
    /// Nested zones (a tab row in a project) can both be targeted, so this is not one value.
    @State private var dropZones: [String: String] = [:]
    /// The title bar over the sidebar and the New Tab button below it.
    @State private var insets = EdgeInsets()
    /// Tabs that need input but are scrolled out of view. Not observed here: it changes
    /// while the user scrolls, and only the hints must update then.
    @State private var hiddenWaiting = HiddenWaitingTabs()

    var body: some View {
        // Cards or colored lines show which tabs belong to a project (Settings → Window).
        ScrollViewReader { proxy in scrollArea(proxy) }
        .background(SidebarBackground())
        .focusable(false)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { store.newTab() } label: {
                    Label("New Tab", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Tab (⌘T)")
                .focusable(false)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: openDropped)
    }

    private func scrollArea(_ proxy: ScrollViewProxy) -> some View {
        ScrollView { groupList }
        .scrollIndicators(.never)
        // Rows that scroll under the title bar or the New Tab button fade out, so they
        // do not collide with the traffic lights or the button (as in Apple Mail).
        .mask { EdgeFade(insets: insets) }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: {
            insets = $0
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { hiddenWaiting.setViewport($0) }
        // Tabs that need input above or below the visible area show a hint at that edge.
        .overlay(alignment: .top) {
            WaitingHint(tracker: hiddenWaiting, edge: .top) { store.selectedID = $0 }.offset(y: -4)
        }
        .overlay(alignment: .bottom) {
            WaitingHint(tracker: hiddenWaiting, edge: .bottom) { store.selectedID = $0 }.offset(y: 4)
        }
        .onAppear { hiddenWaiting.attach(store) }
        // The selected tab scrolls into view, e.g. after ⌘J or a click on a hint.
        .onChange(of: store.selectedID) { _, id in
            guard let id else { return }
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
        }
    }

    private var groupList: some View {
        VStack(spacing: 8) {
            ForEach(store.groups) { group in
                Group {
                switch layout.groupStyle {
                case .cards:
                    VStack(alignment: .leading, spacing: 1) {
                        header(of: group)
                        rows(of: group)
                    }
                    .padding(.horizontal, 3)
                    .padding(.bottom, 3)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                case .lines:
                    // The line in the project color runs below the project icon. Each tab
                    // sits on it with a marker: the agent icon or, for a shell, a dot.
                    VStack(alignment: .leading, spacing: 0) {
                        header(of: group)
                        let color = Color(nsColor: group.color(dark: colorScheme == .dark))
                        let windows = store.windows(of: group)
                        // The line ends at the marker of the last entry.
                        let lastTab = windows.isEmpty ? group.sessions.last?.id : nil
                        ForEach(group.sessions) { s in
                            HStack(spacing: 2) {
                                LineMarker(session: s, color: color, last: s.id == lastTab)
                                row(for: s, icon: false)
                            }
                            .padding(.leading, 6)
                        }
                        ForEach(windows) { w in
                            HStack(spacing: 2) {
                                WindowMarker(link: w.link, color: color, last: w.id == windows.last?.id)
                                windowRow(w, icon: false)
                            }
                            .padding(.leading, 6)
                        }
                    }
                }
                }
                .contentShape(Rectangle())
                .dropDestination(for: SidebarDragItem.self) { items, _ in
                    drop(items, on: group.id)
                } isTargeted: { setZone("group:\(group.id)", root: group.id, $0) }
                .overlay(alignment: insertEdge(at: group.id) ?? .top) {
                    if insertEdge(at: group.id) != nil {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(height: 3)
                            .padding(.horizontal, 2)
                            .offset(y: insertEdge(at: group.id) == .top ? -5.5 : 5.5)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// Opens a tab for each folder that the user dropped (for example from the Finder).
    private func openDropped(_ providers: [NSItemProvider]) -> Bool {
        let providers = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !providers.isEmpty else { return false }
        var urls = [URL?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        for (i, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    urls[i] = url
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            store.openDirectories(urls.compactMap { $0 })
            // The drag starts in another app: bring Shellter to the front for typing.
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    /// Starts a drag inside the sidebar. SwiftUI calls this when the drag starts.
    private func startDrag(_ item: SidebarDragItem) -> SidebarDragItem {
        dragging = item
        dropZones = [:]
        return item
    }

    private func setZone(_ key: String, root: String, _ over: Bool) {
        if over { dropZones[key] = root } else { dropZones[key] = nil }
    }

    /// A dragged project moves to the place of the project `target`. A dragged tab moves
    /// to the place of the tab `tab`, but only inside its own project.
    private func drop(_ items: [SidebarDragItem], on target: String, tab: UUID? = nil) -> Bool {
        defer { dragging = nil; dropZones = [:] }
        guard let item = items.first else { return false }
        if let root = item.group {
            store.move(group: root, to: target)
            return true
        }
        if let id = item.tab, let tab {
            store.move(tab: id, to: tab)
            return true
        }
        return false
    }

    /// Where the line shows that a dragged project lands: below the project `root` when
    /// the project moves down, above it when it moves up. Nil when `root` is not the target.
    private func insertEdge(at root: String) -> Alignment? {
        guard let moving = dragging?.group, moving != root,
              Set(dropZones.values) == [root] else { return nil }
        let ids = store.groups.map(\.id)
        guard let from = ids.firstIndex(of: moving), let to = ids.firstIndex(of: root) else { return nil }
        return from < to ? .bottom : .top
    }

    @ViewBuilder
    private func rows(of group: SessionGroup) -> some View {
        ForEach(group.sessions) { s in row(for: s, icon: true) }
        ForEach(store.windows(of: group)) { w in windowRow(w, icon: true) }
    }

    private func windowRow(_ w: ProjectWindow, icon: Bool) -> some View {
        SidebarRow(selected: false) {
            WindowRow(window: w, condensed: layout.condensedTitles, showIcon: icon)
        }
        .onTapGesture { LinkedWindows.show(w.link) }
        .contextMenu {
            Button("Show \(w.link.label)") { LinkedWindows.show(w.link) }
            if let doc = w.link.document {
                Button("Reveal in Finder") { NSWorkspace.shared.selectFile(doc, inFileViewerRootedAtPath: "") }
            }
            Button("Go to Tab") { store.select(w.session) }
        }
    }

    private func row(for s: Session, icon: Bool) -> some View {
        SidebarRow(selected: s.id == store.selectedID,
                   targeted: dragging?.tab != nil && dropZones["tab:\(s.id)"] != nil) {
            TabRow(session: s, condensed: layout.condensedTitles, showIcon: icon)
        }
        .id(s.id)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            hiddenWaiting.setFrame($0, for: s.id)
        }
        .onTapGesture { store.select(s) }
        .contextMenu { menu(for: s) }
        // Drag a tab onto another tab of the same project to reorder.
        // A project dropped on a tab moves to the place of the tab's project.
        .draggable(startDrag(SidebarDragItem(tab: s.id)))
        .dropDestination(for: SidebarDragItem.self) { items, _ in
            drop(items, on: s.projectRoot, tab: s.id)
        } isTargeted: { setZone("tab:\(s.id)", root: s.projectRoot, $0) }
    }

    /// Drag a project header onto another project to reorder the projects.
    private func header(of group: SessionGroup) -> some View {
        GroupHeader(group: group)
            .contextMenu { colorMenu(for: group) }
            .contentShape(Rectangle())
            .draggable(startDrag(SidebarDragItem(group: group.id)))
    }

    @ViewBuilder
    private func colorMenu(for group: SessionGroup) -> some View {
        let current = projectColors.hex(for: group.id)
        Menu("Project Color") {
            Toggle("Automatic", isOn: Binding(
                get: { current == nil },
                set: { if $0 { projectColors.set(nil, for: group.id) } }
            ))
            Divider()
            ForEach(ProjectColors.palette) { swatch in
                Toggle(isOn: Binding(
                    get: { current == swatch.hex },
                    set: { if $0 { projectColors.set(swatch.color, for: group.id) } }
                )) {
                    Label { Text(swatch.name) } icon: { Image(nsImage: ProjectColors.swatchImage(swatch.color)) }
                }
            }
            Divider()
            Button("Custom…") { projectColors.showColorPanel(for: group.id) }
        }
        Button("New Tab Here") { store.newTab(cwd: group.id) }
        // A fresh session of each agent that already runs in the project, in its root.
        let agents = Agent.allCases.filter { a in group.sessions.contains { $0.agent == a } }
        if let last = group.sessions.last {
            ForEach(agents, id: \.self) { agent in
                Button("New \(agent.name) Session") {
                    store.newAgentSession(next: last, agent: agent, cwd: group.id)
                }
            }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: group.id)
        }
    }

    private func rename(_ s: Session) {
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave the name empty to use the title from the shell again."
        let field = NSTextField(string: s.customTitle ?? s.title)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.rename(s, to: field.stringValue)
    }

    @ViewBuilder
    private func menu(for s: Session) -> some View {
        Button("New Tab Here") { store.newTab(cwd: s.cwd) }
        Button("Rename Tab…") { rename(s) }
        if let agent = s.agent {
            Button("New \(agent.name) Session") { store.newAgentSession(next: s) }
        }
        if let agent = s.agent, AgentSession.forkCommand(agent, session: s.agentSession) != nil {
            Button("Branch \(agent.name) Session") { store.branch(s) }
        }
        if let port = s.serverPort ?? s.ports.first {
            Button("Open localhost:\(port)") {
                NSWorkspace.shared.open(URL(string: "http://localhost:\(port)/")!)
            }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: s.cwd)
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s.cwd, forType: .string)
        }
        Divider()
        Button("Close Tab") { store.close(s) }
    }
}

extension SessionGroup {
    var icon: NSImage? { sessions.first?.dirIcon }
    func color(dark: Bool) -> NSColor { ProjectColor.of(image: icon, key: id, dark: dark) }
}

private struct GroupHeader: View {
    let group: SessionGroup

    var body: some View {
        HStack(spacing: 7) {
            ProjectIcon(image: group.icon, name: group.name, key: group.id, size: 20)
            Text(group.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .foregroundStyle(.secondary)
        .help(group.id)
    }
}

/// A tab or a project, dragged inside the sidebar to reorder it. Its own type keeps it
/// apart from folders dropped from the Finder.
struct SidebarDragItem: Codable, Transferable {
    var tab: UUID?
    var group: String?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .shellterSidebarItem)
    }
}

extension UTType {
    static let shellterSidebarItem = UTType(exportedAs: "com.fgnass.shellter.sidebar-item")
}

/// A row with hover, selection and drop-target highlight.
private struct SidebarRow<Content: View>: View {
    let selected: Bool
    var targeted = false
    @ViewBuilder let content: () -> Content
    @State private var hovered = false

    var body: some View {
        content()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(targeted ? Color.accentColor.opacity(0.2)
                          : Color.primary.opacity(selected ? 0.11 : (hovered ? 0.05 : 0)))
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

private struct TabRow: View {
    @ObservedObject var session: Session
    var condensed = false
    var showIcon = true

    private var width: Font.Width { condensed ? .condensed : .standard }

    var body: some View {
        HStack(spacing: 8) {
            if showIcon { TabIcon(session: session, size: 16) }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 13).width(width))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    subtitle
                        .font(.system(size: 10).width(width))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            StatusBadge(state: session.activity)
        }
        .padding(.vertical, 2)
        .help(session.cwd)
    }

    /// Path below the project root and server port, e.g. "src/app  :3000".
    private var subtitle: Text? {
        var parts: [String] = []
        let rel = relativePath
        if !rel.isEmpty { parts.append(rel) }
        if let port = session.serverPort ?? session.ports.first { parts.append(":\(port)") }
        return parts.isEmpty ? nil : Text(parts.joined(separator: "  "))
    }

    /// The cwd relative to the project root, if it differs.
    private var relativePath: String {
        let root = session.projectRoot, cwd = session.cwd
        guard cwd != root, cwd.hasPrefix(root + "/") else { return "" }
        return String(cwd.dropFirst(root.count + 1))
    }
}

/// A window of another app in the project: an app that a tab started (e.g. the browser
/// of a coding agent) or a file of the project that another app shows. One line, like a tab.
private struct WindowRow: View {
    let window: ProjectWindow
    var condensed = false
    var showIcon = true

    var body: some View {
        HStack(spacing: 8) {
            if showIcon { WindowIcon(link: window.link, size: 16) }
            Text(title)
                .font(.system(size: 13).width(condensed ? .condensed : .standard))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
        }
        .padding(.vertical, 2)
        .help(help)
    }

    private var title: String {
        window.link.document.map { ($0 as NSString).lastPathComponent } ?? window.link.appName
    }

    private var help: String {
        window.link.document.map { "\($0) in \(window.link.appName)" }
            ?? "\(window.link.appName), started by \(window.session.title)"
    }
}

struct WindowIcon: View {
    let link: LinkedWindow
    let size: CGFloat
    /// nil: the app icon in its own colors. Else gray tones of the icon in this color.
    var tint: Color? = nil

    var body: some View {
        Group {
            if let icon = link.icon {
                if let tint {
                    Image(nsImage: icon).resizable().interpolation(.high)
                        .saturation(0).brightness(0.15).colorMultiply(tint)
                } else {
                    Image(nsImage: icon).resizable().interpolation(.high)
                }
            } else {
                Image(systemName: "macwindow").resizable().scaledToFit().foregroundStyle(tint ?? .secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// In the lines layout, a window sits on the project line with its app icon.
private struct WindowMarker: View {
    let link: LinkedWindow
    let color: Color
    var last = false

    var body: some View {
        VStack(spacing: 0) {
            segment
            WindowIcon(link: link, size: 16, tint: color).padding(.vertical, 2)
            segment.opacity(last ? 0 : 1)
        }
        .frame(width: 20)
    }

    private var segment: some View {
        Rectangle().fill(color).frame(width: 2).frame(maxHeight: .infinity)
    }
}

struct StatusBadge: View {
    let state: ActivityState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .working:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 14, height: 14)
                .help("Working")
        case .needsInput:
            Image(systemName: "bell.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 14, height: 14)
                .help("Needs your input")
        }
    }
}

struct ProjectIcon: View {
    @ObservedObject private var colors = ProjectColors.shared
    let image: NSImage?
    let name: String
    let key: String
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: size * 0.25)
                    .fill(Color(nsColor: colors.color(for: key) ?? IconResolver.color(for: key)))
                    .overlay(
                        Text(String(name.prefix(1)).uppercased())
                            .font(.system(size: size * 0.6, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
    }
}

/// What runs in a tab: the agent's logo, else the favicon of a dev server, else a prompt symbol.
private struct TabIcon: View {
    @ObservedObject var session: Session
    let size: CGFloat

    var body: some View {
        Group {
            if let agent = session.agent {
                AgentIcon(agent: agent, size: size)
            } else if let favicon = session.serverIcon {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .help("Shell")
            }
        }
        .frame(width: 20)
    }
}

/// A tab's place on the project line: the agent icon in the project color, or a dot for a
/// shell. The line has a gap around the marker, so no background has to cover it.
private struct LineMarker: View {
    @ObservedObject var session: Session
    let color: Color
    var last = false

    var body: some View {
        VStack(spacing: 0) {
            segment
            Group {
                if let agent = session.agent {
                    AgentIcon(agent: agent, size: 14, tint: color)
                } else {
                    Circle().fill(color).frame(width: 6, height: 6)
                }
            }
            .padding(.vertical, 3)
            segment.opacity(last ? 0 : 1)
        }
        .frame(width: 20)
    }

    private var segment: some View {
        Rectangle().fill(color).frame(width: 2).frame(maxHeight: .infinity)
    }
}

/// The agent's logo, tinted in the agent's color.
struct AgentIcon: View {
    let agent: Agent
    let size: CGFloat
    /// nil: the agent's own color.
    var tint: Color? = nil

    var body: some View {
        Group {
            if let icon = agent.icon {
                Image(nsImage: icon)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Circle()
            }
        }
        .foregroundStyle(tint ?? Color(nsColor: agent.color))
        .frame(width: size, height: size)
        .help(agent.name)
    }
}

/// Finds the tabs that need input but are scrolled out of the sidebar's visible area
/// (above the title bar inset or below the New Tab bar).
final class HiddenWaitingTabs: ObservableObject {
    struct Hidden: Equatable {
        /// The nearest hidden tab in each direction, and how many tabs are hidden there.
        var above: UUID?
        var aboveCount = 0
        var below: UUID?
        var belowCount = 0
    }

    @Published private(set) var hidden = Hidden()
    private var frames: [UUID: CGRect] = [:]
    private var viewport = CGRect.infinite
    private weak var store: SessionStore?
    private var subscription: AnyCancellable?

    func attach(_ store: SessionStore) {
        guard self.store !== store else { return }
        self.store = store
        // The store changes when a tab starts or stops to need input.
        subscription = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.update() }
        update()
    }

    func setFrame(_ frame: CGRect, for id: UUID) { frames[id] = frame; update() }
    func setViewport(_ frame: CGRect) { viewport = frame; update() }

    private func update() {
        guard let store else { return }
        // Row and viewport frames are global: they stay correct while the list scrolls.
        // The scroll view's frame already excludes the title bar and the New Tab bar
        // (its safe area insets lie outside of it).
        let top = viewport.minY, bottom = viewport.maxY
        var h = Hidden()
        for s in store.sessions where s.activity == .needsInput {
            guard let f = frames[s.id] else { continue }
            if f.midY < top {
                h.aboveCount += 1
                if h.above.flatMap({ frames[$0] }).map({ f.midY > $0.midY }) ?? true { h.above = s.id }
            } else if f.midY > bottom {
                h.belowCount += 1
                if h.below.flatMap({ frames[$0] }).map({ f.midY < $0.midY }) ?? true { h.below = s.id }
            }
        }
        if h != hidden { hidden = h }
    }
}

/// A small capsule at the top or bottom edge of the sidebar: tabs that need input are
/// scrolled out of view there. A click selects the nearest of them.
private struct WaitingHint: View {
    @ObservedObject var tracker: HiddenWaitingTabs
    let edge: VerticalEdge
    let select: (UUID) -> Void

    var body: some View {
        let id = edge == .top ? tracker.hidden.above : tracker.hidden.below
        let count = edge == .top ? tracker.hidden.aboveCount : tracker.hidden.belowCount
        ZStack {
            if let id {
                Button { select(id) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bell.fill").foregroundStyle(.orange)
                        Text("\(count)").monospacedDigit()
                        Image(systemName: edge == .top ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.orange.opacity(0.6), lineWidth: 1))
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(count == 1 ? "A tab \(edge == .top ? "above" : "below") needs your input"
                                 : "\(count) tabs \(edge == .top ? "above" : "below") need your input")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: id)
    }
}

/// A mask that hides content under the title bar and the bottom bar, with a short fade.
private struct EdgeFade: View {
    let insets: EdgeInsets

    var body: some View {
        VStack(spacing: 0) {
            fade(insets.top, from: .top)
            Color.black
            fade(insets.bottom, from: .bottom)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func fade(_ inset: CGFloat, from edge: UnitPoint) -> some View {
        if inset > 0 {
            let gradient = LinearGradient(colors: [.clear, .black], startPoint: edge,
                                          endPoint: edge == .top ? .bottom : .top)
            VStack(spacing: 0) {
                // Fully opaque again at the first row (6 pt below the inset).
                if edge == .top { Color.clear.frame(height: max(0, inset - 6)) }
                gradient.frame(height: 12)
                if edge == .bottom { Color.clear.frame(height: max(0, inset - 6)) }
            }
        }
    }
}
