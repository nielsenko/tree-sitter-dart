const assert = require("node:assert");
const { test } = require("node:test");

const Parser = require("tree-sitter");

test("can load grammar and parse", () => {
  const parser = new Parser();
  assert.doesNotThrow(() => parser.setLanguage(require(".")));
  const tree = parser.parse("class A {}");
  assert.strictEqual(tree.rootNode.type, "source_file");
  assert.strictEqual(tree.rootNode.hasError, false);
});
