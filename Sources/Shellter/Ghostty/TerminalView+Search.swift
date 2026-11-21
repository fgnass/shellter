import AppKit
import Combine
import SwiftUI

/// Search state of one terminal. libghostty searches the screen and the scrollback;
/// Shellter only shows the bar and passes the text on.
final class TerminalSearch: ObservableObject {
    @Published var visible = false
    @Published var needle = ""
    /// Number of matches and the index of the selected one, as libghostty reports them.
    @Published var total: Int?
    @Published var selected: Int?
    /// Incremented to move the keyboard focus into the search field.
    @Published var focusRequest = 0
}

extension TerminalView {
    func startSearch() {
        search.visible = true
        search.focusRequest += 1
        if !search.needle.isEmpty { performBinding("search:\(search.needle)") }
    }

    func setSearchNeedle(_ needle: String) {
        search.needle = needle
        performBinding(needle.isEmpty ? "end_search" : "search:\(needle)")
        if needle.isEmpty { search.total = nil; search.selected = nil }
    }

    func searchNext() { performBinding("navigate_search:next") }
    func searchPrevious() { performBinding("navigate_search:previous") }

    func endSearch() {
        guard search.visible else { return }
        search.visible = false
        search.total = nil
        search.selected = nil
        performBinding("end_search")
        window?.makeFirstResponder(self)
    }
}

/// The find bar at the top right of the terminal.
struct SearchBar: View {
    @ObservedObject var search: TerminalSearch
    let terminal: TerminalView
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find", text: Binding(
                get: { search.needle },
                set: { terminal.setSearchNeedle($0) }
            ))
            .textFieldStyle(.plain)
            .focused($focused)
            .frame(minWidth: 140)
            .onKeyPress(.return, phases: .down) { press in
                press.modifiers.contains(.shift) ? terminal.searchPrevious() : terminal.searchNext()
                return .handled
            }
            .onExitCommand { terminal.endSearch() }
            Text(count)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            Button { terminal.searchPrevious() } label: { Image(systemName: "chevron.up") }
                .help("Previous Match (⇧⌘G)")
            Button { terminal.searchNext() } label: { Image(systemName: "chevron.down") }
                .help("Next Match (⌘G)")
            Button { terminal.endSearch() } label: { Image(systemName: "xmark") }
                .help("Close (Esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .onAppear { focused = true }
        .onChange(of: search.focusRequest) { focused = true }
    }

    private var count: String {
        guard !search.needle.isEmpty else { return "" }
        if let selected = search.selected, let total = search.total { return "\(selected + 1)/\(total)" }
        if let total = search.total { return total == 0 ? "No matches" : "\(total)" }
        return ""
    }
}
