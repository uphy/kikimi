import Foundation

// MARK: - ProfileSaveComposer

/// Pure conversion rules for the "プロファイルとして保存…" sheet (`docs/design/41-meeting-profiles.md`
/// §5, §8 #11): turns "the current session's prep files + which of them the user checked" into a
/// `MeetingProfileDraft` ready for `MeetingProfileStore.save(_:overwrite:)`. No `SessionHandle` /
/// `WatcherLibrary` / disk access here -- mirrors `ParticipantContextComposer`'s "pure by
/// construction" idiom so both `compose(...)` and the exclusion rule it applies are directly
/// unit-testable without a session or a profiles directory on disk. The sheet's caller is
/// responsible for gathering every input (current `context.md`/`summary_template.md` text, the
/// current `enabled.yaml` id list, `WatcherLibrary.listPresetIds()`, `SessionParticipants
/// .participantIds`) and for the sheet's *own* concerns this type does not own: computing each
/// checkbox's default/disabled state from content emptiness (§5's "既定は全 ON。ただし対象ファイルが
/// 空/不在なら該当行を disabled"), id-collision/overwrite confirmation (§5's #7), and actually calling
/// `MeetingProfileStore.save(_:overwrite:)`.
enum ProfileSaveComposer {
    // MARK: - Selection

    /// The save sheet's four "何を保存するか" checkboxes (§5: "保存対象のチェックボックス: context.md /
    /// summary_template.md / 有効 Watcher / 参加者名簿"). Each `false` becomes a `nil` field on the
    /// resulting `MeetingProfileDraft` -- "don't include this" means "don't write this file/key at
    /// all" (so overwriting an existing profile with a box unchecked leaves that profile's existing
    /// file/key untouched, per `MeetingProfileDraft`'s own doc comment), not "write it empty".
    struct Selection: Equatable, Sendable {
        var includeContext: Bool
        var includeSummaryTemplate: Bool
        var includeWatchers: Bool
        var includeParticipants: Bool

        init(
            includeContext: Bool = true,
            includeSummaryTemplate: Bool = true,
            includeWatchers: Bool = true,
            includeParticipants: Bool = true
        ) {
            self.includeContext = includeContext
            self.includeSummaryTemplate = includeSummaryTemplate
            self.includeWatchers = includeWatchers
            self.includeParticipants = includeParticipants
        }
    }

    // MARK: - SourceSession

    /// Everything `compose(...)` reads from the session being saved as a profile, bundled into one
    /// value purely to keep `compose(...)`'s parameter list under the project's `function_parameter_
    /// count` SwiftLint limit -- each field's meaning is documented on `compose(...)`'s own doc
    /// comment (the parameter this replaced).
    struct SourceSession: Equatable, Sendable {
        var context: String
        var summaryTemplate: String
        var enabledWatcherIds: [String]
        var presetWatcherIds: Set<String>
        var participantIds: [String]

        init(
            context: String,
            summaryTemplate: String,
            enabledWatcherIds: [String],
            presetWatcherIds: Set<String>,
            participantIds: [String]
        ) {
            self.context = context
            self.summaryTemplate = summaryTemplate
            self.enabledWatcherIds = enabledWatcherIds
            self.presetWatcherIds = presetWatcherIds
            self.participantIds = participantIds
        }
    }

    // MARK: - Result

    /// `compose(...)`'s output: the draft to hand to `MeetingProfileStore.save(_:overwrite:)`, plus
    /// the enabled Watcher ids the sheet must call out in its inline note (§5 / §8 #11).
    struct Result: Equatable, Sendable {
        var draft: MeetingProfileDraft
        /// Enabled ids that were dropped from `draft.enabledWatchers` because no preset exists for
        /// them (§5: "session-local にしか定義が無い id は除外"), in their original `enabled.yaml`
        /// order with duplicates removed. The sheet renders each into "`<id>` はこの会議専用のため保存
        /// されません。プリセットに昇格してから保存してください" (§5). Always empty when
        /// `selection.includeWatchers` is `false`, since nothing was considered for inclusion at all.
        var excludedWatcherIds: [String]
    }

    // MARK: - compose

    /// Builds the `MeetingProfileDraft` for saving the current session's prep state as profile `id`.
    ///
    /// - Parameters:
    ///   - id: The profile directory name to create/overwrite. Passed through unvalidated --
    ///     `MeetingProfileStore.save(_:overwrite:)` owns id validation (`MeetingProfileIdValidation`).
    ///   - name: The profile's display name (sheet's "表示名" field).
    ///   - description: The profile's optional description.
    ///   - source: The session's current prep state to draw from (see `SourceSession`'s field docs).
    ///     `source.context`/`source.summaryTemplate` are only used when `selection.includeContext`/
    ///     `.includeSummaryTemplate` are `true`; `source.enabledWatcherIds`/`.presetWatcherIds` are
    ///     only considered when `selection.includeWatchers` is `true`. `source.presetWatcherIds`
    ///     (every id with a preset definition, `WatcherLibrary.listPresetIds()`) is what an
    ///     `enabledWatcherIds` entry is checked against to decide inclusion (§5's exclusion rule) --
    ///     checked against presets specifically, not against `WatcherOrigin`, because an id forked
    ///     into the session (session-local definition shadowing an *existing* preset of the same id)
    ///     still resolves in a brand-new session and must be kept. `source.participantIds` must be
    ///     `SessionParticipants.participantIds` only, never `removedParticipantIds` (§2.2 / §5: "参加者
    ///     名簿は `participants.json` の `participant_ids` のみ（`removed_participant_ids` は保存しない）"),
    ///     matching `ParticipantContextComposer.resolveParticipantNames(participantIds:in:)`'s same
    ///     contract.
    ///   - selection: Which of the four checkboxes are checked.
    static func compose(
        id: String,
        name: String,
        description: String?,
        source: SourceSession,
        selection: Selection
    ) -> Result {
        var enabledWatchers: [String]?
        var excludedWatcherIds: [String] = []
        if selection.includeWatchers {
            var kept: [String] = []
            var seenIds = Set<String>()
            for watcherId in source.enabledWatcherIds {
                // Defensively de-duplicates a hand-edited `enabled.yaml` with a repeated id, mirroring
                // `MeetingWorkspaceViewModel.refreshWatcherItems()`'s own `seenIds` guard over the same
                // file -- a saved profile should never list the same preset id twice.
                guard seenIds.insert(watcherId).inserted else { continue }
                if source.presetWatcherIds.contains(watcherId) {
                    kept.append(watcherId)
                } else {
                    excludedWatcherIds.append(watcherId)
                }
            }
            enabledWatchers = kept
        }

        let draft = MeetingProfileDraft(
            id: id,
            name: name,
            description: description,
            context: selection.includeContext ? source.context : nil,
            summaryTemplate: selection.includeSummaryTemplate ? source.summaryTemplate : nil,
            enabledWatchers: enabledWatchers,
            participantIds: selection.includeParticipants ? source.participantIds : nil
        )
        return Result(draft: draft, excludedWatcherIds: excludedWatcherIds)
    }
}
