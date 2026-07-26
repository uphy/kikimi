import Foundation
import Yams

// MARK: - SessionStore + Defaults (createDraftSession(basedOn:)'s source resolution)

/// Split out of `SessionStore.swift` to keep that file under the project's `file_length` lint limit.
/// Owns every `createDraftSession(basedOn:)` default-resolution helper: `context.md`/
/// `summary_template.md`/`participant_ids`/`enabled.yaml`'s initial contents for a brand-new session,
/// each falling back through source-session -> global-default -> built-in-default (where applicable),
/// per design doc section 8's failure-mode table / `docs/design/22-participant-hints.md` section 1.3.
extension SessionStore {
    /// Resolves the initial `context.md` contents for `createDraftSession(basedOn:)` (design doc
    /// section 8): source session first, then the global default, then an empty string.
    func loadInitialContext(basedOn sourceSessionId: String?) -> String {
        if let sourceSessionId {
            let url = sessionsRootDirectory.appendingPathComponent(sourceSessionId, isDirectory: true)
                .appendingPathComponent("context.md")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
            logger.warning("Could not read context.md from source session \(sourceSessionId, privacy: .public); falling back to the global default")
        }
        if let text = try? String(contentsOf: defaultContextFileURL, encoding: .utf8) {
            return text
        }
        logger.warning("Could not read the default context file at \(self.defaultContextFileURL.path, privacy: .public); starting with an empty context")
        return ""
    }

    /// Resolves the initial `summary_template.md` contents for `createDraftSession(basedOn:)`
    /// (design doc section 8): source session first, then the global default, then the built-in template.
    func loadInitialSummaryTemplate(basedOn sourceSessionId: String?) -> String {
        if let sourceSessionId {
            let url = sessionsRootDirectory.appendingPathComponent(sourceSessionId, isDirectory: true)
                .appendingPathComponent("summary_template.md")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
            logger.warning(
                "Could not read summary_template.md from source session \(sourceSessionId, privacy: .public); falling back to the global default"
            )
        }
        if let text = try? String(contentsOf: defaultSummaryTemplateFileURL, encoding: .utf8) {
            return text
        }
        logger.warning(
            "Could not read the default summary template file at \(self.defaultSummaryTemplateFileURL.path, privacy: .public); using the built-in default template"
        )
        return Self.builtInDefaultSummaryTemplate
    }

    /// Resolves the initial `participant_ids` for `createDraftSession(basedOn:)`
    /// (`docs/design/22-participant-hints.md` section 1.3): `nil` when there is no source session, or
    /// its `participants.json` is missing/unreadable/undecodable -- unlike `loadInitialContext`/
    /// `loadInitialSummaryTemplate`, there is no global-default fallback to try (a participant roster
    /// is inherently session-specific, kikimi.md has no `defaults.participants_file` equivalent), so a
    /// `nil` here means "write nothing" at the call site, not "fall back to some other source".
    func loadInitialParticipantIds(basedOn sourceSessionId: String?) -> [String]? {
        guard let sourceSessionId else { return nil }
        let url = sessionsRootDirectory.appendingPathComponent(sourceSessionId, isDirectory: true)
            .appendingPathComponent("participants.json")
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard let decoded = try? SessionJSONCoding.makeDecoder().decode(SessionParticipants.self, from: data) else {
            logger.warning(
                "Could not decode participants.json from source session \(sourceSessionId, privacy: .public); not copying the participant roster"
            )
            return nil
        }
        return decoded.participantIds
    }

    /// Resolves the initial `watchers/enabled.yaml` contents for `createDraftSession()`
    /// (kikimi.md 9 章): `defaults.default_enabled_file`, falling back to an empty list.
    func loadInitialEnabledWatchers() -> [String] {
        guard
            let yamlString = try? String(contentsOf: defaultEnabledWatchersFileURL, encoding: .utf8),
            let decoded = try? YAMLDecoder().decode(EnabledWatchersFile.self, from: yamlString)
        else {
            logger.warning(
                "Could not read the default enabled-watchers file at \(self.defaultEnabledWatchersFileURL.path, privacy: .public); starting with none enabled"
            )
            return []
        }
        return decoded.enabled
    }
}
