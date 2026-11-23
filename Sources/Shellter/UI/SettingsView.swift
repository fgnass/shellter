import SwiftUI
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController {
    private static let shared = SettingsWindowController()

    static func open() {
        shared.show()
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.setContentSize(NSSize(width: 760, height: 560))
        window.minSize = NSSize(width: 640, height: 440)
        window.setFrameAutosaveName("ShellterSettings")
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @State private var tab = UserDefaults.standard.string(forKey: "ShellterSettingsTab") ?? "font"

    var body: some View {
        TabView(selection: $tab) {
            FontSettingsView()
                .tabItem { Label("Font", systemImage: "textformat") }
                .tag("font")
            ThemeSettingsView()
                .tabItem { Label("Theme", systemImage: "paintpalette") }
                .tag("theme")
            WindowSettingsView()
                .tabItem { Label("Window", systemImage: "macwindow") }
                .tag("window")
        }
        .padding(16)
    }
}

// MARK: - Shared preview

/// Sample terminal output in the selected font and theme.
struct TerminalPreview: View {
    let family: String
    let size: Double
    let theme: TerminalTheme?

    private var bg: Color { theme.map { Color(nsColor: $0.background.color) } ?? Color(nsColor: GhosttyApp.shared.backgroundColor ?? .black) }
    private var fg: Color { theme.map { Color(nsColor: $0.foreground.color) } ?? .white }
    private func ansi(_ i: Int) -> Color {
        guard let theme else { return Color(nsColor: ThemeLibrary.defaultPalette(dark: true)[i].color) }
        return Color(nsColor: theme.palette[i].color)
    }

    var body: some View {
        let font = Font(FontLibrary.previewFont(family, size: size))
        VStack(alignment: .leading, spacing: 2) {
            (Text("~/projects/app ").foregroundColor(ansi(4)) + Text("on ").foregroundColor(fg)
                + Text("main ").foregroundColor(ansi(5)) + Text("❯ ").foregroundColor(ansi(2))
                + Text("npm run dev").foregroundColor(fg))
            (Text("  VITE ").foregroundColor(ansi(2)) + Text("ready in 312 ms").foregroundColor(fg))
            (Text("  ➜ Local: ").foregroundColor(fg) + Text("http://localhost:5173/").foregroundColor(ansi(6)))
            (Text("const ").foregroundColor(ansi(5)) + Text("ok").foregroundColor(fg)
                + Text(" = a !== b && c >= d || x => y").foregroundColor(ansi(3)))
            (Text("error ").foregroundColor(ansi(1)) + Text("warn ").foregroundColor(ansi(3))
                + Text("info ").foregroundColor(ansi(4)) + Text("// comment").foregroundColor(ansi(8)))
            HStack(spacing: 0) {
                ForEach(0..<16, id: \.self) { i in
                    Rectangle().fill(ansi(i)).frame(width: 18, height: 12)
                }
            }
            .padding(.top, 4)
        }
        .font(font)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// The theme that is active now (for previews).
private func currentTheme(_ s: AppearanceSettings) -> TerminalTheme? {
    let lib = ThemeLibrary.shared
    if s.state.followEditor != nil { return lib.theme(id: s.followedThemes.dark) }
    return lib.theme(id: s.state.darkThemeID)
}

// MARK: - Font

struct FontSettingsView: View {
    @ObservedObject private var settings = AppearanceSettings.shared
    @State private var installed: [FontFamily] = []

    private var selected: String { settings.state.fontFamily ?? FontLibrary.defaultFamily }
    private var size: Double { settings.state.fontSize ?? 13 }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            SelectableList(
                sections: [ListSection(id: "bundled", title: "Bundled", items: FontLibrary.bundledFamilies)]
                    + (installed.isEmpty ? [] : [ListSection(id: "installed", title: "Installed", items: installed)]),
                selection: selected,
                onSelect: { name in
                    settings.state.fontFamily = name == FontLibrary.defaultFamily ? nil : name
                },
                row: { row($0) }
            )
            .frame(width: 260)

            VStack(alignment: .leading, spacing: 14) {
                Text(FontFamily(name: selected, bundled: true, ligatures: false).displayName)
                    .font(.title2.weight(.semibold))
                HStack {
                    Text("Size")
                    Slider(value: Binding(get: { size }, set: { settings.state.fontSize = $0.rounded() }),
                           in: 9...24, step: 1)
                    Stepper("\(Int(size)) pt", value: Binding(
                        get: { size }, set: { settings.state.fontSize = $0 }), in: 9...24, step: 1)
                        .frame(width: 90)
                }
                Toggle("Ligatures (→ != >= =>)", isOn: Binding(
                    get: { settings.state.ligatures }, set: { settings.state.ligatures = $0 }))
                TerminalPreview(family: selected, size: size, theme: currentTheme(settings))
                Text("Nerd Font icons work with every font. Shellter includes the icon glyphs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .onAppear { FontLibrary.loadInstalledMonospaceFamilies { installed = $0 } }
    }

    private func row(_ f: FontFamily) -> some View {
        HStack {
            Text(f.displayName).font(Font(FontLibrary.previewFont(f.name, size: 13)))
            Spacer()
            if f.ligatures {
                Text("ligatures").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Window

struct WindowSettingsView: View {
    @ObservedObject private var settings = AppearanceSettings.shared
    @ObservedObject private var layout = SidebarSettings.shared
    @ObservedObject private var chrome = WindowChrome.shared
    @State private var axAccess = LinkedWindows.hasAccess

    private var opacity: Double { settings.state.backgroundOpacity ?? chrome.opacity }
    private var blur: Int { settings.state.backgroundBlur ?? chrome.blur }
    private var material: Bool { (settings.state.sidebarStyle ?? .terminal).effective == .system }

    var body: some View {
        Form {
            Section {
                Picker("Sidebar", selection: Binding(
                    get: { (settings.state.sidebarStyle ?? .terminal).effective },
                    set: { settings.state.sidebarStyle = $0 == .terminal ? nil : $0 }
                )) {
                    ForEach(AppearanceSettings.SidebarStyle.available) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(AppearanceSettings.SidebarStyle.available.contains(.floating)
                     ? "Terminal colors: the sidebar has the background color of the theme. "
                        + "macOS sidebar: the translucent system sidebar. "
                        + "Floating glass: a glass panel over the terminal background."
                     : "Terminal colors: the sidebar has the background color of the theme. "
                        + "macOS sidebar: the translucent system sidebar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Tabs") {
                Picker("Projects", selection: $layout.groupStyle) {
                    ForEach(SidebarSettings.GroupStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Toggle("Condensed tab titles", isOn: $layout.condensedTitles)
                Text("Condensed titles fit about 20 % more text in a row.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("Windows of other apps") {
                    if axAccess {
                        Text("On").foregroundStyle(.secondary)
                    } else {
                        Button("Allow Access…") { LinkedWindows.requestAccess() }
                    }
                }
                Text("Below its tabs, a project lists the apps that its programs started (e.g. the "
                     + "browser of a coding agent). With Accessibility access, it also lists windows "
                     + "that show files of the project. A click brings the window to the front.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                if axAccess != LinkedWindows.hasAccess { axAccess = LinkedWindows.hasAccess }
            }
            Section("Transparency") {
                LabeledContent("Background opacity") {
                    HStack {
                        Slider(value: Binding(
                            get: { opacity },
                            set: { settings.state.backgroundOpacity = ($0 * 100).rounded() / 100 }
                        ), in: 0.3...1)
                        Text("\(Int((opacity * 100).rounded())) %")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                if !material {
                    LabeledContent("Blur") {
                        HStack {
                            Slider(value: Binding(
                                get: { Double(blur) },
                                set: { settings.state.backgroundBlur = Int($0.rounded()) }
                            ), in: 0...60)
                            Text("\(blur)")
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .disabled(opacity >= 1)
                }
                Text(material
                     ? "The terminal gets the same frosted material as the macOS sidebar, "
                        + "tinted with the theme background. Lower opacity: more material, less theme color."
                     : "The desktop and other windows show through the terminal and the sidebar. "
                        + "Blur makes text easier to read. Full screen is always opaque.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Theme

struct ThemeSettingsView: View {
    @ObservedObject private var settings = AppearanceSettings.shared
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var editingLight = false
    @State private var loaded = false
    @State private var importError: String?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", dark = "Dark", light = "Light"
        var id: String { rawValue }
    }

    private var lib: ThemeLibrary { ThemeLibrary.shared }
    private var editors: [Editor] { lib.editors }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourcePicker
            if let editor = settings.followedEditor {
                followInfo(editor)
            } else {
                chooser
            }
        }
        .onAppear {
            lib.loadIfNeeded()
            loaded = true
        }
        .alert("Import failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var sourcePicker: some View {
        Picker("Theme source", selection: Binding(
            get: { settings.state.followEditor ?? "" },
            set: { settings.state.followEditor = $0.isEmpty ? nil : $0 }
        )) {
            Text("Choose in Shellter").tag("")
            ForEach(editors) { e in Text("Same as \(e.name)").tag(e.name) }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 360)
    }

    private func followInfo(_ editor: Editor) -> some View {
        let dark = lib.theme(id: settings.followedThemes.dark)
        let light = lib.theme(id: settings.followedThemes.light)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Shellter uses the color theme of \(editor.name) and follows every change you make there.")
                .foregroundStyle(.secondary)
            if let dark {
                LabeledContent(light == nil ? "Theme" : "Dark", value: dark.name)
            } else {
                Text("The theme of \(editor.name) was not found.").foregroundStyle(.orange)
            }
            if let light { LabeledContent("Light", value: light.name) }
            TerminalPreview(family: settings.state.fontFamily ?? FontLibrary.defaultFamily,
                            size: settings.state.fontSize ?? 13, theme: dark)
            Spacer()
        }
    }

    private var chooser: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 8) {
                HStack {
                    TextField("Search", text: $query).textFieldStyle(.roundedBorder)
                    Picker("", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
                SelectableList(
                    sections: themeSections,
                    selection: editingLight ? settings.state.lightThemeID : settings.state.darkThemeID,
                    onSelect: { id in
                        if editingLight { settings.state.lightThemeID = id } else { settings.state.darkThemeID = id }
                    },
                    row: { ThemeRow(theme: $0) }
                )
                .id(editingLight)   // scroll to the other selection
                HStack {
                    Button("Import…", action: importTheme)
                    Spacer()
                    Text("iTerm2, VS Code or Ghostty theme files").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 320)

            VStack(alignment: .leading, spacing: 14) {
                Toggle("Different theme in Light Mode", isOn: Binding(
                    get: { settings.state.separateLightTheme },
                    set: { settings.state.separateLightTheme = $0; if !$0 { editingLight = false } }))
                if settings.state.separateLightTheme {
                    Picker("", selection: $editingLight) {
                        Text("Dark Mode").tag(false)
                        Text("Light Mode").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                let shown = lib.theme(id: editingLight ? settings.state.lightThemeID : settings.state.darkThemeID)
                Text(shown?.name ?? "Ghostty default").font(.title2.weight(.semibold))
                TerminalPreview(family: settings.state.fontFamily ?? FontLibrary.defaultFamily,
                                size: settings.state.fontSize ?? 13, theme: shown)
                Spacer()
            }
        }
    }

    private var themeSections: [ListSection<TerminalTheme>] {
        var out: [ListSection<TerminalTheme>] = []
        for e in editors {
            let list = filtered(lib.editorThemes[e.name] ?? [])
            if !list.isEmpty { out.append(ListSection(id: "editor:\(e.name)", title: "From \(e.name)", items: list)) }
        }
        let imported = filtered(lib.imported)
        if !imported.isEmpty { out.append(ListSection(id: "imported", title: "Imported", items: imported)) }
        let builtin = filtered(lib.builtin)
        if !builtin.isEmpty { out.append(ListSection(id: "builtin", title: "Built-in", items: builtin)) }
        return out
    }

    private func filtered(_ list: [TerminalTheme]) -> [TerminalTheme] {
        list.filter { t in
            (filter == .all || (filter == .dark) == t.isDark) &&
                (query.isEmpty || t.name.localizedCaseInsensitiveContains(query))
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a .itermcolors, VS Code theme (.json) or Ghostty theme file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let theme = try lib.importTheme(from: url)
            if editingLight { settings.state.lightThemeID = theme.id } else { settings.state.darkThemeID = theme.id }
        } catch {
            importError = "Shellter could not read colors from “\(url.lastPathComponent)”."
        }
    }
}

private struct ThemeRow: View {
    let theme: TerminalTheme

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach([1, 2, 3, 4, 5, 6], id: \.self) { i in
                    Circle().fill(Color(nsColor: theme.palette[i].color)).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(Color(nsColor: theme.background.color))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15)))
            Text(theme.name).lineLimit(1)
        }
    }
}
