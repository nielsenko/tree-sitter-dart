#!/usr/bin/env node
// Parse files with THIS repo's grammar.
//
// A user-global tree-sitter config (~/.config/tree-sitter/config.json) can
// resolve `.dart` files to a different dart grammar, and the compiled-parser
// cache (~/.cache/tree-sitter/lib/dart.*) is keyed by language name only, so
// a bare `tree-sitter parse` is nondeterministic across machines. This pins
// parser resolution to this repository's checkout and clears the name-keyed
// cache before parsing.
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const configDir = mkdtempSync(join(tmpdir(), "ts-dart-"));
const configPath = join(configDir, "config.json");
writeFileSync(
  configPath,
  JSON.stringify({ "parser-directories": [dirname(repoRoot)] }),
);
for (const ext of ["dylib", "so"]) {
  rmSync(join(homedir(), ".cache", "tree-sitter", "lib", `dart.${ext}`), {
    force: true,
  });
}
try {
  execFileSync(
    "tree-sitter",
    ["parse", "--config-path", configPath, ...process.argv.slice(2)],
    { stdio: "inherit" },
  );
} catch (e) {
  process.exitCode = e.status ?? 1;
} finally {
  rmSync(configDir, { recursive: true, force: true });
}
