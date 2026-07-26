import Foundation

// MARK: - MeetingWorkspaceViewModel + Prep tab (section 6.2)

/// Split into its own file (alongside `MeetingWorkspaceViewModel.swift`'s other extensions) to keep
/// that file under the project's `file_length` lint limit. `MeetingWorkspaceViewModel` (a different
/// file) is this extension's only caller.
extension MeetingWorkspaceViewModel {
    /// Overwrites `context.md`. `SessionHandle.writeContext(_:)` already handles the 32KB size-limit
    /// warning (kikimi.md 7 章, `07-session-store.md` failure mode #12) by logging and saving anyway,
    /// so this only needs to surface genuine write failures.
    func saveContext(_ text: String) async {
        contextText = text
        do {
            try await sessionHandle.writeContext(text)
        } catch {
            logger.error(
                "Failed to write context.md for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Overwrites `summary_template.md`. Same size-limit handling note as `saveContext(_:)`.
    func saveSummaryTemplate(_ text: String) async {
        summaryTemplateText = text
        do {
            try await sessionHandle.writeSummaryTemplate(text)
        } catch {
            logger.error(
                "Failed to write summary_template.md for session \(self.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// "他セッションから複製" (kikimi.md 10 章): overwrites this session's `context.md`/
    /// `summary_template.md` (per `scope`) with `sourceSessionId`'s, then refreshes the
    /// corresponding `@Published` text(s) from disk so the Prep tab reflects the copy immediately.
    func duplicatePrepFiles(from sourceSessionId: String, scope: PrepCopyScope) async {
        do {
            try await sessionHandle.copyPrepFiles(from: sourceSessionId, scope: scope)
        } catch {
            logger.error(
                """
                Failed to copy prep files from \(sourceSessionId, privacy: .public) (scope: \
                \(String(describing: scope), privacy: .public)) into \(self.sessionId, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """
            )
            return
        }

        switch scope {
        case .contextOnly:
            contextText = await sessionHandle.readContext()
        case .templateOnly:
            summaryTemplateText = await sessionHandle.readSummaryTemplate()
        case .both:
            contextText = await sessionHandle.readContext()
            summaryTemplateText = await sessionHandle.readSummaryTemplate()
        }
    }
}
