# Changelog

All notable changes to this grammar.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-10-25

Dart 3.12 and 3.13 support, and node names taken from the Dart
specification. **Breaking**: nine nodes are renamed and several trees change
shape. The README describes the naming contract.

### Added

- Dart 3.13 primary constructors, a preview in 3.12 behind
  `primary-constructors`:
  - the header form on classes and enums, as `primary_constructor`:
    `class User(final String name);`
  - the `this : initializers { body }` member, as
    `primary_constructor_body_signature`
  - abbreviated `new()`, `new name()` and `factory` constructors in the body
  - `;` as an empty body on class, mixin, enum, extension and extension
    type declarations
  - `final` on extension type representation variables
- Dart 3.12 private named parameters (`{required this._x}`). They already
  parsed, and tests now pin them.
- The 33 reserved words are an ABI 15 reserved set, so `var x = for + 0;`
  is an ERROR. Built-in identifiers (`get`, `set`, `required`, `mixin`,
  ...) remain usable as identifiers.
- `await` and `yield` parse as identifiers where the keyword form cannot,
  as the analyzer allows outside async and generator bodies.
- `documentation_comment` for `///` lines and `/** */` blocks.
- Supertypes `_expression` and `_binary_expression`.
- A `cascade` node holding the receiver and its `cascade_section`s.
- Named operator nodes under an `operator:` field: `additive_operator`,
  `multiplicative_operator`, `shift_operator`, `equality_operator`,
  `bitwise_operator` and `increment_operator`, next to the existing
  `relational_operator`.
- Fields: `condition:` on `if_statement`, `guard:` on `when` guards,
  `default_value:` on parameter defaults, `name:` on function-typed,
  `this.` and `super.` parameters, `type:` on `on` clauses.
- Highlights for extension type representations, record and pattern field
  names, pattern variables, dot shorthands and for-in variables. `rethrow`
  is a keyword.
- Tags: `@reference.call` for cascade and dot-shorthand calls,
  `@reference.class` for `new`, `const` and generic constructor
  invocations, `@reference.implementation` for implemented interfaces, and
  operator methods by their operator.
- Tooling, described in the README and `tools/corpus/README.md`:
  - `npm run parse -- file.dart` parses with this checkout's grammar.
  - `tools/analyzer_ast` compares trees with the Dart analyzer's AST
    (`dump`, `compare`, `crossings`, `recovery`).
  - The corpus gate counts analyzer-valid files only, requires failures to
    match `known_failures.txt`, fails on AST crossings not listed in
    `known_ast_crossings.txt`, and flags zero-width recovery nodes.

### Changed

Nine nodes take their spec production names:

| 0.2.0 | 0.3.0 |
|---|---|
| `constructor_param` | `field_formal_parameter` |
| `class_member` | `member_declaration` |
| `enum_constant` | `enum_entry` |
| `qualified` | `qualified_name` |
| `negate_operator` | `negation_operator` |
| `initialized_variable_definition` | `initialized_variable_declaration` |
| `pair` | `map_element` |
| `null_aware_pair` | `null_aware_map_element` |
| `null_aware_element` | `null_aware_expression_element` |

- `///` and `/** */` comments are `documentation_comment`, not `comment`.
  `/** */` still wraps `documentation_block_comment`.
- `multiplicative_expression` nests to the left like `additive_expression`,
  with one `operator:` each. `a * b / c` was one flat node.
- `extension_type_representation` holds a primary constructor parameter. Its
  `type:` is optional, it takes a trailing comma, and `[...]` and `{...}`
  produce `optional_formal_parameters`.
- Value-null-aware map entries (`{k: ?v}`, `{?k: ?v}`) are flat
  `null_aware_map_element` nodes with `key:` and `value:`. They nested a
  `null_aware_expression_element`, which remains for `[?a]` and `{?a}`.

### Removed

- The standalone `"++"`, `"--"` and `"!="` tokens. Capture
  `increment_operator` and `equality_operator` instead.

### Fixed

- Expressions:
  - `f(a < b, c > -x)` and `f(a < b, c > [1])` pass two comparisons, as in
    the analyzer. Type arguments after an expression need one of
    `( . == != ) ] } ; : ,` after the `>`.
  - Arrow function bodies extend as far as the analyzer's. `(b) => b.x()`
    calls `x` on `b`, not on the closure. 0.2.0 got this wrong in 25,798 of
    the 116,764 corpus files checked. Cascades and `/` after the arrow stay
    in the body, and `a ?? (_) => true` parses.
  - `??` binds tighter than `?:` and nests to the left.
    `a ?? b ? c : d` is `(a ?? b) ? c : d`.
  - `a < b >> c` is a relational expression over a shift, not `(a<b>) > c`.
  - `f<T>(g<T>(x), y)` is a generic call, not `f < T > (record)`.
  - `List<int>.new` is a `constructor_tearoff`, `List<int>.filled` a member
    access on an `instantiation_expression`, and `Foo<int>.new(1)` a
    `constructor_invocation`.
  - In `x..y = b = a..z()`, the last cascade section belongs to `x`, not
    `a`.
- Types:
  - `Future<T> Function()` is a type in typedefs, type arguments, `as` and
    `is`, not a comparison chain.
  - Function-type returns have uniform `(type ...)` wrappers. `void
    Function()` had an empty `(type)`, and record returns lost
    `record_type`.
  - Bare `Function` and `Function?` have no empty `function_type`.
  - Type parameters named `out` or `inout` (`class C<out> {}`) are names.
    `<out T>` is still a variance modifier and a name.
- Declarations:
  - Setters without a return type (`set x(v) {}`) are setters, not
    functions returning `set`.
  - `external factory();` is a factory constructor, not a function named
    `factory`.
  - In `{required this.x}`, `required` is not a type.
  - `: this.named(1)` after a constructor signature is a `redirection`.
  - `operator <=` declarations have a flat `binary_operator`.
  - `static`, `covariant`, `external` and `late` before `Function()` are
    modifiers, and `external set x(v);` has no return type.
  - Top-level `external var x;`, `abstract var x;` and
    `extension type E.new(int v) {}` parse.
  - Extension type `implements` clauses produce an `interfaces` node under
    `interfaces:`.
  - Header `const` without a primary constructor (`class const Foo {}`) is
    an ERROR, as in the analyzer.
- Patterns and statements:
  - Names in declaration patterns (`var (a, b) = r;`,
    `for (final [x, y] in l)`) are `variable_pattern` nodes, so
    `locals.scm` defines them. They were `constant_pattern`.
  - `case .new:` and `case const .named(1):` parse, with the same
    `static_member_shorthand` node as in expressions.
  - `case const []:` and other empty const collections parse without error
    recovery.
  - `case == 4:` and `case != 5:` produce `equality_operator` nodes.
  - `for (;;,) {}` is an ERROR, as in the analyzer.
- Strings and comments:
  - `'$a\$foo'` is a substitution of `a`, an escape and text, not one
    identifier `a\$foo`.
  - `'\012'` is the escape `\0` followed by `12`. Dart has no octal escapes.
  - In single-line strings, a lone CR ends the string like LF, a backslash
    before a line break is not an escape, and a `$` before a line break no
    longer reads the next line as interpolation.
  - `'a$'`, invalid Dart, closes at its quote with a MISSING node on the
    `$`.
  - NUL bytes in strings and block comments parse.
  - A shebang line parses without a trailing newline and ends at a CR.
  - `/**/` is a documentation comment, as in the analyzer.
  - A block comment between an annotation name and `(` ends the annotation,
    so `@override/*c*/(String, int) bar()` has a record return type.
  - Whitespace skipping no longer depends on `iswspace()`, which truncated
    supplementary-plane characters on Windows.
- Error recovery:
  - Code after a syntax error is no longer lexed as string content.
    Comments next to the error stay comments, and ERROR nodes cover only
    the bad tokens.
  - A comment inside an ERROR no longer strips the arguments off a later
    annotation.
- Queries:
  - Constructor and factory names no longer take the class's `@type`.
  - `as` in casts and cast patterns is `@keyword.operator`, like `is`.
    Import `as` stays `@keyword`.
  - `await` and `yield` are `@keyword` only in their expressions and
    statements.
  - Annotations: the `@` and qualified names (`@foo.bar()`) are
    `@attribute`, and the opening paren is `@punctuation.bracket`.
  - Interpolation: `$` and the `${ }` braces are `@punctuation.special`,
    and identifiers inside are `@variable`.
  - The redirect target in `factory F() = A.b.c;` is not captured as a
    constructor definition.
  - `user.name` no longer takes the highlight of a local named `name`.
- Bindings:
  - The runtime floors match the ABI 15 parser: npm `tree-sitter ^0.25.0`,
    Python `tree-sitter~=0.25`, go-tree-sitter v0.25.0 and swift-tree-sitter
    0.9.0. With v0.24.0 the Go binding could not load the parser.
  - The Go binding test imports the right module path, and `Makefile` and
    `CMakeLists.txt` link to this repository.

## [0.2.0] - 2026-04-26

Major AST shape changes for downstream tools. 
Existing parse trees change shape, and queries against 0.1.0 will need updating.

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
