import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";

// The dev server proxies /api and /socket to Converger (no CORS setup needed)
// and plays "your backend": POST /demo/token mints a token with the channel
// secret, which stays on the server. Never put a channel secret in browser code.
export default defineConfig(({ mode }) => {
  const env = { ...process.env, ...loadEnv(mode, process.cwd(), "") };
  const target = env.CONVERGER_URL ?? "http://localhost:4000";

  return {
    plugins: [
      react(),
      {
        name: "demo-token-endpoint",
        configureServer(server) {
          server.middlewares.use("/demo/token", async (req, res) => {
            if (!env.CHANNEL_SECRET) {
              res.statusCode = 500;
              res.end("set CHANNEL_SECRET for the dev server");
              return;
            }
            const userId = new URL(req.url ?? "/", "http://localhost").searchParams.get("userId") ?? "widget-user";
            const response = await fetch(`${target}/api/v1/converger/tokens/generate`, {
              method: "POST",
              headers: { authorization: `Bearer ${env.CHANNEL_SECRET}`, "content-type": "application/json" },
              body: JSON.stringify({ user: { id: userId } }),
            });
            res.statusCode = response.status;
            res.setHeader("content-type", "application/json");
            res.end(await response.text());
          });
        },
      },
    ],
    server: {
      proxy: {
        "/api": target,
        "/socket": { target, ws: true },
      },
    },
  };
});
