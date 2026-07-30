// The zoom overlay: one diagram, filling a whole screen (docs/design/40-diagram-zoom.md §3.4).
//
// Runs in its own web view, in its own window. Everything here is about *looking* at a diagram that
// does not fit a floating panel — pan, zoom, fit — so none of the document/chat machinery applies.

import { log, postToSwift } from "./bridge";
import { renderMermaidSource } from "./mermaid-loader";
import { naturalSize } from "./svg-size";

/** Past these the diagram is either unreadable or unnavigable (DZ: §3.4). */
const MIN_SCALE = 0.2;
const MAX_SCALE = 8;
const WHEEL_ZOOM_SENSITIVITY = 0.0015;
const BUTTON_ZOOM_STEP = 1.25;
/** Breathing room between the fitted diagram and the screen edge. */
const FIT_PADDING_PX = 24;

export class DiagramView {
  private readonly root: HTMLElement;
  private readonly stage: HTMLElement;
  private readonly canvas: HTMLElement;
  private scale = 1;
  private translateX = 0;
  private translateY = 0;
  private dragOrigin: { x: number; y: number; translateX: number; translateY: number } | null = null;
  private generation = 0;

  constructor(root: HTMLElement) {
    this.root = root;
    this.root.classList.add("kikimi-diagram-overlay");

    this.stage = document.createElement("div");
    this.stage.className = "kikimi-diagram-stage";
    this.canvas = document.createElement("div");
    this.canvas.className = "kikimi-diagram-canvas";
    this.stage.appendChild(this.canvas);
    this.root.replaceChildren(this.stage);

    this.installPan();
    this.installZoom();
    this.installDismiss();
  }

  async setDiagram(source: string): Promise<void> {
    // Reuses the body renderer's failure handling (DZ10): a diagram that cannot be drawn shows its
    // source rather than an empty screen.
    // "natural": the overlay scales with a transform, so the SVG must occupy its real extent
    // (design 40 §3.4). The body uses the default "fit".
    await renderMermaidSource(this.canvas, source, "natural");
    this.fit();
    this.generation += 1;
    postToSwift({ type: "rendered", generation: this.generation });
  }

  currentText(): string {
    const innerText = (this.root as { innerText?: string }).innerText;
    return innerText ?? this.root.textContent ?? "";
  }

  // MARK: Transform

  /** The initial state, and what a double click returns to: the whole diagram, as large as it fits. */
  fit(): void {
    const diagram = this.canvas.querySelector("svg");
    const available = this.stage.getBoundingClientRect();
    if (!diagram || available.width === 0 || available.height === 0) {
      this.applyTransform(1, 0, 0);
      return;
    }

    const natural = naturalSize(diagram, this.scale);
    if (natural.width === 0 || natural.height === 0) {
      this.applyTransform(1, 0, 0);
      return;
    }

    // Scaled up as well as down. The overlay exists precisely because the diagram was too small to
    // read in the panel, so capping the initial scale at 1 defeats the point -- a wide flowchart
    // would open occupying a sixth of the screen's height, which is what it looked like in the
    // panel. `PADDING` keeps the edges off the screen border.
    const scale = Math.min(
      (available.width - FIT_PADDING_PX * 2) / natural.width,
      (available.height - FIT_PADDING_PX * 2) / natural.height
    );
    this.applyTransform(clamp(scale, MIN_SCALE, MAX_SCALE), 0, 0);
  }

  private zoom(factor: number, anchor?: { x: number; y: number }): void {
    const next = clamp(this.scale * factor, MIN_SCALE, MAX_SCALE);
    if (next === this.scale) return;

    if (anchor) {
      // Keep the point under the cursor fixed: without this, zooming walks the diagram off screen.
      const rect = this.stage.getBoundingClientRect();
      const offsetX = anchor.x - rect.width / 2 - this.translateX;
      const offsetY = anchor.y - rect.height / 2 - this.translateY;
      const ratio = next / this.scale - 1;
      this.applyTransform(next, this.translateX - offsetX * ratio, this.translateY - offsetY * ratio);
      return;
    }

    this.applyTransform(next, this.translateX, this.translateY);
  }

  private applyTransform(scale: number, translateX: number, translateY: number): void {
    this.scale = scale;
    this.translateX = translateX;
    this.translateY = translateY;
    this.canvas.style.transform = `translate(${translateX}px, ${translateY}px) scale(${scale})`;
  }

  // MARK: Interaction

  private installPan(): void {
    this.stage.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      this.dragOrigin = {
        x: event.clientX,
        y: event.clientY,
        translateX: this.translateX,
        translateY: this.translateY
      };
      this.root.classList.add("kikimi-diagram-dragging");
    });

    this.stage.addEventListener("pointermove", (event) => {
      if (!this.dragOrigin) return;
      this.applyTransform(
        this.scale,
        this.dragOrigin.translateX + (event.clientX - this.dragOrigin.x),
        this.dragOrigin.translateY + (event.clientY - this.dragOrigin.y)
      );
    });

    const endDrag = () => {
      this.dragOrigin = null;
      this.root.classList.remove("kikimi-diagram-dragging");
    };
    this.stage.addEventListener("pointerup", endDrag);
    this.stage.addEventListener("pointercancel", endDrag);

    this.stage.addEventListener("dblclick", () => this.fit());
  }

  private installZoom(): void {
    this.stage.addEventListener(
      "wheel",
      (event) => {
        // A trackpad pinch arrives as a ctrl-modified wheel event; a plain wheel is also treated as
        // zoom here because there is nothing else to scroll in this window.
        event.preventDefault();
        const rect = this.stage.getBoundingClientRect();
        this.zoom(Math.exp(-event.deltaY * WHEEL_ZOOM_SENSITIVITY), {
          x: event.clientX - rect.left,
          y: event.clientY - rect.top
        });
      },
      { passive: false }
    );

    document.addEventListener("keydown", (event) => {
      // DZ8: Escape and ⌘W are handled here rather than on the panel. The web view holds key focus
      // while the overlay is up, so AppKit's `cancelOperation(_:)` would never see them.
      if (event.key === "Escape" || (event.metaKey && event.key === "w")) {
        event.preventDefault();
        postToSwift({ type: "closeDiagram" });
        return;
      }
      if (!event.metaKey) return;
      if (event.key === "+" || event.key === "=") {
        event.preventDefault();
        this.zoom(BUTTON_ZOOM_STEP);
      } else if (event.key === "-") {
        event.preventDefault();
        this.zoom(1 / BUTTON_ZOOM_STEP);
      } else if (event.key === "0") {
        event.preventDefault();
        this.fit();
      }
    });
  }

  /** DZ8: clicking outside the diagram closes the overlay; clicking the diagram itself does not. */
  private installDismiss(): void {
    this.root.addEventListener("click", (event) => {
      if (this.dragOrigin) return;
      const target = event.target;
      if (target instanceof Element && target.closest(".kikimi-diagram-canvas")) return;
      postToSwift({ type: "closeDiagram" });
    });

    window.addEventListener("resize", () => this.fit());

    window.addEventListener("error", (event) => log("error", `diagram overlay error: ${event.message}`));
  }
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(Math.max(value, minimum), maximum);
}
