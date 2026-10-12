import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    projects: [
      {
        test: {
          name: "unit",
          include: ["test/unit/**/*.test.ts"],
          environment: "node",
          testTimeout: 10_000,
        },
      },
      {
        // Against a real Converger server (`mix phx.server`), see test/e2e/README.md.
        test: {
          name: "e2e",
          include: ["test/e2e/**/*.test.ts"],
          environment: "node",
          testTimeout: 180_000,
          hookTimeout: 240_000,
          fileParallelism: false,
        },
      },
    ],
  },
});
