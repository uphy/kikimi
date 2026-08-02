import SwiftUI

// MARK: - ModelOverrideMenuButton

/// A split-button (`Menu` + `primaryAction`) carrying the manual-override menu
/// (`docs/design/44-llm-model-config.md` §8): clicking the label part runs immediately with the
/// default model (no override -- the common case stays one click), while the trailing chevron opens
/// "既定" + each `llm.models` alias, name-sorted. No direct-model-id entry (§8's revised list -- the
/// "モデルを指定して実行…" sheet was removed; every model must be defined in Settings' モデル定義 first).
/// Used by the Summary tab's regenerate button and its Ended-only final-pass re-run button -- both
/// fire once per tap, unlike the チャット tab's persistent selection (`ChatModelPicker` below).
struct ModelOverrideMenuButton: View {
    let title: String
    let busyTitle: String
    /// Session-start-snapshotted display value for the "既定" item (§8's "live 表示との乖離防止" --
    /// this is never re-resolved from live config here, only shown as-is).
    let defaultModelLabel: String
    /// Live config the menu's alias list (and each alias's click-time resolution) reads from --
    /// `@ObservedObject` so a mid-session Settings edit to `llm.models` is reflected the next time
    /// this menu opens (§8's "会議中に Settings でモデル定義の中身を変えたら次のクリックから効く").
    @ObservedObject var appConfig: AppConfig
    /// Invoked with the resolved override (`nil` for "既定で実行"). The caller (`MeetingWorkspaceView`)
    /// forwards this straight to `regenerateSummary(modelOverride:)`/`rerunFinalPass(modelOverride:)`.
    let action: (ResolvedModel?) async -> Void

    @State private var isRunning = false

    var body: some View {
        Menu {
            ForEach(ModelMenuItems.build(config: appConfig.data.llm), id: \.menuId) { candidate in
                menuItem(for: candidate)
            }
        } label: {
            if isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busyTitle)
                }
            } else {
                Text(title)
            }
        } primaryAction: {
            // One-click default run; model choice stays behind the chevron.
            run(nil)
        }
        .disabled(isRunning)
    }

    @ViewBuilder
    private func menuItem(for candidate: ModelMenuItems.Candidate) -> some View {
        switch candidate {
        case .useDefault:
            Button("既定（\(defaultModelLabel)）") { run(nil) }
        case .alias(let name):
            Button(name) { run(resolveAlias(name)) }
        }
    }

    /// §8's click-time resolution: live config, but provider existence validated only against
    /// `LLMClient.shared.availableProviders` (the startup snapshot, §3.2/§5.2) -- exactly what
    /// `ModelResolver.resolve(candidates:config:availableProviders:)` already does for a single-alias
    /// candidate list, including the "unresolvable alias → warning + fallthrough to `llm.default` →
    /// builtin, execution never stops" contract (§10).
    private func resolveAlias(_ name: String) -> ResolvedModel {
        ModelResolver.resolve(candidates: [name], config: appConfig.data.llm, availableProviders: LLMClient.shared.availableProviders)
    }

    private func run(_ override: ResolvedModel?) {
        guard !isRunning else { return }
        isRunning = true
        Task {
            await action(override)
            isRunning = false
        }
    }
}

// MARK: - ChatModelPicker

/// The チャット composer's small model picker (`docs/design/44-llm-model-config.md` §8): a persistent,
/// session-only selection (`MeetingWorkspaceViewModel.chatModelOverride`, never written back to
/// `chat.model`/`config.yaml`). Unlike `ModelOverrideMenuButton`, picking an item here does not itself
/// send a question -- it only updates `selection`, which the next `sendChatMessage()`/
/// `retryChatTurn(id:)` call reads.
struct ChatModelPicker: View {
    /// Session-start-snapshotted display value for the "既定" item -- `chatRunner.resolvedModel`,
    /// fixed at `MeetingWorkspaceViewModel.init` (`+Chat.swift`'s `chatRunner` doc comment).
    let defaultModelLabel: String
    @ObservedObject var appConfig: AppConfig
    @Binding var selection: ResolvedModel?

    private var currentLabel: String {
        selection?.model ?? "既定（\(defaultModelLabel)）"
    }

    var body: some View {
        Menu {
            ForEach(ModelMenuItems.build(config: appConfig.data.llm), id: \.menuId) { candidate in
                menuItem(for: candidate)
            }
        } label: {
            Label(currentLabel, systemImage: "cpu")
                .font(.caption)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("この質問で使うモデル")
    }

    @ViewBuilder
    private func menuItem(for candidate: ModelMenuItems.Candidate) -> some View {
        switch candidate {
        case .useDefault:
            Button("既定（\(defaultModelLabel)）") { selection = nil }
        case .alias(let name):
            Button(name) {
                selection = ModelResolver.resolve(candidates: [name], config: appConfig.data.llm, availableProviders: LLMClient.shared.availableProviders)
            }
        }
    }
}

// MARK: - ModelMenuItems.Candidate + Identifiable-for-ForEach

extension ModelMenuItems.Candidate {
    /// A stable id for `ForEach(_:id:)` -- `ModelMenuItems.Candidate` itself stays a plain
    /// `Equatable`/`Sendable` enum (no SwiftUI dependency) since `Kikimi/LLM/ModelMenuItems.swift` is
    /// unit-tested without importing SwiftUI at all.
    var menuId: String {
        switch self {
        case .useDefault: return "default"
        case .alias(let name): return "alias:\(name)"
        }
    }
}
