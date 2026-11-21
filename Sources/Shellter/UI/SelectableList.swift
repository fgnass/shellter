import SwiftUI

struct ListSection<Item: Identifiable>: Identifiable where Item.ID == String {
    let id: String
    let title: String
    let items: [Item]
}

/// A fast list with sections and single selection. SwiftUI's `List` visits every row on
/// each update, which is slow with hundreds of themes. This list builds visible rows only.
struct SelectableList<Item: Identifiable, Row: View>: View where Item.ID == String {
    let sections: [ListSection<Item>]
    let selection: String?
    let onSelect: (String) -> Void
    @ViewBuilder let row: (Item) -> Row

    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                rowView(item)
                            }
                        } header: {
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.background)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .onAppear {
                if let selection { proxy.scrollTo(selection, anchor: .center) }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1, proxy) }
            .onKeyPress(.downArrow) { move(1, proxy) }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
    }

    private func rowView(_ item: Item) -> some View {
        let selected = item.id == selection
        return row(item)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Color.accentColor.opacity(focused ? 0.3 : 0.18) : .clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                focused = true
                onSelect(item.id)
            }
            .id(item.id)
    }

    private func move(_ delta: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = sections.flatMap { $0.items.map(\.id) }
        guard !ids.isEmpty else { return .ignored }
        let index = selection.flatMap { ids.firstIndex(of: $0) }
        let next = index.map { min(max($0 + delta, 0), ids.count - 1) } ?? 0
        onSelect(ids[next])
        proxy.scrollTo(ids[next])
        return .handled
    }
}
