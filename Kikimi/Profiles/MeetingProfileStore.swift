import Foundation
import OSLog
import Yams

// MARK: - MeetingProfileStoreError

/// Failure modes `MeetingProfileStore`'s mutating methods surface (`docs/design/
/// 41-meeting-profiles.md` §3.2/§8). `list()`/`read(id:)`/`readContext(id:)`/`readSummaryTemplate(id:)`
/// never throw -- they degrade to `[]`/`nil` instead (§8 #1/#2), mirroring `WatcherLibrary`'s own
/// "reads never throw, writes can" split.
enum MeetingProfileStoreError: LocalizedError, Equatable, Sendable {
    /// `save(_:overwrite:)` was given a `draft.id` that fails `MeetingProfileIdValidation.validate(_:)`.
    case invalidId(String)
    /// `save(_:overwrite:)` could not write the profile: an id collision with `overwrite: false`, or
    /// an underlying filesystem failure while staging/swapping the temp directory (§8 #8). Either
    /// way, the existing profile (if any) is left untouched -- see `save(_:overwrite:)`'s doc
    /// comment. Also used by `rename(id:newName:)` for an underlying write failure.
    case writeFailed(id: String, reason: String)
    /// `delete(id:)`/`rename(id:newName:)` targeted an id that is invalid, or whose directory /
    /// `profile.yaml` does not exist or does not decode.
    case notFound(String)
    /// `delete(id:)` found the profile but could not remove its directory (permissions, a file still
    /// open, ...).
    case deleteFailed(id: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidId(let id):
            return "Invalid profile id \"\(id)\": only ASCII letters, digits, and hyphens are allowed."
        case .writeFailed(let id, let reason):
            return "Failed to save profile \"\(id)\": \(reason)"
        case .notFound(let id):
            return "Profile not found: \(id)"
        case .deleteFailed(let id, let reason):
            return "Failed to delete profile \"\(id)\": \(reason)"
        }
    }
}

// MARK: - MeetingProfileStore

/// Directory-scanning store for `profiles.dir` (`docs/design/41-meeting-profiles.md` §2, §3.2 --
/// same idiom as `WatcherLibrary`'s preset directory: the filesystem is the single source of truth,
/// no caching, no file watching, every call re-reads). An actor so `save`/`delete`/`rename` are
/// serialized against concurrent Settings-tab + prep-tab use.
///
/// `MeetingProfileManifest`/`MeetingProfile`/`MeetingProfileDraft` (`MeetingProfile.swift`) and
/// `MeetingProfileIdValidation` (`MeetingProfileIdValidation.swift`) live in sibling files -- this
/// type is purely the disk I/O layer over them. `profile.yaml` is read/written with `Yams`
/// (`YAMLDecoder`/`YAMLEncoder`) directly, mirroring `EnabledWatchersFile`'s "thin YAML transport
/// shape" idiom (`SessionHandle+GenericStorage.swift`) rather than `YAMLStore`, which exists for
/// auto-reloading *global* config/state singletons -- a single profile read/write here has no such
/// need (§3.2, §11).
actor MeetingProfileStore {
    static let shared = MeetingProfileStore(
        directoryURL: FileManager.expandingTildePath(AppConfig.shared.data.profiles.dir)
    )

    /// `profiles.dir`, already tilde-expanded by the caller (`static let shared` above; tests pass a
    /// temporary directory directly).
    let directoryURL: URL
    private let fileManager: FileManager

    private static let manifestFilename = "profile.yaml"
    private static let contextFilename = "context.md"
    private static let summaryTemplateFilename = "summary_template.md"

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "MeetingProfileStore")

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    // MARK: - Reads

    /// All valid profiles under `directoryURL`, sorted by `name` (Japanese-aware,
    /// `localizedStandardCompare`, matching `AudioInputEnumerator`'s own sort idiom). `directoryURL`
    /// not existing yet (first launch, §8 #1) returns `[]` with no log -- the same "not-yet-created
    /// root directory is a normal state" treatment `SessionStore.listSessions()` gives
    /// `sessionsRootDirectory`. Any entry that is not a directory, whose name fails
    /// `MeetingProfileIdValidation.validate(_:)`, or whose `profile.yaml` is missing/undecodable
    /// (§8 #2) is skipped with a `.warning` log rather than failing the whole call.
    func list() -> [MeetingProfile] {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError {
                Self.logger.warning(
                    "Could not list the profiles directory at \(self.directoryURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            return []
        }

        var results: [MeetingProfile] = []
        for entry in entries {
            guard isDirectory(entry) else { continue }
            let id = entry.lastPathComponent
            guard MeetingProfileIdValidation.validate(id) else {
                Self.logger.warning("Skipping profile directory with an invalid id: \(id, privacy: .public)")
                continue
            }
            guard let profile = readProfile(id: id, profileDirectoryURL: entry) else {
                Self.logger.warning("Skipping profile with a missing/unreadable profile.yaml: \(id, privacy: .public)")
                continue
            }
            results.append(profile)
        }
        return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `nil` when `id` is invalid, the directory is missing, or `profile.yaml` fails to decode
    /// (§3.2).
    func read(id: String) -> MeetingProfile? {
        guard MeetingProfileIdValidation.validate(id) else { return nil }
        return readProfile(id: id, profileDirectoryURL: profileDirectoryURL(id: id))
    }

    /// `profiles/<id>/context.md`'s contents, or `nil` if `id` is invalid or the file is
    /// absent/unreadable (§4's file-by-file table, row 1's first candidate).
    func readContext(id: String) -> String? {
        readOptionalFile(id: id, filename: Self.contextFilename)
    }

    /// `profiles/<id>/summary_template.md`'s contents, or `nil` if `id` is invalid or the file is
    /// absent/unreadable (§4's file-by-file table, row 2's first candidate).
    func readSummaryTemplate(id: String) -> String? {
        readOptionalFile(id: id, filename: Self.summaryTemplateFilename)
    }

    // MARK: - Writes

    /// Creates (or, with `overwrite: true`, overwrites) the profile at `directoryURL/<draft.id>/`.
    ///
    /// Writes everything into a sibling temp directory first, then swaps it into place with a single
    /// `FileManager.replaceItemAt(_:withItemAt:)` (overwrite) or `moveItem(at:to:)` (new profile) --
    /// so a failure at any point up to that final swap/move leaves the existing profile (if any)
    /// completely untouched (§3.2, §8 #8). The temp directory is removed on any failure path.
    ///
    /// A `nil` `draft.description` / `draft.enabledWatchers` / `draft.participantIds` /
    /// `draft.context` / `draft.summaryTemplate` uniformly means "don't touch this"
    /// (`MeetingProfileDraft`'s doc comment; `ProfileSaveComposer`'s "each unchecked box becomes
    /// `nil`" contract relies on this being symmetric across these fields): for a brand-new profile
    /// that simply means the key/file is never written, but for an *overwrite* it means whatever the
    /// existing `profile.yaml` had for that key (or the existing `context.md`/`summary_template.md`
    /// file) is carried over into the new directory unchanged, rather than being dropped. Only a
    /// non-`nil` draft value ever replaces what was there before. `description` is included here even
    /// though today's only caller (the "プロファイルとして保存…" sheet, `docs/design/
    /// 41-meeting-profiles.md` §5) has no description field and always passes `nil` -- without this
    /// fallback, every overwrite-save through that sheet would silently erase a description a profile
    /// already had (e.g. one set by hand-editing `profile.yaml`). `name` is the only manifest field
    /// that is *not* preserve-on-nil, since the sheet always supplies it (possibly empty).
    ///
    /// - Throws: `MeetingProfileStoreError.invalidId` if `draft.id` fails
    ///   `MeetingProfileIdValidation.validate(_:)`; `.writeFailed` if the profile already exists and
    ///   `overwrite` is `false`, or if any I/O step fails.
    func save(_ draft: MeetingProfileDraft, overwrite: Bool) throws {
        guard MeetingProfileIdValidation.validate(draft.id) else {
            throw MeetingProfileStoreError.invalidId(draft.id)
        }

        let finalURL = profileDirectoryURL(id: draft.id)
        let alreadyExists = isDirectory(finalURL)
        if alreadyExists, !overwrite {
            throw MeetingProfileStoreError.writeFailed(id: draft.id, reason: "A profile with this id already exists.")
        }

        let tempURL = directoryURL.appendingPathComponent(".\(draft.id)-\(UUID().uuidString).tmp", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: tempURL, withIntermediateDirectories: true)

            // A nil description/enabledWatchers/participantIds on overwrite carries over the existing
            // manifest's value rather than dropping the key -- see the doc comment above.
            let existingManifest = alreadyExists ? decodeManifest(at: finalURL) : nil
            let manifest = MeetingProfileManifest(
                name: draft.name,
                description: draft.description ?? existingManifest?.description,
                enabledWatchers: draft.enabledWatchers ?? existingManifest?.enabledWatchers,
                participantIds: draft.participantIds ?? existingManifest?.participantIds
            )
            let manifestText = try YAMLEncoder().encode(manifest)
            try manifestText.write(to: tempURL.appendingPathComponent(Self.manifestFilename), atomically: true, encoding: .utf8)

            try stageOptionalFile(
                newContent: draft.context,
                filename: Self.contextFilename,
                existingDirectoryURL: alreadyExists ? finalURL : nil,
                tempDirectoryURL: tempURL
            )
            try stageOptionalFile(
                newContent: draft.summaryTemplate,
                filename: Self.summaryTemplateFilename,
                existingDirectoryURL: alreadyExists ? finalURL : nil,
                tempDirectoryURL: tempURL
            )

            if alreadyExists {
                _ = try fileManager.replaceItemAt(finalURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: finalURL)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            Self.logger.error("Failed to save profile \(draft.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw MeetingProfileStoreError.writeFailed(id: draft.id, reason: error.localizedDescription)
        }
    }

    /// Removes the profile directory at `directoryURL/<id>/`. Sessions whose `meta.profile_id`
    /// references `id` keep that id -- it is provenance only (§2.3) and is never rewritten here.
    ///
    /// - Throws: `MeetingProfileStoreError.notFound` if `id` is invalid or no such directory exists;
    ///   `.deleteFailed` if the directory exists but could not be removed.
    func delete(id: String) throws {
        guard MeetingProfileIdValidation.validate(id) else {
            throw MeetingProfileStoreError.notFound(id)
        }
        let url = profileDirectoryURL(id: id)
        guard isDirectory(url) else {
            throw MeetingProfileStoreError.notFound(id)
        }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            Self.logger.error("Failed to delete profile \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw MeetingProfileStoreError.deleteFailed(id: id, reason: error.localizedDescription)
        }
    }

    /// Rewrites `profile.yaml`'s `name` in place -- `id`/the directory name never change after
    /// creation (§3.2). Every other manifest field (`description`/`enabled_watchers`/
    /// `participant_ids`) is preserved verbatim from the existing `profile.yaml`.
    ///
    /// - Throws: `MeetingProfileStoreError.notFound` if `id` is invalid or `profile.yaml` is
    ///   missing/undecodable; `.writeFailed` if the rewrite itself fails.
    func rename(id: String, newName: String) throws {
        guard MeetingProfileIdValidation.validate(id) else {
            throw MeetingProfileStoreError.notFound(id)
        }
        guard var manifest = decodeManifest(at: profileDirectoryURL(id: id)) else {
            throw MeetingProfileStoreError.notFound(id)
        }
        let manifestURL = profileDirectoryURL(id: id).appendingPathComponent(Self.manifestFilename)
        manifest.name = newName
        do {
            let newText = try YAMLEncoder().encode(manifest)
            try newText.write(to: manifestURL, atomically: true, encoding: .utf8)
        } catch {
            Self.logger.error("Failed to rename profile \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw MeetingProfileStoreError.writeFailed(id: id, reason: error.localizedDescription)
        }
    }

    // MARK: - Private helpers

    private func profileDirectoryURL(id: String) -> URL {
        directoryURL.appendingPathComponent(id, isDirectory: true)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Decodes `profileDirectoryURL/profile.yaml`, or `nil` if it is missing/unreadable/undecodable.
    /// Shared by `readProfile(id:profileDirectoryURL:)`, `save(_:overwrite:)`'s overwrite-preserve
    /// lookup, and `rename(id:newName:)`.
    private func decodeManifest(at profileDirectoryURL: URL) -> MeetingProfileManifest? {
        let manifestURL = profileDirectoryURL.appendingPathComponent(Self.manifestFilename)
        guard let manifestText = try? String(contentsOf: manifestURL, encoding: .utf8) else { return nil }
        return try? YAMLDecoder().decode(MeetingProfileManifest.self, from: manifestText)
    }

    /// Decodes `profileDirectoryURL/profile.yaml` into a `MeetingProfile`, or `nil` if it is
    /// missing/unreadable/undecodable.
    private func readProfile(id: String, profileDirectoryURL: URL) -> MeetingProfile? {
        guard let manifest = decodeManifest(at: profileDirectoryURL) else { return nil }

        let contextURL = profileDirectoryURL.appendingPathComponent(Self.contextFilename)
        let summaryTemplateURL = profileDirectoryURL.appendingPathComponent(Self.summaryTemplateFilename)
        return MeetingProfile(
            id: id,
            name: manifest.name,
            description: manifest.description,
            enabledWatchers: manifest.enabledWatchers,
            participantIds: manifest.participantIds,
            hasContext: fileManager.isReadableFile(atPath: contextURL.path),
            hasSummaryTemplate: fileManager.isReadableFile(atPath: summaryTemplateURL.path)
        )
    }

    private func readOptionalFile(id: String, filename: String) -> String? {
        guard MeetingProfileIdValidation.validate(id) else { return nil }
        let url = profileDirectoryURL(id: id).appendingPathComponent(filename)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Stages one optional content file (`context.md`/`summary_template.md`) into `tempDirectoryURL`
    /// for `save(_:overwrite:)`: `newContent` non-`nil` writes it verbatim; `newContent == nil` with
    /// `existingDirectoryURL` non-`nil` (an overwrite) copies that file over unchanged if it exists,
    /// so overwriting a profile without re-supplying a field never silently drops it; `newContent ==
    /// nil` with `existingDirectoryURL == nil` (a brand-new profile, or a field this profile never
    /// had) writes nothing at all.
    private func stageOptionalFile(
        newContent: String?,
        filename: String,
        existingDirectoryURL: URL?,
        tempDirectoryURL: URL
    ) throws {
        let destinationURL = tempDirectoryURL.appendingPathComponent(filename)
        if let newContent {
            try newContent.write(to: destinationURL, atomically: true, encoding: .utf8)
            return
        }
        guard let existingDirectoryURL else { return }
        let sourceURL = existingDirectoryURL.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }
}
