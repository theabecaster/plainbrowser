#if canImport(UIKit)
import UIKit
import XCTest
@testable import TabGalleryUI

/// The strip's and sidebar's reorder: what the store is told when UIKit commits a move
/// (TestFlight 2611280102 crashed applying a snapshot inside that commit).
@MainActor
final class TabListReorderTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), p = UUID(), q = UUID()

    private func snapshot(_ regular: [UUID], _ privateTabs: [UUID]) -> NSDiffableDataSourceSnapshot<Int, UUID> {
        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(regular, toSection: 0)
        if !privateTabs.isEmpty {
            snapshot.appendSections([1])
            snapshot.appendItems(privateTabs, toSection: 1)
        }
        return snapshot
    }

    private func moves(
        _ initial: NSDiffableDataSourceSnapshot<Int, UUID>, _ final: NSDiffableDataSourceSnapshot<Int, UUID>
    ) -> [TabListReorder.Move] {
        TabListReorder.moves(final.itemIdentifiers.difference(from: initial.itemIdentifiers), from: initial, to: final)
    }

    /// Each move, told in order to a list that moves one tab at a time, gives the final order.
    private func replay(_ moves: [TabListReorder.Move], on lists: [[UUID]]) -> [[UUID]] {
        var lists = lists
        for move in moves {
            guard let list = lists.firstIndex(where: { $0.contains(move.id) }) else { continue }
            lists[list].removeAll { $0 == move.id }
            lists[list].insert(move.id, at: min(move.index, lists[list].count))
        }
        return lists
    }

    func testAMoveIsItsPlaceInItsOwnList() {
        let initial = snapshot([a, b, c, d], [p, q])
        for (regular, privateTabs) in [([b, c, a, d], [p, q]), ([d, a, b, c], [p, q]), ([a, b, c, d], [q, p]), ([b, a, c, d], [p, q])] {
            let final = snapshot(regular, privateTabs)
            let found = moves(initial, final)
            XCTAssertFalse(found.isEmpty)
            XCTAssertEqual(replay(found, on: [[a, b, c, d], [p, q]]), [regular, privateTabs])
        }
    }

    func testATabThatChangedListsIsNotMoved() {
        let initial = snapshot([a, b, c], [p])
        XCTAssertEqual(moves(initial, snapshot([a, b], [c, p])), [])
        XCTAssertEqual(moves(initial, snapshot([a, p, b, c], [])), [])
    }
}
#endif
