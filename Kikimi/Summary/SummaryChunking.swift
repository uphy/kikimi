import Foundation

// MARK: - Array chunking helper

extension Array {
    /// Splits this array into consecutive chunks of at most `size` elements each. Used by
    /// `SummaryUpdater`'s §6 chunked full regeneration (`docs/design/04-summary-updater.md`). The
    /// last chunk may be smaller than `size`.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
