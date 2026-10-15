// Scaffolds a TypeScript Converger agent project from ../template.
//
// Placeholders in template files: __PACKAGE_NAME__, __CONVERGER_URL__,
// __AGENT_GROUP__, __SDK_VERSION__. Files named `gitignore` and `env.example`
// are renamed to `.gitignore` and `.env.example` (npm drops dotfiles named
// `.gitignore` from published packages).

import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const TEMPLATE = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../template");
const RENAMES = { gitignore: ".gitignore", "env.example": ".env.example" };

/** The version range of the agent SDK new projects depend on. */
export const DEFAULT_SDK_VERSION = "^0.1.0";

/**
 * @typedef {object} ScaffoldOptions
 * @property {string} directory Target directory (created; must be empty unless `force`).
 * @property {string} [name] npm package name. Default: the directory's base name.
 * @property {string} [url] Converger URL written to `.env.example`. Default http://localhost:4000.
 * @property {string} [group] Agent group. Default: the package name.
 * @property {string} [sdkVersion] Dependency spec of the agent SDK package (a range, `file:...`, `workspace:*`).
 * @property {boolean} [force] Write into a non-empty directory, overwriting template files.
 */

/**
 * @param {string} name
 * @returns {boolean}
 */
export function validPackageName(name) {
  return /^(?:@[a-z0-9-~][a-z0-9-._~]*\/)?[a-z0-9-~][a-z0-9-._~]*$/.test(name) && name.length <= 214;
}

/**
 * Write the project. Returns the list of written files (relative paths).
 * @param {ScaffoldOptions} options
 * @returns {string[]}
 */
export function scaffold(options) {
  const target = path.resolve(options.directory);
  const name = options.name ?? path.basename(target).toLowerCase().replace(/[^a-z0-9-._~]/g, "-");
  if (!validPackageName(name)) throw new Error(`invalid package name: ${name} (use --name)`);
  if (existsSync(target) && readdirSync(target).length > 0 && !options.force) {
    throw new Error(`${target} is not empty (use --force to write into it)`);
  }
  const group = options.group ?? name.replace(/^@[^/]+\//, "");
  if (!/^.{1,128}$/.test(group)) throw new Error("the agent group must be 1 to 128 characters");
  const values = {
    __PACKAGE_NAME__: name,
    __CONVERGER_URL__: options.url ?? "http://localhost:4000",
    __AGENT_GROUP__: group,
    __SDK_VERSION__: options.sdkVersion ?? DEFAULT_SDK_VERSION,
  };
  /** @type {string[]} */
  const written = [];
  /** @param {string} relative */
  const copy = (relative) => {
    const source = path.join(TEMPLATE, relative);
    if (statSync(source).isDirectory()) {
      for (const entry of readdirSync(source)) copy(path.join(relative, entry));
      return;
    }
    const base = path.basename(relative);
    const renamed = path.join(path.dirname(relative), /** @type {Record<string, string>} */ (RENAMES)[base] ?? base);
    let content = readFileSync(source, "utf8");
    // Values inside JSON files are JSON-escaped (a Windows `file:C:\...` path).
    const json = base.endsWith(".json");
    for (const [key, value] of Object.entries(values)) content = content.split(key).join(json ? JSON.stringify(value).slice(1, -1) : value);
    const destination = path.join(target, renamed);
    mkdirSync(path.dirname(destination), { recursive: true });
    writeFileSync(destination, content);
    written.push(renamed.split(path.sep).join("/"));
  };
  mkdirSync(target, { recursive: true });
  copy(".");
  return written.sort();
}

/**
 * Parse CLI arguments (non-interactive; every option is a flag).
 * @param {string[]} argv
 * @returns {ScaffoldOptions & { help?: boolean }}
 */
export function parseArgs(argv) {
  /** @type {Record<string, string | boolean>} */
  const flags = {};
  /** @type {string[]} */
  const positional = [];
  for (let i = 0; i < argv.length; i += 1) {
    const arg = /** @type {string} */ (argv[i]);
    if (arg === "-h" || arg === "--help") flags["help"] = true;
    else if (arg === "--force" || arg === "-f") flags["force"] = true;
    else if (arg.startsWith("--")) {
      const [key, inline] = arg.slice(2).split("=", 2);
      const value = inline ?? argv[++i];
      if (value === undefined) throw new Error(`--${key} needs a value`);
      flags[/** @type {string} */ (key)] = value;
    } else positional.push(arg);
  }
  const known = new Set(["help", "force", "name", "url", "group", "sdk-version"]);
  for (const key of Object.keys(flags)) if (!known.has(key)) throw new Error(`unknown option --${key}`);
  if (flags["help"]) return { directory: "", help: true };
  const directory = positional[0];
  if (!directory) throw new Error("missing the project directory");
  /** @type {ScaffoldOptions} */
  const options = { directory, force: flags["force"] === true };
  if (typeof flags["name"] === "string") options.name = flags["name"];
  if (typeof flags["url"] === "string") options.url = flags["url"];
  if (typeof flags["group"] === "string") options.group = flags["group"];
  if (typeof flags["sdk-version"] === "string") options.sdkVersion = flags["sdk-version"];
  return options;
}

export const USAGE = `Usage: npx create-converger-agent <directory> [options]

Scaffolds a TypeScript agent for Converger (@converger/agent): a sample onTurn,
.env.example and a test against the SDK's fake server.

Options:
  --name <name>           npm package name (default: the directory name)
  --url <url>             Converger URL for .env.example (default: http://localhost:4000)
  --group <group>         agent group (default: the package name)
  --sdk-version <spec>    @converger/agent dependency (default: ${DEFAULT_SDK_VERSION})
  -f, --force             write into a non-empty directory
  -h, --help              show this help
`;
