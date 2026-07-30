// Neither plugin ships types, and neither has a maintained @types package. Declaring the shape we
// actually use here keeps the dependency list to the two runtime packages (same approach Chirami
// takes for turndown-plugin-gfm).

declare module "markdown-it-footnote" {
  import type { PluginSimple } from "markdown-it";
  const footnote: PluginSimple;
  export default footnote;
}

declare module "markdown-it-task-lists" {
  import type { PluginWithOptions } from "markdown-it";
  const taskLists: PluginWithOptions<{ enabled?: boolean; label?: boolean; labelAfter?: boolean }>;
  export default taskLists;
}
