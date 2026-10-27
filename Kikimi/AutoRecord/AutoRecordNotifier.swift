import Foundation
import OSLog
import UserNotifications

// MARK: - Model

/// The four notifications of `docs/design/50-meet-auto-record.md` section 3.6.
enum AutoRecordNotificationKind: String, CaseIterable, Sendable {
    case started
    case endScheduled
    case ended
    case discarded
    /// Auto start was attempted but recording did not begin.
    case startFailed
    /// Paused on leaving with auto end disabled (`end_grace_seconds: 0`).
    case pausedNoAutoEnd
}

struct AutoRecordNotification: Equatable, Sendable {
    let kind: AutoRecordNotificationKind
    let sessionId: String
    /// The meeting title (`started` only; nil when the tab had no usable title).
    var title: String?
    /// When the meeting will end (`endScheduled` only).
    var deadline: Date?

    init(kind: AutoRecordNotificationKind, sessionId: String, title: String? = nil, deadline: Date? = nil) {
        self.kind = kind
        self.sessionId = sessionId
        self.title = title
        self.deadline = deadline
    }

    /// Notification body text (section 3.6's table).
    var body: String {
        switch kind {
        case .started:
            let base = "Google Meet の録音を始めました"
            guard let title, !title.isEmpty else { return base }
            return "\(base): \(title)"
        case .endScheduled:
            guard let deadline else { return "Meet から退出しました" }
            return "Meet から退出しました。\(Self.timeString(deadline)) に会議を終了します"
        case .ended:
            return "会議を終了しました"
        case .discarded:
            return "発言がなかったため録音を破棄しました"
        case .startFailed:
            return "Google Meet の自動録音を開始できませんでした。ウィンドウで理由を確認してください"
        case .pausedNoAutoEnd:
            return "Meet から退出したため録音を一時停止しました"
        }
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// Notification authorization as the settings UI needs it.
enum AutoRecordNotificationAuthorization: Equatable, Sendable {
    case granted
    case denied
}

// MARK: - Protocol

/// Everything the coordinator and settings UI need from macOS notifications. Tests substitute a fake
/// so nothing touches `UNUserNotificationCenter`.
@MainActor
protocol AutoRecordNotifying: AnyObject {
    /// Posts `notification`, replacing an earlier one of the same session and kind.
    func post(_ notification: AutoRecordNotification)
    /// Removes the delivered notifications of the given kinds for `sessionId`.
    func remove(_ kinds: [AutoRecordNotificationKind], sessionId: String)
    /// Asks for permission (the system prompts only the first time) and returns the outcome.
    func requestAuthorization() async -> AutoRecordNotificationAuthorization
    /// Current status without prompting. `nil` while undetermined.
    func currentAuthorization() async -> AutoRecordNotificationAuthorization?
}

// MARK: - UNUserNotificationCenter implementation

/// Live notifier. The center is only touched from methods (never `init`), and only inside an `.app`
/// bundle: `UNUserNotificationCenter.current()` traps in the SwiftPM test runner.
@MainActor
final class AutoRecordNotifier: NSObject, AutoRecordNotifying, UNUserNotificationCenterDelegate {
    static let shared = AutoRecordNotifier()

    static let startedCategory = "io.github.uphy.Kikimi.autoRecord.started"
    static let endScheduledCategory = "io.github.uphy.Kikimi.autoRecord.endScheduled"
    static let cancelActionId = "cancelAutoRecord"
    static let keepOpenActionId = "keepMeetingOpen"
    nonisolated private static let sessionIdKey = "sessionId"

    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "AutoRecordNotifier")

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    /// Installs the delegate and action categories. Call once at launch.
    func activate() {
        guard let center else { return }
        center.delegate = self
        let cancel = UNNotificationAction(identifier: Self.cancelActionId, title: "取り消す", options: [])
        let keep = UNNotificationAction(identifier: Self.keepOpenActionId, title: "終了しない", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.startedCategory, actions: [cancel], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.endScheduledCategory, actions: [keep], intentIdentifiers: [], options: [])
        ])
    }

    /// One identifier per session and kind, so a newer notification replaces the older one.
    static func identifier(kind: AutoRecordNotificationKind, sessionId: String) -> String {
        "autoRecord.\(kind.rawValue).\(sessionId)"
    }

    func post(_ notification: AutoRecordNotification) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "Kikimi"
        content.body = notification.body
        content.sound = nil
        content.userInfo = [Self.sessionIdKey: notification.sessionId]
        switch notification.kind {
        case .started: content.categoryIdentifier = Self.startedCategory
        case .endScheduled: content.categoryIdentifier = Self.endScheduledCategory
        case .ended, .discarded, .startFailed, .pausedNoAutoEnd: break
        }
        let request = UNNotificationRequest(
            identifier: Self.identifier(kind: notification.kind, sessionId: notification.sessionId),
            content: content, trigger: nil
        )
        let logger = logger
        center.add(request) { error in
            if let error {
                logger.warning("posting notification failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func remove(_ kinds: [AutoRecordNotificationKind], sessionId: String) {
        guard let center else { return }
        let identifiers = kinds.map { Self.identifier(kind: $0, sessionId: sessionId) }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func requestAuthorization() async -> AutoRecordNotificationAuthorization {
        guard let center else { return .denied }
        do {
            return try await center.requestAuthorization(options: [.alert]) ? .granted : .denied
        } catch {
            logger.warning("notification authorization request failed: \(String(describing: error), privacy: .public)")
            return .denied
        }
    }

    func currentAuthorization() async -> AutoRecordNotificationAuthorization? {
        guard let center else { return nil }
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return nil
        case .denied: return .denied
        default: return .granted
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show even while Kikimi is frontmost; no sound (section 3.6).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionId = response.actionIdentifier
        guard let sessionId = response.notification.request.content.userInfo[Self.sessionIdKey] as? String else { return }
        await MainActor.run {
            switch actionId {
            case Self.cancelActionId:
                MeetAutoRecordCoordinator.shared.handleBannerAction(sessionId: sessionId, action: .cancelAutoRecord)
            case Self.keepOpenActionId:
                MeetAutoRecordCoordinator.shared.handleBannerAction(sessionId: sessionId, action: .keepMeetingOpen)
            case UNNotificationDefaultActionIdentifier:
                // Fronts the window via `showWorkspaceWindow`, reopening it first if it was closed.
                Task { _ = try? await WindowManager.shared.openWorkspace(sessionId: sessionId, presentation: .shown) }
            default:
                break
            }
        }
    }
}
