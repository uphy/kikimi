import Foundation
import OSLog

/// Logs to the unified log and mirrors the line into `AutoRecordDiagnosticsLog`. Messages carry session
/// ids and meeting codes but never tab titles, so they are logged as public.
struct AutoRecordTrace {
    private let logger: Logger
    private let category: String
    private let file: AutoRecordDiagnosticsLog

    init(category: String, file: AutoRecordDiagnosticsLog = .shared) {
        logger = Logger(subsystem: "io.github.uphy.Kikimi", category: category)
        self.category = category
        self.file = file
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        file.write("[\(category)] \(message)")
    }

    func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        file.write("[\(category)] WARN \(message)")
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        file.write("[\(category)] ERROR \(message)")
    }
}

/// Plain-text trail of what auto-record saw and decided (`docs/design/50-meet-auto-record.md` section 7).
/// The unified log drops `info` entries within hours, which left a misdetected meeting impossible to
/// explain the next morning; this file keeps the last few megabytes instead.
///
/// `~/.local/state/kikimi/logs/auto-record.log`, rotated to `auto-record.1.log` past 2 MB. It holds
/// meeting codes and window shapes but never tab titles or other URLs. Writes are dropped outside an
/// `.app` bundle so the test runner never touches the real state directory.
final class AutoRecordDiagnosticsLog: @unchecked Sendable {
    static let shared = AutoRecordDiagnosticsLog(
        directory: AppState.defaultStateDirectory.appendingPathComponent("logs", isDirectory: true),
        enabled: Bundle.main.bundleURL.pathExtension == "app"
    )

    static let maxBytes = 2 * 1024 * 1024

    private let fileURL: URL
    private let rotatedURL: URL
    private let enabled: Bool
    private let queue = DispatchQueue(label: "io.github.uphy.Kikimi.AutoRecordDiagnosticsLog")
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    init(directory: URL, enabled: Bool) {
        fileURL = directory.appendingPathComponent("auto-record.log")
        rotatedURL = directory.appendingPathComponent("auto-record.1.log")
        self.enabled = enabled
    }

    func write(_ message: String) {
        guard enabled else { return }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async { [fileURL, rotatedURL] in
            Self.append(line, to: fileURL, rotatingTo: rotatedURL)
        }
    }

    /// Blocks until queued writes are on disk (tests).
    func flush() {
        queue.sync {}
    }

    private static func append(_ line: String, to fileURL: URL, rotatingTo rotatedURL: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fileManager.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > maxBytes {
            try? fileManager.removeItem(at: rotatedURL)
            try? fileManager.moveItem(at: fileURL, to: rotatedURL)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
