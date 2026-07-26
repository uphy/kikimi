import Foundation
import OSLog

// MARK: - VoiceprintSpeaker

/// One registered voice in the global voiceprint database (`docs/design/13-speaker-diarization.md`
/// section 4.4). `embedding` is expected to already be the L2-normalized 256-d WeSpeaker vector
/// (`VoiceprintExtractor`'s job, not this store's — see the module task notes for R2) so
/// `VoiceprintStore.cosineDistance(_:_:)` stays cheap and every stored entry is directly comparable.
///
/// Registration happens through a user rename (design section 4.4: "登録経路はユーザーのリネーム操作のみ。
/// 自動では増やさない") or, as of `docs/design/22-participant-hints.md` section 4.1 (P2), through the
/// participant-hints suggest box registering an unrecognized name with an empty `embedding: []` --
/// still a user-initiated action, so the "never registered automatically from an auto voiceprint
/// match" invariant is unchanged; only the set of user gestures that can trigger a registration grows.
/// This is why there is no `sessionId`/"first seen" field here — `createdAt` already records when that
/// registration happened.
struct VoiceprintSpeaker: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var embedding: [Float]
    var createdAt: Date
    var updatedAt: Date
    /// The most recent session whose Ended-time moving-average update (design section 4.4, α = 0.1)
    /// was actually applied to `embedding`. `VoiceprintStore.applyMovingAverageUpdate` reads this to
    /// refuse a second application from the same session (dedup guard) rather than to gate matching —
    /// `findMatchCandidate(embedding:)` considers every speaker regardless of this value.
    var lastMatchedSessionId: String?

    init(
        id: String,
        name: String,
        embedding: [Float],
        createdAt: Date,
        updatedAt: Date,
        lastMatchedSessionId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMatchedSessionId = lastMatchedSessionId
    }

    /// Left at the default `camelCase` case names (**not** given explicit `snake_case` raw string
    /// values): `SessionJSONCoding`'s `.convertToSnakeCase`/`.convertFromSnakeCase` key strategies
    /// perform the `camelCase` <-> `snake_case` conversion themselves by transforming the *coding
    /// key's `stringValue`* before matching, so giving a case an explicit `"created_at"` raw value
    /// here would double-convert and silently fail to match anything (`decodeIfPresent` calls below
    /// would then all miss, corrupting every round-trip). Every other `Codable` model that goes
    /// through `SessionJSONCoding` (`SessionModels.swift`, `DiarizationModels.swift`) follows this
    /// same convention: no explicit `snake_case` raw values.
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case embedding
        case createdAt
        case updatedAt
        case lastMatchedSessionId
    }

    /// Defensive decode (mirrors `SpeakerAssignments.init(from:)`,
    /// `SessionStore/DiarizationModels.swift`): `last_matched_session_id` is the one field this
    /// schema could plausibly grow/lose independently (it is set by a code path — the Ended-time
    /// moving-average update — that shipped after the base schema in spirit), so it alone tolerates a
    /// missing key. Every other field is part of design section 4.4's sample JSON from day one and is
    /// required.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        embedding = try container.decode([Float].self, forKey: .embedding)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lastMatchedSessionId = try container.decodeIfPresent(String.self, forKey: .lastMatchedSessionId)
    }
}

// MARK: - VoiceprintDatabase

/// The full contents of `~/.local/state/kikimi/voiceprints.json` (design section 4.4). Whole-file
/// overwrite, but only ever through `VoiceprintStore` (this file), the single actor that owns reads
/// and writes of this path.
struct VoiceprintDatabase: Codable, Sendable, Equatable {
    var speakers: [VoiceprintSpeaker]

    init(speakers: [VoiceprintSpeaker] = []) {
        self.speakers = speakers
    }

    enum CodingKeys: String, CodingKey {
        case speakers
    }

    /// Defensive decode: a freshly-`write`-created-then-truncated file or a future top-level key
    /// addition must not fail decoding of the whole database (same rationale as
    /// `SpeakerAssignments.init(from:)`) — a missing `speakers` array decodes as an empty database
    /// rather than throwing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speakers = try container.decodeIfPresent([VoiceprintSpeaker].self, forKey: .speakers) ?? []
    }
}

// MARK: - VoiceprintStore

/// The single actor allowed to read or write `~/.local/state/kikimi/voiceprints.json` (design section
/// 4.4/7's "グローバル声紋 DB のパスは storage 系と同じ規約で ... 固定"). All cross-session "この声 = この人"
/// bookkeeping — registration, rename, best-match lookup, and the Ended-time moving-average update —
/// goes through this one type, so a concurrent auto-match write (from `RealtimeDiarizationCoordinator`,
/// one session) and a user rename (from another session's UI) can never race each other into a lost
/// update: Swift actor isolation serializes every call below onto this instance's executor, the same
/// guarantee `SessionHandle+Diarization.swift`'s `updateSpeakerAssignments(_:)` gives per-session.
///
/// Loads its database once, synchronously, in `init` (mirroring `YAMLStore.load()`'s "read whatever is
/// on disk right now, or start from the default value" contract) rather than lazily on first access —
/// the file is small (design section 4.4: "1 人あたり約 50KB") and every operation below needs
/// `database` in memory anyway, so there is no benefit to deferring the read.
///
/// Best-effort per kikimi.md 8.5 章 / design section 8: every failure mode this type can hit
/// (missing file, corrupt file, disk write failure) either falls back to an empty database or
/// propagates a `throw` for the caller to catch-and-log — nothing here ever crashes the process or
/// blocks recording/STT.
actor VoiceprintStore {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "VoiceprintStore")

    /// Fixed production path (design section 4.4/7). Tests must construct their own
    /// `VoiceprintStore(fileURL:)` pointing at a temporary file instead of touching this.
    static let defaultFileURL = FileManager.realHomeDirectory
        .appendingPathComponent(".local/state/kikimi/voiceprints.json")

    static let shared = VoiceprintStore(fileURL: VoiceprintStore.defaultFileURL)

    /// α for the Ended-time moving-average voiceprint update when the winning slot for a speaker
    /// stayed `assigned_by: "auto"` all the way to Ended (design section 4.4). Exposed as a default
    /// parameter value on `applyMovingAverageUpdate`, not hardcoded inside it, so tests can exercise
    /// the arithmetic with a distinctive value without depending on the production constant.
    static let defaultMovingAverageAlpha: Double = 0.1

    /// α for the same Ended-time moving-average update when the winning slot is instead
    /// `assigned_by: "user"` (design section 4.4): the user explicitly confirmed or corrected this
    /// speaker, which is a stronger signal than an unreviewed auto-match, so it is weighted more
    /// heavily than `defaultMovingAverageAlpha`. Still bounded well under 1.0 so a single mistaken
    /// correction cannot overwhelm the stored embedding -- it decays via the same EMA on every
    /// subsequent session.
    static let userCorrectionAlpha: Double = 0.3

    private let fileURL: URL
    /// Reuses `SessionStore`'s `snake_case`/ISO-8601 JSON convention (`SessionModels.swift`'s
    /// `SessionJSONCoding`) even though `voiceprints.json` is not a per-session file — there is no
    /// reason for the one JSON file outside `sessions/<id>/` that Kikimi writes to follow a different
    /// convention, and reusing it here keeps `created_at`/`updated_at` formatted identically to every
    /// other timestamp in the app.
    private let encoder = SessionJSONCoding.makeEncoder()

    private var database: VoiceprintDatabase

    /// - Parameter fileURL: Defaults to the production path; tests always override this with a
    ///   temporary file URL (design doc task: "injectable file URL for tests").
    init(fileURL: URL = VoiceprintStore.defaultFileURL) {
        self.fileURL = fileURL
        self.database = Self.loadDatabase(from: fileURL, decoder: SessionJSONCoding.makeDecoder())
    }

    /// - A missing file is a fresh install / first-ever voiceprint registration, not a failure: no
    ///   warning, just an empty database (design doc task: "Missing file => empty DB, no warning").
    /// - An existing-but-unreadable-or-undecodable file is corruption (design section 8:
    ///   "voiceprints.json（グローバル DB）破損 | warning + 空 DB として再スタート（照合が全滅するだけで
    ///   会議は記録できる）"): logged at `.warning` (kikimi.md's logging rule for "Misconfiguration or
    ///   missing resource") and treated as an empty database, never a fatal error. A later
    ///   `registerSpeaker`/`renameSpeaker`/... call will overwrite the corrupt file — deliberately, per
    ///   the same failure mode, unlike `YAMLStore`'s `loadFailed` guard which permanently refuses to
    ///   save over a corrupt config/state file.
    private static func loadDatabase(from url: URL, decoder: JSONDecoder) -> VoiceprintDatabase {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return VoiceprintDatabase()
        }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(VoiceprintDatabase.self, from: data)
        } catch {
            logger.warning(
                """
                voiceprints.json at \(url.path, privacy: .public) could not be read/decoded; starting \
                with an empty voiceprint database: \(String(describing: error), privacy: .public)
                """
            )
            return VoiceprintDatabase()
        }
    }

    // MARK: - Listing / lookup

    /// All registered speakers, in no particular guaranteed order (currently insertion order, since
    /// `database.speakers` is a plain array and every mutator below only appends/edits in place).
    func listSpeakers() -> [VoiceprintSpeaker] {
        database.speakers
    }

    func speaker(id: String) -> VoiceprintSpeaker? {
        database.speakers.first { $0.id == id }
    }

    // MARK: - Registration / rename / delete (design section 4.4: "登録経路はユーザーのリネーム操作のみ")

    /// Registers a brand-new speaker with a fresh UUID `id`. Call sites are a user rename that
    /// introduces a name not already in the global DB (design section 4.4), and, as of
    /// `docs/design/22-participant-hints.md` section 4.1 (P2), the participant-hints suggest box's
    /// `.newName` submission for an unrecognized name, which passes `embedding: []` (no voice sample
    /// yet -- design section 1's "空 embedding のまま新規登録できる"; `findMatchCandidate`'s existing
    /// `isFinite` guard already makes an empty/reset embedding invisible to matching, so this needs no
    /// special-casing here). Nothing in this actor calls this automatically from an auto voiceprint
    /// match.
    @discardableResult
    func registerSpeaker(name: String, embedding: [Float], now: Date = Date()) throws -> VoiceprintSpeaker {
        let speaker = VoiceprintSpeaker(
            id: UUID().uuidString,
            name: name,
            embedding: embedding,
            createdAt: now,
            updatedAt: now,
            lastMatchedSessionId: nil
        )
        return try mutateAndPersist {
            database.speakers.append(speaker)
            return speaker
        }
    }

    /// Renames an existing speaker in place. Never touches `embedding` (design section 4.4: "リネームで
    /// 既存話者を選択 → 割り当てのみ変更し、embedding は更新しない"). A no-op (no throw) if `id` is unknown —
    /// callers are expected to have gotten `id` from `listSpeakers()`/`speaker(id:)` in the first place.
    func renameSpeaker(id: String, name: String, now: Date = Date()) throws {
        guard let index = database.speakers.firstIndex(where: { $0.id == id }) else { return }
        try mutateAndPersist {
            database.speakers[index].name = name
            database.speakers[index].updatedAt = now
        }
    }

    /// Removes a speaker entirely. No cascading cleanup of any session's `speaker_assignments.json`
    /// `global_speaker_id` references (design doc leaves this out of scope for R2 module 1) — a
    /// dangling reference simply fails to resolve to a `VoiceprintSpeaker` the next time it's looked up.
    func deleteSpeaker(id: String) throws {
        try mutateAndPersist {
            database.speakers.removeAll { $0.id == id }
        }
    }

    // MARK: - Reset (design section 4.4 "声紋リセット（誤マッピング汚染からの修復経路）")

    /// Clears a speaker's stored `embedding` (and `lastMatchedSessionId`) while keeping the
    /// speaker's `id`/`name`/`createdAt` intact — the repair path for a speaker whose voiceprint
    /// has drifted onto someone else's voice through repeated bad auto-matches (design section
    /// 4.4): unlike `deleteSpeaker`, this never invalidates a session's `speaker_assignments.json`
    /// `global_speaker_id` reference or loses the display name, it only takes the speaker back out
    /// of automatic matching. An empty `embedding` makes `cosineDistance` return `.infinity`
    /// (existing guard, unchanged by this method), so `findMatchCandidate` can never select this
    /// speaker as nearest or runner-up again until `applyMovingAverageUpdate` re-enrolls it wholesale
    /// from a fresh sample (below).
    /// A no-op (no throw) if `id` is unknown, mirroring `renameSpeaker`.
    func resetSpeakerEmbedding(id: String, now: Date = Date()) throws {
        guard let index = database.speakers.firstIndex(where: { $0.id == id }) else { return }
        try mutateAndPersist {
            database.speakers[index].embedding = []
            database.speakers[index].lastMatchedSessionId = nil
            database.speakers[index].updatedAt = now
        }
    }

    // MARK: - Matching

    /// The nearest registered speaker to `embedding` plus enough context (the runner-up) for
    /// `VoiceprintMatchPolicy.decide(candidate:threshold:margin:)` to judge whether that nearest match
    /// is ambiguous (`docs/design/20-voiceprint-misassignment-mitigation.md` section 3.1). Unlike the
    /// former `findBestMatch(embedding:threshold:)` this method is **threshold-agnostic** — it always
    /// returns the closest speaker regardless of distance, deferring the accept/reject decision (and
    /// the distance logging that goes with it) entirely to the caller
    /// (`RealtimeDiarizationCoordinator+Voiceprint.swift`'s `extractAndMatchVoiceprint`).
    /// A `VoiceprintMatchCandidate`'s runner-up (declared as a sibling of that type, not nested inside
    /// it, to stay within the project's "nested at most 1 level deep" SwiftLint limit — `Voiceprint
    /// MatchCandidate` is already nested one level inside this actor).
    struct RunnerUp: Sendable, Equatable {
        let name: String
        let distance: Float
    }

    struct VoiceprintMatchCandidate: Sendable, Equatable {
        let speaker: VoiceprintSpeaker
        let distance: Float
        /// The closest speaker whose *trimmed* `name` differs from `speaker.name`'s trimmed form,
        /// bundled as one value (rather than two parallel optionals) since they are always either both
        /// present or both absent. `nil` when no other registered speaker has a distinct name (a single
        /// registration, or a database where every entry shares this same name — design section 3.1/
        /// 3.2) — there is then no "different person" to be ambiguous against, so
        /// `VoiceprintMatchPolicy` treats a `nil` runner-up as "no margin competitor".
        let runnerUp: RunnerUp?
    }

    /// Finds the closest registered speaker to `embedding` (design section 3.1), or `nil` if the
    /// database is empty or every entry has an empty/reset `embedding` (`cosineDistance` returns
    /// `.infinity` for those — design section 3.2's "`.infinity` は最近傍にも次点にもなり得ない" — so they
    /// are excluded from both the nearest and runner-up search here, not merely from acceptance).
    ///
    /// The runner-up is deliberately **not** simply "the second-closest speaker overall": it is the
    /// closest speaker whose trimmed `name` differs from the nearest match's trimmed `name` (design
    /// section 3.1). Two registered entries that happen to share a (trimmed) display name — an
    /// existing duplicate registration, design section 3.2's open question — are the same person as
    /// far as this policy cares, so a second entry for that same person must never itself count as an
    /// ambiguity signal against the nearest match.
    ///
    /// - Parameter allowedSpeakerIds: The participant-hints closed-set filter
    ///   (`docs/design/22-participant-hints.md` section 2.1). `nil` (the default) means open-set
    ///   matching -- every registered speaker is a candidate, exactly this method's pre-P1 behavior, so
    ///   every existing call site/test that never passes this parameter is unaffected. When non-`nil`,
    ///   **both** the nearest match and the runner-up are restricted to speakers whose `id` is in the
    ///   set -- a name-only-different-but-off-roster speaker must not even function as a margin
    ///   competitor, or an off-roster near-duplicate could silently suppress an on-roster match via
    ///   `rejectedByMargin` (design section 2.1: "最近傍・次点（runner-up）とも許可リスト内の speaker からのみ選ぶ")
    ///   -- the margin judgment itself, `VoiceprintMatchPolicy` (unchanged), still runs purely on
    ///   whichever nearest/runner-up this method hands it. An **empty** set is treated defensively as
    ///   `nil` resolved to "no candidates" -- i.e. this returns `nil` immediately -- rather than iterating
    ///   an empty allow-list to the same effect, since a caller is never supposed to pass one (design
    ///   section 2.1: "名簿ゼロ = オープンセットは呼び出し側で `nil` に解決する"; this is the safe-side fallback if
    ///   that contract is ever violated, matching design section 6's "誤り = 割り当てなし" bias).
    func findMatchCandidate(embedding: [Float], allowedSpeakerIds: Set<String>? = nil) -> VoiceprintMatchCandidate? {
        if let allowedSpeakerIds, allowedSpeakerIds.isEmpty {
            return nil
        }

        var nearest: (speaker: VoiceprintSpeaker, distance: Float)?
        for speaker in database.speakers {
            if let allowedSpeakerIds, !allowedSpeakerIds.contains(speaker.id) { continue }
            let distance = Self.cosineDistance(embedding, speaker.embedding)
            guard distance.isFinite else { continue }
            if nearest == nil || distance < nearest!.distance {
                nearest = (speaker, distance)
            }
        }
        guard let nearest else { return nil }

        var runnerUp: (speaker: VoiceprintSpeaker, distance: Float)?
        for speaker in database.speakers {
            guard speaker.id != nearest.speaker.id else { continue }
            if let allowedSpeakerIds, !allowedSpeakerIds.contains(speaker.id) { continue }
            guard !SpeakerName.isSame(speaker.name, nearest.speaker.name) else { continue }
            let distance = Self.cosineDistance(embedding, speaker.embedding)
            guard distance.isFinite else { continue }
            if runnerUp == nil || distance < runnerUp!.distance {
                runnerUp = (speaker, distance)
            }
        }

        return VoiceprintMatchCandidate(
            speaker: nearest.speaker,
            distance: nearest.distance,
            runnerUp: runnerUp.map { RunnerUp(name: $0.speaker.name, distance: $0.distance) }
        )
    }

    /// Pure, `nonisolated` cosine-distance function so it is directly unit-testable without an actor
    /// hop and reusable outside this actor if another R2 module needs the same math. Replicates
    /// FluidAudio's `SpeakerUtilities.cosineDistance` convention confirmed by the spike facts: smaller
    /// = closer, `1 - cosine_similarity`, not raw similarity. Divides by both vectors' norms rather
    /// than assuming pre-normalized unit vectors, so it is correct regardless of whether the caller
    /// already L2-normalized `embedding`/the stored voiceprint.
    ///
    /// Returns `Float.infinity` (never matches any positive threshold) for mismatched lengths, empty
    /// vectors, or a zero vector on either side — all of which indicate a caller bug or a corrupt
    /// stored embedding, not a real comparison.
    nonisolated static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return .infinity }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for index in 0..<a.count {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return .infinity }
        let similarity = dot / (normA.squareRoot() * normB.squareRoot())
        return 1 - similarity
    }

    // MARK: - Ended-time moving-average update (design section 4.4)

    /// Applies the α-weighted moving-average update to a speaker's stored `embedding`
    /// (`updated = (1 - α) * old + α * new`), meant to be called at most once per session per speaker,
    /// at Ended time, for whichever single slot the caller has already picked as that speaker's best
    /// sample this session (design section 4.4: a `.user`-confirmed/corrected slot, when one exists,
    /// wins over a merely `.auto`-matched one, with `alpha` chosen accordingly —
    /// `userCorrectionAlpha`/`defaultMovingAverageAlpha`). Picking that winning slot and its `alpha` is
    /// the caller's job; this method only enforces the dedup guard below.
    ///
    /// **Re-enrollment after a voiceprint reset** (design section 4.4 "声紋リセット"): when the
    /// stored `embedding` is empty (only possible via `resetSpeakerEmbedding`), there is nothing
    /// meaningful to average against, so this adopts `newEmbedding` wholesale — effectively
    /// α = 1.0 — instead of computing a weighted average against an empty vector. This is how
    /// "reset → next meeting the user manually assigns this person → the voiceprint re-learns at
    /// Ended" completes without a second registration code path. The non-empty/non-empty length
    /// mismatch guard below is unchanged.
    ///
    /// - Returns: `true` if the update was applied, `false` if it was skipped because
    ///   `sessionId` already matches the speaker's `lastMatchedSessionId` (design section 4.4:
    ///   "`last_matched_session_id` で同一セッションからの重複適用を防ぐ") or `speakerId`/`newEmbedding` are
    ///   invalid (unknown id, empty `newEmbedding`, or a length mismatch against a non-empty stored
    ///   embedding — guards against corrupt/placeholder input silently poisoning the voiceprint).
    @discardableResult
    func applyMovingAverageUpdate(
        speakerId: String,
        newEmbedding: [Float],
        sessionId: String,
        alpha: Double = VoiceprintStore.defaultMovingAverageAlpha,
        now: Date = Date()
    ) throws -> Bool {
        guard let index = database.speakers.firstIndex(where: { $0.id == speakerId }) else {
            Self.logger.warning(
                "applyMovingAverageUpdate: unknown speaker id \(speakerId, privacy: .public); skipping."
            )
            return false
        }
        guard database.speakers[index].lastMatchedSessionId != sessionId else {
            // Already applied for this session (dedup guard) — not an error, just a no-op. Still
            // enforced even for a just-reset speaker (whose `lastMatchedSessionId` was cleared to
            // `nil` by `resetSpeakerEmbedding`, so in practice this never blocks the very next
            // re-enrollment call).
            return false
        }
        guard !newEmbedding.isEmpty else {
            Self.logger.warning(
                "applyMovingAverageUpdate: empty newEmbedding for speaker \(speakerId, privacy: .public); skipping."
            )
            return false
        }

        let existing = database.speakers[index].embedding
        let updated: [Float]
        if existing.isEmpty {
            // Re-enrollment path (see doc comment above): no prior sample to average against.
            updated = newEmbedding
        } else {
            guard existing.count == newEmbedding.count else {
                Self.logger.warning(
                    """
                    applyMovingAverageUpdate: embedding length mismatch for speaker \
                    \(speakerId, privacy: .public) (stored \(existing.count, privacy: .public), \
                    new \(newEmbedding.count, privacy: .public)); skipping.
                    """
                )
                return false
            }
            let keepWeight = Float(1 - alpha)
            let newWeight = Float(alpha)
            updated = (0..<existing.count).map { keepWeight * existing[$0] + newWeight * newEmbedding[$0] }
        }

        return try mutateAndPersist {
            database.speakers[index].embedding = updated
            database.speakers[index].lastMatchedSessionId = sessionId
            database.speakers[index].updatedAt = now
            return true
        }
    }

    // MARK: - Private

    /// Applies `mutation` to `database` in place, then persists, rolling `database` back to its
    /// pre-mutation snapshot if `persist()` throws — so a single unencodable entry (e.g. a NaN-
    /// containing embedding; `JSONEncoder`'s default `nonConformingFloatEncodingStrategy` is `.throw`,
    /// and `VoiceprintExtractor.l2Normalize` passes a NaN-containing vector through unchanged rather
    /// than rejecting it, since `guard norm > 0` is false for NaN too) cannot get stuck in `database`
    /// and permanently wedge every *future* call to this actor: without this rollback, `persist()`
    /// re-encodes the *entire* `speakers` array on every call, so one poisoned in-memory entry would
    /// make every subsequent `registerSpeaker`/`renameSpeaker`/`deleteSpeaker`/
    /// `applyMovingAverageUpdate` throw too, for the rest of the process's life, even though each
    /// individual caller believes it degraded gracefully (best-effort log-and-swallow, kikimi.md 8.5
    /// 章 / design section 8) rather than realizing global persistence is now wedged. All mutators
    /// above go through this helper instead of touching `database`/`persist()` directly.
    private func mutateAndPersist<T>(_ mutation: () -> T) throws -> T {
        let snapshot = database
        let result = mutation()
        do {
            try persist()
        } catch {
            database = snapshot
            throw error
        }
        return result
    }

    private func persist() throws {
        let data = try encoder.encode(database)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Temp-file-then-rename under the hood (same convention as `SessionHandle`'s
        // `atomicWriteData(_:to:)` and `YAMLStore.save()`'s `atomically: true`), so a crash mid-write
        // never leaves a half-written `voiceprints.json` behind.
        try data.write(to: fileURL, options: [.atomic])
    }
}
