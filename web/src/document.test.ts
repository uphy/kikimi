import { beforeEach, describe, expect, it, vi } from "vitest";
import type { JsToSwiftMessage } from "./bridge";
import { DocumentView } from "./document";

// docs/design/39-webview-markdown.md §8.2. The scroll-restore behaviour (MD8) is what these cover:
// getting it wrong shows up as "the Watcher I just opened is scrolled to where the previous one
// was", which is easy to miss by hand and easy to pin here.

function installBridge(): JsToSwiftMessage[] {
  const messages: JsToSwiftMessage[] = [];
  window.webkit = {
    messageHandlers: {
      kikimi: { postMessage: (message: JsToSwiftMessage) => messages.push(message) }
    }
  };
  return messages;
}

/**
 * jsdom does not run rAF callbacks on its own timeline, and the render finishes in a promise chain
 * (the mermaid pass, §4). `runAllTimersAsync` drains both, so assertions see the finished render.
 */
async function flushFrame(): Promise<void> {
  await vi.runAllTimersAsync();
}

describe("DocumentView", () => {
  let root: HTMLElement;
  let messages: JsToSwiftMessage[];

  beforeEach(() => {
    vi.useFakeTimers();
    vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0));
    document.body.innerHTML = '<div id="root"></div>';
    root = document.getElementById("root")!;
    messages = installBridge();
  });

  it("renders markdown into the root", async () => {
    new DocumentView(root).setContent("# 見出し", "summary");
    expect(root.innerHTML).toContain("<h1>見出し</h1>");
  });

  it("reports a render generation so a verifier can wait for it (MD12)", async () => {
    const view = new DocumentView(root);
    view.setContent("a", "summary");
    await flushFrame();
    expect(messages).toContainEqual({ type: "rendered", generation: 1 });
  });

  it("keeps the scroll position when the same document is updated (MD8)", async () => {
    const view = new DocumentView(root);
    view.setContent("first", "summary");
    await flushFrame();

    document.documentElement.scrollTop = 240;
    view.setContent("first, updated", "summary");
    await flushFrame();

    expect(document.documentElement.scrollTop).toBe(240);
  });

  it("returns to the top when the document changes (Watchers sub-tab switch)", async () => {
    const view = new DocumentView(root);
    view.setContent("watcher a", "watcher:a");
    await flushFrame();

    document.documentElement.scrollTop = 240;
    view.setContent("watcher b", "watcher:b");
    await flushFrame();

    expect(document.documentElement.scrollTop).toBe(0);
  });

  it("reports a clicked link to Swift instead of navigating (MD6)", async () => {
    const view = new DocumentView(root);
    view.setContent("[seg_00042](kikimi-seg:seg_00042)", "summary");
    await flushFrame();

    const anchor = root.querySelector("a")!;
    const event = new MouseEvent("click", { bubbles: true, cancelable: true });
    anchor.dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
    expect(messages).toContainEqual({ type: "openLink", url: "kikimi-seg:seg_00042" });
  });

  it("exposes the rendered text for verification (MD12)", async () => {
    const view = new DocumentView(root);
    view.setContent("# タイトル\n\n本文です。", "summary");
    expect(view.currentText()).toContain("タイトル");
  });
});
