import Foundation
import os

#if canImport(Qwen3ASR)
import Qwen3ASR
#endif

/// Ahead-of-time download of the Qwen3-ASR weights
/// (`docs/design/45-qwen3-batch-decode.md` §5.1).
///
/// Without this the ~2GB fetch happens inside `TranscriptPipeline.prepare()`, i.e. at the moment
/// a meeting starts. Recording is not blocked (design 33 MT8 makes the acquire concurrent and
/// falls back to streaming text), but the first minutes of that meeting silently get the *old*
/// transcription quality with nothing on screen saying why. Settings therefore offers an explicit
/// "download now" with progress, and shows whether the selected model is already resident.
///
/// **Deliberately not an actor and not `@MainActor`.** `Qwen3ASRModel.fromPretrained`'s
/// `progressHandler` is a plain (non-`Sendable`) closure invoked off the main actor. A closure
/// written at a `@MainActor` call site inherits that isolation, and the resulting
/// `swift_task_checkIsolated` → `dispatch_assert_queue` failure kills the process with a bare
/// SIGTRAP -- no message, no usable stack. Keeping the whole type non-isolated means the closure
/// built below is non-isolated too, and callers hop to the main actor themselves.
enum Qwen3ModelDownload {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "Qwen3ModelDownload")

    /// Where speech-swift caches weights, mirroring its own default
    /// (`~/Library/Caches/qwen3-speech/models/<org>/<name>`). Read rather than written here: this
    /// type never creates or deletes anything, it only reports what is present and asks the
    /// library to fetch.
    static func cacheDirectory(for variant: Qwen3Variant) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return caches
            .appendingPathComponent("qwen3-speech/models")
            .appendingPathComponent(variant.modelId)
    }

    /// Whether the weights are already on disk.
    ///
    /// Checks for the weight file specifically, not just the directory: an interrupted download
    /// leaves the directory and the small JSON companions behind, and reporting that as "ready"
    /// would send the user into a meeting still expecting a mid-session fetch.
    static func isDownloaded(variant: Qwen3Variant) -> Bool {
        guard let dir = cacheDirectory(for: variant) else { return false }
        let weights = dir.appendingPathComponent("model.safetensors")
        guard let size = try? FileManager.default.attributesOfItem(atPath: weights.path)[.size] as? Int64 else {
            return false
        }
        // Any real bundle is hundreds of MB; a truncated one is not usable.
        return size > 100 * 1_024 * 1_024
    }

    /// Bytes on disk for `variant`, or nil when nothing is cached. Shown in Settings so the user
    /// can see what a model costs before fetching another one.
    static func cachedBytes(variant: Qwen3Variant) -> Int64? {
        guard isDownloaded(variant: variant), let dir = cacheDirectory(for: variant) else { return nil }
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        else { return nil }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    /// Downloads (and loads, then discards) the weights, reporting progress as a 0...1 fraction
    /// plus the library's own status message.
    ///
    /// It loads rather than merely fetching because speech-swift exposes no download-only entry
    /// point. The loaded model is dropped immediately: the pool builds its own when a recording
    /// starts, and holding ~2GB resident from a Settings action the user may not follow with a
    /// meeting is worse than paying the (cached, therefore fast) load again.
    static func download(
        variant: Qwen3Variant,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        #if canImport(Qwen3ASR)
        logger.info("downloading \(variant.modelId, privacy: .public)")
        _ = try await Qwen3ASRModel.fromPretrained(
            modelId: variant.modelId,
            progressHandler: { fraction, message in
                onProgress(min(max(fraction, 0), 1), message)
            }
        )
        logger.info("downloaded \(variant.modelId, privacy: .public)")
        #else
        throw Qwen3ModelDownloadError.unavailableInThisBuild
        #endif
    }
}

/// Separate from the enum so the `#else` branch above can throw something typed.
enum Qwen3ModelDownloadError: LocalizedError {
    /// The SwiftPM build links no MLX (design 45 §4), so there is nothing to download.
    case unavailableInThisBuild

    var errorDescription: String? {
        switch self {
        case .unavailableInThisBuild:
            return "このビルドでは Qwen3 モデルを利用できません（Xcode ビルドが必要です）"
        }
    }
}
