import FluidAudio
import Foundation
import os

#if canImport(Qwen3ASR)
import Qwen3ASR
#endif

/// Ahead-of-time download of whichever model the second pass will use
/// (`docs/design/45-qwen3-batch-decode.md` §5.1).
///
/// Covers **both** engines on purpose. Without this the multi-hundred-MB (Parakeet) or ~2.3GB
/// (Qwen3) fetch happens inside `TranscriptPipeline.prepare()`, i.e. when a meeting starts.
/// Recording is not blocked -- design 33 MT8 makes the acquire concurrent and falls back to
/// streaming text -- but the opening minutes silently get the worse transcript with nothing on
/// screen saying why. That failure mode is identical for Parakeet, so covering only Qwen3 here
/// would just move the surprise rather than remove it.
///
/// **Deliberately not an actor and not `@MainActor`.** Qwen3's `progressHandler` is a plain
/// (non-`Sendable`) closure invoked off the main actor; a closure written at a `@MainActor` call
/// site inherits that isolation and the resulting `dispatch_assert_queue` failure kills the
/// process with a bare SIGTRAP -- no message, no usable stack. Keeping this type non-isolated
/// means the closures built below are non-isolated too, and callers hop to the main actor
/// themselves. (FluidAudio's handler is already `@Sendable`, so only Qwen3 needs the care --
/// but a type that is safe for one and not the other would be a trap.)
enum BatchModelDownload {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "BatchModelDownload")

    /// Which weights a given `stt.batch_model` + `stt.language` pair resolves to. Mirrors
    /// `TranscriptPipeline.defaultBatchDecoderAcquire`'s dispatch so Settings can never report on
    /// a different model than the one a recording would load.
    enum Target {
        case qwen3(Qwen3Variant)
        /// Parakeet still picks its variant by language (`BatchAsrDecoder.resolveModelVersion`).
        case parakeet(AsrModelVersion)
    }

    static func target(batchModel: String, language: String) -> Target {
        #if canImport(Qwen3ASR)
        if let variant = Qwen3Variant(rawValue: batchModel) {
            return .qwen3(variant)
        }
        #endif
        return .parakeet(BatchAsrDecoder.resolveModelVersion(language: language))
    }

    /// Where the weights live. The two engines use different caches -- speech-swift keeps its own
    /// under `~/Library/Caches`, FluidAudio under `~/Library/Application Support` -- so this asks
    /// each library rather than hardcoding a shared root.
    static func cacheDirectory(for target: Target) -> URL? {
        switch target {
        case .qwen3(let variant):
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                return nil
            }
            return caches
                .appendingPathComponent("qwen3-speech/models")
                .appendingPathComponent(variant.modelId)
        case .parakeet(let version):
            return AsrModels.defaultCacheDirectory(for: version)
        }
    }

    /// Whether the weights are already on disk and usable.
    ///
    /// For Qwen3 this checks the weight file's size, not just the directory: an interrupted
    /// download leaves the directory and its small JSON companions behind, and reporting that as
    /// "ready" would send someone into a meeting still expecting a mid-session fetch. FluidAudio
    /// ships its own equivalent check, so that one is used rather than duplicated.
    static func isDownloaded(_ target: Target) -> Bool {
        guard let dir = cacheDirectory(for: target) else { return false }
        switch target {
        case .qwen3:
            let weights = dir.appendingPathComponent("model.safetensors")
            guard let size = try? FileManager.default
                .attributesOfItem(atPath: weights.path)[.size] as? Int64
            else { return false }
            return size > 100 * 1_024 * 1_024
        case .parakeet(let version):
            return AsrModels.modelsExist(at: dir, version: version)
        }
    }

    /// Bytes on disk, or nil when nothing is cached. Shown in Settings so the cost of switching
    /// models is visible before the switch.
    static func cachedBytes(_ target: Target) -> Int64? {
        guard isDownloaded(target), let dir = cacheDirectory(for: target) else { return nil }
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        else { return nil }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Every model the picker can select, in display order, for the "downloaded models" list.
    /// `language` only affects the Parakeet entry (it still resolves its variant by BCP-47
    /// subtag), so the list follows whatever the STT section currently has.
    static func allTargets(language: String) -> [(label: String, target: Target)] {
        var targets: [(String, Target)] = []
        #if canImport(Qwen3ASR)
        targets += Qwen3Variant.allCases.map { ($0.displayName, Target.qwen3($0)) }
        #endif
        targets.append(("Parakeet 日本語", .parakeet(BatchAsrDecoder.resolveModelVersion(language: language))))
        return targets
    }

    /// Deletes the cached weights.
    ///
    /// Only ever removes the resolved model directory, never a shared parent: FluidAudio keeps
    /// every model it manages (diarization, the streaming Nemotron, …) under one root, and
    /// deleting that root to reclaim one ASR model would silently take the rest with it.
    static func delete(_ target: Target) throws {
        guard let dir = cacheDirectory(for: target) else { return }
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
        logger.info("deleted cached model at \(dir.lastPathComponent, privacy: .public)")
    }

    /// Why a model must not be deleted right now, or nil when it is safe to remove.
    ///
    /// Dictation is checked separately from the meeting because it has its own model setting
    /// (design 45 §6.1) -- and it is the easy one to miss: with meetings on Qwen3 and dictation
    /// left on Parakeet, Parakeet is still live, and deleting it would work and then quietly
    /// re-download ~590MB on the next key-up.
    static func usageBlockingDeletion(
        _ target: Target,
        meetingBatchModel: String,
        meetingTwoPassDecode: Bool,
        dictationBatchModel: String,
        dictationEnabled: Bool,
        dictationTwoPassDecode: Bool,
        language: String
    ) -> String? {
        if meetingTwoPassDecode,
           isSameKind(target, self.target(batchModel: meetingBatchModel, language: language)) {
            return "使用中"
        }
        if dictationEnabled, dictationTwoPassDecode,
           isSameKind(target, self.target(batchModel: dictationBatchModel, language: language)) {
            return "ディクテーションで使用中"
        }
        return nil
    }

    /// `Target` cannot be `Equatable` for free -- FluidAudio's `AsrModelVersion` is not -- and the
    /// comparison only ever needs to say "same model", so it is spelled out.
    private static func isSameKind(_ lhs: Target, _ rhs: Target) -> Bool {
        switch (lhs, rhs) {
        case (.qwen3(let a), .qwen3(let b)): return a == b
        case (.parakeet(let a), .parakeet(let b)): return a == b
        default: return false
        }
    }

    /// Fetches the weights, reporting progress as a 0...1 fraction plus a status message.
    ///
    /// Qwen3 loads as well as downloads (speech-swift exposes no download-only entry point) and
    /// the loaded model is dropped immediately: the pool builds its own at recording start, and
    /// holding ~2.3GB resident after a Settings action the user may never follow with a meeting is
    /// worse than paying the -- now cached, therefore fast -- load again. FluidAudio does have a
    /// download-only call, so Parakeet uses it and never materialises a model here.
    static func download(
        _ target: Target,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        switch target {
        case .qwen3(let variant):
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
            throw BatchModelDownloadError.unavailableInThisBuild
            #endif
        case .parakeet(let version):
            logger.info("downloading parakeet \(String(describing: version), privacy: .public)")
            _ = try await AsrModels.download(version: version) { progress in
                onProgress(
                    min(max(progress.fractionCompleted, 0), 1),
                    String(describing: progress.phase))
            }
            logger.info("downloaded parakeet \(String(describing: version), privacy: .public)")
        }
    }
}

/// Separate from the enum so the `#else` branch above can throw something typed.
enum BatchModelDownloadError: LocalizedError {
    /// The SwiftPM build links no MLX (design 45 §4), so there is nothing to download.
    case unavailableInThisBuild

    var errorDescription: String? {
        switch self {
        case .unavailableInThisBuild:
            return "このビルドでは Qwen3 モデルを利用できません（Xcode ビルドが必要です）"
        }
    }
}
