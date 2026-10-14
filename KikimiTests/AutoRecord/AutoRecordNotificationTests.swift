import Foundation
import Testing

@testable import Kikimi

@Suite("AutoRecordNotification")
struct AutoRecordNotificationTests {
    @Test("started body includes the title only when present")
    func startedBody() {
        let withTitle = AutoRecordNotification(kind: .started, sessionId: "s", title: "Weekly sync")
        #expect(withTitle.body.hasSuffix(": Weekly sync"))
        #expect(AutoRecordNotification(kind: .started, sessionId: "s").body == "Google Meet の録音を始めました")
        #expect(AutoRecordNotification(kind: .started, sessionId: "s", title: "").body == "Google Meet の録音を始めました")
    }

    @Test("endScheduled body mentions the deadline time when given")
    func endScheduledBody() {
        #expect(AutoRecordNotification(kind: .endScheduled, sessionId: "s").body == "Meet から退出しました")
        let body = AutoRecordNotification(kind: .endScheduled, sessionId: "s", deadline: Date()).body
        #expect(body.contains("に会議を終了します"))
    }

    @Test("ended and discarded bodies are fixed")
    func fixedBodies() {
        #expect(AutoRecordNotification(kind: .ended, sessionId: "s").body == "会議を終了しました")
        #expect(AutoRecordNotification(kind: .discarded, sessionId: "s").body == "発言がなかったため録音を破棄しました")
    }

    @MainActor
    @Test("identifiers are unique per kind and session")
    func identifiers() {
        let ids = Set(AutoRecordNotificationKind.allCases.map { AutoRecordNotifier.identifier(kind: $0, sessionId: "s1") })
        #expect(ids.count == AutoRecordNotificationKind.allCases.count)
        #expect(AutoRecordNotifier.identifier(kind: .started, sessionId: "a") != AutoRecordNotifier.identifier(kind: .started, sessionId: "b"))
    }
}
