import { defineConfig } from "tsup";

// ESM + CJS builds with type declarations for both. No runtime dependencies:
// the client uses the platform's WebSocket, fetch and (in browsers)
// localStorage.
export default defineConfig({
  entry: ["src/index.ts"],
  format: ["esm", "cjs"],
  dts: true,
  sourcemap: true,
  clean: true,
  target: "es2022",
  platform: "neutral",
  treeshake: true,
});
