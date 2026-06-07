#!/usr/bin/env node
// Fails if any visible named node in the grammar does not appear in at
// least one expected tree in test/corpus/. Keeps the full-node-coverage
// invariant from regressing as the grammar grows.
import { readFileSync, readdirSync } from "node:fs";

const nodeTypes = JSON.parse(readFileSync("src/node-types.json", "utf8"));
const named = new Set(
  nodeTypes
    .filter((n) => n.named && !n.type.startsWith("_"))
    .map((n) => n.type),
);

const covered = new Set();
for (const f of readdirSync("test/corpus")) {
  if (!f.endsWith(".txt")) continue;
  const text = readFileSync(`test/corpus/${f}`, "utf8");
  for (const m of text.matchAll(/\((\w+)/g)) covered.add(m[1]);
}

const uncovered = [...named].filter((n) => !covered.has(n)).sort();
if (uncovered.length) {
  console.error(`coverage: ${named.size - uncovered.length}/${named.size} named nodes`);
  console.error("uncovered nodes (add corpus tests):");
  for (const n of uncovered) console.error(`  ${n}`);
  process.exit(1);
}
console.log(`coverage: ${named.size}/${named.size} named nodes ✓`);
