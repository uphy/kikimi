// The chat view: the whole history in one web view (docs/design/39-webview-markdown.md §3.6 / MD4).
//
// One web view for the entire conversation, not one per bubble — ten exchanges would otherwise mean
// ten WKWebViews whose heights all have to be measured and fed back to a SwiftUI list. The cost of
// that choice is that the bubbles, their buttons, and the auto-follow behaviour all live here
// instead of in SwiftUI.

import { log, postToSwift, type ChatTurnView } from "./bridge";
import { renderMermaidBlocks } from "./mermaid-loader";
import { renderMarkdown } from "./render";

/** Mirrors `TranscriptAutoFollow.pinThreshold`'s intent: near enough to the bottom counts as pinned. */
const BOTTOM_THRESHOLD_PX = 24;

export class ChatView {
  private readonly root: HTMLElement;
  private turns: ChatTurnView[] = [];
  private isResponding = false;
  private respondingSince: number | null = null;
  private copyFeedbackTurnId: string | null = null;
  private isPinnedToBottom = true;
  private elapsedTimer: ReturnType<typeof setInterval> | null = null;
  private generation = 0;

  constructor(root: HTMLElement) {
    this.root = root;
    this.root.classList.add("kikimi-chat");
    this.installDelegatedHandlers();
    this.installScrollTracking();
  }

  setTurns(turns: ChatTurnView[]): void {
    this.turns = turns;
    this.render();
  }

  /** MD16: the seam streaming will arrive through. Rewrites one bubble's body in place. */
  updateTurn(id: string, text: string): void {
    const index = this.turns.findIndex((turn) => turn.id === id);
    if (index < 0) return;
    this.turns[index] = { ...this.turns[index], text };
    // Matched by walking the attribute rather than interpolating the id into a selector: turn ids
    // come from `EntryIdNaming.makeId`, and a selector would need escaping that jsdom's `CSS` shim
    // does not provide.
    const body = Array.from(this.root.querySelectorAll<HTMLElement>("[data-turn-body]")).find(
      (element) => element.dataset.turnBody === id
    );
    if (body) {
      body.innerHTML = renderMarkdown(text);
      void renderMermaidBlocks(body);
      this.followIfPinned();
      return;
    }
    this.render();
  }

  setResponding(responding: boolean, since: number | null): void {
    this.isResponding = responding;
    this.respondingSince = since;
    this.render();
  }

  setCopyFeedback(turnId: string | null): void {
    this.copyFeedbackTurnId = turnId;
    // Only the icons change, so the history is left alone: re-rendering would drop a text selection
    // the user made in an answer they were about to read.
    for (const button of this.root.querySelectorAll<HTMLElement>("[data-copy-turn]")) {
      const isFedBack = button.dataset.copyTurn === turnId;
      button.classList.toggle("kikimi-chat-copied", isFedBack);
      button.innerHTML = isFedBack ? checkmarkIcon() : copyIcon();
    }
  }

  currentText(): string {
    const innerText = (this.root as { innerText?: string }).innerText;
    return innerText ?? this.root.textContent ?? "";
  }

  // MARK: Rendering

  private render(): void {
    const fragment = document.createDocumentFragment();

    if (this.turns.length === 0 && !this.isResponding) {
      fragment.appendChild(this.buildPlaceholder());
    } else {
      for (const turn of this.turns) fragment.appendChild(this.buildBubble(turn));
      if (this.isResponding) fragment.appendChild(this.buildPendingRow());
    }

    this.root.replaceChildren(fragment);
    this.restartElapsedTimer();

    requestAnimationFrame(() => {
      void renderMermaidBlocks(this.root)
        .catch((error: unknown) => log("warn", `mermaid pass failed: ${String(error)}`))
        .finally(() => {
          this.followIfPinned();
          this.generation += 1;
          postToSwift({ type: "rendered", generation: this.generation });
        });
    });
  }

  private buildBubble(turn: ChatTurnView): HTMLElement {
    const bubble = document.createElement("div");
    bubble.className = turn.role === "user" ? "kikimi-chat-user" : "kikimi-chat-assistant";
    bubble.dataset.turnId = turn.id;

    if (turn.role === "user") {
      // MD4: never through markdown-it. "#確認 これでOK?" is a question, not a heading.
      const body = document.createElement("div");
      body.className = "kikimi-chat-body";
      body.textContent = turn.text;
      bubble.appendChild(body);
      return bubble;
    }

    // design 38 §4.5: per answer, not per session, so an old thin answer still explains itself.
    if (turn.contextScope === "summaryAndRecent") {
      bubble.appendChild(this.buildDemotionLabel());
    }

    if (turn.error !== undefined) {
      bubble.appendChild(this.buildFailureRow(turn));
      return bubble;
    }

    const body = document.createElement("div");
    body.className = "kikimi-chat-body";
    body.dataset.turnBody = turn.id;
    body.innerHTML = renderMarkdown(turn.text);
    bubble.appendChild(body);
    bubble.appendChild(this.buildAnswerFooter(turn));
    return bubble;
  }

  private buildDemotionLabel(): HTMLElement {
    const label = document.createElement("div");
    label.className = "kikimi-chat-note";
    label.innerHTML = infoIcon();
    const text = document.createElement("span");
    text.textContent = "会議が長いため、サマリと直近の会話をもとに回答しています";
    label.appendChild(text);
    return label;
  }

  private buildFailureRow(turn: ChatTurnView): HTMLElement {
    const row = document.createElement("div");
    row.className = "kikimi-chat-failure";

    const message = document.createElement("span");
    // textContent, not markdown: the reason is an error string, never LLM Markdown (MD10).
    message.textContent = `回答を取得できませんでした: ${turn.error ?? ""}`;
    row.appendChild(message);

    const retry = document.createElement("button");
    retry.type = "button";
    retry.className = "kikimi-chat-retry";
    retry.dataset.retryTurn = turn.id;
    // The AX contract `ChatTabView` kept via matching `.help`/`.accessibilityLabel` (§3.6), and the
    // hook kikimi-verify drives it through (MD12).
    retry.dataset.testid = `chat-retry-${turn.id}`;
    retry.setAttribute("aria-label", "回答を再送");
    retry.title = "回答を再送";
    retry.textContent = "再送";
    row.appendChild(retry);

    return row;
  }

  private buildAnswerFooter(turn: ChatTurnView): HTMLElement {
    const footer = document.createElement("div");
    footer.className = "kikimi-chat-footer";

    const copy = document.createElement("button");
    copy.type = "button";
    copy.className = "kikimi-chat-icon-button";
    copy.dataset.copyTurn = turn.id;
    copy.dataset.testid = `chat-copy-${turn.id}`;
    copy.setAttribute("aria-label", "回答をコピー");
    copy.title = "回答をコピー";
    // The checkmark is driven by `setCopyFeedback`, i.e. by whether the pasteboard write actually
    // succeeded — design 37 §6 / §7's test item (f).
    copy.innerHTML = this.copyFeedbackTurnId === turn.id ? checkmarkIcon() : copyIcon();
    footer.appendChild(copy);

    const time = document.createElement("span");
    time.className = "kikimi-chat-time";
    time.textContent = formatTime(turn.createdAt);
    footer.appendChild(time);

    return footer;
  }

  private buildPendingRow(): HTMLElement {
    const row = document.createElement("div");
    row.className = "kikimi-chat-pending";

    const spinner = document.createElement("span");
    spinner.className = "kikimi-chat-spinner";
    row.appendChild(spinner);

    const label = document.createElement("span");
    label.dataset.pendingLabel = "1";
    label.textContent = this.pendingLabelText();
    row.appendChild(label);

    return row;
  }

  private pendingLabelText(): string {
    if (this.respondingSince === null) return "回答を作成中…";
    const elapsed = Math.max(0, Math.floor(Date.now() / 1000 - this.respondingSince));
    return `回答を作成中… ${elapsed}秒`;
  }

  /** The SwiftUI version used a `TimelineView`; here the seconds tick from one interval. */
  private restartElapsedTimer(): void {
    if (this.elapsedTimer !== null) {
      clearInterval(this.elapsedTimer);
      this.elapsedTimer = null;
    }
    if (!this.isResponding || this.respondingSince === null) return;
    this.elapsedTimer = setInterval(() => {
      const label = this.root.querySelector("[data-pending-label]");
      if (label instanceof HTMLElement) label.textContent = this.pendingLabelText();
    }, 1000);
  }

  private buildPlaceholder(): HTMLElement {
    const placeholder = document.createElement("div");
    placeholder.className = "kikimi-chat-placeholder";
    placeholder.textContent = "この会議について質問できます（例: ここまでの決定事項は？）";
    return placeholder;
  }

  // MARK: Interaction

  private installDelegatedHandlers(): void {
    // Delegated, so buttons rebuilt by `render()` stay live without re-binding.
    this.root.addEventListener("click", (event) => {
      const target = event.target;
      if (!(target instanceof Element)) return;

      const copy = target.closest<HTMLElement>("[data-copy-turn]");
      if (copy?.dataset.copyTurn) {
        postToSwift({ type: "copyTurn", id: copy.dataset.copyTurn });
        return;
      }

      const retry = target.closest<HTMLElement>("[data-retry-turn]");
      if (retry?.dataset.retryTurn) {
        postToSwift({ type: "retryTurn", id: retry.dataset.retryTurn });
        return;
      }

      // Links inside an answer follow the same rule as everywhere else (MD6).
      const anchor = target.closest("a");
      if (anchor) {
        event.preventDefault();
        const href = anchor.getAttribute("href");
        if (href) postToSwift({ type: "openLink", url: href });
      }
    });
  }

  /**
   * Same contract as `TranscriptAutoFollow` (`Kikimi/Views/MeetingWorkspace/TranscriptAutoFollow.swift`):
   * follow new content only while the reader is already at the bottom, so scrolling back to re-read
   * an earlier answer is not yanked away when the next one lands. The Swift version stays for the
   * transcript tab; the two cannot share code because the scrolling machinery is different.
   */
  private installScrollTracking(): void {
    document.addEventListener(
      "scroll",
      () => {
        this.isPinnedToBottom = this.distanceFromBottom() <= BOTTOM_THRESHOLD_PX;
      },
      { passive: true }
    );
  }

  private distanceFromBottom(): number {
    const element = document.scrollingElement ?? document.documentElement;
    return element.scrollHeight - element.scrollTop - element.clientHeight;
  }

  private followIfPinned(): void {
    if (!this.isPinnedToBottom) return;
    const element = document.scrollingElement ?? document.documentElement;
    element.scrollTop = element.scrollHeight;
  }
}

// MARK: - Formatting

function formatTime(epochSeconds: number): string {
  const date = new Date(epochSeconds * 1000);
  const hours = String(date.getHours()).padStart(2, "0");
  const minutes = String(date.getMinutes()).padStart(2, "0");
  return `${hours}:${minutes}`;
}

// MARK: - Icons
//
// SF Symbols are not available in a web view, so the three glyphs the SwiftUI version used
// (`doc.on.doc`, `checkmark`, `info.circle`) are inline SVG. `currentColor` keeps them on the
// Swift-injected palette.

function copyIcon(): string {
  return `<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="5.5" y="2.5" width="8" height="10" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M10.5 13.5v.5a1.5 1.5 0 0 1-1.5 1.5H4a1.5 1.5 0 0 1-1.5-1.5V5.5A1.5 1.5 0 0 1 4 4h.5" fill="none" stroke="currentColor" stroke-width="1.3"/></svg>`;
}

function checkmarkIcon(): string {
  return `<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3 8.5l3.5 3.5L13 4.5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
}

function infoIcon(): string {
  return `<svg viewBox="0 0 16 16" aria-hidden="true" class="kikimi-chat-note-icon"><circle cx="8" cy="8" r="6.2" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M8 7v4.2" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/><circle cx="8" cy="4.9" r="0.8" fill="currentColor"/></svg>`;
}
