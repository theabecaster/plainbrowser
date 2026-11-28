#if canImport(UIKit)
import UIKit

/// Drag to reorder in the tab strip and the sidebar, where the diffable data source moves the
/// cells itself (`reorderingHandlers`). Its `didReorder` runs inside UIKit's own commit of the
/// move: applying a snapshot there throws (the TestFlight crash of build 2611280102), so the lists
/// only tell the store there and show the store's order on the next turn of the main queue.
enum TabListReorder {
    struct Move: Equatable {
        let id: UUID
        /// The tab's place in its own list (section), as the strip or sidebar shows it.
        let index: Int
    }

    static func moves(in transaction: NSDiffableDataSourceTransaction<Int, UUID>) -> [Move] {
        moves(transaction.difference, from: transaction.initialSnapshot, to: transaction.finalSnapshot)
    }

    /// The tab a finished reorder moved, with its final place, to tell the store. A drag carries
    /// one tab (`itemsForBeginning` gives one item), so there is one move. A tab that changed
    /// lists is left out: a regular tab never becomes private, or the reverse.
    static func moves(
        _ difference: CollectionDifference<UUID>,
        from initial: NSDiffableDataSourceSnapshot<Int, UUID>,
        to final: NSDiffableDataSourceSnapshot<Int, UUID>
    ) -> [Move] {
        difference.insertions.compactMap { change in
            guard case let .insert(_, id, _) = change,
                  let section = final.sectionIdentifier(containingItem: id),
                  initial.sectionIdentifier(containingItem: id) == section,
                  let index = final.itemIdentifiers(inSection: section).firstIndex(of: id) else { return nil }
            return Move(id: id, index: index)
        }
    }
}
#endif
