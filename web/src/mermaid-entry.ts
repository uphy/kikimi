// The lazily loaded second bundle (docs/design/39-webview-markdown.md MD9).
//
// Built as its own IIFE and injected as a plain <script> the first time a ```mermaid fence shows
// up. Phase A0 verified that a second classic script loads over file:// under
// `script-src 'self'`; ESM + code splitting is deliberately avoided because that combination is
// not proven on this transport.
//
// mermaid is ~3MB, which is an order of magnitude more than the rest of the renderer put together.
// Most summaries contain no diagram at all, so keeping it out of the initial parse is the whole
// point of the split.

import mermaid from "mermaid";

declare global {
  interface Window {
    __kikimiMermaid?: typeof mermaid;
  }
}

window.__kikimiMermaid = mermaid;
