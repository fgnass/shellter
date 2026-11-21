/// Drag-and-drop reordering in the sidebar.
enum Reorder {
    /// Moves the element `item` to the place of `target`. Moved down it lands after the
    /// target, moved up before it, so a drop on the neighbor swaps the two.
    /// Returns nil when nothing changes.
    static func move<T, ID: Equatable>(_ items: [T], id: (T) -> ID, item: ID, to target: ID) -> [T]? {
        guard item != target,
              let from = items.firstIndex(where: { id($0) == item }),
              let to = items.firstIndex(where: { id($0) == target }) else { return nil }
        var result = items
        let element = result.remove(at: from)
        let index = result.firstIndex(where: { id($0) == target })! + (from < to ? 1 : 0)
        result.insert(element, at: index)
        return result
    }
}
