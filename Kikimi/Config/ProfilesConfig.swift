import Foundation

// MARK: - ProfilesConfig

/// `profiles:` section of `config.yaml` (`docs/design/41-meeting-profiles.md` §2.4). Path reference
/// only -- the actual profile library lives on disk as `profiles.dir`'s directory contents (same
/// "config keeps the path, filesystem is the source of truth" idiom as `WatchersConfig.presetsDir`).
/// `MeetingProfileStore.shared` resolves this via `FileManager.expandingTildePath(_:)`; this struct
/// itself only stores the raw config-file string, unexpanded.
struct ProfilesConfig: Codable, Equatable, Sendable {
    /// `profiles.dir`.
    var dir: String

    enum CodingKeys: String, CodingKey {
        case dir
    }

    /// The exact default documented in design 41 §2.4's `config.yaml` sample.
    static let `default` = ProfilesConfig(dir: "~/.config/kikimi/profiles/")

    init(dir: String) {
        self.dir = dir
    }

    /// Custom decoder mirroring `DiarizationConfig.init(from:)`: a partial (or absent) `profiles:`
    /// section fills the missing field from `.default` instead of failing the whole `config.yaml`
    /// decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dir = try container.decodeIfPresent(String.self, forKey: .dir) ?? Self.default.dir
    }
}
