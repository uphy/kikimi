import { beforeEach, describe, expect, it, vi } from "vitest";
import type { JsToSwiftMessage } from "./bridge";
import { DiagramView } from "./diagram";

// docs/design/40-diagram-zoom.md §4.

function installBridge(): JsToSwiftMessage[] {
  const messages: JsToSwiftMessage[] = [];
  window.webkit = {
    messageHandlers: { kikimi: { postMessage: (message: JsToSwiftMessage) => messages.push(message) } }
  };
  return messages;
}

function transformOf(root: HTMLElement): string {
  return root.querySelector<HTMLElement>(".kikimi-diagram-canvas")!.style.transform;
}

function scaleOf(root: HTMLElement): number {
  const match = /scale\(([\d.]+)\)/.exec(transformOf(root));
  return match ? Number(match[1]) : 1;
}

describe("DiagramView", () => {
  let root: HTMLElement;
  let messages: JsToSwiftMessage[];
  let view: DiagramView;

  beforeEach(() => {
    document.body.innerHTML = '<div id="root"></div>';
    root = document.getElementById("root")!;
    messages = installBridge();
    view = new DiagramView(root);
  });

  it("builds a stage and a canvas to transform", () => {
    expect(root.querySelector(".kikimi-diagram-stage")).not.toBeNull();
    expect(root.querySelector(".kikimi-diagram-canvas")).not.toBeNull();
  });

  it("closes when the click lands outside the diagram (DZ8)", () => {
    root.querySelector(".kikimi-diagram-stage")!.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    expect(messages).toContainEqual({ type: "closeDiagram" });
  });

  it("does not close when the diagram itself is clicked", () => {
    root.querySelector(".kikimi-diagram-canvas")!.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    expect(messages).not.toContainEqual({ type: "closeDiagram" });
  });

  it("closes on Escape and on ⌘W (DZ8)", () => {
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    expect(messages).toContainEqual({ type: "closeDiagram" });

    messages.length = 0;
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "w", metaKey: true, bubbles: true }));
    expect(messages).toContainEqual({ type: "closeDiagram" });
  });

  it("zooms in and out with ⌘+ / ⌘-", () => {
    const initial = scaleOf(root);
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "+", metaKey: true, bubbles: true }));
    const zoomedIn = scaleOf(root);
    expect(zoomedIn).toBeGreaterThan(initial);

    document.dispatchEvent(new KeyboardEvent("keydown", { key: "-", metaKey: true, bubbles: true }));
    expect(scaleOf(root)).toBeLessThan(zoomedIn);
  });

  it("clamps zoom so the diagram cannot become unnavigable", () => {
    for (let i = 0; i < 100; i++) {
      document.dispatchEvent(new KeyboardEvent("keydown", { key: "+", metaKey: true, bubbles: true }));
    }
    expect(scaleOf(root)).toBeLessThanOrEqual(8);

    for (let i = 0; i < 200; i++) {
      document.dispatchEvent(new KeyboardEvent("keydown", { key: "-", metaKey: true, bubbles: true }));
    }
    expect(scaleOf(root)).toBeGreaterThanOrEqual(0.2);
  });

  it("pans on drag", () => {
    const stage = root.querySelector(".kikimi-diagram-stage")!;
    stage.dispatchEvent(new MouseEvent("pointerdown", { bubbles: true, button: 0, clientX: 100, clientY: 100 }));
    stage.dispatchEvent(new MouseEvent("pointermove", { bubbles: true, clientX: 160, clientY: 130 }));

    expect(transformOf(root)).toContain("translate(60px, 30px)");

    stage.dispatchEvent(new MouseEvent("pointerup", { bubbles: true }));
  });

  it("ignores pointer movement that did not start with a press", () => {
    const stage = root.querySelector(".kikimi-diagram-stage")!;
    stage.dispatchEvent(new MouseEvent("pointermove", { bubbles: true, clientX: 300, clientY: 300 }));
    expect(transformOf(root)).not.toContain("translate(300px");
  });

  it("returns to the fitted state on double click (⌘0's equivalent)", () => {
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "+", metaKey: true, bubbles: true }));
    expect(scaleOf(root)).toBeGreaterThan(1);

    root.querySelector(".kikimi-diagram-stage")!.dispatchEvent(new MouseEvent("dblclick", { bubbles: true }));
    // jsdom reports zero-sized elements, so `fit` lands on its 1.0 fallback -- which is exactly the
    // "no diagram measured yet" branch worth pinning.
    expect(scaleOf(root)).toBe(1);
  });

  it("reports a render generation so a verifier can wait for the diagram (design 39 MD12)", async () => {
    // The mermaid bundle never loads under jsdom, so this exercises the failure path: the source is
    // shown as text and the generation is still reported.
    vi.spyOn(document.head, "appendChild").mockImplementation(((node: Node) => {
      if (node instanceof HTMLScriptElement) {
        queueMicrotask(() => node.dispatchEvent(new Event("error")));
        return node;
      }
      return node;
    }) as typeof document.head.appendChild);

    await view.setDiagram("graph TD; A-->B;");

    expect(messages.some((message) => message.type === "rendered")).toBe(true);
    expect(view.currentText()).toContain("graph TD; A-->B;");
  });
});
