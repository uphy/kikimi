import Foundation
import Testing
import Yams

@testable import Kikimi

/// Layer 1 (unit) coverage for `AppState`, targeting the scenarios called out in
/// `docs/design/06-ui-panels.md` section 5.1 and kikimi.md 12 章's `state.yaml` schema. Every test
/// roots `AppState` at a fresh temporary directory (via the DI initializer) so nothing here ever
/// touches a real `~/.local/state/kikimi`.
@Suite("AppState")
struct AppStateTests {
    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAppState(in directory: URL) -> AppState {
        AppState(directory: directory)
    }

    private func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("state.yaml")
    }

    private func sample(sessionId: String = "2026-07-01T14-30-00_a1b2c3d4") -> WorkspaceWindowState {
        // `.meeting`/`.transcript` mirrors the old `.transcript` tab's post-migration shape
        // (`docs/design/17-session-window-redesign.md` §4.1/§4.3) -- kept as a non-default value so
        // every test below still exercises a genuine, distinguishable `activeTab`/`meetingPaneMode`
        // pair rather than the all-default `.prep`/`.both`.
        WorkspaceWindowState(
            sessionId: sessionId,
            x: 100,
            y: 100,
            width: 800,
            height: 600,
            visible: true,
            activeTab: .meeting,
            meetingPaneMode: .transcript
        )
    }

    // MARK: - Defaults

    @Test("missing state.yaml starts with empty windows and default sessionListWindow")
    func missingFileStartsWithDefaults() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = makeAppState(in: dir)
        #expect(appState.data.windows.isEmpty)
        #expect(appState.data.sessionListWindow == .default)
        #expect(!appState.loadFailed)
    }

    @Test("FloatingWindowState.default matches kikimi.md's documented defaults")
    func floatingWindowStateDefault() {
        let defaultState = FloatingWindowState.default
        #expect(defaultState.x == 100)
        #expect(defaultState.y == 750)
        #expect(defaultState.width == 500)
        #expect(defaultState.height == 400)
        #expect(defaultState.visible == false)
    }

    // MARK: - windowState(for:)

    @Test("windowState(for:) returns nil when no entry exists")
    func windowStateReturnsNilWhenAbsent() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = makeAppState(in: dir)
        #expect(appState.windowState(for: "does-not-exist") == nil)
    }

    @Test("windowState(for:) finds the matching entry by sessionId")
    func windowStateFindsMatch() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = makeAppState(in: dir)
        let state = sample()
        appState.upsertWindowState(state)

        #expect(appState.windowState(for: state.sessionId) == state)
    }

    // MARK: - upsertWindowState

    @Test("upsertWindowState appends a new entry for a new sessionId")
    func upsertAppendsNewEntry() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = makeAppState(in: dir)
        appState.upsertWindowState(sample(sessionId: "session-a"))
        appState.upsertWindowState(sample(sessionId: "session-b"))

        #expect(appState.data.windows.count == 2)
        #expect(appState.data.windows.map(\.sessionId) == ["session-a", "session-b"])
    }

    @Test("upsertWindowState replaces the existing entry in place for a known sessionId")
    func upsertReplacesExistingEntry() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = makeAppState(in: dir)
        appState.upsertWindowState(sample(sessionId: "session-a"))
        appState.upsertWindowState(sample(sessionId: "session-b"))

        var moved = sample(sessionId: "session-a")
        moved.x = 999
        moved.activeTab = .watchers
        appState.upsertWindowState(moved)

        #expect(appState.data.windows.count == 2)
        #expect(appState.windowState(for: "session-a") == moved)
        // Replacing session-a's entry does not disturb session-b's.
        #expect(appState.windowState(for: "session-b") == sample(sessionId: "session-b"))
    }

    // MARK: - markWindowHidden

    @Test("markWindowHidden flips visible to false without removing the entry")
    func markWindowHiddenFlipsVisible() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = makeAppState(in: dir)
        appState.upsertWindowState(sample())

        appState.markWindowHidden(sessionId: sample().sessionId)

        let updated = appState.windowState(for: sample().sessionId)
        #expect(updated != nil)
        #expect(updated?.visible == false)
        // Non-visibility fields (frame/tab) survive the close untouched.
        #expect(updated?.x == sample().x)
        #expect(updated?.activeTab == sample().activeTab)
    }

    @Test("markWindowHidden is a no-op when no entry exists for sessionId")
    func markWindowHiddenNoOpWhenAbsent() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = makeAppState(in: dir)
        appState.markWindowHidden(sessionId: "does-not-exist")

        #expect(appState.data.windows.isEmpty)
    }

    // MARK: - removeWindowState

    @Test("removeWindowState deletes the entry entirely")
    func removeWindowStateDeletesEntry() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = makeAppState(in: dir)
        appState.upsertWindowState(sample(sessionId: "session-a"))
        appState.upsertWindowState(sample(sessionId: "session-b"))

        appState.removeWindowState(sessionId: "session-a")

        #expect(appState.data.windows.count == 1)
        #expect(appState.windowState(for: "session-a") == nil)
        #expect(appState.windowState(for: "session-b") != nil)
    }

    @Test("removeWindowState is a no-op when no entry exists for sessionId")
    func removeWindowStateNoOpWhenAbsent() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = makeAppState(in: dir)
        appState.upsertWindowState(sample())

        appState.removeWindowState(sessionId: "does-not-exist")

        #expect(appState.data.windows.count == 1)
    }

    // MARK: - updateSessionListWindow

    @Test("updateSessionListWindow mutates only the sessionListWindow entry")
    func updateSessionListWindowMutates() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = makeAppState(in: dir)
        appState.updateSessionListWindow { state in
            state.visible = true
            state.x = 42
        }

        #expect(appState.data.sessionListWindow.visible == true)
        #expect(appState.data.sessionListWindow.x == 42)
        // Untouched fields keep their defaults.
        #expect(appState.data.sessionListWindow.width == FloatingWindowState.default.width)
    }

    // MARK: - Persistence round trip / YAML shape

    @Test("upsertWindowState and updateSessionListWindow persist across a fresh AppState instance")
    func mutationsPersistAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = makeAppState(in: dir)
        appState.upsertWindowState(sample())
        appState.updateSessionListWindow { $0.visible = true }

        let reloaded = makeAppState(in: dir)
        #expect(reloaded.windowState(for: sample().sessionId) == sample())
        #expect(reloaded.data.sessionListWindow.visible == true)
    }

    @Test("decodes kikimi.md's sample state.yaml with snake_case keys")
    func decodesKikimiSampleYAML() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Matches kikimi.md 12 章's current `state.yaml` sample exactly (post
        // `docs/design/17-session-window-redesign.md` §4.1: `active_tab: meeting` +
        // `meeting_pane_mode`).
        let sampleYAML = """
        windows:
          - session_id: 2026-07-01T14-30-00_a1b2c3d4
            x: 100
            y: 100
            width: 800
            height: 600
            visible: true
            active_tab: meeting
            meeting_pane_mode: both
          - session_id: 2026-07-01T16-00-00_b2c3d4e5
            x: 950
            y: 100
            width: 800
            height: 600
            visible: true
            active_tab: prep
            meeting_pane_mode: both

        session_list_window:
          x: 100
          y: 750
          width: 500
          height: 400
          visible: false
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appState = makeAppState(in: dir)
        #expect(!appState.loadFailed)
        #expect(appState.data.windows.count == 2)
        #expect(appState.windowState(for: "2026-07-01T14-30-00_a1b2c3d4")?.activeTab == .meeting)
        #expect(appState.windowState(for: "2026-07-01T14-30-00_a1b2c3d4")?.meetingPaneMode == .both)
        #expect(appState.windowState(for: "2026-07-01T16-00-00_b2c3d4e5")?.activeTab == .prep)
        #expect(appState.data.sessionListWindow == FloatingWindowState(x: 100, y: 750, width: 500, height: 400, visible: false))
    }

    // MARK: - MeetingWorkspaceTab/MeetingPaneMode migration (docs/design/17-session-window-redesign.md §4.3)

    @Test("MeetingWorkspaceTab.allCases has exactly 4 cases with the redesigned Japanese titles")
    func meetingWorkspaceTabHasFourCasesWithJapaneseTitles() {
        #expect(MeetingWorkspaceTab.allCases == [.prep, .meeting, .watchers, .chat])
        #expect(MeetingWorkspaceTab.prep.title == "準備")
        #expect(MeetingWorkspaceTab.meeting.title == "会議")
        #expect(MeetingWorkspaceTab.watchers.title == "Watchers")
        #expect(MeetingWorkspaceTab.chat.title == "チャット")
    }

    @Test("restores active_tab: chat instead of silently falling back to 準備")
    func restoresChatActiveTab() throws {
        // `docs/design/38-session-chat.md` §8.1(d): `WorkspaceWindowState.init(from:)` is a
        // hand-written `switch`, so adding the enum case alone would leave `chat` landing in
        // `default:` and every reopen showing 準備.
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleYAML = """
        windows:
          - session_id: session-a
            x: 100
            y: 100
            width: 800
            height: 600
            visible: true
            active_tab: chat

        session_list_window:
          x: 100
          y: 750
          width: 500
          height: 400
          visible: false
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appState = makeAppState(in: dir)
        #expect(!appState.loadFailed)
        #expect(try #require(appState.windowState(for: "session-a")).activeTab == .chat)
    }

    @Test("migrates old active_tab: transcript to activeTab: .meeting, meetingPaneMode: .transcript")
    func migratesOldActiveTabTranscript() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleYAML = """
        windows:
          - session_id: session-a
            x: 100
            y: 100
            width: 800
            height: 600
            visible: true
            active_tab: transcript

        session_list_window:
          x: 100
          y: 750
          width: 500
          height: 400
          visible: false
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appState = makeAppState(in: dir)
        #expect(!appState.loadFailed)
        let state = try #require(appState.windowState(for: "session-a"))
        #expect(state.activeTab == .meeting)
        #expect(state.meetingPaneMode == .transcript)
    }

    @Test("migrates old active_tab: summary to activeTab: .meeting, meetingPaneMode: .summary")
    func migratesOldActiveTabSummary() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleYAML = """
        windows:
          - session_id: session-a
            x: 100
            y: 100
            width: 800
            height: 600
            visible: true
            active_tab: summary

        session_list_window:
          x: 100
          y: 750
          width: 500
          height: 400
          visible: false
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appState = makeAppState(in: dir)
        #expect(!appState.loadFailed)
        let state = try #require(appState.windowState(for: "session-a"))
        #expect(state.activeTab == .meeting)
        #expect(state.meetingPaneMode == .summary)
    }

    @Test("old active_tab: prep/watchers default meetingPaneMode to .both when the key is missing")
    func migratesOldActiveTabPrepAndWatchersDefaultPaneMode() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleYAML = """
        windows:
          - session_id: session-prep
            x: 100
            y: 100
            width: 800
            height: 600
            visible: true
            active_tab: prep
          - session_id: session-watchers
            x: 100
            y: 100
            width: 800
            height: 600
            visible: true
            active_tab: watchers

        session_list_window:
          x: 100
          y: 750
          width: 500
          height: 400
          visible: false
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appState = makeAppState(in: dir)
        #expect(!appState.loadFailed)
        let prepState = try #require(appState.windowState(for: "session-prep"))
        #expect(prepState.activeTab == .prep)
        #expect(prepState.meetingPaneMode == .both)
        let watchersState = try #require(appState.windowState(for: "session-watchers"))
        #expect(watchersState.activeTab == .watchers)
        #expect(watchersState.meetingPaneMode == .both)
    }

    @Test("an unknown active_tab value falls back to .prep/.both instead of failing the whole decode")
    func unknownActiveTabFallsBackToPrepAndBoth() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleYAML = """
        windows:
          - session_id: session-a
            x: 100
            y: 100
            width: 800
            height: 600
            visible: true
            active_tab: some-future-value

        session_list_window:
          x: 100
          y: 750
          width: 500
          height: 400
          visible: false
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appState = makeAppState(in: dir)
        #expect(!appState.loadFailed)
        let state = try #require(appState.windowState(for: "session-a"))
        #expect(state.activeTab == .prep)
        #expect(state.meetingPaneMode == .both)
    }

    @Test("a new-format active_tab: meeting with an explicit meeting_pane_mode is read as-is (round trip)")
    func decodesNewFormatMeetingWithExplicitPaneMode() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleYAML = """
        windows:
          - session_id: session-a
            x: 100
            y: 100
            width: 800
            height: 600
            visible: true
            active_tab: meeting
            meeting_pane_mode: summary

        session_list_window:
          x: 100
          y: 750
          width: 500
          height: 400
          visible: false
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appState = makeAppState(in: dir)
        #expect(!appState.loadFailed)
        let state = try #require(appState.windowState(for: "session-a"))
        #expect(state.activeTab == .meeting)
        #expect(state.meetingPaneMode == .summary)
    }

    @Test("a new-format active_tab: meeting with no meeting_pane_mode key defaults to .both")
    func decodesNewFormatMeetingWithMissingPaneModeDefaultsToBoth() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleYAML = """
        windows:
          - session_id: session-a
            x: 100
            y: 100
            width: 800
            height: 600
            visible: true
            active_tab: meeting

        session_list_window:
          x: 100
          y: 750
          width: 500
          height: 400
          visible: false
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appState = makeAppState(in: dir)
        #expect(!appState.loadFailed)
        let state = try #require(appState.windowState(for: "session-a"))
        #expect(state.activeTab == .meeting)
        #expect(state.meetingPaneMode == .both)
    }

    @Test("WorkspaceWindowState always encodes the new format: active_tab + meeting_pane_mode")
    func encodesAlwaysNewFormat() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Round-trips through the migrating decoder first (old `transcript` raw value), then saves --
        // the on-disk shape after that save must be the new format, never the old raw value.
        let sampleYAML = """
        windows:
          - session_id: session-a
            x: 100
            y: 100
            width: 800
            height: 600
            visible: true
            active_tab: transcript

        session_list_window:
          x: 100
          y: 750
          width: 500
          height: 400
          visible: false
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appState = makeAppState(in: dir)
        appState.upsertWindowState(try #require(appState.windowState(for: "session-a")))

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let windows = root?["windows"] as? [[String: Any]]
        #expect(windows?.first?["active_tab"] as? String == "meeting")
        #expect(windows?.first?["meeting_pane_mode"] as? String == "transcript")
    }

    @Test("saved YAML uses snake_case keys and omits the computed Identifiable id")
    func savedYAMLUsesSnakeCaseAndOmitsId() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = makeAppState(in: dir)
        appState.upsertWindowState(sample())

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let windows = root?["windows"] as? [[String: Any]]
        #expect(root?["session_list_window"] != nil)
        #expect(windows?.first?.keys.contains("session_id") == true)
        #expect(windows?.first?.keys.contains("active_tab") == true)
        // "id" is a computed property (mirrors sessionId), not a stored one, so Codable synthesis
        // never emits it into the YAML mapping.
        #expect(windows?.first?.keys.contains("id") == false)
    }

    @Test("WorkspaceWindowState.id mirrors sessionId for Identifiable conformance")
    func identifiableIdMirrorsSessionId() {
        let state = sample(sessionId: "some-session")
        #expect(state.id == "some-session")
    }

    // MARK: - lastAudioInput (docs/design/10-audio-input-selection.md section 3)

    @Test("missing state.yaml starts with a default lastAudioInput")
    func missingFileStartsWithDefaultAudioInput() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = makeAppState(in: dir)
        #expect(appState.data.lastAudioInput == .default)
    }

    @Test("update writes and persists lastAudioInput across a fresh AppState instance")
    func lastAudioInputPersistsAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = makeAppState(in: dir)
        let selection = AudioInputSelection(
            mic: MicSelection(enabled: true, deviceUid: "BuiltInMicrophoneDevice"),
            system: SystemAudioSelection(enabled: true, bundleId: "us.zoom.xos")
        )
        appState.update { $0.lastAudioInput = selection }

        let reloaded = makeAppState(in: dir)
        #expect(reloaded.data.lastAudioInput == selection)
    }

    @Test("saved YAML serializes last_audio_input with snake_case nested keys")
    func savedYAMLIncludesLastAudioInputSnakeCase() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = makeAppState(in: dir)
        appState.update {
            $0.lastAudioInput = AudioInputSelection(
                mic: MicSelection(enabled: true, deviceUid: "abc"),
                system: SystemAudioSelection(enabled: false, bundleId: "us.zoom.xos")
            )
        }

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let lastAudioInput = root?["last_audio_input"] as? [String: Any]
        let mic = lastAudioInput?["mic"] as? [String: Any]
        let system = lastAudioInput?["system"] as? [String: Any]

        #expect(mic?["device_uid"] as? String == "abc")
        #expect(system?["bundle_id"] as? String == "us.zoom.xos")
    }

    @Test("decoding state.yaml without last_audio_input migrates: windows preserved, lastAudioInput defaults, save succeeds")
    func migratesStateYAMLWithoutLastAudioInput() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Pre-migration on-disk shape: no `last_audio_input` key at all (docs/design/10-audio-input-selection.md
        // section 3 "後方互換" / section 8 失敗モード #10).
        let sampleYAML = """
        windows:
          - session_id: 2026-07-01T14-30-00_a1b2c3d4
            x: 100
            y: 100
            width: 800
            height: 600
            visible: true
            active_tab: transcript

        session_list_window:
          x: 100
          y: 750
          width: 500
          height: 400
          visible: false
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appState = makeAppState(in: dir)

        // Decode must not fail (loadFailed would permanently refuse further save()).
        #expect(!appState.loadFailed)
        // windows/sessionListWindow are preserved untouched.
        #expect(appState.data.windows.count == 1)
        // `active_tab: transcript` migrates per `docs/design/17-session-window-redesign.md` §4.3.
        #expect(appState.windowState(for: "2026-07-01T14-30-00_a1b2c3d4")?.activeTab == .meeting)
        #expect(appState.windowState(for: "2026-07-01T14-30-00_a1b2c3d4")?.meetingPaneMode == .transcript)
        #expect(appState.data.sessionListWindow == FloatingWindowState(x: 100, y: 750, width: 500, height: 400, visible: false))
        // Missing key falls back to the field-level default.
        #expect(appState.data.lastAudioInput == .default)

        // Subsequent save() succeeds (not refused by a stale loadFailed flag) and round-trips
        // through a fresh instance, now including last_audio_input.
        appState.upsertWindowState(sample(sessionId: "session-b"))
        #expect(!appState.loadFailed)

        let reloaded = makeAppState(in: dir)
        #expect(reloaded.data.windows.count == 2)
        #expect(reloaded.data.lastAudioInput == .default)
    }

    // MARK: - dictationHistoryWindow (docs/design/29-dictation-history.md section 6.1, DH8)

    @Test("missing state.yaml starts with a default dictationHistoryWindow")
    func missingFileStartsWithDefaultDictationHistoryWindow() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = makeAppState(in: dir)
        #expect(appState.data.dictationHistoryWindow == .default)
    }

    @Test("updateDictationHistoryWindow mutates only the dictationHistoryWindow entry")
    func updateDictationHistoryWindowMutates() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = makeAppState(in: dir)
        appState.updateDictationHistoryWindow { state in
            state.visible = true
            state.x = 42
        }

        #expect(appState.data.dictationHistoryWindow.visible == true)
        #expect(appState.data.dictationHistoryWindow.x == 42)
        // Untouched fields keep their defaults.
        #expect(appState.data.dictationHistoryWindow.width == FloatingWindowState.default.width)
        // sessionListWindow is unaffected.
        #expect(appState.data.sessionListWindow == .default)
    }

    @Test("updateDictationHistoryWindow persists across a fresh AppState instance")
    func dictationHistoryWindowPersistsAcrossInstances() {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = makeAppState(in: dir)
        appState.updateDictationHistoryWindow { $0.visible = true }

        let reloaded = makeAppState(in: dir)
        #expect(reloaded.data.dictationHistoryWindow.visible == true)
    }

    @Test("saved YAML serializes dictation_history_window with snake_case key")
    func savedYAMLIncludesDictationHistoryWindowSnakeCase() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = makeAppState(in: dir)
        appState.updateDictationHistoryWindow { state in
            state.x = 200
            state.visible = true
        }

        let onDisk = try String(contentsOf: fileURL(in: dir), encoding: .utf8)
        let root = try Yams.load(yaml: onDisk) as? [String: Any]
        let dictationHistoryWindow = root?["dictation_history_window"] as? [String: Any]
        // `FloatingWindowState.x` is a `Double` (`AppState.swift:178`), so Yams round-trips it back
        // as a `Double`, not an `Int` -- unlike `#expect(_ == _)`'s other numeric literal
        // comparisons in this file, this one must cast to `Double` or the cast itself silently
        // produces `nil` and the assertion never actually checks the persisted value.
        #expect(dictationHistoryWindow?["x"] as? Double == 200)
        #expect(dictationHistoryWindow?["visible"] as? Bool == true)
    }

    @Test("decoding state.yaml without dictation_history_window migrates: existing fields preserved, dictationHistoryWindow defaults, save succeeds")
    func migratesStateYAMLWithoutDictationHistoryWindow() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Pre-migration on-disk shape: no `dictation_history_window` key at all
        // (`docs/design/29-dictation-history.md` section 6.1: `decodeIfPresent` + `.default`, not a
        // throwing decode, so this must not fail the whole `state.yaml` load).
        let sampleYAML = """
        windows:
          - session_id: 2026-07-01T14-30-00_a1b2c3d4
            x: 100
            y: 100
            width: 800
            height: 600
            visible: true
            active_tab: meeting
            meeting_pane_mode: both

        session_list_window:
          x: 100
          y: 750
          width: 500
          height: 400
          visible: false
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appState = makeAppState(in: dir)

        // Decode must not fail (loadFailed would permanently refuse further save()).
        #expect(!appState.loadFailed)
        // Existing fields are preserved untouched.
        #expect(appState.data.windows.count == 1)
        #expect(appState.data.sessionListWindow == FloatingWindowState(x: 100, y: 750, width: 500, height: 400, visible: false))
        // Missing key falls back to the field-level default.
        #expect(appState.data.dictationHistoryWindow == .default)

        // Subsequent save() succeeds (not refused by a stale loadFailed flag) and round-trips
        // through a fresh instance, now including dictation_history_window.
        appState.updateDictationHistoryWindow { $0.visible = true }
        #expect(!appState.loadFailed)

        let reloaded = makeAppState(in: dir)
        #expect(reloaded.data.windows.count == 1)
        #expect(reloaded.data.dictationHistoryWindow.visible == true)
    }

    @Test("decodes kikimi.md's sample state.yaml with explicit last_audio_input")
    func decodesSampleYAMLWithLastAudioInput() throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleYAML = """
        windows: []

        session_list_window:
          x: 100
          y: 750
          width: 500
          height: 400
          visible: false

        last_audio_input:
          mic:
            enabled: true
            device_uid: "BuiltInMicrophoneDevice"
          system:
            enabled: true
            bundle_id: "us.zoom.xos"
        """
        try sampleYAML.write(to: fileURL(in: dir), atomically: true, encoding: .utf8)

        let appState = makeAppState(in: dir)
        #expect(!appState.loadFailed)
        #expect(appState.data.lastAudioInput.mic.deviceUid == "BuiltInMicrophoneDevice")
        #expect(appState.data.lastAudioInput.system.bundleId == "us.zoom.xos")
    }
}
