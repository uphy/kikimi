// Swift <-> JS contract for the Markdown views (docs/design/39-webview-markdown.md §3.1).
//
// Both directions are declared here, including the chat half that Phase C implements, so the
// contract is settled once. MD16 in particular: `updateTurn` exists from the start so that adding
// streaming later (design 38 §9) does not mean re-cutting the bridge.

export type ChatTurnRole = "user" | "assistant";

export interface ChatTurnView {
  id: string;
  role: ChatTurnRole;
  /** Markdown for assistant turns; plain text for user turns (MD4 -- never run through markdown-it). */
  text: string;
  /** Epoch seconds. */
  createdAt: number;
  error?: string;
  /** design 38 §4.5: shown as the "会議が長いため…" note above the answer. */
  contextScope?: "full" | "summaryAndRecent";
}

/**
 * Called by Swift via `callAsyncJavaScript` (MD11).
 *
 * **Every function takes exactly one object.** `callAsyncJavaScript` passes arguments as a
 * dictionary and the call site has to name them positionally in the script it builds, so a
 * multi-parameter signature here means Swift and this file have to agree on an order that nothing
 * checks. They did not: `setContent(markdown, docKey)` was being called with the two swapped,
 * which put the document key on screen as the body text. A single payload makes the mismatch
 * impossible to express.
 */
export interface SwiftToJsApi {
  setTheme: (payload: { vars: Record<string, string> }) => void;
  /**
   * `docKey` identifies the *document*, not the revision (MD8): the same key means "this is an
   * update of what you are already showing" and the scroll position is kept; a different key means
   * a different document (another Watcher's result) and the view starts at the top.
   */
  setContent: (payload: { markdown: string; docKey: string }) => void;
  setTurns: (payload: { turns: ChatTurnView[] }) => void;
  updateTurn: (payload: { id: string; text: string }) => void;
  setResponding: (payload: { responding: boolean; since: number | null }) => void;
  setCopyFeedback: (payload: { turnId: string | null }) => void;
  /**
   * Boots the zoom overlay with one diagram (`docs/design/40-diagram-zoom.md` §3.1). Only the
   * overlay window's own web view ever receives this; a document/chat page never does.
   */
  setDiagram: (payload: { source: string }) => void;
}

export type JsToSwiftMessage =
  | { type: "ready" }
  /** MD12: lets an external verifier wait for a specific render instead of racing the screenshot. */
  | { type: "rendered"; generation: number }
  | { type: "openLink"; url: string }
  | { type: "copyTurn"; id: string }
  | { type: "retryTurn"; id: string }
  /** design 40 DZ4: the mermaid source, not the drawn SVG — the overlay re-renders it. */
  | { type: "zoomDiagram"; source: string }
  | { type: "closeDiagram" }
  | { type: "log"; level: "debug" | "info" | "warn" | "error"; message: string };

interface KikimiWebkit {
  messageHandlers: {
    kikimi: { postMessage: (message: JsToSwiftMessage) => void };
  };
}

declare global {
  interface Window {
    webkit?: KikimiWebkit;
    kikimi?: SwiftToJsApi;
    __kikimiDumpText?: () => string;
    __kikimiClick?: (testId: string) => boolean;
  }
}

export function postToSwift(message: JsToSwiftMessage): void {
  window.webkit?.messageHandlers.kikimi.postMessage(message);
}

export function log(level: "debug" | "info" | "warn" | "error", message: string): void {
  postToSwift({ type: "log", level, message });
}

export function exposeApi(api: SwiftToJsApi): void {
  window.kikimi = api;
}
