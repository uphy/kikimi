// Draws ```mermaid fences (docs/design/39-webview-markdown.md §4) and, in the body, attaches the
// zoom button that opens them full-screen (docs/design/40-diagram-zoom.md §3.2).
//
// Split from `render.ts` because everything here is asynchronous and DOM-bound: the markup is
// produced synchronously with a placeholder, and diagrams fill in afterwards.

import { log, postToSwift } from "./bridge";
import { MERMAID_BLOCK_CLASS } from "./render";
import { naturalSize, pinNaturalSize } from "./svg-size";
import { mermaidTheme } from "./theme";

const BUNDLE_SRC = "mermaid.bundle.js";

let loadPromise: Promise<boolean> | null = null;
let renderCount = 0;

/**
 * Injects the mermaid bundle once, resolving to whether it is usable. Failure is reported but not
 * thrown: a missing diagram must not take the surrounding text down with it (design 39 §7).
 */
function loadBundle(): Promise<boolean> {
  if (loadPromise) return loadPromise;

  loadPromise = new Promise<boolean>((resolve) => {
    const script = document.createElement("script");
    script.src = BUNDLE_SRC;
    script.onload = () => resolve(window.__kikimiMermaid !== undefined);
    script.onerror = () => {
      log("error", `failed to load ${BUNDLE_SRC}`);
      resolve(false);
    };
    document.head.appendChild(script);
  });

  return loadPromise;
}

/**
 * How the drawn SVG is sized (design 40 DZ9).
 *
 * - `"fit"` — leave mermaid's own `width="100%"`, so CSS shrinks a wide diagram to the container.
 *   What the body wants: the whole diagram visible at a glance, with the zoom button for reading it.
 * - `"natural"` — pin the SVG to its `viewBox` extent, so the transform's scale alone decides how
 *   big it appears. What the overlay needs.
 */
export type MermaidSizing = "fit" | "natural";

/**
 * Draws one diagram into `container`, replacing its contents. Resolves to whether it drew — a
 * `false` means `container` now holds the source as text instead (design 39 §4).
 *
 * Shared by the body renderer and the zoom overlay (design 40 DZ10) so the failure presentation is
 * identical in both.
 */
export async function renderMermaidSource(
  container: HTMLElement,
  source: string,
  sizing: MermaidSizing = "fit"
): Promise<boolean> {
  const loaded = await loadBundle();
  const mermaid = window.__kikimiMermaid;
  if (!loaded || !mermaid) {
    showSource(container, source, "図の描画エンジンを読み込めませんでした");
    return false;
  }

  mermaid.initialize({
    startOnLoad: false,
    // design 39 MD10: no HTML labels, no click handlers. The diagram source comes from an LLM.
    securityLevel: "strict",
    theme: mermaidTheme()
  });

  renderCount += 1;
  try {
    const { svg } = await mermaid.render(`kikimi-mermaid-${renderCount}`, source);
    // The only place `innerHTML` is used on generated content besides markdown-it's own output;
    // mermaid's `strict` level is what makes that safe.
    container.innerHTML = svg;
    if (sizing === "natural") {
      // Overlay only. In the body, mermaid's `width="100%"` plus the stylesheet's `max-width: 100%`
      // is exactly the wanted behaviour -- the diagram shrinks to the panel and stays whole.
      const drawn = container.querySelector("svg");
      if (drawn) pinNaturalSize(drawn, naturalSize(drawn));
    }
    return true;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    log("warn", `mermaid render failed: ${message}`);
    showSource(container, source, "図を描画できませんでした");
    return false;
  }
}

/**
 * Renders every mermaid placeholder inside `root`. Does nothing — including not loading the
 * bundle — when there is no diagram, which is the common case (design 39 MD9).
 */
export async function renderMermaidBlocks(root: HTMLElement): Promise<void> {
  const blocks = Array.from(root.querySelectorAll<HTMLElement>(`.${MERMAID_BLOCK_CLASS}`));
  if (blocks.length === 0) return;

  for (const block of blocks) {
    const source = block.dataset.src ?? "";
    const drawn = await renderMermaidSource(block, source);
    block.classList.toggle("kikimi-mermaid-rendered", drawn);
    // design 40 DZ1: only a diagram that actually drew gets a zoom button. Enlarging a failed one
    // would just show the same failure on a bigger screen.
    if (drawn) attachZoomButton(block, source);
  }
}

/**
 * design 40 §3.2. `aria-label` and `title` carry the same wording, which is the AX contract the rest
 * of Kikimi's controls keep; `data-testid` is what `__kikimiClick` drives.
 */
function attachZoomButton(block: HTMLElement, source: string): void {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "kikimi-mermaid-zoom";
  button.dataset.testid = "mermaid-zoom";
  button.setAttribute("aria-label", "図を拡大");
  button.title = "図を拡大";
  button.innerHTML = zoomIcon();
  button.addEventListener("click", (event) => {
    // The click must not also reach the chat view's delegated handler, which would read it as a
    // click on the bubble.
    event.stopPropagation();
    postToSwift({ type: "zoomDiagram", source });
  });
  block.appendChild(button);
}

/**
 * design 39 §4's fallback: keep the source visible. An LLM that emits broken mermaid should cost the
 * reader a diagram, not the content — the code is still readable as text.
 */
function showSource(block: HTMLElement, source: string, reason: string): void {
  const notice = document.createElement("div");
  notice.className = "kikimi-mermaid-error";
  notice.textContent = reason;

  const pre = document.createElement("pre");
  const code = document.createElement("code");
  // textContent, never innerHTML (design 39 MD10): this string never went through markdown-it.
  code.textContent = source;
  pre.appendChild(code);

  block.classList.add("kikimi-mermaid-failed");
  block.replaceChildren(notice, pre);
}

/** `arrow.up.left.and.arrow.down.right`'s shape, as inline SVG. */
function zoomIcon(): string {
  return `<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M6.5 2.5H2.5v4M9.5 13.5h4v-4" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/><path d="M2.8 2.8l4.4 4.4M13.2 13.2L8.8 8.8" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>`;
}
