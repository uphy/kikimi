// Hooks for kikimi-verify (docs/design/39-webview-markdown.md MD12 / §8.3).
//
// These are always present in the page; what gates them is the Swift side, which only calls them
// when a `KIKIMI_TEST_*` environment variable is set. A page function nobody can reach is inert,
// and keeping them unconditional means the build that gets verified is the build that ships.

export function installTestingHooks(readText: () => string): void {
  window.__kikimiDumpText = readText;

  window.__kikimiClick = (testId: string): boolean => {
    // Attribute walk, not an interpolated selector: ids contain turn ids, and escaping them would
    // depend on `CSS.escape`.
    const element = Array.from(document.querySelectorAll<HTMLElement>("[data-testid]")).find(
      (candidate) => candidate.dataset.testid === testId
    );
    if (!element) return false;
    element.click();
    return true;
  };
}
