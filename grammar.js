/**
 * @file Dart grammar for tree-sitter
 * @author Kasper Overgård Nielsen <kasper@byolimit.com>
 * @license MIT
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

module.exports = grammar({
  name: "dart",

  rules: {
    // TODO: add the actual grammar rules
    source_file: $ => "hello"
  }
});
