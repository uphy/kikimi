import Combine
import Foundation

/// How `WindowManager.openWorkspace` presents a newly created Session Window
/// (`docs/design/50-meet-auto-record.md` section 3.6).
enum WorkspacePresentation: Equatable, Sendable {
    /// Show and front the window (the default for every user-initiated route).
    case shown
    /// Create the controller and view model but keep the window hidden ("しまう" state, design 18).
    case stowed
}

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
    /// `presentation` applies only when the window has to be (re)opened.
    func workspace(for sessionId: String, presentation: WorkspacePresentation) async throws -> AutoRecordWorkspace
    func quickRecord(overrides: DraftMetaOverrides, presentation: WorkspacePresentation) async throws -> AutoRecordWorkspace
    var recordingSessionId: String? { get }
    /// Fronts the session's window (a no-op if it is not open).
    func showWindow(sessionId: String)
    /// Closes the session's window if it is still stowed, releasing its view model. A window the user
    /// has brought up is left alone.
    func closeIfStowed(sessionId: String)
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

    func workspace(for sessionId: String, presentation: WorkspacePresentation) async throws -> AutoRecordWorkspace {
        let viewModel: MeetingWorkspaceViewModel
        if let controller = WindowManager.shared.workspaceControllers[sessionId] {
            viewModel = controller.viewModel
        } else {
            viewModel = try await WindowManager.shared.openWorkspace(sessionId: sessionId, presentation: presentation).viewModel
        }
        // A reopened window's view model starts at `.startRecording` and hydrates asynchronously; the
        // coordinator reads `recordingButtonState`/`hasConfirmedTranscript` right after this returns
        // (design 50 section 3.0.1, failure mode 7b).
        await viewModel.waitUntilHydrated()
        return viewModel
    }

    func quickRecord(overrides: DraftMetaOverrides, presentation: WorkspacePresentation) async throws -> AutoRecordWorkspace {
        try await WindowManager.shared.quickRecord(overrides: overrides, presentation: presentation).viewModel
    }

    func showWindow(sessionId: String) {
        WindowManager.shared.showWorkspaceWindow(sessionId: sessionId)
    }

    func closeIfStowed(sessionId: String) {
        WindowManager.shared.closeWorkspaceWindowIfStowed(sessionId: sessionId)
    }
}
