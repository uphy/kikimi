import Foundation
import Testing

@testable import Kikimi

@Suite("ControlProtocol")
struct ControlProtocolTests {
    @Test("parses the two known verbs")
    func parsesKnownVerbs() {
        #expect(ControlCommand.parse("status") == .status)
        #expect(ControlCommand.parse("quit") == .quit)
    }

    @Test("ignores the newline and spaces a shell client sends")
    func ignoresSurroundingWhitespace() {
        #expect(ControlCommand.parse("quit\n") == .quit)
        #expect(ControlCommand.parse("  status  ") == .status)
    }

    @Test("rejects unknown, empty, and wrong-case requests")
    func rejectsAnythingElse() {
        #expect(ControlCommand.parse("QUIT") == nil)
        #expect(ControlCommand.parse("shutdown") == nil)
        #expect(ControlCommand.parse("") == nil)
        #expect(ControlCommand.parse("status quit") == nil)
    }

    @Test("status omits the reason key when idle")
    func statusLineWhenIdle() {
        #expect(ControlResponse.status(busyReason: nil).line == "{\"busy\":false}\n")
    }

    @Test("status carries the reason when busy")
    func statusLineWhenBusy() {
        let line = ControlResponse.status(busyReason: "dictation is capturing").line

        #expect(line == "{\"busy\":true,\"reason\":\"dictation is capturing\"}\n")
    }

    @Test("quit replies are a flat boolean plus an optional reason")
    func quitLines() {
        #expect(ControlResponse.quitAccepted.line == "{\"quit\":true}\n")
        #expect(ControlResponse.quitRefused(reason: "session x is recording").line
            == "{\"quit\":false,\"reason\":\"session x is recording\"}\n")
    }

    @Test("error replies stay parseable JSON")
    func errorLine() {
        #expect(ControlResponse.error("unknown command").line == "{\"error\":\"unknown command\"}\n")
    }

    /// The response has to reach the client before the process goes away (design 46 §5), so only
    /// an accepted quit may terminate -- a refusal or an error must leave the app running.
    @Test("only an accepted quit terminates the app")
    func onlyAcceptedQuitTerminates() {
        #expect(ControlResponse.quitAccepted.terminatesApp)
        #expect(!ControlResponse.quitRefused(reason: "busy").terminatesApp)
        #expect(!ControlResponse.status(busyReason: nil).terminatesApp)
        #expect(!ControlResponse.error("unknown command").terminatesApp)
    }

    /// A session id with a quote in it cannot happen today, but the reason string is the one part
    /// of the reply that is not a literal -- it must not be able to break the JSON.
    @Test("a reason with JSON metacharacters stays escaped")
    func escapesReason() {
        let line = ControlResponse.quitRefused(reason: "session \"a\\b\" is recording").line
        let parsed = try? JSONSerialization.jsonObject(
            with: Data(line.utf8), options: []
        ) as? [String: Any]

        #expect(parsed?["reason"] as? String == "session \"a\\b\" is recording")
    }
}
