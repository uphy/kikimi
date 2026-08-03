import Darwin
import Foundation
import Testing

@testable import Kikimi

/// End-to-end over a real Unix domain socket (`docs/design/46-control-socket.md` §8): the wire
/// format and the decision are unit-tested elsewhere, so what is left to prove is that a client
/// which only knows "write a line, read a line" gets served.
@Suite("ControlSocketServer")
struct ControlSocketServerTests {
    /// Records what an accepted `quit` did, in place of `NSApp.terminate` and the dictation hotkey.
    @MainActor
    final class QuitRecorder {
        var prepareCount = 0
        var terminateCount = 0
    }

    @MainActor
    @Test("status reports an idle app")
    func statusWhenIdle() async throws {
        let url = Self.makeSocketURL()
        let server = ControlSocketServer(socketURL: url, busyReasonProvider: { nil })
        server.start()
        defer { server.stop() }

        let response = try await Self.request("status", at: url)

        #expect(response == "{\"busy\":false}")
    }

    @MainActor
    @Test("status reports the reason the app is busy")
    func statusWhenBusy() async throws {
        let url = Self.makeSocketURL()
        let server = ControlSocketServer(socketURL: url, busyReasonProvider: { "dictation is capturing" })
        server.start()
        defer { server.stop() }

        let response = try await Self.request("status", at: url)

        #expect(response == "{\"busy\":true,\"reason\":\"dictation is capturing\"}")
    }

    @MainActor
    @Test("quit is refused while busy, and nothing is torn down")
    func quitRefusedWhileBusy() async throws {
        let url = Self.makeSocketURL()
        let recorder = QuitRecorder()
        let server = ControlSocketServer(
            socketURL: url,
            busyReasonProvider: { "session rec-1 is recording" },
            prepareForQuit: { recorder.prepareCount += 1 },
            terminate: { recorder.terminateCount += 1 }
        )
        server.start()
        defer { server.stop() }

        let response = try await Self.request("quit", at: url)

        #expect(response == "{\"quit\":false,\"reason\":\"session rec-1 is recording\"}")
        #expect(recorder.prepareCount == 0)
        #expect(recorder.terminateCount == 0)
    }

    /// §5's ordering: the client must have the reply in hand before the app starts going away,
    /// so `request` returning is itself the evidence the reply was flushed first.
    @MainActor
    @Test("quit is accepted while idle: the hotkey is shut down and the app terminates")
    func quitAcceptedWhileIdle() async throws {
        let url = Self.makeSocketURL()
        let recorder = QuitRecorder()
        let server = ControlSocketServer(
            socketURL: url,
            busyReasonProvider: { nil },
            prepareForQuit: { recorder.prepareCount += 1 },
            terminate: { recorder.terminateCount += 1 }
        )
        server.start()
        defer { server.stop() }

        let response = try await Self.request("quit", at: url)

        #expect(response == "{\"quit\":true}")
        #expect(recorder.prepareCount == 1)
        #expect(await Self.eventually { recorder.terminateCount == 1 })
    }

    @MainActor
    @Test("an unknown request is answered rather than dropped")
    func unknownCommand() async throws {
        let url = Self.makeSocketURL()
        let recorder = QuitRecorder()
        let server = ControlSocketServer(
            socketURL: url,
            busyReasonProvider: { nil },
            prepareForQuit: { recorder.prepareCount += 1 },
            terminate: { recorder.terminateCount += 1 }
        )
        server.start()
        defer { server.stop() }

        let response = try await Self.request("shutdown", at: url)

        #expect(response == "{\"error\":\"unknown command\"}")
        #expect(recorder.terminateCount == 0)
    }

    /// A stale socket file must not make a client think the app is alive (§7 #2).
    @MainActor
    @Test("stop() removes the socket and stops answering")
    func stopRemovesSocket() async throws {
        let url = Self.makeSocketURL()
        let server = ControlSocketServer(socketURL: url, busyReasonProvider: { nil })
        server.start()
        _ = try await Self.request("status", at: url)

        server.stop()

        #expect(!FileManager.default.fileExists(atPath: url.path))
        await #expect(throws: (any Error).self) { try await Self.request("status", at: url) }
    }

    // MARK: - Client

    enum ClientError: Error, Equatable {
        case socketFailed(Int32)
        case connectFailed(Int32)
        case noResponse
    }

    /// Unique per test: the suite runs in parallel, and `sun_path` is too short for nesting these
    /// in a per-test directory (49-byte TMPDIR + name has to stay under 104).
    private static func makeSocketURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kikimi-ctl-\(UUID().uuidString.prefix(8)).sock")
    }

    /// Off the main actor on purpose: this blocks on `read`, and the server answers *on* the main
    /// actor. Doing both on the same thread would deadlock.
    private static func request(_ command: String, at url: URL) async throws -> String {
        try await Task.detached { try blockingRequest(command, at: url) }.value
    }

    private static func blockingRequest(_ command: String, at url: URL) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.socketFailed(errno) }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { field in
            field.copyBytes(from: Array(url.path.utf8))
        }
        let connected = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                connect(fd, pointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ClientError.connectFailed(errno) }

        var request = Array("\(command)\n".utf8)
        _ = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }

        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < 512 {
            guard read(fd, &byte, 1) == 1 else { break }
            if byte == UInt8(ascii: "\n") { break }
            bytes.append(byte)
        }
        guard let line = String(bytes: bytes, encoding: .utf8), !line.isEmpty else {
            throw ClientError.noResponse
        }
        return line
    }

    /// `terminate` runs in its own task after the reply is flushed, so it is observed by polling
    /// rather than by the request returning.
    @MainActor
    private static func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
