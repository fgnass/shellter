import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var layout = SidebarSettings.shared
    @ObservedObject private var projectColors = ProjectColors.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var dropTargeted = false
    /// The tab or project that a dragged sidebar item is over.
    @State private var dragTarget: String?

    var body: some View {
        // Cards or colored lines show which tabs belong to a project (Settings → Window).
        ScrollView {
            VStack(spacing: 8) {
                ForEach(store.groups) { group in
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
                            ForEach(group.sessions) { s in
                                HStack(spacing: 2) {
                                    LineMarker(session: s, color: Color(nsColor: group.color(dark: colorScheme == .dark)))
                                    row(for: s, icon: false)
                                }
                                .padding(.leading, 6)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
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

    private func rows(of group: SessionGroup) -> some View {
        ForEach(group.sessions) { s in row(for: s, icon: true) }
    }

    private func row(for s: Session, icon: Bool) -> some View {
        SidebarRow(selected: s.id == store.selectedID, targeted: dragTarget == "tab:\(s.id)") {
            TabRow(session: s, condensed: layout.condensedTitles, showIcon: icon)
        }
        .onTapGesture { store.select(s) }
        .contextMenu { menu(for: s) }
        // Drag a tab onto another tab of the same project to reorder.
        .draggable(SidebarDragItem(tab: s.id))
        .dropDestination(for: SidebarDragItem.self) { items, _ in
            guard let id = items.first?.tab else { return false }
            store.move(tab: id, to: s.id)
            return true
        } isTargeted: { over in
            if over { dragTarget = "tab:\(s.id)" } else if dragTarget == "tab:\(s.id)" { dragTarget = nil }
        }
    }

    /// Drag a project header onto another one to reorder the projects.
    private func header(of group: SessionGroup) -> some View {
        GroupHeader(group: group)
            .contextMenu { colorMenu(for: group) }
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(dragTarget == "group:\(group.id)" ? 0.2 : 0))
            )
            .contentShape(Rectangle())
            .draggable(SidebarDragItem(group: group.id))
            .dropDestination(for: SidebarDragItem.self) { items, _ in
                guard let root = items.first?.group else { return false }
                store.move(group: root, to: group.id)
                return true
            } isTargeted: { over in
                if over { dragTarget = "group:\(group.id)" } else if dragTarget == "group:\(group.id)" { dragTarget = nil }
            }
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
            segment
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
