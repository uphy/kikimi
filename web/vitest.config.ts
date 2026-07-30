import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // `render.ts` / `document.ts` build real DOM nodes, so the unit tests need a document.
    environment: "jsdom",
    globals: true,
    include: ["src/**/*.test.ts"]
  }
});
