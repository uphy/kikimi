import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
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

// docs/design/47-summary-split-pane.md §5.2/§8. The 議事詳細 pane follows its own tail while the
// reader is at the bottom, and leaves them alone when they are not.
describe("DocumentView auto-follow", () => {
  let root: HTMLElement;

  /**
   * jsdom hard-wires `scrollHeight`/`clientHeight` to 0, which makes `distanceFromBottom()` return
   * 0 for every position -- every reader would look pinned and every assertion here would pass
   * without testing anything (§8). `scrollTop` is a plain stored value, so only the two read-only
   * getters need standing in for a real layout.
   */
  function stubLayout(scrollHeight: number, clientHeight: number): void {
    Object.defineProperty(document.documentElement, "scrollHeight", { value: scrollHeight, configurable: true });
    Object.defineProperty(document.documentElement, "clientHeight", { value: clientHeight, configurable: true });
  }

  /** Moves the reader and lets the scroll listener observe it, the way a real scroll would. */
  function scrollTo(position: number): void {
    document.documentElement.scrollTop = position;
    document.dispatchEvent(new Event("scroll"));
  }

  beforeEach(() => {
    vi.useFakeTimers();
    vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0));
    document.body.innerHTML = '<div id="root"></div>';
    root = document.getElementById("root")!;
    installBridge();
    stubLayout(1000, 500);
  });

  afterEach(() => {
    // `documentElement` is shared across tests in this file; leaving the stubs in place would make
    // the plain scroll-restore suite above see a fake layout.
    for (const name of ["scrollHeight", "clientHeight"]) {
      delete (document.documentElement as unknown as Record<string, unknown>)[name];
    }
  });

  it("scrolls to the new bottom when the reader is already at the bottom", async () => {
    const view = new DocumentView(root);
    view.setContent("議事詳細", "summary-topics", true);
    await flushFrame();

    scrollTo(500); // 1000 - 500 - 500 = 0 from the bottom
    stubLayout(1400, 500); // the update made the document taller
    view.setContent("議事詳細\n\n追記", "summary-topics", true);
    await flushFrame();

    expect(document.documentElement.scrollTop).toBe(1400);
  });

  it("leaves the reader alone when they have scrolled up to re-read", async () => {
    const view = new DocumentView(root);
    view.setContent("議事詳細", "summary-topics", true);
    await flushFrame();

    scrollTo(100); // 1000 - 100 - 500 = 400 from the bottom, well past the threshold
    stubLayout(1400, 500);
    view.setContent("議事詳細\n\n追記", "summary-topics", true);
    await flushFrame();

    expect(document.documentElement.scrollTop).toBe(100);
  });

  it("restores the previous position, not the bottom, when following is off", async () => {
    const view = new DocumentView(root);
    view.setContent("サマリ", "summary-top");
    await flushFrame();

    scrollTo(500); // at the bottom -- irrelevant without followBottom
    stubLayout(1400, 500);
    view.setContent("サマリ\n\n追記", "summary-top");
    await flushFrame();

    expect(document.documentElement.scrollTop).toBe(500);
  });

  it("re-pins on a new document, so a scrolled-away position is not inherited", async () => {
    const view = new DocumentView(root);
    view.setContent("議事詳細 A", "summary-topics:a", true);
    await flushFrame();

    scrollTo(100); // scrolled away in the *previous* document
    stubLayout(1400, 500);
    view.setContent("議事詳細 B", "summary-topics:b", true);
    await flushFrame();

    expect(document.documentElement.scrollTop).toBe(1400);
  });
});
