import XCTest

final class ReorderTests: XCTestCase {
    private func move(_ items: [String], _ item: String, to target: String) -> [String]? {
        Reorder.move(items, id: { $0 }, item: item, to: target)
    }

    func testMoveDownLandsAfterTarget() {
        XCTAssertEqual(move(["a", "b", "c", "d"], "a", to: "c"), ["b", "c", "a", "d"])
    }

    func testMoveUpLandsBeforeTarget() {
        XCTAssertEqual(move(["a", "b", "c", "d"], "d", to: "b"), ["a", "d", "b", "c"])
    }

    func testDropOnNeighborSwaps() {
        XCTAssertEqual(move(["a", "b", "c"], "a", to: "b"), ["b", "a", "c"])
        XCTAssertEqual(move(["a", "b", "c"], "c", to: "b"), ["a", "c", "b"])
    }

    func testNoChange() {
        XCTAssertNil(move(["a", "b"], "a", to: "a"))
        XCTAssertNil(move(["a", "b"], "x", to: "a"))
    }
}
