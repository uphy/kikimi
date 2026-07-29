import Foundation
import Testing

@testable import Kikimi

// MARK: - WatchersTabView.inputScopeLabel

/// Unit tests for the Watchers-tab footer's `input_scope` badge text
/// (`Kikimi/Views/MeetingWorkspace/WatchersTabView.swift`). The badge exists because the scope was
/// otherwise invisible from the results view -- a reader could not tell whether a Watcher's output
/// came from the whole meeting or only its tail without opening the definition `.md`.
///
/// The wording is pinned here rather than left to the view because it has to stay in lockstep with
/// `SimpleWatcherFormSheet`'s picker labels: both spell out that the summary is included in *every*
/// scope, which is what `WatcherRunner` actually does (it expands `{{summary}}` on every run
/// regardless of `input_scope`).
@Suite("WatchersTabView.inputScopeLabel")
struct WatchersTabInputScopeLabelTests {
    @Test("summary renders as サマリのみ")
    func summaryLabel() {
        #expect(WatchersTabView.inputScopeLabel(.summary) == "サマリのみ")
    }

    @Test("summary_and_recent spells out the configured segment count, not a generic 直近")
    func summaryAndRecentLabelIncludesCount() {
        #expect(WatchersTabView.inputScopeLabel(.summaryAndRecent(count: 30)) == "サマリ + 直近30発言")
        #expect(WatchersTabView.inputScopeLabel(.summaryAndRecent(count: 5)) == "サマリ + 直近5発言")
    }

    @Test("full_refined renders as サマリ + 全発言")
    func fullRefinedLabel() {
        #expect(WatchersTabView.inputScopeLabel(.fullRefined) == "サマリ + 全発言")
    }

    /// Every label starts with "サマリ" -- the property the wording change exists to convey (the old
    /// "直近の会話 / サマリのみ / 会議全体" set read as three mutually exclusive sources).
    @Test("every scope's label makes clear the summary is always included")
    func everyLabelMentionsSummary() {
        let labels = [
            WatchersTabView.inputScopeLabel(.summary),
            WatchersTabView.inputScopeLabel(.summaryAndRecent(count: WatcherInputScope.defaultRecentCount)),
            WatchersTabView.inputScopeLabel(.fullRefined)
        ]
        #expect(labels.allSatisfy { $0.hasPrefix("サマリ") })
    }
}

// MARK: - WatchersTabView.inputScopeFooterText

/// Unit tests for the footer's complete `対象:` value, which has to describe the *result on screen*
/// while still admitting when the definition has since been edited
/// (`docs/design/05-watcher-runner.md` §7.2).
@Suite("WatchersTabView.inputScopeFooterText")
struct WatchersTabInputScopeFooterTextTests {
    @Test("shows the run's scope alone when it still matches the definition")
    func matchingScopesRenderOnce() {
        #expect(
            WatchersTabView.inputScopeFooterText(lastRun: .fullRefined, definition: .fullRefined)
                == "サマリ + 全発言"
        )
    }

    @Test("shows both when the definition was edited after the last run, so neither reading misleads")
    func divergentScopesShowNextRunToo() {
        #expect(
            WatchersTabView.inputScopeFooterText(lastRun: .summaryAndRecent(count: 30), definition: .fullRefined)
                == "サマリ + 直近30発言（次回: サマリ + 全発言）"
        )
    }

    /// Watchers that have never run, plus results persisted before `run.json` existed: the
    /// definition's value is all there is, and it correctly describes the next run.
    @Test("falls back to the definition's scope when the run's is unknown")
    func unknownRunScopeFallsBackToDefinition() {
        #expect(WatchersTabView.inputScopeFooterText(lastRun: nil, definition: .summary) == "サマリのみ")
    }

    /// `origin: .missing` -- an `enabled.yaml` id whose definition is gone. There is no scope to
    /// report and no run to describe, so the footer shows no badge at all rather than inventing one.
    @Test("returns nil when neither scope is known")
    func bothUnknownReturnsNil() {
        #expect(WatchersTabView.inputScopeFooterText(lastRun: nil, definition: nil) == nil)
    }

    @Test("reports the run's scope even if the definition can no longer be resolved")
    func missingDefinitionStillReportsTheRun() {
        #expect(
            WatchersTabView.inputScopeFooterText(lastRun: .summaryAndRecent(count: 5), definition: nil)
                == "サマリ + 直近5発言"
        )
    }
}
