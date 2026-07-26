import Foundation

/// Writes to both stdout and a file, because the spike runs as an LSUIElement
/// bundle (launched via `open`, so stdout is not attached to a terminal).
enum Log {
    static let fileURL = URL(fileURLWithPath: "/tmp/dictation-spike.log")

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        append(line)
    }

    private static func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    static func startSession() {
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
