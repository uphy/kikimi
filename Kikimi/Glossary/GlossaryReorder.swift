import Foundation

// MARK: - GlossaryReorder

/// Pure reordering logic for the 用語集 tab's drag-to-reorder feature (`docs/design/28-glossary.md`
/// §4.3). No SwiftUI dependency, so the index arithmetic below is unit-testable without a view host.
///
/// **Why entries move within absolute slots rather than being reassigned wholesale.** The visible rows
/// of the 用語集 tab are always a *bucket* (すべて / 未分類 / one category) intersected with a 絞り込み
/// query (`GlossaryCategoryDetailView.visibleIndices`). Writing a reordered *visible* list straight back
/// into `glossary` would scramble every entry that belongs to a different bucket -- their absolute
/// positions would have to shift to make room. The only well-defined operation is: permute the entries
/// that belong to the current bucket among themselves, and write the permuted values back into exactly
/// the absolute array slots those entries already occupied (`bucketIndices`, ascending). Every entry
/// outside the bucket never moves, in value or in position -- which is also why reordering is disabled
/// while a 絞り込み query narrows the visible set to less than the whole bucket (`docs/design/28-glossary.md`
/// §4.3): "insert before visible row N" would be ambiguous about where among the *hidden* bucket members
/// the entry should land.
///
/// **Array order is prompt order.** `GlossaryRenderer` walks `glossary` in array order within each
/// category (`docs/design/28-glossary.md` §2), so reordering here changes the order terms are listed to
/// the LLM within their category -- not merely a cosmetic Settings-UI affordance.
enum GlossaryReorder {
    /// Moves the entry at bucket position `from` to bucket position `to`, permuting only the entries at
    /// `bucketIndices` and leaving every other entry at its absolute position.
    ///
    /// **Destination convention (`onMove`-style, matching `List.onMove`/`IndexSet.move`):** `to` is the
    /// index, within the *pre-removal* bucket-ordered list, before which the entry should be inserted.
    /// Concretely, to swap an entry with its very next neighbor ("move down one"), pass `to: from + 2`
    /// -- not `from + 1` -- because removing the entry first shifts every later index left by one; when
    /// `from < to`, the effective post-removal insertion index is `to - 1`. A drop on the reorder
    /// separator directly after bucket position `p` (i.e. "insert here") should pass `to: p + 1` with no
    /// further adjustment -- that already is this convention.
    ///
    /// `bucketIndices` must be strictly ascending, duplicate-free indices into `entries` (exactly what
    /// `GlossaryCategorization` returns). `from` is a position within `bucketIndices`
    /// (`0..<bucketIndices.count`); `to` is a position in `0...bucketIndices.count` (the upper bound
    /// meaning "insert at the end of the bucket").
    ///
    /// Returns `entries` unchanged whenever the move would be a no-op (`from == to`, or the
    /// downward-adjacent case `to == from + 1`, which -- after the effective-index adjustment above --
    /// also puts the entry right back where it started) or the arguments are out of range: an empty or
    /// malformed `bucketIndices`, a single-element bucket (there is nowhere else to put the only entry),
    /// or `from`/`to` outside their valid ranges.
    static func reordered(entries: [GlossaryEntry], bucketIndices: [Int], from: Int, to: Int) -> [GlossaryEntry] {
        guard !bucketIndices.isEmpty,
              bucketIndices == bucketIndices.sorted(),
              Set(bucketIndices).count == bucketIndices.count,
              bucketIndices.allSatisfy(entries.indices.contains),
              bucketIndices.indices.contains(from),
              (0...bucketIndices.count).contains(to)
        else { return entries }

        // When moving forward (from < to), the entry's own removal shifts every later slot left by one,
        // so the destination expressed against the pre-removal list is one past where it actually lands.
        let effectiveTo = from < to ? to - 1 : to
        guard effectiveTo != from else { return entries }

        var bucketEntries = bucketIndices.map { entries[$0] }
        let moved = bucketEntries.remove(at: from)
        bucketEntries.insert(moved, at: effectiveTo)

        var result = entries
        for (position, absoluteIndex) in bucketIndices.enumerated() {
            result[absoluteIndex] = bucketEntries[position]
        }
        return result
    }
}
