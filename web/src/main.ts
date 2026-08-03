// Entry point for Kikimi's Markdown web views (docs/design/39-webview-markdown.md §3).
//
// One bundle serves every surface. Which view boots is decided by the first API call Swift makes:
// `setContent` means the Summary/Watchers document view, `setTurns` means chat, `setDiagram` means
// the zoom overlay (design 40). Nothing is built until then, so an idle tab costs a parse and
// nothing more.

import { exposeApi, log, postToSwift } from "./bridge";
import { ChatView } from "./chat";
import { DiagramView } from "./diagram";
import { DocumentView } from "./document";
import { applyTheme } from "./theme";
import { installTestingHooks } from "./testing";

function boot(): void {
  const root = document.getElementById("root");
  if (!root) {
    log("error", "missing #root");
    return;
  }

  let documentView: DocumentView | null = null;
  let chatView: ChatView | null = null;
  let diagramView: DiagramView | null = null;

  const ensureDocumentView = (): DocumentView => {
    documentView ??= new DocumentView(root);
    return documentView;
  };
  const ensureChatView = (): ChatView => {
    chatView ??= new ChatView(root);
    return chatView;
  };
  const ensureDiagramView = (): DiagramView => {
    diagramView ??= new DiagramView(root);
    return diagramView;
  };

  installTestingHooks(() => diagramView?.currentText() ?? chatView?.currentText() ?? documentView?.currentText() ?? "");

  exposeApi({
    setTheme: ({ vars }) => applyTheme(vars),
    setContent: ({ markdown, docKey, followBottom }) =>
      ensureDocumentView().setContent(markdown, docKey, followBottom ?? false),
    setTurns: ({ turns }) => ensureChatView().setTurns(turns),
    updateTurn: ({ id, text }) => ensureChatView().updateTurn(id, text),
    setResponding: ({ responding, since }) => ensureChatView().setResponding(responding, since),
    setCopyFeedback: ({ turnId }) => ensureChatView().setCopyFeedback(turnId),
    // design 40: only the zoom overlay's own web view is ever sent this.
    setDiagram: ({ source }) => void ensureDiagramView().setDiagram(source)
  });

  // Swift queues everything it wants to push until this arrives (MD11): the first `setContent`
  // routinely beats the page, because the summary is already on disk when the window opens.
  postToSwift({ type: "ready" });
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
