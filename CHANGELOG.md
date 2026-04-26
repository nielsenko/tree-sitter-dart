# Changelog

All notable changes to this grammar.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-04-26

Major AST shape changes for downstream tools. 
Existing parse trees change shape; queries against 0.1.0 will need updating.

### Added

- Postfix wrapper nodes: `call_expression`, `instantiation_expression`,
  `member_expression`, `index_expression`, `null_aware_member_expression`,
  `null_aware_index_expression`, `null_assertion_expression`, plus 7
  cascade-prefixed parallels (`cascade_call_expression`, etc.). Each
  chain step is now a single named subtree.
- Top-level wrapper nodes: `function_declaration`, `getter_declaration`,
  `setter_declaration`, `external_function_declaration`,
  `external_getter_declaration`, `external_setter_declaration`,
  `top_level_variable_declaration`, `external_variable_declaration`.
  Every branch of `_top_level_definition` produces exactly one named
  child of `source_file`.
- `method_declaration` wrapper around `method_signature` + `function_body`
  inside `class_member`, paralleling `function_declaration`. Exposes
  `signature:` and `body:` fields.
- `type` named wrapper around every type-labeled position. Composite
  types (generics, function types, record types, nullable forms) nest
  inside it. Replaces the previously-hidden `_type` rule.
- Hidden supertype `_instantiation` grouping `new_expression`,
  `const_object_expression`, `constructor_invocation`. Queryable as
  `(_instantiation)` without alternation.
- `property:` field on `cascade_call_expression` for simple `..foo()`
  forms, mirroring `member_expression`.
- Query captures: `@function.call`, `@function.method.call`,
  `@reference.call`, `@definition.variable`, `@definition.function` on
  the new wrappers.
- `nullable(rule)` and `postfixChainWrappers(base, prefix)` JS helpers
  in `grammar.js` for repeated rule shapes.

### Changed

- `_type_not_function`, `_type_not_void`, `_type_not_void_not_function`
  alias their output to `type` so consumers see uniform `(type ...)`
  regardless of which scope-restricted variant matched.
- `factory_constructor_signature` and
  `redirecting_factory_constructor_signature` now use
  `optional(seq(".", _identifier_or_new))` instead of
  `repeat(seq(".", identifier))`. Tightens to one dot (per Dart spec)
  and accepts `Foo.new()` factory form.
- `tags.scm` and `highlights.scm` rewritten for the new shapes.
- The cascade `function:` field reserved for chained forms
  (`..foo().bar()`); simple `..foo()` uses `property:`.

### Removed

- Hidden rules: `selector`, `argument_part`, `_assignable_selector`,
  `unconditional_assignable_selector`, `conditional_assignable_selector`,
  `_assignable_selector_part` (subsumed by named postfix wrappers).
- The flat `_postfix_expression: seq(_primary, repeat(selector))` shape.

### Fixed

- Duplicate `return_type:` (and other type-labeled) fields on signatures
  with composite types like `Future<int>`. The hidden `_type` rule
  inlined its children and propagated the parent field label to each;
  the new public `type` wrapper produces a single labeled child.
- `(factory_constructor_signature name: (identifier) @name)` now matches
  both segments of `factory Foo.create()` (Foo and create), matching the
  behavior of regular named constructors. Previous parser-table quirk
  caused only the first segment to match when `repeat` was used in the
  field body.

### Verification

- 86/86 unit tests pass.
- 219,874 / 219,918 (99.98%) on combined pub.dev (205,728) + curated
  (14,190) corpora. Identical to 0.1.0 baseline; no regressions.

## [0.1.0]

Initial release. Grammar built from scratch against the Dart language
specification through 3.11. Covers records, patterns, class modifiers,
extension types, null-aware elements, dot shorthands, digit separators.
