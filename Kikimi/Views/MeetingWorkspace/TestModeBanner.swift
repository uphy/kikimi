import SwiftUI

// MARK: - Test-mode indicator

/// Detects the `kikimi-verify` test env vars so the UI can surface an unmissable badge in the Session
/// Window header (`MeetingWorkspaceView`). Belt-and-suspenders against the recurring
/// "書き起こしが一切できない" footgun: `KIKIMI_TEST_INPUT` replaces the real mic with a dummy WAV
/// (`AudioCapture.swift`) and `KIKIMI_STUB_LLM` stubs the LLM, so a leftover test-mode process looks
/// exactly like a broken build. Read once at process start (env is fixed for a process's lifetime),
/// keeping this a pure static lookup with no per-render `ProcessInfo` cost. `nil` in production
/// (neither var set) so no badge is ever rendered.
enum TestModeIndicator {
    /// Human-readable description of which test env is active, or `nil` when none is.
    static let message: String? = {
        let env = ProcessInfo.processInfo.environment
        let dummyAudio = env["KIKIMI_TEST_INPUT"]?.isEmpty == false
        let stubbedLLM = env["KIKIMI_STUB_LLM"] == "1"
        switch (dummyAudio, stubbedLLM) {
        case (true, true):
            return "テスト入力モード（ダミー音源・LLM スタブ）— 実マイクは録音されません"
        case (true, false):
            return "テスト入力モード（ダミー音源）— 実マイクは録音されません"
        case (false, true):
            return "LLM スタブモード（整形・サマリは固定応答）"
        case (false, false):
            return nil
        }
    }()
}

// MARK: - TestModeBanner

/// Always-visible, non-dismissable banner shown while a test env var is active (`TestModeIndicator`).
/// Deliberately distinct from the dismissable `WorkspaceBannerRow` (transient failures): this state
/// is a launch-time condition the user must not be able to accidentally hide and then forget.
struct TestModeBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "testtube.2")
                .foregroundStyle(.black)
            Text(message)
                .font(.callout.weight(.medium))
                .foregroundStyle(.black)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.yellow)
    }
}
