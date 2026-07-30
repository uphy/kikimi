import Foundation
import OSLog

// MARK: - TranscriptMarkdownSource

/// Disk-backed speaker-name resolution adapter (`docs/design/37-transcript-markdown-copy.md` §3.2(b),
/// TC5(b)): reads a session's transcript/refined/diarization files from a `SessionHandle` and
/// produces a `TranscriptMarkdownRenderer.Input` with every line's speaker name already resolved.
/// Used by the session list's "Markdown をコピー" context menu item and by `WikiExporter` -- both read
/// a session from disk rather than from a live `MeetingWorkspaceViewModel` (the *live* adapter,
/// `MeetingWorkspaceViewModel+Copy.swift`, reuses `transcriptRows`/`speakerLabels` instead and does not
/// go through this type at all).
///
/// **Isolation**: deliberately *not* `@MainActor` and *not* an `actor`. A plain `struct`'s methods are
/// `nonisolated` under this project's Swift 5.9 tools, so `load(sessionHandle:)` runs on the
/// cooperative thread pool even when awaited from a `@MainActor` caller (`SessionListViewModel`).
/// `SpeakerLabelResolver.resolve(...)` calls `SegmentAttribution.attribute(...)` once per segment, and
/// this method calls `resolve` once per `system` segment in the session -- segment count × turn count
/// work for a multi-hour meeting. `docs/design/13-speaker-diarization.md` §5 records that running the
/// same per-row computation on the main actor once pinned the CPU and froze the UI; keeping this type
/// off `@MainActor` is what prevents that regression here. `actor` is unnecessary: `load` is a pure
/// function of its arguments plus the injected `Sendable` dependencies below, with no mutable state of
/// its own to protect.
struct TranscriptMarkdownSource: Sendable {
    /// Captured by value (not a live `AppConfig` reference) for the same reason `WikiExporting`'s
    /// conformers capture `ExportConfig` (`WikiExporter.swift`'s doc comment): `Sendable` conformers
    /// cannot hold `AppConfig`, a `@MainActor`, non-`Sendable` `ObservableObject`. `selfName` names
    /// every `mic` line (design §3.2(b)/§4.2); `enabled` gates `activeRanges` below.
    var diarization: DiarizationConfig
    /// `actor`, so held directly rather than captured by value.
    var voiceprintStore: VoiceprintStore

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "TranscriptMarkdownSource")

    /// Reads everything `TranscriptMarkdownRenderer.render(_:scope:)` needs for `sessionHandle` and
    /// resolves every line's speaker name (design §3.2(b), §4.2, TC15).
    func load(sessionHandle: SessionHandle) async throws -> TranscriptMarkdownRenderer.Input {
        let meta = await sessionHandle.meta
        let refinedSegments = try await sessionHandle.readRefinedSegments()
        let transcriptSegments = try await sessionHandle.readTranscriptSegments()
        let turns = try await sessionHandle.readDiarizationTurns()
        let assignments = try await sessionHandle.readSpeakerAssignments()
        let speakerNames = await currentSpeakerNames()

        let summaryMarkdown: String
        do {
            summaryMarkdown = try await sessionHandle.readText(.summaryMarkdown) ?? ""
        } catch {
            // Same "not fatal, empty サマリ section" fallback as `WikiExporter.export(sessionHandle:)`
            // (`WikiExport/WikiExporter.swift:44`): an unreadable/corrupt `summary.md` must not block
            // the transcript from being read.
            Self.logger.warning(
                """
                Failed to read summary.md for session \(sessionHandle.sessionId, privacy: .public); \
                loading with an empty サマリ section: \(String(describing: error), privacy: .public)
                """
            )
            summaryMarkdown = ""
        }

        // TC15's precondition (design §3.2(b)): `activeRanges` opts every segment into attribution
        // only when there is at least one turn to attribute against *and* diarization is enabled for
        // this session. Without the `turns.isEmpty` guard, `SpeakerLabelResolver.resolve(...)` treats
        // "within an active range, but no turns" as `.unattributed`, and with `confirmedAt: .distantPast`
        // below that always resolves to `.unknown` ("Speaker ?") -- so a session with no
        // `diarization.jsonl` at all (diarization never ran, or ran before this feature existed) would
        // render every `system` line as "Speaker ?" instead of falling back to `.systemFallback`
        // ("system"). `MeetingWorkspaceViewModel+Diarization.swift`'s `currentActiveRanges()` guards
        // the same way for the live adapter.
        let activeRanges: [DiarizationActiveRange] = (!turns.isEmpty && diarization.enabled)
            ? [DiarizationActiveRange(startMs: 0, endMs: nil)]
            : []

        var lines: [TranscriptMarkdownRenderer.Line] = []
        lines.reserveCapacity(refinedSegments.count + transcriptSegments.count)

        for segment in refinedSegments {
            guard let text = displayText(for: segment) else { continue }
            lines.append(
                TranscriptMarkdownRenderer.Line(
                    id: segment.id,
                    startMs: segment.startMs,
                    speakerName: speakerName(
                        speaker: segment.speaker,
                        startMs: segment.startMs,
                        endMs: segment.endMs,
                        sourceSegIds: segment.sourceSegIds,
                        turns: turns,
                        activeRanges: activeRanges,
                        assignments: assignments,
                        speakerNames: speakerNames
                    ),
                    text: text,
                    isRawFallback: segment.refinedText == nil
                )
            )
        }

        // TC15: raw segments not covered by any `RefinedSegment.sourceSegIds` -- an in-progress
        // recording's tail, or a crash-recovery session whose last batch never got refined. Included
        // with `isRawFallback: true` (design §4.3) so a copy taken mid-recording, or from a list
        // right-click, never silently drops the newest few lines.
        let coveredSegIds = Set(refinedSegments.flatMap(\.sourceSegIds))
        for segment in transcriptSegments where !coveredSegIds.contains(segment.id) {
            lines.append(
                TranscriptMarkdownRenderer.Line(
                    id: segment.id,
                    startMs: segment.startMs,
                    speakerName: speakerName(
                        speaker: segment.speaker,
                        startMs: segment.startMs,
                        endMs: segment.endMs,
                        sourceSegIds: [segment.id],
                        turns: turns,
                        activeRanges: activeRanges,
                        assignments: assignments,
                        speakerNames: speakerNames
                    ),
                    text: segment.text,
                    isRawFallback: true
                )
            )
        }

        return TranscriptMarkdownRenderer.Input(meta: meta, summaryMarkdown: summaryMarkdown, lines: lines)
    }

    // MARK: - Speaker name resolution

    /// `mic` never goes through `SpeakerLabelResolver` -- diarization never runs on the mic stream
    /// (`docs/design/13-speaker-diarization.md` §4.5) -- so it is always the injected `selfName`.
    /// `system` is resolved through `SpeakerLabelResolver.resolve(...)`, with `confirmedAt: .distantPast`
    /// (a past session's rows are never "(認識中…)": design §3.2(b)) and the per-segment override, if
    /// any, looked up from `sourceSegIds` (see `firstOverride(sourceSegIds:assignments:)`).
    private func speakerName(
        speaker: AudioSourceKind,
        startMs: Int,
        endMs: Int,
        sourceSegIds: [String],
        turns: [DiarizationTurn],
        activeRanges: [DiarizationActiveRange],
        assignments: SpeakerAssignments,
        speakerNames: [String: String]
    ) -> String {
        guard speaker == .system else {
            return diarization.selfName
        }

        let resolved = SpeakerLabelResolver.resolve(
            startMs: startMs,
            endMs: endMs,
            turns: turns,
            activeRanges: activeRanges,
            assignments: assignments,
            override: firstOverride(sourceSegIds: sourceSegIds, assignments: assignments),
            confirmedAt: .distantPast,
            now: Date(),
            speakerNames: speakerNames
        )
        return displayName(for: resolved.label)
    }

    /// `speaker_assignments.json`'s `segmentOverrides` is keyed by raw `TranscriptSegment.id`, but a
    /// merged `RefinedSegment` only carries `id == sourceSegIds.first` (`SessionModels.swift:62`) --
    /// an override pinned to a non-leading covered seg id would otherwise never be found by a plain
    /// `assignments.segmentOverrides[segment.id]` lookup. Scanning `sourceSegIds` in order and taking
    /// the first hit recovers that case (design §3.2(b)).
    private func firstOverride(
        sourceSegIds: [String], assignments: SpeakerAssignments
    ) -> SegmentSpeakerOverride? {
        for segId in sourceSegIds {
            if let override = assignments.segmentOverrides[segId] {
                return override
            }
        }
        return nil
    }

    /// `ResolvedSpeakerLabel.label` -> Markdown display name (design §4.2's table). `hasOverlapMarker`
    /// is deliberately ignored (TC4): the ⚠ marker is a screen-only "this row's attribution is
    /// uncertain" cue, not part of the exported speaker name.
    private func displayName(for label: SpeakerDisplayLabel) -> String {
        switch label {
        case .named(let name):
            return name
        case .anonymous(let slotNumber):
            return "Speaker \(slotNumber)"
        case .mixed(let primary, let secondary):
            return "\(primary) + \(secondary)"
        case .recognizing, .unknown:
            // `.recognizing` cannot actually be produced here (`confirmedAt: .distantPast` always
            // clears `AttributionTuning.unattributedGraceMs`), but is handled explicitly rather than
            // assumed unreachable -- design §4.2 maps both to the same "Speaker ?" text anyway.
            return "Speaker ?"
        case .systemFallback:
            return "system"
        }
    }

    /// `[globalSpeakerId: name]` from every currently-registered voice (design §3.2(b),
    /// `docs/design/23-speaker-settings-rename.md` §2.2: "現在の登録名が snapshot に優先"). Passed straight
    /// through to `SpeakerLabelResolver.resolve(...)`'s `speakerNames` parameter, which already
    /// implements the "current name wins over the frozen `speaker_assignments.json` snapshot" rule.
    private func currentSpeakerNames() async -> [String: String] {
        let speakers = await voiceprintStore.listSpeakers()
        return Dictionary(speakers.map { ($0.id, $0.name) }, uniquingKeysWith: { _, last in last })
    }

    // MARK: - Raw/refined text fallback (moved from `WikiExportRenderer.displayText(for:)`, TC1)

    /// Resolves one refined segment's exported transcript text, or `nil` to exclude the line entirely
    /// (design §4.3):
    ///
    /// - `refinedText` non-`nil` and non-empty -> used as-is (the normal, successfully-refined case).
    /// - `refinedText == nil` (refinement failed, kikimi.md 5 章) -> falls back to `rawText`, **without**
    ///   `TranscriptMarkdownRenderer.rawFallbackMarker` appended here -- the caller sets the returned
    ///   `Line.isRawFallback` to `true` for this case, and `TranscriptMarkdownRenderer` appends the
    ///   marker itself at render time from that flag (`Line.isRawFallback`'s doc comment). Appending it
    ///   here too would double it up (`"... *(raw)* *(raw)*"`); this mirrors the raw-tail segment loop
    ///   below and the live adapter's `markdownBody(for:rawText:)` (`MeetingWorkspaceViewModel+Copy
    ///   .swift`), neither of which embeds the marker in `text` either.
    /// - `refinedText == ""` (intentional deletion, kikimi.md 7 章 "意味なしと判定され削除されたセグメント")
    ///   -> excluded entirely, never falls back to raw.
    private func displayText(for segment: RefinedSegment) -> String? {
        guard let refinedText = segment.refinedText else {
            return segment.rawText
        }
        guard !refinedText.isEmpty else {
            return nil
        }
        return refinedText
    }
}
