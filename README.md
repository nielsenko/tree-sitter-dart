# tree-sitter-dart

A [tree-sitter](https://tree-sitter.github.io/tree-sitter/) grammar for
[Dart](https://dart.dev/).

It covers Dart through 3.13. That includes records, patterns, class
modifiers, extension types, null-aware elements, dot shorthands, digit
separators, private named parameters (3.12) and primary constructors (3.13).
Primary constructors include the `this : initializers { body }` member form
and abbreviated `new` and `factory` constructors.

The reference throughout is the Dart analyzer. It is the parser behind
`dart analyze` and the Dart IDE plugins. When this README calls a file
valid Dart, it means the analyzer reports no syntax error in it.

## The tree

Here is a line of Dart:

```dart
var x = a + b * c;
```

The grammar turns it into this tree:

```
(source_file
  (top_level_variable_declaration
    (initialized_identifier_list
      (initialized_identifier
        name: (identifier)
        value: (additive_expression
          (identifier)
          operator: (additive_operator)
          (multiplicative_expression
            (identifier)
            operator: (multiplicative_operator)
            (identifier)))))))
```

Each parenthesized name is a node. A label before a child, such as `value:`
or `operator:`, is a field. A query, written in tree-sitter's pattern
language, can ask for a child by its field.

### Node names

The node names come from the
[Dart language specification](https://github.com/dart-lang/language/blob/main/specification/dartLangSpec.tex).
The spec defines Dart's syntax as a list of named rules, such as
`additiveExpression` and `formalParameterList`. Each node takes the name of
its rule in snake_case: `additive_expression`, `formal_parameter_list`.
Features newer than the spec take their names from the
[accepted feature specifications](https://github.com/dart-lang/language/tree/main/accepted).

A few nodes have names the spec doesn't use:

- `source_file` is the root, as in most tree-sitter grammars. The spec has
  `libraryDefinition` and `partDeclaration`.
- `class_body`, `enum_body` and `extension_body` wrap the braces, which the
  spec inlines. `enum_declaration` replaces the spec's `enumType` to match
  the other `*_declaration` nodes.
- `annotation` is the spec's `metadatum`.
- `catch_clause` and `finally_clause` are the spec's `onPart` and
  `finallyPart`.
- `documentation_comment` holds `///` lines and `/** */` blocks. Other
  comments are `comment`. The spec has only single-line and multi-line
  comments. The split lets editors style doc comments differently.
- String nodes follow the tokens of the external scanner, a hand-written
  lexer described [below](#external-scanner).
- The spec has `booleanLiteral` and `numericLiteral`. The grammar has `true`
  and `false`, and one node per numeric form, such as
  `decimal_integer_literal` and `hex_integer_literal`.
- Postfix chains, described next.

### Postfix chains

The spec reads `a.b.c(1)` as a flat list. First comes `a`, then the
selectors `.b`, `.c` and `(1)`. In that shape neither `a.b` nor `a.b.c` is a
node. A query can't match them, and a structural diff can't move them.

The grammar gives each selector its own node instead:

```
(call_expression                  ; a.b.c(1)
  function: (member_expression    ; a.b.c
    object: (member_expression    ; a.b
      object: (identifier)        ; a
      property: (identifier))     ; b
    property: (identifier))       ; c
  arguments: (arguments
    (decimal_integer_literal)))   ; 1
```

Each node applies one selector, so the tree holds the same information as
the spec's list. The chain nodes are `call_expression`, `member_expression`,
`index_expression`, `null_aware_member_expression`,
`null_aware_index_expression`, `null_assertion_expression` and
`instantiation_expression`. All but `instantiation_expression` have a `cascade_` version as well - for cascade sections such as `x..a.b()`.

### Other wrappers

The grammar wraps other common constructs in one node each, so a tool can
match or diff them as a unit:

- Each top-level declaration: `function_declaration`, `getter_declaration`,
  `setter_declaration`, `top_level_variable_declaration`, and the
  `external_*_declaration` variants.
- `method_declaration` for a method with a body.
- `type` at every type position. Generic, function, record and nullable
  types nest inside it.
- A named node for every operator, under the expression's `operator:` field,
  as in the first example: `additive_operator`, `multiplicative_operator`,
  `shift_operator`, `equality_operator`, `relational_operator`,
  `bitwise_operator`, `increment_operator`, `prefix_operator` and
  `negation_operator`.

### Supertypes

A supertype is a name for a group of node kinds. It never appears in the
tree, but a query can match it. In the first example, the query
`(_binary_expression) @b` matches both `a + b * c` and `b * c`.

- `_expression`: any expression.
- `_binary_expression`: the spec's binary operator family, such as
  `additive_expression` and `relational_expression`.
- `_statement`, `_literal` and `_declaration`.
- `_instantiation`: `new_expression`, `const_object_expression` and
  `constructor_invocation`.

### Keywords

Dart has three kinds of keywords. The grammar treats each the way the
analyzer does:

- The 33 reserved words, such as `class`, `if` and `var`, are never
  identifiers.
- Built-in identifiers, such as `get`, `set` and `mixin`, can be
  identifiers.
- `await` and `yield` are identifiers outside async functions and
  generators.

## Queries

`queries/` holds three query files:

- `highlights.scm` for syntax highlighting: keywords, types, functions,
  literals, operators, properties, calls and references.
- `tags.scm` for symbol navigation: classes, methods, constructors,
  top-level declarations and call references.
- `locals.scm` for scopes and variable resolution.

## How well it parses

The grammar is checked against a corpus of 219,918 Dart files. 205,728 come
from pub.dev packages and 14,190 from open-source Dart projects. The check
asks three questions.

### Does every file parse?

A file parses when its tree has no error nodes. 219,875 of the 219,918
files parse:

```
pub                    205728 files    205706 passed     22 failed  99.99%
curated                 14190 files     14169 passed     21 failed  99.85%
TOTAL                  219918 files    219875 passed     43 failed  99.98%
```

The analyzer rejects 42 of the 43 failing files too. They are 20 templates
for Mason, a code generator, with `{{name}}` placeholders, parse error test
files, broken generated code, packages published with syntax errors, and a
cut-off `.pb.dart` fragment.

The corpus has 218,505 valid files, and 218,504 of them parse. The one that
fails has a binary constant pattern, the first item under
[Known limitations](#known-limitations). The other way round, the grammar
accepts more than Dart does. It parses most of the 1,413 invalid files.

### Is the tree right?

A tree with no errors can still be wrong. Take `a + b * c`. Multiplication
binds tighter than addition, so the analyzer groups it as `a + (b * c)`. A
grammar with the precedence backwards would build `(a + b) * c`. Both trees
cover all the text, and neither has an error.

To catch this, `tools/analyzer_ast` parses each file with the analyzer as
well and compares the two trees by span. A span is where a node starts and
ends in the file. In the wrong tree, the node `a + b` spans from `a` to `b`.
The analyzer's node `b * c` spans from `b` to `c`. Each starts inside the
other and ends outside it. That is a crossing. It means the two parsers
group the code differently.

No corpus file has a crossing. 94.5% of the analyzer's non-leaf nodes have a
grammar node with the same span. The rest are nodes only one side has, such
as the analyzer's node for a function's parameters and body. A node only one
side has is not a crossing.

### What happens after a syntax error?

Code in an editor is often broken while you type. Tree-sitter still builds a
tree. It puts the broken part in an `ERROR` node and tries to keep the rest.

`analyzer_ast recovery` measures how much is kept. It copies sampled files
and breaks each copy with one edit, such as a deleted token or a missing
closing bracket. Then it checks the nodes away from the edit. On 2,000
files, 94.4% of those nodes kept their span and kind, and half of the edits
lost no node at all.

This is the weakest part of the grammar. A missing `)` before `{`, or an
unbalanced brace, can turn the rest of a class into one `ERROR` node.

## Known limitations

Each limitation has a test in `test/limitations.test.mjs` that asserts the
correct behavior. Node's `expectFailure` mark turns that test's failure into
a pass. When a limitation is fixed, its test passes, the mark turns that
into a failure, and the run fails until someone removes the mark. Corpus
tests also pin today's trees for all but the last.

- **Binary constant patterns.** A switch case whose constant pattern is a
  binary expression, such as `case A.x + B.y:`, does not parse. Dart 3
  rejects it too, but code that opts into an older language version, such
  as `// @dart=2.19`, may use it. Supporting it breaks other constant
  patterns. Write `case const (A.x + B.y):` instead.
- **Call-shaped `await` and `yield`.** Outside async functions and
  generators, `await(5)` and `yield(5)` call functions named `await` and
  `yield`. The grammar does not track whether the enclosing function is
  async, so it parses them as an `await` expression and a `yield`
  statement.
- **Zero-width nodes in invalid code.** In `class C<in> {}` and
  `void f({}) {}`, error recovery leaves an empty `type_identifier` or
  `identifier` and no `ERROR`. The tree's `has_error()` is true, but
  `tree-sitter parse` exits 0. `tools/check_zero_width.mjs` finds these
  files.
- **Error recovery.** See [above](#what-happens-after-a-syntax-error).

## Development

You need Node.js 26 or later and a C compiler. The limitation tests use
`node:test`'s `expectFailure`.

```sh
npm install
npm run build-test
```

`build-test` runs five steps:

1. `tree-sitter generate` builds the C parser in `src/` from `grammar.js`.
2. `node-gyp build` compiles the Node binding.
3. `tree-sitter test` runs the tests.
4. `npm run coverage` fails if a named node appears in no expected tree.
5. `node --test test/limitations.test.mjs` runs the known-limitation tests.

The tests live in `test/`. Each file in `test/corpus/` holds Dart snippets
with the tree each one must produce. `ambiguities.txt` pins how the grammar
reads ambiguous code, and some tests pin the trees of known limitations.
When code can be parsed more than one way, tree-sitter follows each
reading in parallel until the wrong ones fail. It follows at most six at a
time and drops the rest. `parse_versions.txt` holds code from pub.dev that
has many readings at once, so a grammar change that adds readings there
can drop the right one.
`test/highlight/` and `test/tags/` check the query captures. After a
deliberate change to the trees, update the expected trees with:

```sh
npx tree-sitter test --update
```

To parse a file:

```sh
npm run parse -- path/to/file.dart
```

Use this rather than a bare `tree-sitter parse`. Tree-sitter looks up
grammars through your global config, and it caches compiled parsers by
language name. If another Dart grammar is installed, a bare
`tree-sitter parse` may use it. `npm run parse` points tree-sitter at this
checkout and clears the cache first.

To try the grammar in a browser, run `npm start`.

### Corpus check

`tools/corpus` downloads the corpus and runs the checks from
[How well it parses](#how-well-it-parses). It fails when a file starts or
stops failing, or a new crossing appears. Accepted failures are listed in
`tools/corpus/known_failures.txt`, and accepted crossings in
`tools/corpus/known_ast_crossings.txt`. Setup and flags are in
[tools/corpus/README.md](tools/corpus/README.md).

`tools/analyzer_ast` runs the analyzer comparison on its own. It has four
subcommands:

- `dump` prints the analyzer's tree in the same format as
  `tree-sitter parse`.
- `compare` shows, per analyzer node kind, how many nodes the grammar
  matches by span.
- `crossings` lists the crossings.
- `recovery` runs the error recovery measurement.

Usage is in the comment at the top of `tools/analyzer_ast/bin/analyzer_ast.dart`.

### The Dart spec

The [dart-lang/language](https://github.com/dart-lang/language) repository
is a submodule. Git doesn't fetch it by default:

```sh
git submodule update --init
```

It holds the spec (`language/specification/dartLangSpec.tex`), accepted
Dart 3 feature specs (`language/accepted/`) and specs in progress
(`language/working/`).

## External scanner

Tree-sitter generates a lexer from `grammar.js`. A lexer splits the text
into tokens, such as names, operators and pieces of strings. A few Dart
tokens need more than the generated lexer can do. `src/scanner.c` is a
hand-written lexer, called the external scanner, that tree-sitter calls for
those tokens. It has five jobs.

1. **String content.** A Dart string can contain `$name` and `${expr}`. The
   scanner emits the text between them as `template_chars_*` tokens. It does
   this for every quote style: single, double, triple single, triple double
   and raw. A single-line string ends at the end of the line.

2. **Nested comments.** A `/* */` comment can contain another one. The
   scanner counts the depth. It also tells `/** */` doc comments apart from
   plain ones.

3. **Annotation arguments.** Look at these three lines:

   ```dart
   @Foo(1) int f() => 1;
   @override (String, int) g() => ('a', 1);
   @override/*c*/(String, int) g() => ('a', 1);
   ```

   In the first line, `(1)` is the annotation's arguments. In the second,
   the space ends the annotation, so `(String, int)` is the record type
   `g` returns. The analyzer reads the third line like the second. A block
   comment ends the annotation too.

   The spec's rule is that arguments start only where `(` comes right
   after the name. The scanner emits `annotation_open_paren` only there.
   The space needs no memory to get right:

   ```
   @override (String, int) g()
            ^ the scan starts at the space, sees no "(" and declines
   ```

   The comment does, because the scanner emits it as a token of its own:

   ```
   @override/*c*/(String, int) g()
            ^^^^^ scan 1 emits the comment, sees "(" next, records a veto
                 ^ scan 2 starts at "(" and can't see the comment
   ```

   Scan 2 finds the veto and emits an ordinary `(` instead of
   `annotation_open_paren`. The veto also records the column of the `(`,
   and scan 2 checks it, as a guard against a veto left over from
   somewhere else.

4. **Type arguments after an expression.** `f(a < b, c > (d))` passes one
   argument, a generic call of `a`. `f(a < b, c > -d)` passes two, `a < b`
   and `c > -d`. The spec decides by the token after the `>`. The `<` and
   `>` enclose type arguments only when that token is one of
   `( . == != ) ] } ; : ,` or the end of the file. The scanner looks past
   whitespace and comments to that token, and emits the `>` that closes
   the type arguments only then.

5. **Error recovery.** Tree-sitter tells the scanner which tokens are valid
   at each point. During error recovery it marks every token valid. A
   scanner that believed this would read code after a syntax error as string
   content. So the grammar declares `_error_sentinel`, a token no rule
   uses. If tree-sitter says it is valid, the parser is recovering. The
   scanner then lexes only comments and string bodies that end on the same
   line.

The veto from item 3 is the scanner's only state, and tree-sitter controls
where it lives. After the scanner emits a token, tree-sitter saves the
scanner's state on that token. Before each scan, it restores the state
saved on the last such token. It works this way because it can follow
several readings at once and can restart parsing in the middle of a file
after an edit. Each needs the state as it was at that point.

So the scanner saves the veto and its column. And it emits the `(` in
scan 2 rather than declining. A scan that emits nothing saves nothing, so
the veto would stay in place for later annotations.

When no veto is armed, the scanner saves no state at all. Tree-sitter
merges two readings that reach the same point only if their saved scanner
states are equal, and a reading that has passed no scanner token has an
empty state. Saving zeros instead would keep identical readings apart,
and tree-sitter follows at most six. With zeros, the closing `>` from
item 4 would push the right reading of `return A<R>(g(x.y));` out of that
limit.

## License

[MIT](LICENSE)
