import AppKit
import Darwin
import Foundation
import OSLog

// MARK: - ControlSocketError

enum ControlSocketError: LocalizedError, Equatable {
    /// `sockaddr_un.sun_path` is a fixed 104-byte field (`docs/design/46-control-socket.md` §7 #6).
    case pathTooLong(actual: Int, limit: Int)
    case syscallFailed(name: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case let .pathTooLong(actual, limit):
            return "control socket path is \(actual) bytes, over AF_UNIX's \(limit)-byte limit"
        case let .syscallFailed(name, code):
            return "\(name)() failed: \(String(cString: strerror(code))) (errno \(code))"
        }
    }
}

// MARK: - ControlSocketServer

/// Answers "can Kikimi be quit and replaced right now?" over a Unix domain socket
/// (`docs/design/46-control-socket.md`). `mise run apply` is the only client today: it asks
/// `status` before building and `quit` once the new bundle is ready.
///
/// Exists because the installer used to decide this from the outside, by reading `meta.json` and
/// the dictation history folder, and then `pkill`ing. That had to approximate "in progress" with a
/// grace window, could not see dictation at all when history was disabled, and skipped
/// `applicationShouldTerminate` (so `prepareForTermination()`'s flush never ran). Here the app
/// answers from its own live state, and `quit` decides and terminates in one MainActor hop -- no
/// window for an utterance to start in between (§5).
@MainActor
final class ControlSocketServer {
    static let shared = ControlSocketServer()

    static var defaultSocketURL: URL {
        FileManager.realHomeDirectory
            .appendingPathComponent(".local/state/kikimi/control.sock", isDirectory: false)
    }

    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "ControlSocketServer")
    private let socketURL: URL
    private let busyReasonProvider: @MainActor () -> String?
    private let prepareForQuit: @MainActor () -> Void
    private let terminate: @MainActor () -> Void

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let ioQueue = DispatchQueue(label: "io.github.uphy.Kikimi.control-socket")

    /// Every collaborator is injected so `ControlSocketServerTests` can drive a real socket without
    /// a running `NSApplication`: the defaults are the production wiring and nothing else here
    /// reaches for a singleton.
    init(
        socketURL: URL? = nil,
        busyReasonProvider: (@MainActor () -> String?)? = nil,
        prepareForQuit: (@MainActor () -> Void)? = nil,
        terminate: (@MainActor () -> Void)? = nil
    ) {
        self.socketURL = socketURL ?? Self.defaultSocketURL
        self.busyReasonProvider = busyReasonProvider ?? {
            ControlBusyEvaluator.busyReason(
                recordingSessionId: WindowManager.shared.recordingSessionId,
                dictationState: DictationController.shared.state,
                openPausedSessionIds: WindowManager.shared.openPausedSessionIds
            )
        }
        self.prepareForQuit = prepareForQuit ?? { DictationController.shared.suspendForTermination() }
        // Not `NSApp.terminate` directly: that path flushes via `terminateLater`, which deadlocks
        // when entered from a Swift concurrency task. See `AppDelegate.terminateForUpdate()`.
        self.terminate = terminate ?? { AppDelegate.terminateForUpdate() }
    }

    // MARK: Lifecycle

    /// Call once from `AppDelegate.applicationDidFinishLaunching`. A failure here is logged and
    /// swallowed (§7 #1): losing the control socket costs an unattended `mise run apply`, which is
    /// not worth refusing to launch over.
    func start() {
        guard listenFD < 0 else { return }

        do {
            listenFD = try Self.makeListeningSocket(at: socketURL)
        } catch {
            logger.error("control socket unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: ioQueue)
        let listenFD = self.listenFD
        source.setEventHandler { [weak self] in
            guard let clientFD = Self.acceptClient(listenFD) else { return }
            guard let self else {
                close(clientFD)
                return
            }
            self.serve(clientFD: clientFD)
        }
        source.resume()
        acceptSource = source

        logger.info("control socket listening at \(self.socketURL.path, privacy: .public)")
    }

    /// Best-effort teardown. A socket file left behind by a crash is harmless: clients fail to
    /// connect and fall back, and the next `start()` unlinks it before binding (§7 #2).
    func stop() {
        let fd = listenFD
        listenFD = -1

        if let source = acceptSource {
            // The descriptor has to outlive the source: closing it before the cancel handler runs
            // lets the source fire once more on a number the kernel may already have handed to
            // something else. Handing the close to the cancel handler is the documented order.
            source.setCancelHandler { if fd >= 0 { close(fd) } }
            source.cancel()
            acceptSource = nil
        } else if fd >= 0 {
            close(fd)
        }

        unlink(socketURL.path)
    }

    // MARK: Request handling

    /// Reads on `ioQueue`, decides on the main actor, then writes and closes back on `ioQueue`.
    /// The reply is flushed and the socket closed *before* `terminate()` so the client can tell an
    /// accepted quit from a crash (§5).
    private func serve(clientFD: Int32) {
        let request = Self.readRequestLine(clientFD, limit: ControlCommand.maxRequestBytes)
        let ioQueue = self.ioQueue

        Task { @MainActor in
            let response = self.respond(to: request)
            ioQueue.async {
                Self.write(response.line, to: clientFD)
                close(clientFD)
                if response.terminatesApp {
                    Task { @MainActor in self.terminate() }
                }
            }
        }
    }

    /// The whole decision, on the main actor: reading the live state, refusing, and -- for an
    /// accepted `quit` -- shutting the hotkey down happen without yielding, so nothing can start
    /// an utterance between the check and the decision.
    private func respond(to request: String?) -> ControlResponse {
        guard let request, let command = ControlCommand.parse(request) else {
            logger.warning("control socket: unknown request \(request ?? "<none>", privacy: .public)")
            return .error("unknown command")
        }

        let busyReason = busyReasonProvider()

        switch command {
        case .status:
            return .status(busyReason: busyReason)
        case .quit:
            if let busyReason {
                logger.info("control socket: refused quit -- \(busyReason, privacy: .public)")
                return .quitRefused(reason: busyReason)
            }
            prepareForQuit()
            logger.info("control socket: quitting for an update")
            return .quitAccepted
        }
    }

    // MARK: Socket primitives

    private static func makeListeningSocket(at url: URL) throws -> Int32 {
        let path = url.path
        let pathBytes = Array(path.utf8)
        let pathLimit = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard pathBytes.count < pathLimit else {
            throw ControlSocketError.pathTooLong(actual: pathBytes.count, limit: pathLimit)
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketError.syscallFailed(name: "socket", code: errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { field in
            field.copyBytes(from: pathBytes)
        }

        let bound = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(fd, pointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw ControlSocketError.syscallFailed(name: "bind", code: code)
        }

        // Owner-only: the socket quits the app, so nothing about it belongs to other users.
        chmod(path, 0o600)

        guard listen(fd, 4) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw ControlSocketError.syscallFailed(name: "listen", code: code)
        }

        // Non-blocking so `DispatchSourceRead` owns the waiting; a spurious readability event must
        // not park the io queue inside accept().
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        return fd
    }

    private static func acceptClient(_ listenFD: Int32) -> Int32? {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return nil }
        // The accepted socket inherits nothing on macOS, but be explicit: the read below relies on
        // blocking semantics plus SO_RCVTIMEO for its timeout.
        let flags = fcntl(clientFD, F_GETFL, 0)
        _ = fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK)
        return clientFD
    }

    /// One line, or `nil` if the client sent nothing before disconnecting or timing out (§7 #3).
    /// Byte-at-a-time: the limit is 64 bytes, so buffering would only add a partial-line state
    /// machine for no gain.
    private static func readRequestLine(_ fd: Int32, limit: Int) -> String? {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < limit {
            let count = read(fd, &byte, 1)
            guard count == 1 else { break }
            if byte == UInt8(ascii: "\n") { break }
            bytes.append(byte)
        }

        // Failable rather than lossy: a request that is not valid UTF-8 is not one of the two
        // verbs either, and `respond(to:)` already answers `unknown command` for `nil`.
        return bytes.isEmpty ? nil : String(bytes: bytes, encoding: .utf8)
    }

    private static func write(_ line: String, to fd: Int32) {
        var bytes = Array(line.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            guard written > 0 else { return }
            offset += written
        }
    }
}
