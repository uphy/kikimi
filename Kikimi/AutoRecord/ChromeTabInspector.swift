import AppKit
import CoreServices
import Foundation
import OSLog

/// A Google Meet meeting tab. See `docs/design/50-meet-auto-record.md` section 2.2.
struct MeetTab: Equatable, Sendable {
    let code: String
    let title: String
    /// The active tab of its window.
    let isActive: Bool
    /// The active tab of the frontmost Chrome window (used to notice a switch to another meeting).
    var isFrontmost: Bool = false
}

enum ChromeTabInspectionFailure: Equatable, Sendable {
    case notAuthorized
    case notDetermined
    case timeout
    case other(Int)
}

enum ChromeTabInspectionResult: Equatable, Sendable {
    /// Meet meeting tabs only (possibly empty).
    case tabs([MeetTab])
    case chromeNotRunning
    case failed(ChromeTabInspectionFailure)
}

enum ChromeTabInspectionMode: Sendable {
    /// Never shows the Automation consent dialog.
    case monitoring
    /// May show the Automation consent dialog (settings toggle path).
    case interactive
}

protocol ChromeTabInspecting: Sendable {
    func inspect(mode: ChromeTabInspectionMode) async -> ChromeTabInspectionResult

    /// Non-prompting Automation permission check. `nil` when it cannot be determined (Chrome not running).
    func automationPermitted() -> Bool?
}

/// Queries Chrome's tabs through AppleScript. Parsing and error mapping are pure statics so they can be
/// unit tested; the actual script execution is verified by hand (design 50 section 10).
final class ChromeTabInspector: ChromeTabInspecting, @unchecked Sendable {
    static let chromeBundleId = "com.google.Chrome"
    static let fieldSeparator = "\u{1F}"
    static let recordSeparator = "\u{1E}"

    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "ChromeTabInspector")
    /// `NSAppleScript` is not thread safe: everything touching it stays on this queue.
    private let queue = DispatchQueue(label: "io.github.uphy.Kikimi.ChromeTabInspector")
    private var compiledScript: NSAppleScript?

    init() {}

    // MARK: ChromeTabInspecting

    func inspect(mode: ChromeTabInspectionMode) async -> ChromeTabInspectionResult {
        // 1. Chrome must be running (compiling `tell application "Google Chrome"` without it shows a dialog).
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.chromeBundleId).isEmpty else {
            return .chromeNotRunning
        }
        // 2. Automation permission. Only the interactive path may prompt.
        let status = Self.determinePermission(askUserIfNeeded: mode == .interactive)
        if status != noErr {
            if let failure = Self.failure(forErrorCode: Int(status)) {
                return .failed(failure)
            }
            if status == OSStatus(procNotFound) { return .chromeNotRunning }
            return .failed(.other(Int(status)))
        }
        // 3. Run the script on the serial queue.
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: runScript())
            }
        }
    }

    func automationPermitted() -> Bool? {
        let status = Self.determinePermission(askUserIfNeeded: false)
        if status == OSStatus(procNotFound) { return nil }
        return status == noErr
    }

    // MARK: Script execution (queue-confined)

    private func runScript() -> ChromeTabInspectionResult {
        if compiledScript == nil {
            let script = NSAppleScript(source: Self.scriptSource)
            var compileError: NSDictionary?
            script?.compileAndReturnError(&compileError)
            compiledScript = script
        }
        guard let script = compiledScript else { return .failed(.other(-1)) }

        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? -1
            logger.debug("tab query failed code=\(code)")
            AutoRecordDiagnosticsLog.shared.write("tab query failed: code=\(code)")
            return .failed(Self.failure(forErrorCode: code) ?? .other(code))
        }
        let output = descriptor.stringValue ?? ""
        let tabs = Self.parseTabs(output)
        let meets = tabs.map { "\($0.code)\($0.isFrontmost ? "(front)" : $0.isActive ? "(active)" : "")" }
        AutoRecordDiagnosticsLog.shared.write(
            "tab query: windows=[\(Self.windowSummary(output))] meet=[\(meets.joined(separator: ", "))]"
        )
        return .tabs(tabs)
    }

    private static func determinePermission(askUserIfNeeded: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: chromeBundleId)
        guard let desc = target.aeDesc else { return OSStatus(paramErr) }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, askUserIfNeeded)
    }

    /// Wrapped in `with timeout`; every window and tab is guarded by its own `try` so one vanished window
    /// (PiP) does not fail the whole query.
    ///
    /// The "frontmost" window is the first one (Chrome orders `windows` front to back) whose active tab
    /// is a web page: Meet's picture-in-picture window floats above everything with a non-web active
    /// tab, and treating it as frontmost hid a switch to the next meeting for minutes (design 50
    /// section 2.3). One `#` record per window describes its shape for the diagnostics log.
    static let scriptSource = """
    with timeout of 5 seconds
        tell application id "com.google.Chrome"
            set fs to character id 31
            set rs to character id 30
            set out to ""
            set windowCount to count of windows
            set frontIdx to 0
            repeat with wi from 1 to windowCount
                try
                    set w to window wi
                    set au to URL of (active tab of w)
                    set out to out & "#" & fs & wi & fs & (count of tabs of w) & fs & au & rs
                    if frontIdx is 0 and au starts with "http" then set frontIdx to wi
                end try
            end repeat
            repeat with wi from 1 to windowCount
                try
                    set w to window wi
                    set activeIdx to active tab index of w
                    set ts to tabs of w
                    set tabCount to count of ts
                    repeat with ti from 1 to tabCount
                        try
                            set t to item ti of ts
                            set u to URL of t
                            if u contains "meet.google.com/" then
                                set flag to "0"
                                if ti is activeIdx then
                                    if wi is frontIdx then
                                        set flag to "2"
                                    else
                                        set flag to "1"
                                    end if
                                end if
                                set out to out & flag & fs & u & fs & (title of t) & rs
                            end if
                        end try
                    end repeat
                end try
            end repeat
            return out
        end tell
    end timeout
    """

    // MARK: Pure helpers

    /// `-1743` / `-1744` / `-1712` mapping (design 50 section 2.2). `nil` for any other code.
    static func failure(forErrorCode code: Int) -> ChromeTabInspectionFailure? {
        switch code {
        case -1743: .notAuthorized
        case -1744: .notDetermined
        case -1712: .timeout
        default: nil
        }
    }

    /// Meeting code from a Meet URL (query strings such as `?authuser=` are ignored).
    static func meetCode(fromURL url: String) -> String? {
        let prefix = "https://meet.google.com/"
        guard let range = url.range(of: #"^https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}"#, options: .regularExpression) else {
            return nil
        }
        return String(url[range].dropFirst(prefix.count))
    }

    /// Strips the leading `↗ ` (PiP marker) and `Meet - ` prefix from a tab title.
    static func cleanTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.hasPrefix("↗") {
            title = String(title.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if title.hasPrefix("Meet - ") {
            title = String(title.dropFirst("Meet - ".count))
        }
        return title
    }

    /// Parses the script output: records separated by U+001E, fields (`active`, `url`, `title`) by U+001F.
    /// `active` is `0` (inactive), `1` (active tab of a background window) or `2` (active tab of the
    /// frontmost web window, see `scriptSource`). `#` window records are skipped.
    static func parseTabs(_ output: String) -> [MeetTab] {
        output.components(separatedBy: recordSeparator).compactMap { record in
            guard !record.hasPrefix("#") else { return nil }
            let fields = record.components(separatedBy: fieldSeparator)
            guard fields.count >= 3, let code = meetCode(fromURL: fields[1]) else { return nil }
            let title = fields[2...].joined(separator: fieldSeparator)
            return MeetTab(
                code: code, title: cleanTitle(title),
                isActive: fields[0] != "0", isFrontmost: fields[0] == "2"
            )
        }
    }

    /// Window shapes from the `#` records, for the diagnostics log: index, tab count and the active
    /// tab's origin only (`about:blank`, `https://meet.google.com`; never a path or title).
    static func windowSummary(_ output: String) -> String {
        output.components(separatedBy: recordSeparator).compactMap { record -> String? in
            let fields = record.components(separatedBy: fieldSeparator)
            guard fields.count >= 4, fields[0] == "#" else { return nil }
            return "w\(fields[1]) tabs=\(fields[2]) active=\(origin(of: fields[3]))"
        }.joined(separator: ", ")
    }

    private static func origin(of url: String) -> String {
        if url.hasPrefix("about:") { return url }
        guard let components = URLComponents(string: url), let scheme = components.scheme else { return "?" }
        guard let host = components.host, !host.isEmpty else { return scheme + ":" }
        return "\(scheme)://\(host)"
    }
}
