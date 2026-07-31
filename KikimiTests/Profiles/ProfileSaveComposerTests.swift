import Foundation
import Testing

@testable import Kikimi

/// Layer 1 (unit) coverage for `ProfileSaveComposer.compose(...)`
/// (`Kikimi/Profiles/ProfileSaveComposer.swift`, `docs/design/41-meeting-profiles.md` §5/§8 #11): the
/// pure conversion rules the "プロファイルとして保存…" sheet uses to turn the current session's prep
/// state + which checkboxes are checked into a `MeetingProfileDraft`. No disk access, no
/// `SessionHandle`/`WatcherLibrary` -- every input is a plain value, mirroring
/// `ParticipantContextComposerTests.swift`'s own "pure function, no fixtures" scoping.
@Suite("ProfileSaveComposer")
struct ProfileSaveComposerTests {
    private func source(
        context: String = "# context",
        summaryTemplate: String = "# {{title}}",
        enabledWatcherIds: [String] = ["pre-check", "action-items"],
        presetWatcherIds: Set<String> = ["pre-check", "action-items"],
        participantIds: [String] = ["spk_1", "spk_2"]
    ) -> ProfileSaveComposer.SourceSession {
        ProfileSaveComposer.SourceSession(
            context: context,
            summaryTemplate: summaryTemplate,
            enabledWatcherIds: enabledWatcherIds,
            presetWatcherIds: presetWatcherIds,
            participantIds: participantIds
        )
    }

    // MARK: - All-included (defaults), no session-local ids

    @Test("with every checkbox on and no session-local watcher ids, every field is carried through and nothing is excluded")
    func allIncludedNoExclusions() {
        let result = ProfileSaveComposer.compose(
            id: "daily-scrum",
            name: "デイリースクラム",
            description: "毎朝のスクラム",
            source: source(),
            selection: ProfileSaveComposer.Selection()
        )

        #expect(result.draft.id == "daily-scrum")
        #expect(result.draft.name == "デイリースクラム")
        #expect(result.draft.description == "毎朝のスクラム")
        #expect(result.draft.context == "# context")
        #expect(result.draft.summaryTemplate == "# {{title}}")
        #expect(result.draft.enabledWatchers == ["pre-check", "action-items"])
        #expect(result.draft.participantIds == ["spk_1", "spk_2"])
        #expect(result.excludedWatcherIds.isEmpty)
    }

    // MARK: - Per-checkbox off -> nil field, source not consulted

    @Test("includeContext == false yields draft.context == nil")
    func includeContextFalseYieldsNilContext() {
        var selection = ProfileSaveComposer.Selection()
        selection.includeContext = false

        let result = ProfileSaveComposer.compose(
            id: "p", name: "n", description: nil, source: source(), selection: selection
        )

        #expect(result.draft.context == nil)
    }

    @Test("includeSummaryTemplate == false yields draft.summaryTemplate == nil")
    func includeSummaryTemplateFalseYieldsNilTemplate() {
        var selection = ProfileSaveComposer.Selection()
        selection.includeSummaryTemplate = false

        let result = ProfileSaveComposer.compose(
            id: "p", name: "n", description: nil, source: source(), selection: selection
        )

        #expect(result.draft.summaryTemplate == nil)
    }

    @Test("includeParticipants == false yields draft.participantIds == nil")
    func includeParticipantsFalseYieldsNilParticipants() {
        var selection = ProfileSaveComposer.Selection()
        selection.includeParticipants = false

        let result = ProfileSaveComposer.compose(
            id: "p", name: "n", description: nil, source: source(), selection: selection
        )

        #expect(result.draft.participantIds == nil)
    }

    @Test("includeWatchers == false yields draft.enabledWatchers == nil and no excludedWatcherIds (nothing was considered)")
    func includeWatchersFalseYieldsNilWatchersAndNoExclusions() {
        var selection = ProfileSaveComposer.Selection()
        selection.includeWatchers = false

        let result = ProfileSaveComposer.compose(
            id: "p", name: "n", description: nil,
            source: source(enabledWatcherIds: ["pre-check", "session-only"], presetWatcherIds: ["pre-check"]),
            selection: selection
        )

        #expect(result.draft.enabledWatchers == nil)
        #expect(result.excludedWatcherIds.isEmpty)
    }

    // MARK: - Session-local id exclusion (§5 / §8 #11)

    @Test("a session-local-only enabled watcher id (no matching preset) is excluded from the draft and reported in excludedWatcherIds, in original order")
    func excludesSessionLocalOnlyIds() {
        let result = ProfileSaveComposer.compose(
            id: "p", name: "n", description: nil,
            source: source(
                enabledWatcherIds: ["pre-check", "risk-check", "action-items"],
                presetWatcherIds: ["pre-check", "action-items"]
            ),
            selection: ProfileSaveComposer.Selection()
        )

        #expect(result.draft.enabledWatchers == ["pre-check", "action-items"])
        #expect(result.excludedWatcherIds == ["risk-check"])
    }

    @Test("every enabled id lacking a preset is excluded when none of them resolve to a preset")
    func excludesAllWhenNoPresetsMatch() {
        let result = ProfileSaveComposer.compose(
            id: "p", name: "n", description: nil,
            source: source(enabledWatcherIds: ["risk-check", "custom-only"], presetWatcherIds: []),
            selection: ProfileSaveComposer.Selection()
        )

        #expect(result.draft.enabledWatchers == [])
        #expect(result.draft.enabledWatchers != nil, "an explicit empty list (key present) is written, not an absent key")
        #expect(result.excludedWatcherIds == ["risk-check", "custom-only"])
    }

    @Test("a session-local id whose id happens to shadow an existing preset id is still kept (checked against presets, not origin)")
    func keepsAnIdThatHasAMatchingPresetEvenIfForkedLocally() {
        // Design doc §5's own wording: an id forked into the session (session-local definition
        // shadowing an *existing* preset of the same id) still resolves in a brand-new session and
        // must be kept -- `compose` only ever consults `presetWatcherIds`, never a WatcherOrigin.
        let result = ProfileSaveComposer.compose(
            id: "p", name: "n", description: nil,
            source: source(enabledWatcherIds: ["pre-check"], presetWatcherIds: ["pre-check"]),
            selection: ProfileSaveComposer.Selection()
        )

        #expect(result.draft.enabledWatchers == ["pre-check"])
        #expect(result.excludedWatcherIds.isEmpty)
    }

    // MARK: - Duplicate ids in enabledWatcherIds are de-duplicated

    @Test("a duplicated preset id in enabledWatcherIds appears only once in the kept list")
    func deduplicatesRepeatedPresetId() {
        let result = ProfileSaveComposer.compose(
            id: "p", name: "n", description: nil,
            source: source(enabledWatcherIds: ["pre-check", "pre-check", "action-items"], presetWatcherIds: ["pre-check", "action-items"]),
            selection: ProfileSaveComposer.Selection()
        )

        #expect(result.draft.enabledWatchers == ["pre-check", "action-items"])
    }

    @Test("a duplicated session-local-only id appears only once in excludedWatcherIds")
    func deduplicatesRepeatedExcludedId() {
        let result = ProfileSaveComposer.compose(
            id: "p", name: "n", description: nil,
            source: source(enabledWatcherIds: ["risk-check", "risk-check"], presetWatcherIds: []),
            selection: ProfileSaveComposer.Selection()
        )

        #expect(result.excludedWatcherIds == ["risk-check"])
    }

    // MARK: - Empty inputs

    @Test("an empty enabledWatcherIds yields an empty (not nil) draft.enabledWatchers when includeWatchers is true")
    func emptyEnabledWatcherIdsYieldsEmptyArray() {
        let result = ProfileSaveComposer.compose(
            id: "p", name: "n", description: nil,
            source: source(enabledWatcherIds: [], presetWatcherIds: ["pre-check"]),
            selection: ProfileSaveComposer.Selection()
        )

        #expect(result.draft.enabledWatchers == [])
        #expect(result.excludedWatcherIds.isEmpty)
    }

    @Test("participantIds passes through verbatim, including an empty roster")
    func participantIdsPassesThroughVerbatim() {
        let result = ProfileSaveComposer.compose(
            id: "p", name: "n", description: nil,
            source: source(participantIds: []),
            selection: ProfileSaveComposer.Selection()
        )

        #expect(result.draft.participantIds == [])
    }

    // MARK: - id/name/description pass-through

    @Test("id/name/description are passed through onto the draft unvalidated")
    func idNameDescriptionPassThrough() {
        let result = ProfileSaveComposer.compose(
            id: "some-id", name: "表示名", description: "説明文",
            source: source(), selection: ProfileSaveComposer.Selection()
        )

        #expect(result.draft.id == "some-id")
        #expect(result.draft.name == "表示名")
        #expect(result.draft.description == "説明文")
    }

    @Test("a nil description stays nil on the draft")
    func nilDescriptionStaysNil() {
        let result = ProfileSaveComposer.compose(
            id: "some-id", name: "表示名", description: nil,
            source: source(), selection: ProfileSaveComposer.Selection()
        )

        #expect(result.draft.description == nil)
    }
}
