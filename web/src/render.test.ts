import { describe, expect, it } from "vitest";
import { MERMAID_BLOCK_CLASS, renderMarkdown } from "./render";

// docs/design/39-webview-markdown.md §8.2.

describe("renderMarkdown", () => {
  it("renders the GFM table the summary's action items depend on (design 04 §5.1)", () => {
    const html = renderMarkdown(["| 担当 | 期限 |", "|---|---|", "| 山田 | 8/1 |"].join("\n"));
    expect(html).toContain("<table>");
    expect(html).toContain("<th>担当</th>");
    expect(html).toContain("<td>山田</td>");
  });

  it("renders task list checkboxes", () => {
    const html = renderMarkdown("- [ ] 未対応\n- [x] 対応済み");
    expect(html).toContain('type="checkbox"');
    expect(html).toContain("checked");
  });

  it("renders footnotes", () => {
    const html = renderMarkdown("本文[^1]\n\n[^1]: 注記");
    expect(html).toContain("footnote");
    expect(html).toContain("注記");
  });

  it("highlights a fenced code block with a known language", () => {
    const html = renderMarkdown("```swift\nlet a = 1\n```");
    expect(html).toContain("hljs");
    expect(html).toContain("<code>");
  });

  it("keeps a fenced code block readable when the language is unknown", () => {
    const html = renderMarkdown("```notalanguage\nplain text\n```");
    expect(html).toContain("plain text");
  });
});

describe("mermaid fences (MD9)", () => {
  it("turns a mermaid fence into a placeholder carrying its source", () => {
    const html = renderMarkdown("```mermaid\ngraph TD;\n  A-->B;\n```");
    expect(html).toContain(`class="${MERMAID_BLOCK_CLASS}"`);
    expect(html).toContain("data-src=");
    expect(html).toContain("graph TD;");
    // The source must not also be emitted as a code block: it would show up twice, once as text
    // and once as the drawn diagram.
    expect(html).not.toContain("<pre");
  });

  it("leaves other fences alone", () => {
    const html = renderMarkdown("```ts\nconst a = 1;\n```");
    expect(html).not.toContain(MERMAID_BLOCK_CLASS);
    expect(html).toContain("<pre");
  });

  it("escapes the source it stores in the attribute", () => {
    const html = renderMarkdown('```mermaid\ngraph TD; A["<b>x</b>"];\n```');
    expect(html).not.toContain("<b>x</b>");
    expect(html).toContain("&lt;b&gt;");
  });
});

describe("security (MD10)", () => {
  it("escapes raw HTML instead of passing it through", () => {
    const html = renderMarkdown("<script>alert(1)</script>");
    expect(html).not.toContain("<script>");
    expect(html).toContain("&lt;script&gt;");
  });

  it("escapes an img tag carrying an event handler", () => {
    const html = renderMarkdown('<img src="x" onerror="alert(1)">');
    expect(html).not.toContain("<img");
    expect(html).toContain("&lt;img");
  });

  it("does not linkify bare URLs (nothing should become clickable that the author did not write)", () => {
    const html = renderMarkdown("見てください https://example.com/a");
    expect(html).not.toContain("<a ");
  });
});

describe("seg links (design 05 §8.1)", () => {
  it("renders a kikimi-seg: link as an anchor the page can intercept", () => {
    const html = renderMarkdown("根拠: [seg_00042](kikimi-seg:seg_00042)");
    expect(html).toContain('href="kikimi-seg:seg_00042"');
    expect(html).toContain(">seg_00042<");
  });
});
