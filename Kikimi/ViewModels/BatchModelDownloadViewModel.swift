import Foundation
import SwiftUI

/// Drives the batch-model download row in Settings
/// (`docs/design/45-qwen3-batch-decode.md` §5.1).
///
/// Bridges `Qwen3ModelDownload`, which is deliberately non-isolated (its progress callback is
/// invoked off the main actor and inheriting `@MainActor` there crashes the process), to the
/// `@Published` state SwiftUI observes. Every hop back to the main actor happens here, in one
/// place, rather than in the view.
@MainActor
final class BatchModelDownloadViewModel: ObservableObject {
    enum Phase: Equatable {
        /// Not checked yet, or the selected model is not a Qwen3 one (`parakeet-ja`).
        case notApplicable
        case missing
        case downloading(fraction: Double, message: String)
        case ready(bytes: Int64?)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .notApplicable

    /// The variant the row is currently describing, so a config change mid-download is visible
    /// rather than silently attributing the progress to the newly-selected model.
    private var variant: Qwen3Variant?
    private var downloadTask: Task<Void, Never>?

    var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    /// Re-reads disk state for `batchModel`. Cheap (a stat plus, when present, one directory
    /// walk), so the view can call it on appear and on every model-selection change.
    func refresh(batchModel: String) {
        guard let variant = Qwen3Variant(rawValue: batchModel) else {
            self.variant = nil
            // Cancel rather than leave an orphan download running for a model the user just
            // switched away from -- it would keep writing progress into a row nobody is reading.
            downloadTask?.cancel()
            downloadTask = nil
            phase = .notApplicable
            return
        }
        self.variant = variant
        guard !isDownloading else { return }
        phase = Qwen3ModelDownload.isDownloaded(variant: variant)
            ? .ready(bytes: Qwen3ModelDownload.cachedBytes(variant: variant))
            : .missing
    }

    func startDownload() {
        guard let variant, !isDownloading else { return }
        phase = .downloading(fraction: 0, message: "準備中…")
        downloadTask = Task { [weak self] in
            do {
                try await Qwen3ModelDownload.download(variant: variant) { fraction, message in
                    // The callback arrives off the main actor; this is the single hop back.
                    Task { @MainActor [weak self] in
                        guard let self, self.isDownloading else { return }
                        self.phase = .downloading(fraction: fraction, message: message)
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.phase = .ready(bytes: Qwen3ModelDownload.cachedBytes(variant: variant))
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
            await MainActor.run { [weak self] in self?.downloadTask = nil }
        }
    }

    /// Human-readable size for the ready state. `nil` bytes prints nothing rather than "0 MB",
    /// which would read as "downloaded but empty".
    static func formatBytes(_ bytes: Int64?) -> String? {
        guard let bytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
