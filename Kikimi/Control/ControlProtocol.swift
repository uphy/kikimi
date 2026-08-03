import Foundation

// MARK: - ControlCommand

/// The control socket's request vocabulary (`docs/design/46-control-socket.md` §3). Line-oriented:
/// one command line in, one JSON line out, connection closed -- so `echo status | nc -U <socket>`
/// is a complete client.
enum ControlCommand: String, Equatable, Sendable, CaseIterable {
    /// Report whether Kikimi is busy. Changes nothing; `mise run apply` sends this before building.
    case status
    /// Quit when idle so the installer can replace the bundle, refuse when busy (§5).
    case quit

    /// Requests longer than this are rejected without parsing. Only two fixed verbs are accepted,
    /// so anything larger is a malformed client rather than a request worth reading to the end.
    static let maxRequestBytes = 64

    /// Returns `nil` for anything that is not exactly one of the known verbs. Surrounding
    /// whitespace (including the newline `nc` sends) is ignored. Case is *not*: every caller is a
    /// script, and accepting `QUIT` would only hide typos in one.
    static func parse(_ line: String) -> ControlCommand? {
        ControlCommand(rawValue: line.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - ControlResponse

/// The control socket's reply. Encoded as a single newline-terminated JSON object so a shell client
/// can read it with `jq` and branch on the boolean alone -- the `reason` string is for humans and
/// logs, and clients must not match on its text (§3).
enum ControlResponse: Equatable, Sendable {
    case status(busyReason: String?)
    case quitAccepted
    case quitRefused(reason: String)
    case error(String)

    /// Whether the app must terminate once this response has been flushed and the socket closed.
    /// The write has to happen first: terminating the process with the reply still buffered would
    /// leave the client unable to tell "quit accepted" from "app crashed" (§5).
    var terminatesApp: Bool {
        self == .quitAccepted
    }

    /// The wire line, newline included. `sortedKeys` keeps the output stable for tests and for
    /// anyone diffing logs; `withoutEscapingSlashes` keeps session ids readable.
    var line: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let data: Data
        do {
            switch self {
            case let .status(busyReason):
                data = try encoder.encode(StatusPayload(busy: busyReason != nil, reason: busyReason))
            case .quitAccepted:
                data = try encoder.encode(QuitPayload(quit: true, reason: nil))
            case let .quitRefused(reason):
                data = try encoder.encode(QuitPayload(quit: false, reason: reason))
            case let .error(message):
                data = try encoder.encode(ErrorPayload(error: message))
            }
        } catch {
            // Encoding three fixed shapes of `String`/`Bool` cannot fail in practice. Emit
            // something a client can still parse rather than propagating the error to a caller
            // that has no better recovery than this.
            return "{\"error\":\"response encoding failed\"}\n"
        }

        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }

    // A `nil` reason is omitted by `JSONEncoder` rather than encoded as `null`, which is what
    // `{"busy":false}` / `{"quit":true}` in the design doc's table expect.
    private struct StatusPayload: Encodable {
        let busy: Bool
        let reason: String?
    }

    private struct QuitPayload: Encodable {
        let quit: Bool
        let reason: String?
    }

    private struct ErrorPayload: Encodable {
        let error: String
    }
}
