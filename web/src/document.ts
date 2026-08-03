// The Summary / Watchers view: one Markdown document, replaced wholesale on every update
// (docs/design/39-webview-markdown.md §3.5).

import { log, postToSwift } from "./bridge";
import { renderMermaidBlocks } from "./mermaid-loader";
import { renderMarkdown } from "./render";

/**
 * How close to the bottom still counts as "at the bottom". Same value as `chat.ts`, deliberately:
 * the two surfaces should feel identical when new content arrives.
 */
const BOTTOM_THRESHOLD_PX = 24;

export class DocumentView {
  private readonly root: HTMLElement;
  private currentDocKey: string | null = null;
  private generation = 0;
  /** Same contract as `chat.ts`: start pinned, unpin as soon as the reader scrolls away. */
  private isPinnedToBottom = true;

  constructor(root: HTMLElement) {
    this.root = root;
    this.root.classList.add("kikimi-document");
    this.installLinkInterception();
    this.installScrollTracking();
  }

  /**
   * MD8: `docKey` decides whether this is an update of the document already on screen (keep the
   * reader where they were) or a different document entirely (start at the top). Watchers switches
   * between sub-tabs through this same view, so position alone cannot tell the two apart.
   *
   * `followBottom` (`docs/design/47-summary-split-pane.md` §5.2) turns the Summary tab's 議事詳細
   * pane into a log that follows its own tail: 議事詳細 grows by appending, so a reader sitting at
   * the bottom wants the newest entry, while one who scrolled up to re-read something does not want
   * to be yanked away. Every other surface passes `false` and behaves exactly as it did before.
   */
  setContent(markdown: string, docKey: string, followBottom = false): void {
    const isSameDocument = this.currentDocKey === docKey;
    const previousScrollTop = isSameDocument ? this.scrollTop() : 0;
    // A different document carries no meaningful pin state: start pinned again, matching the
    // "start at the top" reset above rather than inheriting where the reader sat in the old one.
    if (!isSameDocument) this.isPinnedToBottom = true;
    const shouldFollow = followBottom && this.isPinnedToBottom;

    this.root.innerHTML = renderMarkdown(markdown);
    this.currentDocKey = docKey;

    // Restoring synchronously would race the layout that the freshly inserted markup triggers.
    requestAnimationFrame(() => {
      if (shouldFollow) {
        this.scrollToBottom();
      } else {
        this.setScrollTop(previousScrollTop);
      }
      // Diagrams land after the text (§4). `rendered` is deliberately withheld until they do: it
      // is what a verifier waits on before taking a screenshot, and a half-drawn page is exactly
      // what that is meant to avoid.
      void renderMermaidBlocks(this.root)
        .catch((error: unknown) => log("warn", `mermaid pass failed: ${String(error)}`))
        .finally(() => {
          // Mermaid changes the page height after the fact, so the scroll done above landed against
          // a shorter document. Without this the pane stops short of the newest entry whenever the
          // 議事詳細 contains a diagram (`chat.ts` follows in its own `finally` for the same reason).
          if (shouldFollow) this.scrollToBottom();
          this.generation += 1;
          postToSwift({ type: "rendered", generation: this.generation });
        });
    });
  }

  currentText(): string {
    // `innerText` reflects what is actually laid out (collapsed whitespace, line breaks between
    // blocks), which is what a verifier wants to assert on. jsdom does not implement it, hence the
    // `textContent` fallback -- it only ever applies under test.
    const innerText = (this.root as { innerText?: string }).innerText;
    return innerText ?? this.root.textContent ?? "";
  }

  /** `scrollingElement` is null in quirks mode and absent in some test environments. */
  private scrollElement(): Element {
    return document.scrollingElement ?? document.documentElement;
  }

  private scrollTop(): number {
    return this.scrollElement().scrollTop;
  }

  private setScrollTop(value: number): void {
    this.scrollElement().scrollTop = value;
  }

  private scrollToBottom(): void {
    const element = this.scrollElement();
    element.scrollTop = element.scrollHeight;
  }

  /**
   * Keeps `isPinnedToBottom` current. Passive because this never calls `preventDefault` and the
   * listener runs on every scroll frame.
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
    const element = this.scrollElement();
    return element.scrollHeight - element.scrollTop - element.clientHeight;
  }

  /**
   * MD6: the page never navigates. Every click on a link is reported to Swift, which decides
   * whether it is a `kikimi-seg:` jump, an external URL, or nothing at all
   * (`MarkdownLinkRouter`). `decidePolicyFor` on the Swift side is the second line of defense.
   */
  private installLinkInterception(): void {
    this.root.addEventListener("click", (event) => {
      const target = event.target;
      if (!(target instanceof Element)) return;
      const anchor = target.closest("a");
      if (!anchor) return;
      event.preventDefault();
      const href = anchor.getAttribute("href");
      if (!href) {
        log("debug", "link click with no href");
        return;
      }
      postToSwift({ type: "openLink", url: href });
    });
  }
}
