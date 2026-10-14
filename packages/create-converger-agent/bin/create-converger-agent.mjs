#!/usr/bin/env node
// npx create-converger-agent my-agent [--name ...] [--url ...] [--group ...] [--sdk-version ...] [--force]
import process from "node:process";
import { parseArgs, scaffold, USAGE } from "../src/scaffold.mjs";

try {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(USAGE);
  } else {
    const files = scaffold(options);
    process.stdout.write(
      `Created ${options.directory} (${files.length} files).\n\n` +
        `Next:\n  cd ${options.directory}\n  npm install\n  cp .env.example .env   # set CONVERGER_CHANNEL_SECRET\n  npm test\n  npm start\n`,
    );
  }
} catch (error) {
  process.stderr.write(`create-converger-agent: ${error instanceof Error ? error.message : String(error)}\n\n${USAGE}`);
  process.exit(1);
}
