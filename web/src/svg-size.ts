// Sizing a mermaid-produced SVG (docs/design/40-diagram-zoom.md §3.4).
//
// mermaid emits `<svg width="100%" style="max-width: NNNpx" viewBox="0 0 W H">`. Those three pull in
// different directions, and getting the combination wrong broke the zoom overlay twice:
//
// 1. Trusting `getBoundingClientRect` as the natural size: `max-width` means the box reports the
//    *container's* width, so the fit scale always came out around 1 and the diagram opened as small
//    as it had been in the panel.
// 2. Overriding `width` to `auto` in CSS: that dropped the `width="100%"` attribute's effect and left
//    the SVG at a replaced element's default size, while `fit` still computed from `viewBox` — the
//    two disagreed and only the canvas background was visible.
//
// The fix is to make layout and measurement agree: pin the SVG to its `viewBox` extent, then scale
// with a transform.

export interface Size {
  width: number;
  height: number;
}

/** The diagram's size in its own coordinate space, `viewBox` first and the measured box as fallback. */
export function naturalSize(diagram: SVGElement, currentScale = 1): Size {
  const viewBox = (diagram as SVGSVGElement).viewBox?.baseVal;
  if (viewBox && viewBox.width > 0 && viewBox.height > 0) {
    return { width: viewBox.width, height: viewBox.height };
  }
  const box = diagram.getBoundingClientRect();
  // Undo the current scale, otherwise fitting twice in a row would compound.
  return { width: box.width / currentScale, height: box.height / currentScale };
}

/**
 * Fixes the element's layout size to `size`, undoing mermaid's own `width="100%"` / `max-width`.
 *
 * Once pinned, the SVG occupies exactly its `viewBox` extent: inside the panel that means a wide
 * diagram overflows and scrolls (DZ9) instead of being squeezed flat, and inside the overlay it means
 * the transform's scale is the only thing deciding how big the diagram appears.
 */
export function pinNaturalSize(svg: SVGElement, size: Size): void {
  svg.setAttribute("width", String(size.width));
  svg.setAttribute("height", String(size.height));
  // Inline, not a stylesheet rule: it has to beat mermaid's own inline `max-width`.
  svg.style.maxWidth = "none";
  svg.style.width = `${size.width}px`;
  svg.style.height = `${size.height}px`;
}
