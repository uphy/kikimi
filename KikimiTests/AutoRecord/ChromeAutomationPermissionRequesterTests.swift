import Foundation
import Testing

@testable import Kikimi

@Suite("ChromeAutomationPermissionRequester")
struct ChromeAutomationPermissionRequesterTests {
    @Test("inspection results map to permission outcomes")
    func mapping() {
        typealias R = ChromeAutomationPermissionRequester
        #expect(R.outcome(for: .tabs([])) == .authorized)
        #expect(R.outcome(for: .chromeNotRunning) == .chromeNotRunning)
        #expect(R.outcome(for: .failed(.notAuthorized)) == .notAuthorized)
        #expect(R.outcome(for: .failed(.notDetermined)) == .notAuthorized)
        #expect(R.outcome(for: .failed(.timeout)) == .authorized)
        #expect(R.outcome(for: .failed(.other(-1))) == .authorized)
    }

    @Test("requestInteractive uses the interactive mode")
    func interactiveMode() async {
        final class Recorder: ChromeTabInspecting, @unchecked Sendable {
            var mode: ChromeTabInspectionMode?
            func inspect(mode: ChromeTabInspectionMode) async -> ChromeTabInspectionResult {
                self.mode = mode
                return .chromeNotRunning
            }
            func automationPermitted() -> Bool? { nil }
        }
        let recorder = Recorder()
        let outcome = await ChromeAutomationPermissionRequester(inspector: recorder).requestInteractive()
        #expect(outcome == .chromeNotRunning)
        #expect(recorder.mode == .interactive)
    }
}
