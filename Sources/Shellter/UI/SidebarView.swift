import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        List(selection: Binding(
            get: { store.selectedID },
            set: { if let id = $0 { store.selectedID = id } }
        )) {
            ForEach(store.groups) { group in
                Section {
                    ForEach(group.sessions) { s in
                        TabRow(session: s)
                            .tag(s.id)
                            .contextMenu { menu(for: s) }
                    }
                } header: {
                    GroupHeader(group: group)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
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

private struct GroupHeader: View {
    let group: SessionGroup

    var body: some View {
        HStack(spacing: 6) {
            ProjectIcon(image: group.sessions.first?.dirIcon, name: group.name, key: group.id, size: 14)
            Text(group.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(group.id)
    }
}

private struct TabRow: View {
    @ObservedObject var session: Session

    var body: some View {
        HStack(spacing: 8) {
            ProjectIcon(image: session.icon, name: session.projectName, key: session.projectRoot, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            StatusBadge(state: session.activity)
        }
        .padding(.vertical, 2)
        .help(session.cwd)
    }

    private var subtitle: String? {
        var parts: [String] = []
        let rel = relativePath
        if !rel.isEmpty { parts.append(rel) }
        if let port = session.serverPort ?? session.ports.first { parts.append(":\(port)") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
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
