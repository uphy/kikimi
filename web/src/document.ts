// The Summary / Watchers view: one Markdown document, replaced wholesale on every update
// (docs/design/39-webview-markdown.md §3.5).

import { log, postToSwift } from "./bridge";
import { renderMermaidBlocks } from "./mermaid-loader";
import { renderMarkdown } from "./render";

export class DocumentView {
  private readonly root: HTMLElement;
  private currentDocKey: string | null = null;
  private generation = 0;

  constructor(root: HTMLElement) {
    this.root = root;
    this.root.classList.add("kikimi-document");
    this.installLinkInterception();
  }

  /**
   * MD8: `docKey` decides whether this is an update of the document already on screen (keep the
   * reader where they were) or a different document entirely (start at the top). Watchers switches
   * between sub-tabs through this same view, so position alone cannot tell the two apart.
   */
  setContent(markdown: string, docKey: string): void {
    const isSameDocument = this.currentDocKey === docKey;
    const previousScrollTop = isSameDocument ? this.scrollTop() : 0;

    this.root.innerHTML = renderMarkdown(markdown);
    this.currentDocKey = docKey;

    // Restoring synchronously would race the layout that the freshly inserted markup triggers.
    requestAnimationFrame(() => {
      this.setScrollTop(previousScrollTop);
      // Diagrams land after the text (§4). `rendered` is deliberately withheld until they do: it
      // is what a verifier waits on before taking a screenshot, and a half-drawn page is exactly
      // what that is meant to avoid.
      void renderMermaidBlocks(this.root)
        .catch((error: unknown) => log("warn", `mermaid pass failed: ${String(error)}`))
        .finally(() => {
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
