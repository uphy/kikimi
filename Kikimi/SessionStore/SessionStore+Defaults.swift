import Foundation
import Yams

// MARK: - SessionStore + Defaults (createDraftSession(seed:)'s source resolution)

/// Split out of `SessionStore.swift` to keep that file under the project's `file_length` lint limit.
/// Owns every `createDraftSession(seed:)` default-resolution helper: `context.md`/
/// `summary_template.md`/`participant_ids`/`enabled.yaml`'s initial contents for a brand-new session,
/// each falling back through seed-source -> global-default -> built-in-default (where applicable),
/// per `docs/design/41-meeting-profiles.md` §4's per-file resolution-chain table (failure modes are
/// §8) / `docs/design/22-participant-hints.md` section 1.3.
///
/// Every helper below takes `seed: DraftSeed` plus `profile: MeetingProfile?` -- the caller
/// (`SessionStore.createDraftSession(seed:)`) is the one that resolves a `.profile(id:)` seed
/// against `MeetingProfileStore` *once* and logs the section 8 failure-mode-#3 `.warning` there if
/// that resolution itself fails; `profile == nil` while `seed` is still `.profile(id:)` is exactly
/// how that "requested profile could not be resolved" outcome arrives here. These helpers never
/// re-resolve or re-log that top-level failure -- they only decide, file by file, what to do once a
/// seed (or the absence of one) is already known.
extension SessionStore {
    /// Tilde-expanded form of `ProfilesConfig.default.dir` (`docs/design/41-meeting-profiles.md`
    /// §2.4) -- meant to never drift apart from it, same as `defaultContextFileURL`/
    /// `defaultSummaryTemplateFileURL` (`SessionStore.swift`).
    static var defaultProfilesDirectoryURL: URL {
        FileManager.realHomeDirectory.appendingPathComponent(".config/kikimi/profiles", isDirectory: true)
    }

    /// Thin compatibility wrapper over `createDraftSession(seed:)` (`docs/design/
    /// 41-meeting-profiles.md` §3.1): every pre-profiles call site only ever needed `.meta`, so this
    /// keeps compiling unchanged rather than forcing a blanket migration to `seed:`.
    @discardableResult
    func createDraftSession(basedOn sourceSessionId: String? = nil) async throws -> SessionMeta {
        try await createDraftSession(seed: sourceSessionId.map { .basedOn(sessionId: $0) } ?? .none).meta
    }

    /// Resolves `seed` into what `createDraftSession(seed:)` should actually apply, consulting a
    /// `MeetingProfileStore` scoped to this `SessionStore`'s own `profilesDirectoryURL` for a
    /// `.profile(id:)` seed exactly once (`docs/design/41-meeting-profiles.md` §4 / §8 failure mode
    /// #3). Deliberately **not** `MeetingProfileStore.shared`: that singleton always reads
    /// `AppConfig.shared.data.profiles.dir`, which would silently ignore this `SessionStore`
    /// instance's `profilesDirectoryURL` DI (breaking the same test-isolation guarantee
    /// `sessionsRootDirectory`/`defaultContextFileURL`/etc. give -- `loadInitialContext(seed:profile:)`/
    /// `loadInitialSummaryTemplate(seed:profile:)` already read `profilesDirectoryURL` directly for the
    /// same reason). `static let shared`'s `profilesDirectoryURL` happens to equal
    /// `MeetingProfileStore.shared`'s directory in production, but every DI'd test instance needs its
    /// own scoped store to stay isolated from the real `~/.config/kikimi/profiles`.
    ///
    /// - `.none`/`.basedOn` pass through unchanged as `.none`/`.basedOn`, with no resolved profile.
    /// - `.profile(id:)` that resolves returns `.profile(id:)` plus the resolved `MeetingProfile`.
    /// - `.profile(id:)` that does **not** resolve (invalid id / missing directory / broken
    ///   `profile.yaml`, i.e. `MeetingProfileStore.read(id:)` returns `nil`) logs a `.warning` here
    ///   (the only place this failure is logged) and returns `.profileFallback(requestedId:)` with no
    ///   resolved profile -- the caller then seeds the session exactly as `.none` would and does not
    ///   record `meta.profileId` (§4: "meta.profile_id は記録しない"). This never throws
    ///   `SessionStoreError`: an unresolvable profile is a soft fallback, not a creation failure.
    func resolveDraftSeed(_ seed: DraftSeed) async -> (appliedSeed: AppliedDraftSeed, profile: MeetingProfile?) {
        switch seed {
        case .none:
            return (.none, nil)
        case .basedOn(let sourceSessionId):
            return (.basedOn(sessionId: sourceSessionId), nil)
        case .profile(let profileId):
            let profileStore = MeetingProfileStore(directoryURL: profilesDirectoryURL)
            if let profile = await profileStore.read(id: profileId) {
                return (.profile(id: profileId), profile)
            }
            logger.warning(
                "Could not resolve meeting profile \(profileId, privacy: .public) for Draft creation; continuing with global defaults"
            )
            return (.profileFallback(requestedId: profileId), nil)
        }
    }

    /// Resolves the initial `context.md` contents for `createDraftSession(seed:)`
    /// (`docs/design/41-meeting-profiles.md` §4's table, row 1): the seed's own `context.md` first
    /// (source session for `.basedOn`, `profiles/<id>/context.md` for a resolved `.profile`), then
    /// the global default, then an empty string.
    func loadInitialContext(seed: DraftSeed, profile: MeetingProfile?) -> String {
        switch seed {
        case .none:
            break
        case .basedOn(let sourceSessionId):
            let url = sessionsRootDirectory.appendingPathComponent(sourceSessionId, isDirectory: true)
                .appendingPathComponent("context.md")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
            logger.warning("Could not read context.md from source session \(sourceSessionId, privacy: .public); falling back to the global default")
        case .profile(let profileId):
            // `profile == nil` here means the profile itself failed to resolve (invalid id /
            // missing directory / broken `profile.yaml`); the caller already logged that at
            // `.warning` (design doc §4/§8 #3), so fall straight through to the global default
            // below without a second, redundant warning.
            if profile != nil {
                let url = profilesDirectoryURL.appendingPathComponent(profileId, isDirectory: true)
                    .appendingPathComponent("context.md")
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    return text
                }
                logger.warning("Could not read context.md from profile \(profileId, privacy: .public); falling back to the global default")
            }
        }
        if let text = try? String(contentsOf: defaultContextFileURL, encoding: .utf8) {
            return text
        }
        logger.warning("Could not read the default context file at \(self.defaultContextFileURL.path, privacy: .public); starting with an empty context")
        return ""
    }

    /// Resolves the initial `summary_template.md` contents for `createDraftSession(seed:)`
    /// (`docs/design/41-meeting-profiles.md` §4's table, row 2): the seed's own
    /// `summary_template.md` first, then the global default, then the built-in template.
    func loadInitialSummaryTemplate(seed: DraftSeed, profile: MeetingProfile?) -> String {
        switch seed {
        case .none:
            break
        case .basedOn(let sourceSessionId):
            let url = sessionsRootDirectory.appendingPathComponent(sourceSessionId, isDirectory: true)
                .appendingPathComponent("summary_template.md")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
            logger.warning(
                "Could not read summary_template.md from source session \(sourceSessionId, privacy: .public); falling back to the global default"
            )
        case .profile(let profileId):
            // See `loadInitialContext(seed:profile:)`: `profile == nil` means the top-level
            // resolution already failed (and already warned), so no second warning here.
            if profile != nil {
                let url = profilesDirectoryURL.appendingPathComponent(profileId, isDirectory: true)
                    .appendingPathComponent("summary_template.md")
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    return text
                }
                logger.warning(
                    "Could not read summary_template.md from profile \(profileId, privacy: .public); falling back to the global default"
                )
            }
        }
        if let text = try? String(contentsOf: defaultSummaryTemplateFileURL, encoding: .utf8) {
            return text
        }
        logger.warning(
            "Could not read the default summary template file at \(self.defaultSummaryTemplateFileURL.path, privacy: .public); using the built-in default template"
        )
        return Self.builtInDefaultSummaryTemplate
    }

    /// Resolves the initial `participant_ids` for `createDraftSession(seed:)`
    /// (`docs/design/41-meeting-profiles.md` §4's table, row 4 / `docs/design/
    /// 22-participant-hints.md` section 1.3): `nil` when there is no seed-provided roster --
    /// unlike `loadInitialContext`/`loadInitialSummaryTemplate`, there is no global-default fallback
    /// to try (a participant roster is inherently session/profile-specific, kikimi.md has no
    /// `defaults.participants_file` equivalent), so a `nil` here means "write nothing" at the call
    /// site, not "fall back to some other source". Unresolved/unknown speaker ids inside a
    /// profile's `participant_ids` are passed through as-is, unvalidated (design doc §4/§8 #6).
    func loadInitialParticipantIds(seed: DraftSeed, profile: MeetingProfile?) -> [String]? {
        switch seed {
        case .none:
            return nil
        case .basedOn(let sourceSessionId):
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
        case .profile:
            // `profile.yaml`'s `participant_ids` is already-decoded structured data (unlike
            // context.md/summary_template.md, there is no separate on-disk read to fail here), and
            // `profile == nil` (unresolved profile) collapses to "no roster" the same as `.none`.
            return profile?.participantIds
        }
    }

    /// Resolves the initial `watchers/enabled.yaml` contents for `createDraftSession(seed:)`
    /// (`docs/design/41-meeting-profiles.md` §4's table, row 3 / kikimi.md 9 章): a resolved
    /// `.profile` seed's own `enabled_watchers` first *if the key is present* (an explicit empty
    /// list is honored -- "enable nothing" -- design doc §2.2), then `defaults.default_enabled_file`,
    /// then an empty list. `.basedOn`/`.none` are unchanged from the pre-profiles behavior: neither
    /// ever copies a source session's `enabled.yaml`, only `.profile` adds a seed-level override.
    func loadInitialEnabledWatchers(seed: DraftSeed, profile: MeetingProfile?) -> [String] {
        if case .profile = seed, let enabledWatchers = profile?.enabledWatchers {
            return enabledWatchers
        }
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
