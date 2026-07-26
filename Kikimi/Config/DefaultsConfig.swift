import Foundation

// MARK: - DefaultsConfig

/// `defaults:` section of `config.yaml` (kikimi.md 12 章 / `docs/design/26-settings-ui.md` §4.2).
/// Drives `SessionStore.shared`'s `defaultContextFileURL`/`defaultSummaryTemplateFileURL` (wired in
/// `SessionStore.swift`'s `static let shared`), i.e. the files copied as a new Draft session's
/// initial `context.md`/`summary_template.md` (kikimi.md 4 章). Path fields are `~`-rooted strings,
/// resolved via `FileManager.expandingTildePath(_:)` by whoever consumes them -- this struct itself
/// only stores the raw config-file string, mirroring `WatchersConfig.presetsDir`'s own doc comment.
struct DefaultsConfig: Codable, Equatable, Sendable {
    /// `defaults.context_file`.
    var contextFile: String
    /// `defaults.summary_template_file`.
    var summaryTemplateFile: String

    enum CodingKeys: String, CodingKey {
        case contextFile = "context_file"
        case summaryTemplateFile = "summary_template_file"
    }

    /// The exact defaults documented in kikimi.md 12 章's `config.yaml` sample. Must always match
    /// `SessionStore.defaultContextFileURL`/`defaultSummaryTemplateFileURL`'s own static XDG paths
    /// (`docs/design/26-settings-ui.md` §4.2's invariant note).
    static let `default` = DefaultsConfig(
        contextFile: "~/.config/kikimi/context/common.md",
        summaryTemplateFile: "~/.config/kikimi/templates/summary.md"
    )

    init(contextFile: String, summaryTemplateFile: String) {
        self.contextFile = contextFile
        self.summaryTemplateFile = summaryTemplateFile
    }

    /// Custom decoder mirroring `DiarizationConfig.init(from:)`: a partial (or absent) `defaults:`
    /// section fills every missing field from `.default` instead of failing the whole `config.yaml`
    /// decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contextFile = try container.decodeIfPresent(String.self, forKey: .contextFile) ?? Self.default.contextFile
        summaryTemplateFile = try container.decodeIfPresent(String.self, forKey: .summaryTemplateFile) ?? Self.default.summaryTemplateFile
    }
}
