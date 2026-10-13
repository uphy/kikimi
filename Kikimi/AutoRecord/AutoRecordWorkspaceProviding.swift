import Combine
import Foundation

/// The part of `MeetingWorkspaceViewModel` the auto-record coordinator uses
/// (`docs/design/50-meet-auto-record.md` section 3.0.1). Tests substitute a fake at this boundary.
@MainActor
protocol AutoRecordWorkspace: AnyObject {
    var sessionId: String { get }
    var recordingButtonState: RecordingButtonState { get }
    /// Emits on every change of `recordingButtonState` (the new value is the argument; the property
    /// itself may still hold the old value while the publisher is delivering).
    var recordingButtonStatePublisher: AnyPublisher<RecordingButtonState, Never> { get }
    var hasConfirmedTranscript: Bool { get }
    var onBannerAction: ((WorkspaceBanner, BannerActionID) -> Void)? { get set }

    func pauseRecording() async
    func resumeRecording() async
    func endMeeting() async
    /// Returns `false` when the session was not in a discardable state (nothing happened).
    @discardableResult
    func discardAutoRecordedSession() async -> Bool

    /// Adds `banner`, replacing any banner with the same `id`.
    func showBanner(_ banner: WorkspaceBanner)
    func removeBanners(withId id: String)
}

/// Gives the coordinator view models without holding them (a Paused window can be closed by the user,
/// which discards its view model).
@MainActor
protocol AutoRecordWorkspaceProviding {
    /// Returns the open view model, or opens the Session Window and returns its view model.
    func workspace(for sessionId: String) async throws -> AutoRecordWorkspace
    func quickRecord(overrides: DraftMetaOverrides) async throws -> AutoRecordWorkspace
    var recordingSessionId: String? { get }
}

// MARK: - Production implementations

extension MeetingWorkspaceViewModel: AutoRecordWorkspace {
    var recordingButtonStatePublisher: AnyPublisher<RecordingButtonState, Never> {
        $recordingButtonState.eraseToAnyPublisher()
    }

    func showBanner(_ banner: WorkspaceBanner) {
        banners.removeAll { $0.id == banner.id }
        banners.append(banner)
    }

    func removeBanners(withId id: String) {
        banners.removeAll { $0.id == id }
    }
}

/// `WindowManager`-backed provider. Does not front an already-open window (unlike `openWorkspace`).
@MainActor
struct WindowManagerAutoRecordProvider: AutoRecordWorkspaceProviding {
    var recordingSessionId: String? { WindowManager.shared.recordingSessionId }

    func workspace(for sessionId: String) async throws -> AutoRecordWorkspace {
        let viewModel: MeetingWorkspaceViewModel
        if let controller = WindowManager.shared.workspaceControllers[sessionId] {
            viewModel = controller.viewModel
        } else {
            viewModel = try await WindowManager.shared.openWorkspace(sessionId: sessionId).viewModel
        }
        // A reopened window's view model starts at `.startRecording` and hydrates asynchronously; the
        // coordinator reads `recordingButtonState`/`hasConfirmedTranscript` right after this returns
        // (design 50 section 3.0.1, failure mode 7b).
        await viewModel.waitUntilHydrated()
        return viewModel
    }

    func quickRecord(overrides: DraftMetaOverrides) async throws -> AutoRecordWorkspace {
        try await WindowManager.shared.quickRecord(overrides: overrides).viewModel
    }
}
