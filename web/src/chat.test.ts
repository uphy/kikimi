import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ChatTurnView, JsToSwiftMessage } from "./bridge";
import { ChatView } from "./chat";

// docs/design/39-webview-markdown.md §8.2. Phase C moved the bubbles, buttons and auto-follow out of
// SwiftUI and into the page, so the behaviours `ChatTabView` used to get from the framework now need
// covering here.

function installBridge(): JsToSwiftMessage[] {
  const messages: JsToSwiftMessage[] = [];
  window.webkit = {
    messageHandlers: { kikimi: { postMessage: (message: JsToSwiftMessage) => messages.push(message) } }
  };
  return messages;
}

/**
 * Advances only the zero-delay timers (the rAF stub) and drains the promise chain behind a render.
 * `runAllTimersAsync` cannot be used here: the pending row's one-second interval never runs out, so
 * it trips vitest's infinite-loop guard.
 */
async function flushFrame(): Promise<void> {
  await vi.advanceTimersByTimeAsync(0);
}

function turn(overrides: Partial<ChatTurnView> & { id: string }): ChatTurnView {
  return {
    role: "assistant",
    text: "",
    createdAt: 1_751_000_000,
    ...overrides
  };
}

describe("ChatView", () => {
  let root: HTMLElement;
  let messages: JsToSwiftMessage[];
  let view: ChatView;

  beforeEach(() => {
    vi.useFakeTimers();
    vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0));
    document.body.innerHTML = '<div id="root"></div>';
    root = document.getElementById("root")!;
    messages = installBridge();
    view = new ChatView(root);
  });

  it("shows the empty placeholder until there is a history", async () => {
    view.setTurns([]);
    await flushFrame();
    expect(root.textContent).toContain("この会議について質問できます");
  });

  it("renders an answer as Markdown", async () => {
    view.setTurns([turn({ id: "a1", text: "## 決定事項\n\n- 続行" })]);
    await flushFrame();
    expect(root.querySelector("h2")?.textContent).toBe("決定事項");
    expect(root.querySelector("li")?.textContent).toBe("続行");
  });

  it("does NOT render a question as Markdown (MD4)", async () => {
    // A question like this is a question, not a heading and an ordered list.
    view.setTurns([turn({ id: "q1", role: "user", text: "#確認 これでOK?\n1. と 2. どっち?" })]);
    await flushFrame();
    expect(root.querySelector("h1")).toBeNull();
    expect(root.querySelector("ol")).toBeNull();
    expect(root.textContent).toContain("#確認 これでOK?");
  });

  it("shows a failed answer with a retry button that reports to Swift (design 38 §6)", async () => {
    view.setTurns([turn({ id: "a1", text: "", error: "timeout" })]);
    await flushFrame();
    expect(root.textContent).toContain("回答を取得できませんでした: timeout");

    const retry = root.querySelector<HTMLElement>("[data-retry-turn]")!;
    expect(retry.getAttribute("aria-label")).toBe("回答を再送");
    expect(retry.title).toBe("回答を再送");
    retry.click();
    expect(messages).toContainEqual({ type: "retryTurn", id: "a1" });
  });

  it("reports a copy request and shows the checkmark only when Swift confirms it (design 37 §6)", async () => {
    view.setTurns([turn({ id: "a1", text: "答え" })]);
    await flushFrame();

    const copy = root.querySelector<HTMLElement>("[data-copy-turn]")!;
    expect(copy.getAttribute("aria-label")).toBe("回答をコピー");
    copy.click();
    expect(messages).toContainEqual({ type: "copyTurn", id: "a1" });
    // The tap alone must not flip the icon: a failed pasteboard write shows nothing.
    expect(copy.classList.contains("kikimi-chat-copied")).toBe(false);

    view.setCopyFeedback("a1");
    expect(root.querySelector("[data-copy-turn]")!.classList.contains("kikimi-chat-copied")).toBe(true);
  });

  it("shows the demotion note only on an answer that was demoted (design 38 §4.5)", async () => {
    view.setTurns([
      turn({ id: "a1", text: "全部見た", contextScope: "full" }),
      turn({ id: "a2", text: "一部だけ", contextScope: "summaryAndRecent" })
    ]);
    await flushFrame();
    expect(root.querySelectorAll(".kikimi-chat-note")).toHaveLength(1);
    expect(root.textContent).toContain("会議が長いため");
  });

  it("counts elapsed seconds while an answer is in flight", async () => {
    vi.setSystemTime(new Date(1_751_000_010_000));
    view.setResponding(true, 1_751_000_000);
    await flushFrame();
    expect(root.textContent).toContain("回答を作成中… 10秒");
  });

  it("stops showing the pending row once the answer lands", async () => {
    view.setResponding(true, 1_751_000_000);
    await flushFrame();
    view.setResponding(false, null);
    view.setTurns([turn({ id: "a1", text: "答え" })]);
    await flushFrame();
    expect(root.querySelector(".kikimi-chat-pending")).toBeNull();
  });

  it("rewrites one bubble in place on updateTurn (MD16, the streaming seam)", async () => {
    view.setTurns([turn({ id: "a1", text: "途中" })]);
    await flushFrame();
    view.updateTurn("a1", "完成した回答");
    expect(root.querySelector('[data-turn-body="a1"]')?.textContent).toContain("完成した回答");
  });

  it("reports a link inside an answer instead of navigating (MD6)", async () => {
    view.setTurns([turn({ id: "a1", text: "根拠: [seg_00042](kikimi-seg:seg_00042)" })]);
    await flushFrame();

    const anchor = root.querySelector("a")!;
    const event = new MouseEvent("click", { bubbles: true, cancelable: true });
    anchor.dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
    expect(messages).toContainEqual({ type: "openLink", url: "kikimi-seg:seg_00042" });
  });

  it("escapes HTML in an answer (MD10)", async () => {
    view.setTurns([turn({ id: "a1", text: "<img src=x onerror=alert(1)>" })]);
    await flushFrame();
    expect(root.querySelector("img")).toBeNull();
  });

  it("exposes the rendered text for verification (MD12)", async () => {
    view.setTurns([turn({ id: "a1", text: "決定事項はこれ" })]);
    await flushFrame();
    expect(view.currentText()).toContain("決定事項はこれ");
  });
});
