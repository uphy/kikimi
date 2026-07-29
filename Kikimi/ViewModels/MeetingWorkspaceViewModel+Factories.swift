import Foundation

// MARK: - MeetingWorkspaceViewModel.AudioCaptureFactory / TranscriptPipelineFactory defaults
//
// Split into its own file (alongside `MeetingWorkspaceViewModel.swift`'s other extensions, e.g.
// `+Prep.swift`/`+AudioInput.swift`) to keep `MeetingWorkspaceViewModel.swift` under the project's
// `file_length` lint limit. `defaultAudioCaptureFactory` lives in
// `MeetingWorkspaceViewModel+AudioInput.swift` instead of here: it constructs `AudioCapture` from
// an `AudioInputSelection`, so it stayed alongside the rest of that feature's logic.

extension MeetingWorkspaceViewModel {
    /// Production default for `transcriptPipelineFactory`: a real `TranscriptPipeline` with an
    /// `SttEngineConfig` whose `language`/`chunkMs`/`segmentIdleTimeout`/`maxSegmentCharacters`/
    /// `twoPassDecode` all come from `AppConfig.shared.data.stt` (`docs/design/11-streaming-stt.md`
    /// section 3.9; `twoPassDecode` per `docs/design/33-meeting-two-pass-decode.md` §4/MT10), rather
    /// than `SttEngineConfig`'s own struct-literal defaults. `twoPassDecode` is a recording-start
    /// snapshot like the other fields here -- a mid-recording Settings toggle only takes effect on
    /// the next recording (MT10).
    ///
    /// - Parameter startMsOffset: The recording segment's `RecordingSegment.startMsOffset`
    ///   (kikimi.md 5/6 章), forwarded unchanged to `TranscriptPipeline.init`.
    static func defaultTranscriptPipelineFactory(_ sessionHandle: SessionHandle, _ startMsOffset: Int) -> RecordingTranscriptPipelining {
        let sttConfig = AppConfig.shared.data.stt
        var engineConfig = SttEngineConfig()
        engineConfig.language = sttConfig.language
        engineConfig.chunkMs = sttConfig.chunkMs
        engineConfig.segmentIdleTimeout = sttConfig.segmentIdleTimeout
        engineConfig.maxSegmentCharacters = sttConfig.maxSegmentCharacters
        engineConfig.twoPassDecode = sttConfig.twoPassDecode
        return TranscriptPipeline(sessionHandle: sessionHandle, startMsOffset: startMsOffset, config: engineConfig)
    }

    /// Production default for `summaryUpdaterFactory`: a real `SummaryUpdater` using `LLMClient
    /// .shared` and `AppConfig.shared.data.summary` (`docs/design/04-summary-updater.md` section 7/§8,
    /// same "config.yaml 対応で先行させる" rationale `defaultRefinementQueueFactory` below documents for
    /// `AppConfig.shared.data.refinement`). `KIKIMI_STUB_LLM` is handled internally by `LLMClient`, not
    /// here (`Kikimi/LLM/LLMClient.swift`).
    ///
    /// `docs/design/16-llm-usage-stats.md` section 3: `LLMClient.shared` is wrapped in
    /// `UsageRecordingLLM` so every summary/title call this session makes gets its token usage
    /// recorded to `llm_usage.jsonl`, without `SummaryUpdater` itself knowing that decorator exists.
    @MainActor
    static func defaultSummaryUpdaterFactory(_ sessionHandle: SessionHandle) -> SummaryUpdater {
        SummaryUpdater(
            sessionHandle: sessionHandle,
            llm: UsageRecordingLLM(base: LLMClient.shared, sessionHandle: sessionHandle),
            config: AppConfig.shared.data.summary
        )
    }

    /// Production default for `refinementQueueFactory`: a real `RefinementQueue` using `LLMClient
    /// .shared` and `AppConfig.shared.data.refinement` (`docs/design/03-refinement-batch.md` §8,
    /// same "config.yaml 対応で先行させる" rationale `defaultDiarizationCoordinatorFactory` documents for
    /// `AppConfig.shared.data.diarization`). `KIKIMI_STUB_LLM` is handled internally by `LLMClient`,
    /// not here, same as `defaultSummaryUpdaterFactory` above.
    ///
    /// `docs/design/16-llm-usage-stats.md` section 3: `LLMClient.shared` is wrapped in
    /// `UsageRecordingLLM`, same rationale as `defaultSummaryUpdaterFactory` above.
    ///
    /// `docs/design/28-glossary.md` §3: `AppConfig.shared.data.glossary` and `.glossaryCategories` are
    /// snapshotted here, on the main actor, into plain values captured by the `glossaryProvider` /
    /// `glossaryCategoriesProvider` closures -- mirroring how `config: AppConfig.shared.data.refinement`
    /// itself is a one-time snapshot, not a live `AppConfig` reference (see
    /// `RefinementQueue.glossaryProvider`'s doc comment for why this must not read `AppConfig.shared`
    /// from inside the actor instead).
    @MainActor
    static func defaultRefinementQueueFactory(_ sessionHandle: SessionHandle) -> RefinementQueue {
        let glossary = AppConfig.shared.data.glossary
        let glossaryCategories = AppConfig.shared.data.glossaryCategories
        return RefinementQueue(
            sessionHandle: sessionHandle,
            llm: UsageRecordingLLM(base: LLMClient.shared, sessionHandle: sessionHandle),
            config: AppConfig.shared.data.refinement,
            glossaryProvider: { glossary },
            glossaryCategoriesProvider: { glossaryCategories }
        )
    }

    /// Production default for `watcherLibrary`: a `WatcherLibrary` rooted at `AppConfig.shared.data
    /// .watchers.presetsDir` (`docs/design/05-watcher-runner.md` §3.2), tilde-expanded via
    /// `FileManager.expandingTildePath(_:)`. Creates the directory if missing (§3.2: "presets_dir が
    /// 無ければ factory 時点で作成する") so a brand-new install's first Watcher preset save never fails
    /// with "no such directory".
    ///
    /// `nonisolated`: unlike `defaultDiarizationCoordinatorFactory`/`defaultWatcherRunnerFactory`
    /// (function *references* passed as still-unevaluated default parameter values), this one is
    /// *called* immediately as `MeetingWorkspaceViewModel.init`'s own default argument expression --
    /// which is evaluated at each call site, not inside `init`'s own `@MainActor` body. `AppConfig`/
    /// `FileManager` touch no main-actor-isolated state, so this is safe to run from any context.
    nonisolated static func defaultWatcherLibrary() -> WatcherLibrary {
        let presetsDirectory = FileManager.expandingTildePath(AppConfig.shared.data.watchers.presetsDir)
        try? FileManager.default.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)
        return WatcherLibrary(presetsDirectory: presetsDirectory)
    }

    /// Production default for `watcherRunnerFactory`: a real `WatcherRunner` using `LLMClient.shared`
    /// and `AppConfig.shared.data.watchers.defaultModel` (`docs/design/05-watcher-runner.md` §3.2/§9).
    /// `KIKIMI_STUB_LLM` is handled internally by `LLMClient`, not here, same as
    /// `defaultSummaryUpdaterFactory`/`defaultRefinementQueueFactory` above.
    ///
    /// `docs/design/16-llm-usage-stats.md` section 3: `LLMClient.shared` is wrapped in
    /// `UsageRecordingLLM`, same rationale as the other two factories above -- `WatcherRunner`'s own
    /// `completeRaw` calls get the identical `llm_usage.jsonl` bookkeeping without knowing this
    /// decorator exists (`UsageRecordingLLM.completeRaw(_:)`'s own doc comment).
    @MainActor
    static func defaultWatcherRunnerFactory(_ sessionHandle: SessionHandle) -> WatcherRunner {
        WatcherRunner(
            sessionHandle: sessionHandle,
            llm: UsageRecordingLLM(base: LLMClient.shared, sessionHandle: sessionHandle),
            library: defaultWatcherLibrary(),
            defaultModel: AppConfig.shared.data.watchers.defaultModel
        )
    }

    /// Production default for `wikiExporter`: a real `WikiExporter` capturing `AppConfig.shared.data
    /// .export`'s current value (`docs/design/08-wiki-export.md`) and a `TranscriptMarkdownSource`
    /// capturing `AppConfig.shared.data.diarization` (`docs/design/37-transcript-markdown-copy.md`
    /// §5) so the export shares the same speaker-name resolution as the "copy transcript" feature.
    /// `nonisolated`/called immediately as `MeetingWorkspaceViewModel.init`'s own default argument
    /// expression, same shape as `defaultWatcherLibrary()` above -- reading `AppConfig.shared` touches
    /// no main-actor-isolated state either.
    nonisolated static func defaultWikiExporter() -> WikiExporting {
        WikiExporter(
            config: AppConfig.shared.data.export,
            source: TranscriptMarkdownSource(diarization: AppConfig.shared.data.diarization, voiceprintStore: .shared)
        )
    }
}
