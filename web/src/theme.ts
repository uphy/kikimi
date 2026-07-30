// CSS custom properties pushed down from Swift (docs/design/39-webview-markdown.md MD13 / §3.4).
//
// Colors are resolved on the AppKit side (`NSColor.labelColor` and friends under the panel's
// `effectiveAppearance`) rather than guessed here, so light/dark and the user's accent color follow
// the system without this layer knowing anything about appearance.

/** Key Swift sends alongside the colors; mirrored onto `data-appearance` for mermaid's benefit. */
const APPEARANCE_KEY = "--kikimi-appearance";

export function applyTheme(vars: Record<string, string>): void {
  const style = document.documentElement.style;
  for (const [name, value] of Object.entries(vars)) {
    // Only the documented namespace is settable: a typo'd key should do nothing rather than
    // silently redefine some unrelated custom property.
    if (!name.startsWith("--kikimi-")) continue;
    style.setProperty(name, value);
    if (name === APPEARANCE_KEY) {
      document.documentElement.dataset.appearance = value;
    }
  }
}

/**
 * Which mermaid theme matches the current appearance. Driven by what Swift resolved, not by
 * `prefers-color-scheme`: the panel's `effectiveAppearance` is the authority, and it is what every
 * other color here already follows.
 */
export function mermaidTheme(): "dark" | "default" {
  return document.documentElement.dataset.appearance === "dark" ? "dark" : "default";
}
