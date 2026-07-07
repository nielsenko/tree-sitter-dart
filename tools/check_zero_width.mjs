#!/usr/bin/env node
// Flag files whose parse tree contains ERROR, MISSING, or zero-width named
// nodes, using THIS repo's grammar.
//
// `tree-sitter parse` exits 0 when error recovery inserts a MISSING *hidden*
// token (e.g. `_name`): the visible tree then contains a zero-width named
// node — `void f({}) {}` yields `(identifier [0, 8] - [0, 8])` — and no
// ERROR/MISSING is printed, so exit-code/--stat acceptance (including the
// corpus report) counts the file as a success. A zero-width named node can
// never occur in a genuine parse (tokens consume input; the only legitimate
// zero-width node is the root of an empty file), so its presence is proof of
// recovery.
//
// Usage:
//   node tools/check_zero_width.mjs [--paths listfile] [--config-path cfg]
//                                   [--quiet] [file|dir ...]
//
// Directories are searched recursively for .dart files. Exits 1 if any file
// is flagged. --config-path skips the config/cache pinning (for callers like
// report.dart that already pinned the grammar and warmed the cache).
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { readdirSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const args = process.argv.slice(2);
const files = [];
let configPath = null;
let ownConfigDir = null;
let quiet = false;

for (let i = 0; i < args.length; i++) {
  if (args[i] === "--paths") {
    const list = readFileSync(args[++i], "utf8");
    for (const line of list.split("\n")) {
      if (line.trim() !== "") files.push(line.trim());
    }
  } else if (args[i] === "--config-path") {
    configPath = args[++i];
  } else if (args[i] === "--quiet") {
    quiet = true;
  } else {
    collect(args[i]);
  }
}

function collect(path) {
  if (statSync(path).isDirectory()) {
    for (const entry of readdirSync(path, { withFileTypes: true })) {
      const child = join(path, entry.name);
      if (entry.isDirectory()) collect(child);
      else if (entry.name.endsWith(".dart")) files.push(child);
    }
  } else {
    files.push(path);
  }
}

if (files.length === 0) {
  console.error("no input files (pass files, dirs, or --paths listfile)");
  process.exit(2);
}

if (configPath === null) {
  ownConfigDir = mkdtempSync(join(tmpdir(), "ts-dart-zw-"));
  configPath = join(ownConfigDir, "config.json");
  writeFileSync(
    configPath,
    JSON.stringify({ "parser-directories": [dirname(repoRoot)] }),
  );
  for (const ext of ["dylib", "so"]) {
    rmSync(join(homedir(), ".cache", "tree-sitter", "lib", `dart.${ext}`), {
      force: true,
    });
  }
}

const localCli = join(repoRoot, "node_modules", ".bin", "tree-sitter");
const cli = existsSync(localCli) ? localCli : "tree-sitter";
const SPAN = /\[(\d+), (\d+)\] - \[(\d+), (\d+)\]/;
const BATCH = 200;
let flagged = 0;

for (let start = 0; start < files.length; start += BATCH) {
  const batch = files.slice(start, start + BATCH);
  await new Promise((done, fail) => {
    const child = spawn(
      cli,
      ["parse", "--config-path", configPath, ...batch],
      { cwd: repoRoot, stdio: ["ignore", "pipe", "inherit"] },
    );
    let fileIdx = -1;
    let reported = false;
    createInterface({ input: child.stdout }).on("line", (line) => {
      // A root node line starts at column 0; inner lines are indented.
      const isRoot = line.startsWith("(");
      if (isRoot) {
        fileIdx++;
        reported = false;
      }
      if (reported) return;
      const span = line.match(SPAN);
      // An empty file's root is legitimately zero-width; any other
      // zero-width node is inserted by recovery.
      const zeroWidth =
        !isRoot && span !== null && span[1] === span[3] && span[2] === span[4];
      if (zeroWidth || line.includes("(ERROR") || line.includes("(MISSING")) {
        flagged++;
        reported = true;
        if (!quiet) {
          const kind = zeroWidth ? "zero-width" : "error";
          console.log(`${batch[fileIdx]}: ${kind}: ${line.trim()}`);
        }
      }
    });
    child.on("error", fail);
    child.on("close", () => done());
  });
}

console.log(`zero-width check: flagged ${flagged} of ${files.length} files`);
if (ownConfigDir !== null) {
  rmSync(ownConfigDir, { recursive: true, force: true });
}
process.exit(flagged > 0 ? 1 : 0);
