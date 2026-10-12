/**
 * Runs the real Converger server (`mix phx.server`) for the e2e test: a
 * dedicated database, a fixed port, and a hard kill (the whole process tree,
 * SIGKILL / taskkill /F) to simulate a crash.
 */
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

export const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../..");
const IS_WINDOWS = process.platform === "win32";

export interface ServerOptions {
  port: number;
  database: string;
  mixEnv: string;
}

export function serverOptions(): ServerOptions {
  return {
    port: Number(process.env["E2E_PORT"] ?? 4123),
    database: process.env["E2E_DB_NAME"] ?? "converger_sdk_e2e",
    mixEnv: process.env["E2E_MIX_ENV"] ?? "dev",
  };
}

function env(options: ServerOptions): NodeJS.ProcessEnv {
  return {
    ...process.env,
    MIX_ENV: options.mixEnv,
    DB_NAME: options.database,
    PORT: String(options.port),
    // Quiet logs; the test reads its own markers.
    LOG_LEVEL: "warning",
  };
}

/**
 * On Windows `mix` is a .bat file, which only runs through a shell; pass one
 * command string then (the arguments are constants of this file).
 */
function command(args: string[]): [string, string[]] {
  return IS_WINDOWS ? [`mix ${args.join(" ")}`, []] : ["mix", args];
}

export function mixAvailable(): boolean {
  const [cmd, cmdArgs] = command(["--version"]);
  const result = spawnSync(cmd, cmdArgs, { cwd: REPO_ROOT, shell: IS_WINDOWS, encoding: "utf8" });
  return result.status === 0;
}

function mix(args: string[], options: ServerOptions): string {
  const [cmd, cmdArgs] = command(args);
  const result = spawnSync(cmd, cmdArgs, {
    cwd: REPO_ROOT,
    env: env(options),
    shell: IS_WINDOWS,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(`mix ${args.join(" ")} failed (${result.status}):\n${result.stdout}\n${result.stderr}`);
  }
  return result.stdout;
}

/** Create and migrate the e2e database, then create a tenant and channel. */
export function prepareDatabase(options: ServerOptions): { secret: string; channel_id: string; tenant_id: string } {
  mix(["ecto.create", "--quiet"], options);
  mix(["ecto.migrate", "--quiet"], options);
  const output = mix(["run", "packages/client-ts/test/e2e/setup.exs"], options);
  const line = output.split(/\r?\n/).find((l) => l.startsWith("E2E_FIXTURES "));
  if (!line) throw new Error(`no fixtures printed:\n${output}`);
  return JSON.parse(line.slice("E2E_FIXTURES ".length)) as { secret: string; channel_id: string; tenant_id: string };
}

export class ConvergerServer {
  readonly options: ServerOptions;
  #process: ChildProcess | undefined;
  #output = "";

  constructor(options: ServerOptions) {
    this.options = options;
  }

  get baseUrl(): string {
    return `http://127.0.0.1:${this.options.port}`;
  }

  get output(): string {
    return this.#output.slice(-20_000);
  }

  async start(timeoutMs = 120_000): Promise<void> {
    if (this.#process) throw new Error("already running");
    // Never test against someone else's server on the same port.
    const busy = await fetch(`${this.baseUrl}/health/live`, { signal: AbortSignal.timeout(2_000) }).then(
      () => true,
      () => false,
    );
    if (busy) throw new Error(`port ${this.options.port} is already in use; set E2E_PORT`);
    const [cmd, cmdArgs] = command(["phx.server"]);
    const child = spawn(cmd, cmdArgs, {
      cwd: REPO_ROOT,
      env: env(this.options),
      shell: IS_WINDOWS,
      // Own process group on POSIX, so the whole tree can be killed at once.
      detached: !IS_WINDOWS,
      stdio: ["ignore", "pipe", "pipe"],
    });
    this.#process = child;
    child.stdout?.on("data", (chunk: Buffer) => (this.#output += chunk.toString()));
    child.stderr?.on("data", (chunk: Buffer) => (this.#output += chunk.toString()));
    const started = Date.now();
    for (;;) {
      if (child.exitCode !== null) throw new Error(`mix phx.server exited (${child.exitCode}):\n${this.output}`);
      try {
        const response = await fetch(`${this.baseUrl}/health/live`, { signal: AbortSignal.timeout(2_000) });
        if (response.ok) return;
      } catch {
        // not up yet
      }
      if (Date.now() - started > timeoutMs) throw new Error(`server did not start in ${timeoutMs} ms:\n${this.output}`);
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
  }

  /** Kill the server hard (no graceful drain): the whole process tree. */
  async kill(): Promise<void> {
    const child = this.#process;
    this.#process = undefined;
    if (!child?.pid) return;
    const exited = new Promise<void>((resolve) => {
      if (child.exitCode !== null) resolve();
      else child.once("exit", () => resolve());
    });
    if (IS_WINDOWS) {
      spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], { stdio: "ignore" });
    } else {
      try {
        process.kill(-child.pid, "SIGKILL");
      } catch {
        child.kill("SIGKILL");
      }
    }
    await exited;
    // Wait until the port is free again.
    for (let i = 0; i < 100; i += 1) {
      try {
        await fetch(`${this.baseUrl}/health/live`, { signal: AbortSignal.timeout(2_000) });
      } catch {
        return;
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
}
