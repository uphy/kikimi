// Builds the web assets into Kikimi/Resources/editor/ (docs/design/39-webview-markdown.md §9).
//
// Output is a classic IIFE script, not an ES module: the page is loaded over `file://` with a
// `script-src 'self'` CSP, and Phase A0 verified that plain scripts (including a second one
// injected at runtime, which is how mermaid will arrive -- MD9) load fine under exactly that
// combination. ESM + code splitting is deliberately not used.

import { cp, mkdir, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import * as esbuild from "esbuild";

const webDir = dirname(dirname(fileURLToPath(import.meta.url)));
const outDir = join(webDir, "..", "Kikimi", "Resources", "editor");

await rm(outDir, { recursive: true, force: true });
await mkdir(outDir, { recursive: true });

await esbuild.build({
  entryPoints: [join(webDir, "src", "main.ts")],
  bundle: true,
  minify: true,
  format: "iife",
  target: "safari17",
  outfile: join(outDir, "bundle.js"),
  logLevel: "info"
});

// The lazily injected mermaid bundle (MD9). A separate IIFE, not a code-split chunk: it is loaded
// by appending a plain <script> at runtime, which is the form Phase A0 proved works over file://
// under `script-src 'self'`.
await esbuild.build({
  entryPoints: [join(webDir, "src", "mermaid-entry.ts")],
  bundle: true,
  minify: true,
  format: "iife",
  target: "safari17",
  outfile: join(outDir, "mermaid.bundle.js"),
  logLevel: "info"
});

await esbuild.build({
  entryPoints: [join(webDir, "src", "style.css")],
  bundle: true,
  minify: true,
  outfile: join(outDir, "bundle.css"),
  loader: { ".woff": "dataurl", ".woff2": "dataurl" },
  logLevel: "info"
});

await cp(join(webDir, "index.html"), join(outDir, "index.html"));

console.log(`Web assets written to ${outDir}`);
