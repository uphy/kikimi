import Foundation

// MARK: - ExportConfig

/// `export:` section of `config.yaml` (kikimi.md 12 章 / kikimi.md 11 章 "LLM Wiki raw export" /
/// `docs/design/08-wiki-export.md` §3). Drives whether/where `WikiExporter` writes a session's Wiki
/// raw export Markdown file at `on_session_end`.
struct ExportConfig: Codable, Equatable, Sendable {
    /// `false` disables the whole feature: `endMeeting()` still calls `WikiExporter.export(
    /// sessionHandle:)`, which simply returns without touching disk (kikimi.md 11 章 "config で無効化
    /// 可能").
    var enabled: Bool
    /// `~`-rooted (or absolute) target directory for the exported `.md` file, tilde-expanded via
    /// `FileManager.expandingTildePath(_:)` by `WikiExporter` -- this struct only stores the raw
    /// config-file string, mirroring `WatchersConfig.presetsDir`'s own doc comment.
    var targetDir: String

    enum CodingKeys: String, CodingKey {
        case enabled
        case targetDir = "target_dir"
    }

    /// The exact defaults documented in kikimi.md 12 章's `config.yaml` sample.
    static let `default` = ExportConfig(
        enabled: true,
        targetDir: "~/Documents/Kikimi/export/"
    )

    init(enabled: Bool, targetDir: String) {
        self.enabled = enabled
        self.targetDir = targetDir
    }

    /// Custom decoder mirroring `DiarizationConfig.init(from:)`: a partial (or absent) `export:`
    /// section fills every missing field from `.default` instead of failing the whole `config.yaml`
    /// decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? Self.default.enabled
        targetDir = try container.decodeIfPresent(String.self, forKey: .targetDir) ?? Self.default.targetDir
    }
}
