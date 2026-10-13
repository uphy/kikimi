import AppKit
import SwiftUI

// MARK: - AutomationPermissionRequesting

/// Result of an interactive Automation permission request for Google Chrome.
enum AutomationPermissionOutcome: Equatable, Sendable {
    case authorized
    /// The user denied (or previously denied) Kikimi's control of Chrome.
    case notAuthorized
    /// Chrome is not running, so the system could not show the permission dialog.
    case chromeNotRunning
}

/// The only thing the settings UI needs from `ChromeTabInspector`
/// (`docs/design/50-meet-auto-record.md` section 4). The AutoRecord module provides the live
/// implementation (a thin wrapper over `ChromeTabInspector.inspect(mode: .interactive)`) and
/// assigns it to `AutomationPermissionRequesterRegistry.shared` at app start.
protocol AutomationPermissionRequesting: Sendable {
    /// Triggers the system permission dialog if needed. Must be the only path that shows it.
    func requestInteractive() async -> AutomationPermissionOutcome
}

/// Holds the live requester so the settings view does not depend on the AutoRecord types.
@MainActor
enum AutomationPermissionRequesterRegistry {
    static var shared: AutomationPermissionRequesting?
}

// MARK: - AutoRecordSettingsSection

/// "会議の自動録音" section of the General tab (`docs/design/50-meet-auto-record.md` section 4).
struct AutoRecordSettingsSection: View {
    @ObservedObject private var appConfig = AppConfig.shared
    @State private var outcome: AutomationPermissionOutcome?
    @State private var isChecking = false

    private struct GraceChoice: Identifiable {
        let label: String
        let seconds: Int
        var id: Int { seconds }
    }

    private static let graceOptions = [
        GraceChoice(label: "しない", seconds: 0),
        GraceChoice(label: "1 分", seconds: 60),
        GraceChoice(label: "2 分", seconds: 120),
        GraceChoice(label: "5 分", seconds: 300)
    ]

    var body: some View {
        Section("会議の自動録音") {
            Toggle("Google Meet への参加で録音を始める", isOn: enabledBinding)
            Picker(
                "退出後に自動で終了するまでの猶予",
                selection: appConfig.binding(\.autoRecord.googleMeet.endGraceSeconds)
            ) {
                ForEach(graceChoices) { Text($0.label).tag($0.seconds) }
            }
            if appConfig.data.autoRecord.googleMeet.enabled {
                permissionNotice
            }
        }
    }

    /// The preset list plus the current value when it is a custom one from `config.yaml`.
    private var graceChoices: [GraceChoice] {
        let current = appConfig.data.autoRecord.googleMeet.endGraceSeconds
        if Self.graceOptions.contains(where: { $0.seconds == current }) { return Self.graceOptions }
        return Self.graceOptions + [GraceChoice(label: "\(current) 秒", seconds: current)]
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { appConfig.data.autoRecord.googleMeet.enabled },
            set: { newValue in
                appConfig.update { $0.autoRecord.googleMeet.enabled = newValue }
                if newValue {
                    requestPermission()
                } else {
                    outcome = nil
                }
            }
        )
    }

    @ViewBuilder
    private var permissionNotice: some View {
        switch outcome {
        case .chromeNotRunning:
            Text("Chrome を起動したあと、もう一度オンにすると許可を求めます。")
                .font(.caption).foregroundStyle(.secondary)
            Button("許可を確認") { requestPermission() }.disabled(isChecking)
        case .notAuthorized:
            Text("システム設定 > プライバシーとセキュリティ > オートメーション で Kikimi に Google Chrome の制御を許可してください。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("オートメーション設定を開く") { Self.openAutomationSettings() }
                Button("許可を確認") { requestPermission() }.disabled(isChecking)
            }
        case .authorized, nil:
            EmptyView()
        }
    }

    private func requestPermission() {
        guard let requester = AutomationPermissionRequesterRegistry.shared, !isChecking else { return }
        isChecking = true
        Task {
            let result = await requester.requestInteractive()
            outcome = result
            isChecking = false
        }
    }

    private static func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
