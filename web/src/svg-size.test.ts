import { describe, expect, it } from "vitest";
import { naturalSize, pinNaturalSize } from "./svg-size";

// docs/design/40-diagram-zoom.md §3.4. Both of the overlay's sizing bugs came from this pair
// disagreeing, so both halves are pinned here.

describe("naturalSize", () => {
  it("prefers viewBox over the measured box", () => {
    // mermaid stamps a `max-width` onto its SVG, so the measured box reports the *container's* width.
    // Trusting it made `fit` compute a scale of ~1 and open the diagram as small as it was in the panel.
    const diagram = {
      viewBox: { baseVal: { width: 2400, height: 380 } },
      getBoundingClientRect: () => ({ width: 1400, height: 220 })
    } as unknown as SVGElement;

    expect(naturalSize(diagram)).toEqual({ width: 2400, height: 380 });
  });

  it("falls back to the measured box, undoing the current scale, when there is no viewBox", () => {
    const diagram = {
      viewBox: { baseVal: { width: 0, height: 0 } },
      getBoundingClientRect: () => ({ width: 600, height: 300 })
    } as unknown as SVGElement;

    expect(naturalSize(diagram, 2)).toEqual({ width: 300, height: 150 });
  });

  it("tolerates an element with no viewBox property at all", () => {
    const diagram = {
      getBoundingClientRect: () => ({ width: 100, height: 50 })
    } as unknown as SVGElement;

    expect(naturalSize(diagram)).toEqual({ width: 100, height: 50 });
  });
});

describe("pinNaturalSize", () => {
  function makeMermaidSvg(): SVGElement {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    // What mermaid actually emits.
    svg.setAttribute("width", "100%");
    svg.setAttribute("viewBox", "0 0 2400 380");
    svg.style.maxWidth = "2400px";
    return svg;
  }

  it("replaces mermaid's width=100% with the real extent", () => {
    const svg = makeMermaidSvg();
    pinNaturalSize(svg, { width: 2400, height: 380 });

    expect(svg.getAttribute("width")).toBe("2400");
    expect(svg.getAttribute("height")).toBe("380");
    expect(svg.style.width).toBe("2400px");
    expect(svg.style.height).toBe("380px");
  });

  it("clears the max-width that keeps the diagram at the container's width", () => {
    const svg = makeMermaidSvg();
    pinNaturalSize(svg, { width: 2400, height: 380 });

    // Left in place, a wide diagram is squeezed to the panel's width in the body and cannot be
    // scaled past it in the overlay.
    expect(svg.style.maxWidth).toBe("none");
  });

  it("never leaves the size as auto (the collapse that showed only the canvas background)", () => {
    const svg = makeMermaidSvg();
    pinNaturalSize(svg, { width: 300, height: 150 });

    expect(svg.style.width).not.toBe("auto");
    expect(svg.style.height).not.toBe("auto");
  });
});
