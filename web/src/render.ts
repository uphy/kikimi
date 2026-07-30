// Markdown -> HTML (docs/design/39-webview-markdown.md §3 / §4 / §5).
//
// The one place that turns LLM output into markup. Everything here is deliberately synchronous and
// DOM-free so it can be unit-tested as a string transform; mermaid's asynchronous drawing happens
// afterwards, against the rendered DOM (Phase B).

import hljs from "highlight.js/lib/common";
import MarkdownIt from "markdown-it";
import footnote from "markdown-it-footnote";
import taskLists from "markdown-it-task-lists";

/** Class name for a ```mermaid fence, drawn later by the lazily loaded mermaid bundle (MD9). */
export const MERMAID_BLOCK_CLASS = "kikimi-mermaid";

function highlight(code: string, language: string): string {
  if (language && hljs.getLanguage(language)) {
    try {
      return hljs.highlight(code, { language, ignoreIllegals: true }).value;
    } catch {
      // Fall through to the escaped-plain-text path below: a highlighter failure must never cost
      // the reader the code itself.
    }
  }
  return "";
}

export function createRenderer(): MarkdownIt {
  const md = new MarkdownIt({
    // MD10: never pass raw HTML through. Everything rendered here originates from an LLM.
    html: false,
    linkify: false,
    breaks: false,
    highlight: (code, language) => {
      if (language === "mermaid") return "";
      const highlighted = highlight(code, language);
      if (!highlighted) return "";
      return `<pre class="hljs"><code>${highlighted}</code></pre>`;
    }
  });

  md.use(footnote);
  md.use(taskLists, { label: true, labelAfter: true });

  installMermaidFence(md);
  return md;
}

/**
 * Replaces the renderer for ```mermaid fences with a placeholder div carrying the source in a data
 * attribute. `min-height` is set in CSS rather than left to the drawn SVG: the diagram arrives
 * asynchronously, and a block that grows after the fact would shove the restored scroll position
 * (MD8) out from under the reader.
 */
function installMermaidFence(md: MarkdownIt): void {
  const defaultFence = md.renderer.rules.fence;
  md.renderer.rules.fence = (tokens, index, options, env, self) => {
    const token = tokens[index];
    const info = token.info.trim().split(/\s+/)[0];
    if (info !== "mermaid") {
      return defaultFence ? defaultFence(tokens, index, options, env, self) : self.renderToken(tokens, index, options);
    }
    // `md.utils.escapeHtml` covers the attribute context here: the value only ever lands in a
    // double-quoted attribute, and the source is read back via `dataset`, never re-parsed as HTML.
    return `<div class="${MERMAID_BLOCK_CLASS}" data-src="${md.utils.escapeHtml(token.content)}"></div>\n`;
  };
}

const renderer = createRenderer();

export function renderMarkdown(markdown: string): string {
  return renderer.render(markdown);
}
