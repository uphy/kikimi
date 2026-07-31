import Foundation

// MARK: - MeetingProfile

/// One saved meeting profile: `profile.yaml` (`MeetingProfileManifest`) decoded plus which optional
/// prep files exist on disk (`docs/design/41-meeting-profiles.md` §2.1, §3.2). This is a plain,
/// filesystem-independent value -- `MeetingProfileStore` is the actor that reads/writes it; this
/// type carries no path or I/O of its own so it stays trivially `Sendable` and testable without a
/// directory on disk.
struct MeetingProfile: Identifiable, Equatable, Sendable {
    /// Directory name under `profiles.dir`. Always satisfies
    /// `MeetingProfileIdValidation.validate(_:)` -- `MeetingProfileStore` never surfaces a profile
    /// whose directory name doesn't.
    let id: String
    /// `profile.yaml`'s `name`. Display name; UI falls back to `id` when this is empty (§2.2: "空
    /// なら id で表示"). This type itself never performs that fallback -- callers (list rows, menu
    /// items, ...) do, per each call site's own display contract.
    var name: String
    /// `profile.yaml`'s `description`. `nil`/absent means no subtext.
    var description: String?
    /// `profile.yaml`'s `enabled_watchers`. `nil` means the key was absent (fall back to
    /// `default_watchers.yaml`, §4's file-by-file table); an empty array means the key was present
    /// but empty (enable nothing) -- the two are deliberately distinct (§2.2).
    var enabledWatchers: [String]?
    /// `profile.yaml`'s `participant_ids`. `nil` means the key was absent (write no
    /// `participants.json` on Draft creation, §4); an empty array means the key was present but
    /// empty (write an empty roster).
    var participantIds: [String]?
    /// Whether `profiles/<id>/context.md` exists and was readable when this value was produced.
    let hasContext: Bool
    /// Whether `profiles/<id>/summary_template.md` exists and was readable when this value was
    /// produced.
    let hasSummaryTemplate: Bool
}

// MARK: - MeetingProfileDraft

/// Input to `MeetingProfileStore.save(_:overwrite:)` (§3.2, §5): everything a profile persists,
/// gathered by the caller (the "プロファイルとして保存…" sheet). Unlike `MeetingProfile`, this type
/// carries the actual file contents (`context`/`summaryTemplate`) rather than just presence flags,
/// since it's the *input* to a write rather than the *result* of reading what's already on disk.
struct MeetingProfileDraft: Equatable, Sendable {
    /// Directory name to create/overwrite under `profiles.dir`. Must satisfy
    /// `MeetingProfileIdValidation.validate(_:)` -- `MeetingProfileStore.save(_:overwrite:)` is
    /// responsible for rejecting an invalid id (`MeetingProfileStoreError.invalidId`), not this type.
    var id: String
    var name: String
    var description: String?
    /// `nil` means don't write `context.md` (leave the profile without one, or leave an existing one
    /// untouched on overwrite -- `MeetingProfileStore.save(_:overwrite:)` defines the exact
    /// overwrite semantics).
    var context: String?
    /// `nil` means don't write `summary_template.md`. See `context`'s doc comment.
    var summaryTemplate: String?
    /// Preset ids only (§5: "session-local にしか定義が無い id は除外" -- the caller filters those out
    /// before constructing this draft). `nil` means leave the `enabled_watchers` key untouched --
    /// omitted on a brand-new profile (fall back to `default_watchers.yaml` on later Draft creation),
    /// carried over from the existing manifest on overwrite (see `context`'s doc comment); an empty
    /// array means write the key with an empty list (enable nothing).
    var enabledWatchers: [String]?
    /// `nil` means leave the `participant_ids` key untouched (see `enabledWatchers`'s doc comment).
    /// An empty array means write the key with an empty list.
    var participantIds: [String]?
}

// MARK: - MeetingProfileManifest

/// `profile.yaml`'s on-disk shape (§2.2), decoded directly by `Yams.YAMLDecoder` -- mirrors
/// `EnabledWatchersFile`'s "thin YAML transport shape" idiom rather than going through `YAMLStore`
/// (no file watching / auto-reload is needed for a single-shot profile read, §3.2).
///
/// `enabledWatchers`/`participantIds` are `Optional` array properties with no custom
/// `init(from:)`: Swift's synthesized `Decodable` conformance already calls `decodeIfPresent` for an
/// `Optional`-typed property, which is exactly the "key absent -> nil, key present (even empty) ->
/// the array" distinction §2.2 requires -- no hand-written decoder is needed to get that right.
struct MeetingProfileManifest: Codable, Equatable, Sendable {
    /// Required display name (§2.2: "表示名（必須。空なら id で表示）"). A `profile.yaml` missing this
    /// key fails to decode -- `MeetingProfileStore.list()`/`read(id:)` treat that the same as any
    /// other broken manifest (skipped with a `.warning` log / `nil`, §3.2).
    var name: String
    var description: String?
    var enabledWatchers: [String]?
    var participantIds: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case enabledWatchers = "enabled_watchers"
        case participantIds = "participant_ids"
    }
}
