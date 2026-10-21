import Foundation

/// Live `AutomationPermissionRequesting`: a thin wrapper over `ChromeTabInspector.inspect(mode: .interactive)`
/// (`docs/design/50-meet-auto-record.md` section 4). The only path that may show the consent dialog.
struct ChromeAutomationPermissionRequester: AutomationPermissionRequesting {
    private let inspector: ChromeTabInspecting

    init(inspector: ChromeTabInspecting = ChromeTabInspector()) {
        self.inspector = inspector
    }

    func requestInteractive() async -> AutomationPermissionOutcome {
        Self.outcome(for: await inspector.inspect(mode: .interactive))
    }

    static func outcome(for result: ChromeTabInspectionResult) -> AutomationPermissionOutcome {
        switch result {
        case .tabs:
            return .authorized
        case .chromeNotRunning:
            return .chromeNotRunning
        case .failed(.notAuthorized), .failed(.notDetermined):
            return .notAuthorized
        case .failed(.timeout), .failed(.other):
            // The permission check itself passed (the script only runs after it); the script failing
            // afterwards is not a permission problem, and the monitor retries on its own.
            return .authorized
        }
    }
}
