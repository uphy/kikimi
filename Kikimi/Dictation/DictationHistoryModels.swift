import Foundation

// MARK: - DictationHistoryRefineOutcome

/// `entry.json`'s `refine_outcome` field (`docs/design/29-dictation-history.md` section 3.2).
/// Distinct from the runtime `DictationRefineOutcome` struct (`DictationRefiner.swift`) -- that type
/// carries the in-flight result of a single `DictationRefiner.refine` call (text/usage/model/
/// failure); this one is the closed set of persisted labels a caller maps that result onto before
/// writing `entry.json` (including the `.fallback` + "empty refinement" case that has no equivalent
/// on the runtime type -- see the invariant note on `DictationHistoryEntry` below).
enum DictationHistoryRefineOutcome: String, Codable, Sendable, Equatable {
    case success
    case fallback
    case disabled
}

// MARK: - DictationHistoryInsertOutcome

/// `entry.json`'s `insert_outcome` field (`docs/design/29-dictation-history.md` section 3.2, DH11).
/// Mirrors the runtime `DictationInsertOutcome` enum's two cases (`DictationInserter.swift`) but is
/// declared separately since that type is not `Codable`/`String`-backed and this one needs an
/// explicit snake_case raw value for `.abortedAndStashed` (see the `CodingKeys`-adjacent note below:
/// `SessionJSONCoding`'s key strategies only convert JSON *keys*, never enum raw *values*, so this
/// case's raw value must already be the literal JSON string).
enum DictationHistoryInsertOutcome: String, Codable, Sendable, Equatable {
    case inserted
    case abortedAndStashed = "aborted_and_stashed"
}

// MARK: - DictationHistoryRawSource

/// `entry.json`'s `raw_source` field (`docs/design/31-dictation-two-pass-decode.md` TP7): which
/// decoder supplied `raw_text`. Declared separately from the runtime `DictationRawSource`
/// (`DictationRawSelection.swift`) for the same reason `DictationHistoryInsertOutcome` mirrors
/// rather than reuses its runtime enum -- persisted labels are a closed, string-backed set.
enum DictationHistoryRawSource: String, Codable, Sendable, Equatable {
    case batch
    case streaming
}

// MARK: - DictationHistoryEntry

/// `~/.local/state/kikimi/dictation/history/{id}/entry.json`
/// (`docs/design/29-dictation-history.md` section 3.2). Encoded/decoded via `SessionJSONCoding`
/// (`SessionModels.swift`) -- same `snake_case` key / ISO 8601 date conventions as every other
/// session JSON file, even though this file lives outside `SessionStore`'s session directories
/// (DH5: dictation has no `SessionHandle`).
///
/// Invariant (section 3.2's table, enforced by callers that build this type -- not by `Decodable`
/// itself, since a corrupt-on-disk file must still be decodable enough to log-and-skip rather than
/// crash): when `refineOutcome == .success`, `finalText == refinedText`. The one case that looks like
/// a success but is not recorded as one is "empty refinement" (`DictationController`'s existing
/// behavior of falling back to `rawText` when the LLM call succeeded but trimmed to an empty
/// string) -- that is recorded as `refineOutcome == .fallback` with `refineError == "empty
/// refinement"`, and `llmUsage` is still populated (the call did succeed and cost tokens).
struct DictationHistoryEntry: Codable, Sendable, Equatable {
    /// Hotkey key-down time (UTC) -- also what the entry's folder name is derived from
    /// (`EntryIdNaming`-style shared helper, section 3.1).
    var recordedAt: Date
    /// Utterance length in milliseconds (section 4.2's tap-thread sample counter).
    var durationMs: Int
    /// The insertion target's bundle id at key-down (`FrontmostGuard.Target.bundleId`). `nil` when
    /// nothing was focused or the target app reports no bundle id.
    var targetBundleId: String?
    /// Trimmed raw STT output of whichever decoder confirmed the utterance (`raw_source`),
    /// independent of `refineOutcome` -- always the exact text refinement received
    /// (`docs/design/31-dictation-two-pass-decode.md` TP7's unchanged definition).
    var rawText: String
    /// Which decoder supplied `rawText` (design 31 TP7). `nil` only for entries recorded before
    /// two-pass decode existed; display treats `nil` as `.streaming` (the only source back then).
    var rawSource: DictationHistoryRawSource?
    /// The streaming decoder's text when `rawSource == .batch`, kept for diagnosing streaming
    /// word drops against the batch result (design 31 TP7/§9's diff-marking 布石). `nil` when the
    /// streaming text itself is `rawText` (fallback or two-pass off) or on pre-design-31 entries.
    var streamingText: String?
    /// Refinement result text. `nil` unless refinement actually ran and returned this text as
    /// distinct from `rawText`'s role -- `nil` for both `.disabled` and any `.fallback` (including
    /// the "empty refinement" case, where the LLM's output was the empty string, not `rawText`).
    var refinedText: String?
    /// The text actually inserted (or attempted). Equals `refinedText` when `refineOutcome ==
    /// .success`, else equals `rawText`.
    var finalText: String
    var refineOutcome: DictationHistoryRefineOutcome
    /// Failure/fallback reason (e.g. `"missingAPIKey"`, `"timedOut(3.0 seconds)"`, `"empty
    /// refinement"`). `nil` on `.success` and `.disabled`.
    var refineError: String?
    var insertOutcome: DictationHistoryInsertOutcome
    /// `LLMUsageRecord`-compatible usage/cost (DH5). Present when the LLM call succeeded --
    /// `refineOutcome == .success`, or `.fallback` with `refineError == "empty refinement"` (the call
    /// still succeeded and cost tokens). `nil` for `.disabled` and every other `.fallback` reason
    /// (the call never completed, so there is no usage to report).
    var llmUsage: LLMUsageRecord?
    /// The microphone actually captured from for this utterance (added as an addendum to section
    /// 3.2, alongside the "入力" tab's mic `Picker`): `AudioDeviceInfo.name` for the resolved
    /// `dictation.mic_device_uid`, or the system default input device's name when that config
    /// field was empty or didn't resolve to a currently-available device
    /// (`DictationMicDeviceResolver.resolve(configuredUID:enumerator:)` mirrors
    /// `MicrophoneSource.configureInputDevice(deviceUID:on:)`'s own fallback so the recorded name
    /// always matches what was actually opened). `nil` only for entries recorded before this field
    /// existed -- synthesized `Decodable` already treats a missing key as `decodeIfPresent` for an
    /// `Optional` property, so old `entry.json` files decode this as `nil` without any custom
    /// decoder logic.
    var micDeviceName: String?
    /// The resolved CoreAudio device UID actually used, when `dictation.mic_device_uid` was
    /// non-empty and resolved to a device `AudioInputEnumerator.inputDevices()` currently reports.
    /// `nil` whenever the system default input device was used instead (config left empty, or the
    /// persisted UID no longer resolves) -- mirrors `MicrophoneSource.deviceUID == nil` meaning
    /// "system default input device".
    var micDeviceUID: String?

    /// Explicit memberwise init, replacing the synthesized one only to give the design 31
    /// additions (`rawSource`/`streamingText`) parameter defaults -- the many pre-design-31
    /// construction sites (tests/fixtures) stay untouched. Property-level `= nil` initial values
    /// would achieve the same but violate SwiftLint's `implicit_optional_initialization`.
    init(
        recordedAt: Date,
        durationMs: Int,
        targetBundleId: String?,
        rawText: String,
        rawSource: DictationHistoryRawSource? = nil,
        streamingText: String? = nil,
        refinedText: String?,
        finalText: String,
        refineOutcome: DictationHistoryRefineOutcome,
        refineError: String?,
        insertOutcome: DictationHistoryInsertOutcome,
        llmUsage: LLMUsageRecord?,
        micDeviceName: String? = nil,
        micDeviceUID: String? = nil
    ) {
        self.recordedAt = recordedAt
        self.durationMs = durationMs
        self.targetBundleId = targetBundleId
        self.rawText = rawText
        self.rawSource = rawSource
        self.streamingText = streamingText
        self.refinedText = refinedText
        self.finalText = finalText
        self.refineOutcome = refineOutcome
        self.refineError = refineError
        self.insertOutcome = insertOutcome
        self.llmUsage = llmUsage
        self.micDeviceName = micDeviceName
        self.micDeviceUID = micDeviceUID
    }

    /// Explicit `CodingKeys` documenting the JSON field names this type round-trips through
    /// `SessionJSONCoding` (section 3.2's schema table). Left at implicit (property-name-matching)
    /// raw values on purpose, same convention as every other `SessionJSONCoding` model in
    /// `SessionModels.swift`/`DiarizationModels.swift`: `SessionJSONCoding`'s `JSONEncoder`/
    /// `JSONDecoder` already apply `.convertToSnakeCase`/`.convertFromSnakeCase` globally, and an
    /// explicit snake_case *string* raw value here would be converted a second time and silently
    /// fail to round-trip (see `SessionParticipants.CodingKeys`'s doc comment for the same pitfall).
    /// `micDeviceUID` is the one exception, for the same reason as `LLMUsageRecord.reportedCostUSD`
    /// (see that type's `CodingKeys` doc comment): a trailing all-caps acronym is not a fixed point
    /// of `.convertToSnakeCase` followed by `.convertFromSnakeCase` (`"micDeviceUID"` encodes to
    /// `"mic_device_uid"` but decodes back to the candidate key `"micDeviceUid"`, not
    /// `"micDeviceUID"`), so its rawValue is spelled out to match what `.convertFromSnakeCase`
    /// actually produces.
    enum CodingKeys: String, CodingKey {
        case recordedAt
        case durationMs
        case targetBundleId
        case rawText
        case rawSource
        case streamingText
        case refinedText
        case finalText
        case refineOutcome
        case refineError
        case insertOutcome
        case llmUsage
        case micDeviceName
        case micDeviceUID = "micDeviceUid"
    }
}
