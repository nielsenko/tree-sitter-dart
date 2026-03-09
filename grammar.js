/**
 * @file Dart grammar for tree-sitter
 * @author Kasper Overgård Nielsen <kasper@byolimit.com>
 * @license MIT
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

module.exports = grammar({
  name: "dart",

  externals: ($) => [
    $.template_chars_single,
    $.template_chars_double,
    $.template_chars_single_single,
    $.template_chars_double_single,
    $.template_chars_raw_slash,
    $.block_comment,
    $.documentation_block_comment,
  ],

  extras: ($) => [
    /\s/,
    $.comment,
  ],

  rules: {
    // Top-level
    source_file: ($) => repeat($._top_level_definition),

    _top_level_definition: ($) =>
      choice(
        // Placeholder for future phases — for now just allow declarations
        $.function_signature,
        ";",
      ),

    // --- Identifiers ---

    identifier: (_) => /[a-zA-Z_$][a-zA-Z0-9_$]*/,

    // Qualified name: e.g. prefix.identifier
    qualified_name: ($) =>
      seq($.identifier, ".", $.identifier),

    // Type identifier (same pattern, but distinct node for type names)
    type_identifier: ($) => $.identifier,

    // --- Comments ---

    comment: ($) =>
      choice(
        // Single-line comment (not doc comment)
        token(seq("//", /[^/\n].*/)),
        token(seq("//", /\n/)),
        // Single-line doc comment: /// ...
        token(seq("///", /.*/)),
        // Block comments (via external scanner)
        $.block_comment,
        $.documentation_block_comment,
      ),

    // --- Function signature (minimal, for testing) ---

    function_signature: ($) =>
      seq(
        optional($._type),
        field("name", $.identifier),
        "(",
        ")",
      ),

    // --- Types (minimal stubs for Phase 1) ---

    _type: ($) => choice($.type_identifier, "void"),
  },
});
