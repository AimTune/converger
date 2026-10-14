import { defineConfig } from "vitest/config";

// template/test is the scaffolded project's test, not ours.
export default defineConfig({ test: { include: ["test/**/*.test.ts"], environment: "node" } });
