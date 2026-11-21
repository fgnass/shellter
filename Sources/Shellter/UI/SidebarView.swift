import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var layout = SidebarSettings.shared
    @State private var dropTargeted = false

    var body: some View {
        // Cards or colored lines show which tabs belong to a project (Settings → Window).
        ScrollView {
            VStack(spacing: 8) {
                ForEach(store.groups) { group in
                    switch layout.groupStyle {
                    case .cards:
                        VStack(alignment: .leading, spacing: 1) {
                            GroupHeader(group: group)
                            rows(of: group)
                        }
                        .padding(.horizontal, 3)
                        .padding(.bottom, 3)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                    case .lines:
                        // The line in the project color runs below the project icon. Each tab
                        // sits on it with a marker: the agent icon or, for a shell, a dot.
                        VStack(alignment: .leading, spacing: 0) {
                            GroupHeader(group: group)
                            ForEach(group.sessions) { s in
                                HStack(spacing: 2) {
                                    LineMarker(session: s, color: Color(nsColor: group.color))
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
        SidebarRow(selected: s.id == store.selectedID) {
            TabRow(session: s, condensed: layout.condensedTitles, showIcon: icon)
        }
        .onTapGesture { store.select(s) }
        .contextMenu { menu(for: s) }
    }

    @ViewBuilder
    private func menu(for s: Session) -> some View {
        Button("New Tab Here") { store.newTab(cwd: s.cwd) }
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
    var color: NSColor { ProjectColor.of(image: icon, key: id) }
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

/// A row with hover and selection highlight.
private struct SidebarRow<Content: View>: View {
    let selected: Bool
    @ViewBuilder let content: () -> Content
    @State private var hovered = false

    var body: some View {
        content()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(selected ? 0.11 : (hovered ? 0.05 : 0)))
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
                    .fill(Color(nsColor: IconResolver.color(for: key)))
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
        Rectangle().fill(color.opacity(0.75)).frame(width: 2).frame(maxHeight: .infinity)
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
