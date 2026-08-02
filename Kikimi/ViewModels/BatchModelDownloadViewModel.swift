import Foundation
import SwiftUI

/// Drives the batch-model download row in Settings
/// (`docs/design/45-qwen3-batch-decode.md` §5.1).
///
/// Bridges `BatchModelDownload`, which is deliberately non-isolated (Qwen3's progress callback is
/// invoked off the main actor and inheriting `@MainActor` there crashes the process), to the
/// `@Published` state SwiftUI observes. Every hop back to the main actor happens here, in one
/// place, rather than in the view.
@MainActor
final class BatchModelDownloadViewModel: ObservableObject {
    enum Phase: Equatable {
        /// Nothing to report -- only reached when the second pass is off entirely.
        case notApplicable
        case missing
        case downloading(fraction: Double, message: String)
        case ready(bytes: Int64?)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .notApplicable

    /// What the row is currently describing, so a config change mid-download is visible rather
    /// than silently attributing the progress to the newly-selected model.
    private var target: BatchModelDownload.Target?
    private var downloadTask: Task<Void, Never>?

    var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    /// Re-reads disk state for the model `batchModel`/`language` resolve to. Cheap (a stat plus,
    /// when present, one directory walk), so the view can call it on appear and on every
    /// model-selection change.
    ///
    /// Covers Parakeet as well as Qwen3: it needs its own ~600MB fetch on a fresh machine, and
    /// hiding that just relocates the mid-meeting surprise instead of removing it.
    func refresh(batchModel: String, language: String) {
        // Cancel rather than leave an orphan download running for a model the user just switched
        // away from -- it would keep writing progress into a row describing something else.
        if isDownloading, changedTarget(batchModel: batchModel, language: language) {
            downloadTask?.cancel()
            downloadTask = nil
        }
        let target = BatchModelDownload.target(batchModel: batchModel, language: language)
        self.target = target
        self.currentKey = key(batchModel: batchModel, language: language)
        guard !isDownloading else { return }
        phase = BatchModelDownload.isDownloaded(target)
            ? .ready(bytes: BatchModelDownload.cachedBytes(target))
            : .missing
    }

    /// `BatchModelDownload.Target` wraps FluidAudio's `AsrModelVersion`, which is not `Hashable`,
    /// so identity is tracked with the config strings that produced it instead.
    private var currentKey: String?

    private func key(batchModel: String, language: String) -> String {
        "\(batchModel)|\(language)"
    }

    private func changedTarget(batchModel: String, language: String) -> Bool {
        currentKey != key(batchModel: batchModel, language: language)
    }

    func startDownload() {
        guard let target, !isDownloading else { return }
        phase = .downloading(fraction: 0, message: "準備中…")
        downloadTask = Task { [weak self] in
            do {
                try await BatchModelDownload.download(target) { fraction, message in
                    // The callback arrives off the main actor; this is the single hop back.
                    Task { @MainActor [weak self] in
                        guard let self, self.isDownloading else { return }
                        self.phase = .downloading(fraction: fraction, message: message)
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.phase = .ready(bytes: BatchModelDownload.cachedBytes(target))
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
