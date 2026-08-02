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
            .onAppear { downloadModel.refresh(batchModel: appConfig.data.stt.batchModel) }
            .onChange(of: appConfig.data.stt.batchModel) { _, newValue in
                downloadModel.refresh(batchModel: newValue)
            }
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
            .help("会議中に取得が始まるのを避けるため、事前にダウンロードしておくことを勧めます")
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
