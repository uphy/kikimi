import Foundation

// MARK: - MeetingWorkspaceTab

/// The active tab of a Session Window window, persisted per-window so reopening a session
/// restores the tab the user was last looking at. See `docs/design/17-session-window-redesign.md`
/// §4.1 (which supersedes `docs/design/06-ui-panels.md` section 5.1's four-tab layout) and kikimi.md
/// 10 章's three-tab layout (準備/会議/Watchers).
///
/// This is the single canonical definition (also consumed by `MeetingWorkspaceView`'s tab
/// container and `MeetingWorkspaceViewModel.activeTab`, `docs/design/06-ui-panels.md` section 5.3) —
/// `Identifiable`/`title` are here rather than behind a same-module extension elsewhere so the type
/// never gets redeclared by a sibling file.
///
/// The former `.transcript`/`.summary` cases were merged into a single `.meeting` tab
/// (`docs/design/17-session-window-redesign.md` §4.1/R2): that tab now shows both via
/// `MeetingPaneMode` below. `WorkspaceWindowState`'s custom decoder (§4.3) migrates any `state.yaml`
/// written before this change.
enum MeetingWorkspaceTab: String, Codable, CaseIterable, Sendable, Identifiable {
    case prep
    case meeting
    case watchers
    /// `docs/design/38-session-chat.md` CH1: ad-hoc questions about this session's conversation.
    case chat

    var id: String { rawValue }

    /// Tab bar label (`docs/design/17-session-window-redesign.md` §4.1/§6).
    var title: String {
        switch self {
        case .prep: return "準備"
        case .meeting: return "会議"
        case .watchers: return "Watchers"
        case .chat: return "チャット"
        }
    }
}

// MARK: - MeetingPaneMode

/// The `.meeting` tab's pane display mode, persisted per-window alongside `activeTab`
/// (`docs/design/17-session-window-redesign.md` §4.2). `.both` (書き起こし + サマリの2ペイン) is the
/// default so Summary stays visible while Recording (§2 R3's invariant), even though the user can
/// narrow to a single pane at any time.
enum MeetingPaneMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// 書き起こしのみ表示.
    case transcript
    /// 両方表示 (既定).
    case both
    /// サマリのみ表示.
    case summary

    var id: String { rawValue }
}

// MARK: - WorkspaceWindowState

/// One Session Window window's persisted frame/visibility/tab/pane-mode, keyed by `sessionId`. See
/// `docs/design/06-ui-panels.md` section 5.1, `docs/design/17-session-window-redesign.md` §4.3, and
/// kikimi.md 12 章's `windows:` list sample.
///
/// `id` is a computed property (not stored) so `Identifiable` conformance is free for SwiftUI list
/// diffing without adding an `id` key to the YAML representation — Swift's `Codable` synthesis only
/// considers stored properties, so this never shows up in `state.yaml`.
struct WorkspaceWindowState: Codable, Equatable, Identifiable, Sendable {
    var id: String { sessionId }

    var sessionId: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var visible: Bool
    var activeTab: MeetingWorkspaceTab
    /// `docs/design/17-session-window-redesign.md` §4.2/§4.3. Only meaningful while `activeTab ==
    /// .meeting`, but always stored/round-tripped regardless of `activeTab` so switching back to
    /// `.meeting` later restores whatever pane mode was last chosen.
    var meetingPaneMode: MeetingPaneMode

    init(
        sessionId: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        visible: Bool,
        activeTab: MeetingWorkspaceTab,
        meetingPaneMode: MeetingPaneMode = .both
    ) {
        self.sessionId = sessionId
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.visible = visible
        self.activeTab = activeTab
        self.meetingPaneMode = meetingPaneMode
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case x
        case y
        case width
        case height
        case visible
        case activeTab = "active_tab"
        case meetingPaneMode = "meeting_pane_mode"
    }

    /// Migrates a pre-redesign `active_tab` value (`docs/design/17-session-window-redesign.md` §4.3's
    /// table): the old `.transcript`/`.summary` tab cases collapse into `.meeting` with the matching
    /// `MeetingPaneMode`, `.prep`/`.watchers` keep their own tab and default to `.both` (or whatever
    /// `meeting_pane_mode` a still-newer file already wrote), and any unrecognized raw value falls
    /// back to `.prep`/`.both` rather than failing the whole `state.yaml` decode. A present
    /// `meeting_pane_mode` key always wins over the table's own default when both are compatible with
    /// `.meeting`/`.prep`/`.watchers` (i.e. every row except the old `transcript`/`summary` values,
    /// which predate that key entirely and so always imply their own fixed pane mode).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        width = try container.decode(Double.self, forKey: .width)
        height = try container.decode(Double.self, forKey: .height)
        visible = try container.decode(Bool.self, forKey: .visible)

        let rawActiveTab = try container.decode(String.self, forKey: .activeTab)
        let decodedPaneMode = try container.decodeIfPresent(MeetingPaneMode.self, forKey: .meetingPaneMode)

        switch rawActiveTab {
        case MeetingWorkspaceTab.prep.rawValue:
            activeTab = .prep
            meetingPaneMode = decodedPaneMode ?? .both
        case "transcript":
            activeTab = .meeting
            meetingPaneMode = .transcript
        case "summary":
            activeTab = .meeting
            meetingPaneMode = .summary
        case MeetingWorkspaceTab.watchers.rawValue:
            activeTab = .watchers
            meetingPaneMode = decodedPaneMode ?? .both
        case MeetingWorkspaceTab.meeting.rawValue:
            activeTab = .meeting
            meetingPaneMode = decodedPaneMode ?? .both
        case MeetingWorkspaceTab.chat.rawValue:
            // `docs/design/38-session-chat.md` §8.1(d): this `switch` is hand-written, so adding the
            // enum case alone is not enough -- without this arm `chat` falls to `default:` and the
            // window silently reopens on 準備 every time.
            activeTab = .chat
            meetingPaneMode = decodedPaneMode ?? .both
        default:
            activeTab = .prep
            meetingPaneMode = .both
        }
    }

    /// Always encodes the new format (`active_tab: meeting` + `meeting_pane_mode: ...` once on that
    /// tab) — the old `transcript`/`summary` raw values are only ever produced by reading a
    /// pre-redesign file, never written back out (`docs/design/17-session-window-redesign.md` §4.3
    /// "エンコードは常に新形式").
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(visible, forKey: .visible)
        try container.encode(activeTab, forKey: .activeTab)
        try container.encode(meetingPaneMode, forKey: .meetingPaneMode)
    }
}

// MARK: - FloatingWindowState

/// A single floating window's persisted frame/visibility, used for windows that aren't keyed by
/// session (currently only the Session List window). See `docs/design/06-ui-panels.md` section 5.1
/// and kikimi.md 12 章's `session_list_window:` sample.
///
/// The Settings window's position is intentionally **not** persisted (kikimi.md 12 章's sample has
/// no `settings_window` key; see `Kikimi/Window/SettingsWindowController.swift`), so this type is
/// currently used for `KikimiStateData.sessionListWindow` and `KikimiStateData
/// .dictationHistoryWindow` (`docs/design/29-dictation-history.md` section 6.1, DH8).
struct FloatingWindowState: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var visible: Bool

    static let `default` = FloatingWindowState(x: 100, y: 750, width: 500, height: 400, visible: false)
}

// MARK: - KikimiStateData

/// The full contents of `~/.local/state/kikimi/state.yaml`. See `docs/design/06-ui-panels.md`
/// section 5.1, kikimi.md 12 章, and `docs/design/10-audio-input-selection.md` section 3
/// (`lastAudioInput`).
struct KikimiStateData: Codable, Equatable, Sendable {
    var windows: [WorkspaceWindowState] = []
    var sessionListWindow: FloatingWindowState = .default
    var lastAudioInput: AudioInputSelection = .default
    /// `docs/design/29-dictation-history.md` section 6.1 (DH8): the Dictation History window's
    /// frame/visibility, keyed identically to `sessionListWindow` (it is likewise a single,
    /// not-per-session floating window).
    var dictationHistoryWindow: FloatingWindowState = .default
    /// `docs/design/42-prompt-overrides.md` §7.1: `true` once `DictationPromptMigration` has run
    /// (successfully, or as a deliberate no-op — see that type's doc comment) at least once for this
    /// state directory. Gates the one-time `dictation.context` -> `prompts/dictation.md` /
    /// `prompts/dictation/apps/<bundle-id>.md` migration so it never re-runs (which would otherwise
    /// re-migrate every time a user removes an override to restore the built-in default).
    /// Deliberately a marker in `state.yaml`, not "does `prompts/dictation.md` exist" — the latter
    /// can't tell "never migrated" apart from "migrated, then the user deleted the override on
    /// purpose to go back to the default".
    var dictationPromptsMigrated: Bool = false

    enum CodingKeys: String, CodingKey {
        case windows
        case sessionListWindow = "session_list_window"
        case lastAudioInput = "last_audio_input"
        case dictationHistoryWindow = "dictation_history_window"
        case dictationPromptsMigrated = "dictation_prompts_migrated"
    }

    init(windows: [WorkspaceWindowState] = [], sessionListWindow: FloatingWindowState = .default,
         lastAudioInput: AudioInputSelection = .default,
         dictationHistoryWindow: FloatingWindowState = .default,
         dictationPromptsMigrated: Bool = false) {
        self.windows = windows
        self.sessionListWindow = sessionListWindow
        self.lastAudioInput = lastAudioInput
        self.dictationHistoryWindow = dictationHistoryWindow
        self.dictationPromptsMigrated = dictationPromptsMigrated
    }

    /// Custom decoder so that existing `state.yaml` files written before `last_audio_input`/
    /// `dictation_history_window`/`dictation_prompts_migrated` were introduced keep decoding
    /// successfully: a missing key falls back to `.default` rather than failing the whole decode
    /// (which would set `YAMLStore.loadFailed` and permanently refuse further `save()` calls).
    /// `windows`/`sessionListWindow` keep their pre-existing (throwing) decode behavior unchanged —
    /// only `lastAudioInput`/`dictationHistoryWindow`/`dictationPromptsMigrated` are decoded
    /// leniently. (`docs/design/10-audio-input-selection.md` section 3, "後方互換（必須）";
    /// `docs/design/29-dictation-history.md` section 6.1 explicitly calls out repeating this
    /// `decodeIfPresent` pattern rather than `sessionListWindow`'s throwing one, since a throwing
    /// decode of a brand new field would fail loading any pre-existing `state.yaml`. A missing
    /// `dictation_prompts_migrated` key must default to `false`, not skip migration — an old
    /// `state.yaml` written before `docs/design/42-prompt-overrides.md` shipped has, by definition,
    /// never run the migration.)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windows = try container.decode([WorkspaceWindowState].self, forKey: .windows)
        sessionListWindow = try container.decode(FloatingWindowState.self, forKey: .sessionListWindow)
        lastAudioInput = try container.decodeIfPresent(AudioInputSelection.self, forKey: .lastAudioInput) ?? .default
        dictationHistoryWindow = try container.decodeIfPresent(
            FloatingWindowState.self, forKey: .dictationHistoryWindow
        ) ?? .default
        dictationPromptsMigrated = try container.decodeIfPresent(
            Bool.self, forKey: .dictationPromptsMigrated
        ) ?? false
    }
}

// MARK: - AppState

/// Reads and writes `~/.local/state/kikimi/state.yaml` (kikimi.md 12 章). Owns only window
/// position/visibility/tab state; no other component reads or writes this file
/// (`docs/design/06-ui-panels.md` section 3, "`AppState.shared` は `WindowManager` からのみ読み書きされる").
///
/// `windows` is kept as the array shape kikimi.md 12 章's sample shows (rather than a dictionary
/// keyed by `sessionId`) so the on-disk YAML matches the spec verbatim; lookups/updates below do a
/// linear scan, which is fine at the expected scale of at most a few dozen entries
/// (`docs/design/06-ui-panels.md` section 5.1).
final class AppState: YAMLStore<KikimiStateData> {
    static let shared = AppState()
    static let defaultStateDirectory = FileManager.realHomeDirectory
        .appendingPathComponent(".local/state/kikimi", isDirectory: true)

    private convenience init() {
        self.init(directory: Self.defaultStateDirectory)
    }

    /// Designated initializer. Tests must pass a temporary directory so the real
    /// `~/.local/state/kikimi` is never touched (`docs/design/06-ui-panels.md` section 2, Chirami's
    /// `AppState`/`AppConfig` DI pattern). `watchForChanges` is always `false`: `state.yaml` is only
    /// ever written by this single process's `WindowManager` (section 2/4 of the design doc).
    init(directory: URL) {
        super.init(directory: directory, fileName: "state.yaml", label: "State",
                    defaultValue: KikimiStateData(), watchForChanges: false)
    }

    /// Linear lookup by `sessionId`. `nil` if no window has ever been opened for this session.
    func windowState(for sessionId: String) -> WorkspaceWindowState? {
        data.windows.first { $0.sessionId == sessionId }
    }

    /// Inserts or replaces the entry matching `state.sessionId`.
    func upsertWindowState(_ state: WorkspaceWindowState) {
        update { data in
            if let index = data.windows.firstIndex(where: { $0.sessionId == state.sessionId }) {
                data.windows[index] = state
            } else {
                data.windows.append(state)
            }
        }
    }

    /// Called when a Session Window window is closed. Only flips `visible` to `false`; the entry
    /// itself is kept so reopening the same session later restores its last frame/tab
    /// (`docs/design/06-ui-panels.md` section 5.1: "Draft のまま閉じられたセッションのフォルダ自体は
    /// ... 残置される"). A no-op if no entry exists for `sessionId`.
    func markWindowHidden(sessionId: String) {
        update { data in
            guard let index = data.windows.firstIndex(where: { $0.sessionId == sessionId }) else { return }
            data.windows[index].visible = false
        }
    }

    /// Removes the entry for `sessionId` entirely. Used when the session itself is deleted
    /// (`docs/design/06-ui-panels.md` section 5.1/9, `WindowManager.handleSessionDeleted`), as
    /// opposed to merely closing its window (`markWindowHidden`).
    func removeWindowState(sessionId: String) {
        update { data in
            data.windows.removeAll { $0.sessionId == sessionId }
        }
    }

    /// Mutates the single `sessionListWindow` entry in place and persists the result.
    func updateSessionListWindow(_ mutate: (inout FloatingWindowState) -> Void) {
        update { data in
            mutate(&data.sessionListWindow)
        }
    }

    /// Mutates the single `dictationHistoryWindow` entry in place and persists the result
    /// (`docs/design/29-dictation-history.md` section 6.1, DH8).
    func updateDictationHistoryWindow(_ mutate: (inout FloatingWindowState) -> Void) {
        update { data in
            mutate(&data.dictationHistoryWindow)
        }
    }

    /// Sets the `dictation_prompts_migrated` marker (`docs/design/42-prompt-overrides.md` §7.1).
    /// Called by `DictationPromptMigration` only after every attempted override write succeeded --
    /// a partial failure must leave the marker unset so the next launch retries (§8 #14).
    func markDictationPromptsMigrated() {
        update { data in
            data.dictationPromptsMigrated = true
        }
    }
}
