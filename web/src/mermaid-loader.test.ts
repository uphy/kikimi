import { beforeEach, describe, expect, it, vi } from "vitest";
import type { JsToSwiftMessage } from "./bridge";
import { MERMAID_BLOCK_CLASS } from "./render";

// docs/design/39-webview-markdown.md §8.2. The behaviour worth pinning here is the failure path
// (§4): a diagram that cannot be drawn must leave its source readable, because an LLM emitting
// broken mermaid should cost the reader a picture, not the content.

interface ScriptStub {
  element: HTMLScriptElement;
  succeed: (mermaid: unknown) => void;
  fail: () => void;
}

/**
 * jsdom never fetches `<script src>`, so the injected element's load/error callbacks are driven by
 * hand. Returns a handle to whatever `mermaid-loader` appends.
 */
function interceptScriptInjection(): { next: () => ScriptStub | undefined } {
  const injected: ScriptStub[] = [];
  const original = document.head.appendChild.bind(document.head);
  vi.spyOn(document.head, "appendChild").mockImplementation(((node: Node) => {
    if (node instanceof HTMLScriptElement) {
      injected.push({
        element: node,
        succeed: (mermaid) => {
          window.__kikimiMermaid = mermaid as never;
          node.dispatchEvent(new Event("load"));
        },
        fail: () => node.dispatchEvent(new Event("error"))
      });
      return node;
    }
    return original(node);
  }) as typeof document.head.appendChild);
  return { next: () => injected.shift() };
}

function makeRoot(sources: string[]): HTMLElement {
  document.body.innerHTML = "";
  const root = document.createElement("div");
  for (const source of sources) {
    const block = document.createElement("div");
    block.className = MERMAID_BLOCK_CLASS;
    block.dataset.src = source;
    root.appendChild(block);
  }
  document.body.appendChild(root);
  return root;
}

/** Fresh module state per test: the loader caches its load promise on purpose. */
async function importLoader() {
  vi.resetModules();
  return await import("./mermaid-loader");
}

describe("renderMermaidBlocks", () => {
  let messages: JsToSwiftMessage[];

  beforeEach(() => {
    vi.restoreAllMocks();
    delete window.__kikimiMermaid;
    messages = [];
    window.webkit = {
      messageHandlers: { kikimi: { postMessage: (message: JsToSwiftMessage) => messages.push(message) } }
    };
  });

  it("does not load the 3MB bundle when the document has no diagram (MD9)", async () => {
    const scripts = interceptScriptInjection();
    const { renderMermaidBlocks } = await importLoader();

    await renderMermaidBlocks(makeRoot([]));

    expect(scripts.next()).toBeUndefined();
  });

  it("loads the bundle once and draws each diagram", async () => {
    const scripts = interceptScriptInjection();
    const { renderMermaidBlocks } = await importLoader();
    const render = vi.fn(async (id: string) => ({ svg: `<svg id="${id}"></svg>` }));

    const root = makeRoot(["graph TD; A-->B;", "graph TD; C-->D;"]);
    const pending = renderMermaidBlocks(root);
    scripts.next()!.succeed({ initialize: vi.fn(), render });
    await pending;

    expect(render).toHaveBeenCalledTimes(2);
    // Scoped to direct children: each block also holds the zoom button's own icon SVG.
    expect(root.querySelectorAll(`.${MERMAID_BLOCK_CLASS} > svg`)).toHaveLength(2);
    // One injection for two diagrams, and none left over.
    expect(scripts.next()).toBeUndefined();
  });

  // design 40 §4.

  it("attaches a zoom button to a diagram that drew, carrying the source (DZ1/DZ4)", async () => {
    const scripts = interceptScriptInjection();
    const { renderMermaidBlocks } = await importLoader();
    const render = vi.fn(async (id: string) => ({ svg: `<svg id="${id}"></svg>` }));

    const root = makeRoot(["graph TD; A-->B;"]);
    const pending = renderMermaidBlocks(root);
    scripts.next()!.succeed({ initialize: vi.fn(), render });
    await pending;

    const button = root.querySelector<HTMLElement>(".kikimi-mermaid-zoom")!;
    expect(button.getAttribute("aria-label")).toBe("図を拡大");
    expect(button.title).toBe("図を拡大");
    expect(button.dataset.testid).toBe("mermaid-zoom");

    button.click();
    expect(messages).toContainEqual({ type: "zoomDiagram", source: "graph TD; A-->B;" });
  });

  it("leaves mermaid's own width alone in the body, so CSS can shrink it to the panel (DZ9)", async () => {
    const scripts = interceptScriptInjection();
    const { renderMermaidBlocks } = await importLoader();
    // What mermaid emits: a percentage width plus a max-width.
    const render = vi.fn(async (id: string) => ({
      svg: `<svg id="${id}" width="100%" style="max-width: 2400px" viewBox="0 0 2400 380"></svg>`
    }));

    const root = makeRoot(["graph TD; A-->B;"]);
    const pending = renderMermaidBlocks(root);
    scripts.next()!.succeed({ initialize: vi.fn(), render });
    await pending;

    const svg = root.querySelector("svg")!;
    // Pinning it to 2400px here is what pushed the diagram off the right edge of the panel.
    expect(svg.getAttribute("width")).toBe("100%");
    expect((svg as SVGElement).style.width).toBe("");
  });

  it("pins the SVG to its real extent when asked for natural sizing (the overlay)", async () => {
    const scripts = interceptScriptInjection();
    const { renderMermaidSource } = await importLoader();
    const render = vi.fn(async (id: string) => ({
      svg: `<svg id="${id}" width="100%" style="max-width: 2400px" viewBox="0 0 2400 380"></svg>`
    }));

    const container = document.createElement("div");
    document.body.appendChild(container);
    const pending = renderMermaidSource(container, "graph TD; A-->B;", "natural");
    scripts.next()!.succeed({ initialize: vi.fn(), render });
    await pending;

    const svg = container.querySelector("svg")!;
    // jsdom does not implement `viewBox.baseVal`, so the measured-box fallback is what runs here; the
    // point being pinned is that *something* concrete replaced the percentage width.
    expect(svg.getAttribute("width")).not.toBe("100%");
    expect((svg as SVGElement).style.maxWidth).toBe("none");
  });

  it("does not attach a zoom button to a diagram that failed (nothing to enlarge)", async () => {
    const scripts = interceptScriptInjection();
    const { renderMermaidBlocks } = await importLoader();

    const root = makeRoot(["graph TD; A-->;"]);
    const pending = renderMermaidBlocks(root);
    scripts.next()!.fail();
    await pending;

    expect(root.querySelector(".kikimi-mermaid-zoom")).toBeNull();
  });

  it("keeps the source visible when a diagram fails to parse (§4)", async () => {
    const scripts = interceptScriptInjection();
    const { renderMermaidBlocks } = await importLoader();
    const render = vi.fn(async () => {
      throw new Error("Parse error on line 2");
    });

    const root = makeRoot(["graph TD; A-->;"]);
    const pending = renderMermaidBlocks(root);
    scripts.next()!.succeed({ initialize: vi.fn(), render });
    await pending;

    const block = root.querySelector(`.${MERMAID_BLOCK_CLASS}`)!;
    expect(block.classList.contains("kikimi-mermaid-failed")).toBe(true);
    expect(block.textContent).toContain("graph TD; A-->;");
    expect(block.querySelector("svg")).toBeNull();
  });

  it("keeps every source visible when the bundle itself cannot load", async () => {
    const scripts = interceptScriptInjection();
    const { renderMermaidBlocks } = await importLoader();

    const root = makeRoot(["graph TD; A-->B;", "graph TD; C-->D;"]);
    const pending = renderMermaidBlocks(root);
    scripts.next()!.fail();
    await pending;

    const blocks = root.querySelectorAll(`.${MERMAID_BLOCK_CLASS}`);
    expect(blocks).toHaveLength(2);
    for (const block of blocks) {
      expect(block.classList.contains("kikimi-mermaid-failed")).toBe(true);
      expect(block.textContent).toContain("graph TD;");
    }
  });

  it("escapes nothing into HTML on the failure path (MD10)", async () => {
    const scripts = interceptScriptInjection();
    const { renderMermaidBlocks } = await importLoader();

    const root = makeRoot(['graph TD; A["<img src=x onerror=alert(1)>"];']);
    const pending = renderMermaidBlocks(root);
    scripts.next()!.fail();
    await pending;

    const block = root.querySelector(`.${MERMAID_BLOCK_CLASS}`)!;
    expect(block.querySelector("img")).toBeNull();
    expect(block.textContent).toContain("<img src=x onerror=alert(1)>");
  });
});
