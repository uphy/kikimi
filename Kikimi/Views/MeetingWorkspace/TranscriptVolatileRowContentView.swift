import SwiftUI

// MARK: - TranscriptVolatileRowContentView

/// One in-progress (unconfirmed) source's trailing line (`docs/design/11-streaming-stt.md` section
/// 3.6), rendered in the same 2-line layout as `TranscriptRowContentView`
/// (`docs/design/17-session-window-redesign.md` section 5.3.1): a header line with the speaker icon
/// only (no timestamp -- this text has no confirmed `startMs`/`endMs` yet, it may still grow, shrink,
/// or be replaced entirely before ever becoming a real row) followed by a full-width dim/italic text
/// line.
///
/// Split out of `TranscriptTabView.swift` (`file_length` lint) -- both files render rows for the
/// same "Transcript" tab (`docs/design/06-ui-panels.md` section 6.3).
struct TranscriptVolatileRowContentView: View {
    let source: AudioSourceKind
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: source.sfSymbolName)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(source.accessibilityLabel)

            Text(text)
                .font(.body.italic())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(source.accessibilityLabel)、書き起こし中: \(text)")
    }
}

// MARK: - AudioSourceKind display helpers

/// Shared between `TranscriptRowContentView` (confirmed rows, `TranscriptTabView.swift`) and
/// `TranscriptVolatileRowContentView` (in-progress rows) so both render the same icon/label per
/// source.
extension AudioSourceKind {
    var sfSymbolName: String {
        switch self {
        case .mic:
            return "mic.fill"
        case .system:
            return "speaker.wave.2.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .mic:
            return "マイク"
        case .system:
            return "システム音声"
        }
    }
}
