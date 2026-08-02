import SwiftUI

/// Batch (second-pass) model selection plus its ahead-of-time download, shown inside the STT
/// section's 詳細 group when 二段デコード is on (`docs/design/45-qwen3-batch-decode.md` §5.1).
///
/// A separate file rather than more rows in `GeneralSettingsTab`: that file is near the project's
/// `file_length` limit, and this row has real state (a running download) that does not belong in
/// a tab otherwise made of plain config bindings.
struct BatchModelSection: View {
    @ObservedObject private var appConfig = AppConfig.shared
    @ObservedObject var downloadModel: BatchModelDownloadViewModel

    init(downloadModel: BatchModelDownloadViewModel) {
        self.downloadModel = downloadModel
    }

    var body: some View {
        Picker("再認識モデル", selection: appConfig.binding(\.stt.batchModel)) {
            Text("Qwen3-ASR 1.7B（高精度・推奨）").tag(Qwen3Variant.large.rawValue)
            Text("Qwen3-ASR 0.6B（軽量）").tag(Qwen3Variant.small.rawValue)
            Text("Parakeet 日本語（旧既定）").tag(SttConfig.parakeetBatchModel)
        }
        .help(
            "録音開始時に固定されます。録音中の変更は次の録音から反映されます。"
                + "Parakeet は語の取りこぼしが多く、英語の固有名詞をカタカナ化します"
        )

        downloadRow
            .onAppear { refresh() }
            // Both inputs matter: Parakeet still resolves its variant by language
            // (`BatchAsrDecoder.resolveModelVersion`), so `ja-JP` and `en-US` are different
            // downloads even with the model row unchanged.
            .onChange(of: appConfig.data.stt.batchModel) { _, _ in refresh() }
            .onChange(of: appConfig.data.stt.language) { _, _ in refresh() }
            // A finished download puts a new model on disk; without this the list below would not
            // show it until the tab is left and reopened.
            .onChange(of: downloadModel.phase) { _, _ in refreshCachedModels() }

        cachedModelsGroup
    }

    /// Every model actually on disk, with its size and a delete action. Separate from the row
    /// above because that one only ever describes the *selected* model: after switching, the model
    /// you want to reclaim space from is by definition the one no longer selected, so a
    /// delete button up there could never reach it.
    @ViewBuilder
    private var cachedModelsGroup: some View {
        if !downloadModel.cachedModels.isEmpty {
            DisclosureGroup {
                ForEach(downloadModel.cachedModels) { model in
                    LabeledContent(model.label) {
                        HStack(spacing: 8) {
                            Text(BatchModelDownloadViewModel.formatBytes(model.bytes) ?? "")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            if let reason = model.inUseReason {
                                Text(reason).foregroundStyle(.secondary)
                            } else {
                                Button("削除") { pendingDeletion = model }
                            }
                        }
                    }
                }
            } label: {
                LabeledContent("ダウンロード済みモデル") {
                    Text("合計 \(BatchModelDownloadViewModel.formatBytes(downloadModel.cachedTotalBytes) ?? "")")
                        .foregroundStyle(.secondary)
                }
            }
            .confirmationDialog(
                pendingDeletion.map { "\($0.label) を削除しますか？" } ?? "",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }),
                titleVisibility: .visible
            ) {
                Button("削除", role: .destructive) {
                    if let model = pendingDeletion { downloadModel.delete(model) }
                    pendingDeletion = nil
                }
                Button("キャンセル", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("再び使うときはダウンロードし直しになります（最大 2.3 GB・数分）")
            }
        }
    }

    /// Set while the confirmation dialog is up. Deleting is reversible in principle -- the weights
    /// can be fetched again -- but "again" is minutes and up to 2.3GB, so a mis-click is worth a
    /// confirmation.
    @State private var pendingDeletion: BatchModelDownloadViewModel.CachedModel?

    private func refresh() {
        downloadModel.refresh(
            batchModel: appConfig.data.stt.batchModel,
            language: appConfig.data.stt.language)
        refreshCachedModels()
    }

    private func refreshCachedModels() {
        downloadModel.refreshCachedModels(
            batchModel: appConfig.data.stt.batchModel,
            language: appConfig.data.stt.language,
            twoPassDecode: appConfig.data.stt.twoPassDecode,
            dictationEnabled: appConfig.data.dictation.enabled,
            dictationTwoPassDecode: appConfig.data.dictation.twoPassDecode)
    }

    /// The state of the selected model's weights. Present as its own row rather than only as an
    /// error after the fact: a first-run download is ~2GB, and discovering that at the start of a
    /// meeting means the opening minutes silently fall back to the streaming transcript.
    @ViewBuilder
    private var downloadRow: some View {
        switch downloadModel.phase {
        case .notApplicable:
            EmptyView()
        case .missing:
            LabeledContent("モデル") {
                HStack(spacing: 8) {
                    Text("未ダウンロード").foregroundStyle(.secondary)
                    Button("今すぐダウンロード") { downloadModel.startDownload() }
                }
            }
            .help(
                "会議中に取得が始まるのを避けるため、事前にダウンロードしておくことを勧めます。"
                    + "未取得のまま録音を始めても中断はしませんが、取得が終わるまでは"
                    + "再認識が効かず従来の精度になります"
            )
        case .downloading(let fraction, let message):
            LabeledContent("モデル") {
                VStack(alignment: .leading, spacing: 4) {
                    // Determinate bar: the library reports a real fraction, and a spinner would
                    // hide that a multi-GB transfer is going to take minutes.
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                    Text("\(Int(fraction * 100))%  \(message)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .ready(let bytes):
            LabeledContent("モデル") {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(BatchModelDownloadViewModel.formatBytes(bytes).map { "ダウンロード済み（\($0)）" }
                        ?? "ダウンロード済み")
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            LabeledContent("モデル") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ダウンロードに失敗しました").foregroundStyle(.red)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button("再試行") { downloadModel.startDownload() }
                }
            }
        }
    }
}
