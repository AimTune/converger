/**
 * Validates frames against the Protocol v1 JSON Schemas of the server
 * (`priv/protocol/v1`), so the SDK cannot drift from the wire contract.
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../../priv/protocol/v1");
const BASE = "https://converger.aimtune.dev/schemas/protocol/v1/";

function files(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) return files(full);
    return name.endsWith(".schema.json") ? [full] : [];
  });
}

// ajv's default export differs between its ESM and CJS builds.
const AjvClass = ((Ajv2020 as unknown as { default?: unknown }).default ?? Ajv2020) as typeof Ajv2020;
const ajv = new AjvClass({ strict: false, allErrors: true });
for (const file of files(ROOT)) ajv.addSchema(JSON.parse(readFileSync(file, "utf8")) as object);

function validator(relative: string) {
  const validate = ajv.getSchema(BASE + relative);
  if (!validate) throw new Error(`schema not found: ${relative}`);
  return (value: unknown): string | undefined => (validate(value) ? undefined : ajv.errorsText(validate.errors));
}

/** Errors of an agent -> server envelope, or undefined when valid. */
export const clientEnvelopeErrors = validator("frames/channel/client-envelope.schema.json");
/** Errors of a server -> agent envelope. */
export const serverEnvelopeErrors = validator("frames/channel/server-envelope.schema.json");
/** Errors of a client hello. */
export const helloErrors = validator("frames/client/hello.schema.json");
/** Errors of a server frame (bare). */
export const serverFrameErrors = validator("server-frame.schema.json");
