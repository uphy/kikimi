import Foundation

// MARK: - ChatTurnView

/// The display projection of a `ChatTurn`, as handed to the chat web view
/// (`docs/design/39-webview-markdown.md` §3.1 / §3.6).
///
/// Deliberately narrower than `ChatTurn`: `parentTurnId` / `replacesTurnId` / `usage` are bookkeeping
/// that `ChatTurnLog.fold(_:)` and the cost badge consume, and the page has no business knowing
/// about them. Keeping the projection explicit also means `chat.jsonl`'s on-disk shape can change
/// without touching the bridge.
struct ChatTurnView: Equatable {
    let id: String
    /// `"user"` / `"assistant"` — `ChatRole`'s raw value, which is also the page's union type.
    let role: String
    /// The question (plain text, never run through markdown-it — MD4) or the answer's Markdown.
    let text: String
    /// Epoch seconds; the page formats it (`HH:mm`, matching the SwiftUI version).
    let createdAt: Double
    /// Non-nil marks a failed answer: the page shows the reason and a retry button (design 38 §6).
    let error: String?
    /// `"summaryAndRecent"` makes the page show the "会議が長いため…" note (design 38 §4.5).
    let contextScope: String?

    init(turn: ChatTurn) {
        id = turn.id
        role = turn.role.rawValue
        text = turn.text
        createdAt = turn.createdAt.timeIntervalSince1970
        error = turn.error
        contextScope = turn.contextScope?.rawValue
    }

    /// `callAsyncJavaScript` only accepts JSON-representable values, so the projection is flattened
    /// by hand rather than encoded. `nil` fields are omitted instead of sent as `NSNull`: the page's
    /// optional properties then simply read as `undefined`.
    var payload: [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "role": role,
            "text": text,
            "createdAt": createdAt
        ]
        if let error { payload["error"] = error }
        if let contextScope { payload["contextScope"] = contextScope }
        return payload
    }
}
