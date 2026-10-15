import { defineConfig } from "tsup";

// ESM + CJS builds with type declarations for both. No runtime dependencies:
// the agent uses the platform's WebSocket and fetch (or an injected `ws`).
// `@converger/agent/testing` is a separate entry so the fake server (which
// needs the `ws` package) never ends up in an agent's production bundle.
export default defineConfig({
  entry: { index: "src/index.ts", testing: "src/testing/index.ts" },
  format: ["esm", "cjs"],
  dts: true,
  sourcemap: true,
  clean: true,
  target: "es2022",
  platform: "neutral",
  treeshake: true,
  external: ["ws"],
});
