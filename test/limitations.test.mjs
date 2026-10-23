// The README's known limitations, each asserted the way the grammar should
// behave. expectFailure accepts only an AssertionError, so a broken harness
// still fails, and a fixed limitation fails until its mark is removed.
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const cli = join(repoRoot, "node_modules", ".bin", "tree-sitter");
const dir = mkdtempSync(join(tmpdir(), "ts-dart-limitations-"));
const library = join(dir, "dart.so");

// Loading the parser from a library built here bypasses the user's global
// tree-sitter config and its compiled-parser cache.
before(() => {
  execFileSync(cli, ["build", "-o", library, repoRoot], { stdio: "ignore" });
});
after(() => rmSync(dir, { recursive: true, force: true }));

function knownLimitation(label) {
  return { expectFailure: { label, match: assert.AssertionError } };
}

// Returns the nodes of `tree-sitter parse` output in document order, each
// with its type, start and end as [row, column].
function parse(source) {
  const file = join(dir, "input.dart");
  writeFileSync(file, source);
  const result = spawnSync(
    cli,
    ["parse", "-l", library, "--lang-name", "dart", file],
    { encoding: "utf8" },
  );
  const nodes = [];
  for (const line of result.stdout.split("\n")) {
    const match = line.match(
      /^ *(?:\w+: )?\((MISSING (?:"[^"]*"|\S+)|\w+) \[(\d+), (\d+)\] - \[(\d+), (\d+)\]/,
    );
    if (match) {
      const [, type, startRow, startColumn, endRow, endColumn] = match;
      nodes.push({
        type,
        start: [Number(startRow), Number(startColumn)],
        end: [Number(endRow), Number(endColumn)],
      });
    }
  }
  assert.ok(nodes.length > 0, `no tree for ${JSON.stringify(source)}`);
  return nodes;
}

function has(nodes, type, start, end) {
  return nodes.some(
    (node) =>
      node.type === type &&
      node.start.join() === start.join() &&
      node.end.join() === end.join(),
  );
}

function assertRecoveryIsVisible(nodes) {
  const silent = nodes
    .slice(1)
    .filter(
      (node) =>
        node.start.join() === node.end.join() &&
        !node.type.startsWith("MISSING"),
    );
  assert.deepEqual(silent, [], "zero-width node without ERROR or MISSING");
  assert.ok(
    nodes.some(
      (node) => node.type === "ERROR" || node.type.startsWith("MISSING"),
    ),
    "invalid code parsed without ERROR or MISSING",
  );
}

test("the harness parses valid code", () => {
  const nodes = parse("void f() {\n  g(a < b);\n}\n");
  assert.ok(has(nodes, "relational_expression", [1, 4], [1, 9]));
});

test(
  "binary constant patterns parse",
  knownLimitation("Binary constant patterns"),
  () => {
    const nodes = parse(
      "// @dart=2.19\nvoid f(int x) {\n  switch (x) {\n    case A.x + B.y:\n      break;\n  }\n}\n",
    );
    assert.ok(!nodes.some((node) => node.type === "ERROR"));
    assert.ok(has(nodes, "additive_expression", [3, 9], [3, 18]));
  },
);

test(
  "call-shaped await in sync code is a call",
  knownLimitation("Call-shaped await and yield"),
  () => {
    const nodes = parse("void f() {\n  await(5);\n}\n");
    assert.ok(has(nodes, "call_expression", [1, 2], [1, 10]));
  },
);

test(
  "call-shaped yield in sync code is a call",
  knownLimitation("Call-shaped await and yield"),
  () => {
    const nodes = parse("void f() {\n  yield(5);\n}\n");
    assert.ok(has(nodes, "call_expression", [1, 2], [1, 10]));
  },
);

test(
  "recovery in class C<in> {} is visible",
  knownLimitation("Zero-width nodes in invalid code"),
  () => {
    assertRecoveryIsVisible(parse("class C<in> {}\n"));
  },
);

test(
  "recovery in void f({}) {} is visible",
  knownLimitation("Zero-width nodes in invalid code"),
  () => {
    assertRecoveryIsVisible(parse("void f({}) {}\n"));
  },
);

test(
  "a missing ) keeps the next method",
  knownLimitation("Error recovery"),
  () => {
    const nodes = parse("class A {\n  void f(int a {}\n  void g() {}\n}\n");
    assert.ok(has(nodes, "method_declaration", [2, 2], [2, 13]));
  },
);
