import { mkdtempSync, readFileSync, existsSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { DEFAULT_SDK_VERSION, parseArgs, scaffold, validPackageName } from "../src/scaffold.mjs";

const BIN = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../bin/create-converger-agent.mjs");
const dirs: string[] = [];

function tempDir(): string {
  const dir = mkdtempSync(path.join(tmpdir(), "cca-"));
  dirs.push(dir);
  return dir;
}

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe("scaffold", () => {
  it("writes the template with the placeholders filled in", () => {
    const target = path.join(tempDir(), "my-agent");
    const files = scaffold({ directory: target, url: "https://converger.example.com", group: "faq" });
    expect(files).toEqual([
      ".env.example",
      ".gitignore",
      "README.md",
      "package.json",
      "src/handler.ts",
      "src/main.ts",
      "test/handler.test.ts",
      "tsconfig.json",
    ]);
    const pkg = JSON.parse(readFileSync(path.join(target, "package.json"), "utf8")) as Record<string, any>;
    expect(pkg["name"]).toBe("my-agent");
    expect(pkg["dependencies"]["@converger/agent"]).toBe(DEFAULT_SDK_VERSION);
    const windows = path.join(tempDir(), "win");
    // A Windows path: backslashes must be JSON-escaped in package.json.
    const spec = String.raw`file:C:\sdk\agent.tgz`;
    scaffold({ directory: windows, sdkVersion: spec });
    expect(JSON.parse(readFileSync(path.join(windows, "package.json"), "utf8")).dependencies["@converger/agent"]).toBe(spec);
    const env = readFileSync(path.join(target, ".env.example"), "utf8");
    expect(env).toContain("CONVERGER_URL=https://converger.example.com");
    expect(env).toContain("CONVERGER_AGENT_GROUP=faq");
    for (const file of files) expect(readFileSync(path.join(target, file), "utf8")).not.toMatch(/__[A-Z_]+__/);
  });

  it("refuses a non-empty directory unless forced", () => {
    const target = tempDir();
    writeFileSync(path.join(target, "keep.txt"), "x");
    expect(() => scaffold({ directory: target, name: "x" })).toThrow(/not empty/);
    scaffold({ directory: target, name: "x", force: true });
    expect(existsSync(path.join(target, "keep.txt"))).toBe(true);
    expect(existsSync(path.join(target, "src/handler.ts"))).toBe(true);
  });

  it("validates package names", () => {
    expect(validPackageName("@acme/faq-agent")).toBe(true);
    expect(validPackageName("Bad Name")).toBe(false);
    expect(() => scaffold({ directory: path.join(tempDir(), "x"), name: "Bad Name" })).toThrow(/invalid package name/);
  });
});

describe("CLI", () => {
  it("parses non-interactive flags", () => {
    expect(parseArgs(["agent", "--name", "@acme/a", "--url=https://c.example.com", "--group", "g", "--sdk-version", "file:../sdk", "-f"])).toEqual({
      directory: "agent",
      name: "@acme/a",
      url: "https://c.example.com",
      group: "g",
      sdkVersion: "file:../sdk",
      force: true,
    });
    expect(() => parseArgs([])).toThrow(/directory/);
    expect(() => parseArgs(["a", "--bogus", "1"])).toThrow(/unknown option/);
  });

  it("scaffolds through the bin script", () => {
    const target = path.join(tempDir(), "cli-agent");
    const result = spawnSync(process.execPath, [BIN, target, "--group", "cli"], { encoding: "utf8" });
    expect(result.status, result.stderr).toBe(0);
    expect(result.stdout).toContain("Created");
    expect(readFileSync(path.join(target, ".env.example"), "utf8")).toContain("CONVERGER_AGENT_GROUP=cli");
  });

  it("exits non-zero with usage on bad input", () => {
    const result = spawnSync(process.execPath, [BIN], { encoding: "utf8" });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("Usage:");
  });
});
