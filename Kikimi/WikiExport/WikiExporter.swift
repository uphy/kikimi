import Foundation
import OSLog

// MARK: - WikiExporting

/// DI seam for `docs/design/08-wiki-export.md`'s session-end Wiki raw export (kikimi.md 11 章),
/// injected into `MeetingWorkspaceViewModel` as `wikiExporter` so `endMeeting()`'s call site is
/// testable without ever touching the real `~/Documents/Kikimi/export/` directory.
///
/// Unlike `SummaryUpdaterFactory`/`RefinementQueueFactory`/`WatcherRunnerFactory` (which construct a
/// session-scoped collaborator with its own lifecycle), `WikiExporter` has no state to carry across
/// calls -- it is invoked exactly once, at `on_session_end`. So this mirrors `AudioInputEnumerating`/
/// `VoiceprintStore`'s "inject the dependency itself, not a factory for one" shape instead (design
/// §3/§7).
protocol WikiExporting: Sendable {
    /// Renders and writes `sessionHandle`'s Wiki raw export Markdown file (design §3/§4), or does
    /// nothing if `ExportConfig.enabled == false`. Callers (`endMeeting()`) must treat any thrown
    /// error as best-effort/non-fatal (design §6 -- kikimi.md 8.5 章 "録音は絶対に止めない" extends to
    /// `on_session_end`'s other side effects too).
    func export(sessionHandle: SessionHandle) async throws
}

// MARK: - WikiExporter

/// Production `WikiExporting`. Holds a plain `ExportConfig` value (captured once by
/// `defaultWikiExporter()` at `MeetingWorkspaceViewModel.init` time), mirroring how
/// `defaultRefinementQueueFactory`/`defaultWatcherRunnerFactory` capture `AppConfig.shared.data.X` as
/// a value rather than holding a live `AppConfig` reference -- `WikiExporting: Sendable` requires
/// every conformer to be `Sendable`, and `AppConfig` (a plain `ObservableObject` class, `@MainActor`
/// by convention but not itself `Sendable`) cannot be stored in one. A `config.yaml` `export:` edit
/// made after a session's window opens is therefore picked up the same way `RefinementConfig`/
/// `SummaryConfig` already are elsewhere: on the next window open, not intra-session.
struct WikiExporter: WikiExporting {
    var config: ExportConfig

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "WikiExporter")

    func export(sessionHandle: SessionHandle) async throws {
        guard config.enabled else { return }

        let meta = await sessionHandle.meta
        let refinedSegments = try await sessionHandle.readRefinedSegments()

        let summaryMarkdown: String
        do {
            summaryMarkdown = try await sessionHandle.readText(.summaryMarkdown) ?? ""
        } catch {
            // A Draft/Ended session that never produced a readable summary.md is not fatal to the
            // whole export (design §6) -- render with an empty summary section instead.
            Self.logger.warning(
                """
                Failed to read summary.md for session \(sessionHandle.sessionId, privacy: .public); \
                exporting with an empty サマリ section: \(String(describing: error), privacy: .public)
                """
            )
            summaryMarkdown = ""
        }

        let markdown = WikiExportRenderer.render(
            WikiExportRenderer.Input(meta: meta, summaryMarkdown: summaryMarkdown, refinedSegments: refinedSegments)
        )
        let fileName = WikiExportRenderer.fileName(for: meta)

        let targetDirectory = FileManager.expandingTildePath(config.targetDir)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let fileURL = targetDirectory.appendingPathComponent(fileName)
        // Overwrites unconditionally -- kikimi.md 4 章 "on_session_end の副作用は冪等（上書き）",
        // matched here exactly the same way `WikiExportRenderer`'s pure output is deterministic for
        // the same input.
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)

        Self.logger.info(
            "Wrote Wiki export for session \(sessionHandle.sessionId, privacy: .public) to \(fileURL.path, privacy: .public)"
        )
    }
}
