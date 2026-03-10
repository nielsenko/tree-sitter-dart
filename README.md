# tree-sitter-dart

A [tree-sitter](https://tree-sitter.github.io/tree-sitter/) grammar for [Dart](https://dart.dev/),
built from scratch using the official [Dart language specification](https://github.com/dart-lang/language/blob/main/specification/dartLangSpec.tex).

Supports Dart through version 3.11, including records, patterns, class modifiers,
extension types, null-aware elements, dot shorthands, and digit separators.

## Setup

### Prerequisites

- [Node.js](https://nodejs.org/) (v18 or later)
- A C compiler (for building the parser)

### Install dependencies

```sh
npm install
```

### Build and test

```sh
npm run build-test
```

This runs `tree-sitter generate`, `node-gyp build`, and `tree-sitter test` in sequence.

### Playground

To try the grammar interactively in a browser:

```sh
npm start
```

This builds a WASM version of the parser and opens the tree-sitter playground.

## Architecture

### External scanner

The parser uses a custom external scanner (`src/scanner.c`) for three aspects of
Dart syntax that cannot be expressed with tree-sitter's generated lexer:

1. **String interpolation characters** - Dart strings can contain `$expr` and
   `${expr}` interpolations. The scanner emits `template_chars_*` tokens for
   the literal text between interpolation boundaries, handling all four string
   quote styles (single, double, triple-single, triple-double) and raw strings.

2. **Nested block comments** - Dart block comments (`/* ... */`) can nest
   arbitrarily. The scanner tracks nesting depth and distinguishes regular block
   comments from documentation block comments (`/** ... */`).

3. **Annotation argument disambiguation** - In Dart, `@Foo(args)` is an
   annotation with arguments, but `@override (String, int)` (with a space) is
   an annotation followed by a record type. The scanner emits an
   `annotation_open_paren` token only when `(` appears immediately after the
   annotation name with no whitespace, matching the Dart spec's NO_SPACE rule.

The scanner is stateless - serialize/deserialize are no-ops.

## Development

The grammar is defined entirely in `grammar.js`. After making changes, run:

```sh
npm run build-test
```

This generates the parser from the grammar, builds the native module, and runs all
unit tests.

### Tests

Unit tests live in `test/corpus/*.txt` in the standard tree-sitter test format:
each test has a name, input source, a separator, and the expected S-expression parse tree.

To auto-update expected parse trees after grammar changes:

```sh
npx tree-sitter test --update
```

### Parsing files

To parse a Dart file:

```sh
npx tree-sitter parse path/to/file.dart
```

To parse all Dart files in a directory:

```sh
find path/to/dir -name '*.dart' -type f | xargs npx tree-sitter parse --quiet
```

### Reference material

The `language/` directory is a git submodule of
[dart-lang/language](https://github.com/dart-lang/language). It provides:

- `language/specification/dartLangSpec.tex` - The formal Dart grammar
- `language/accepted/` - Feature specifications for Dart 3.x additions
- `language/working/` - In-progress feature specifications

To initialize the submodule:

```sh
git submodule update --init
```

### Corpus testing

The `language/` submodule includes tools for downloading large corpora of
open-source Dart code from [pub.dev](https://pub.dev/) to test the parser
against real-world code.

#### Download the corpus

```sh
cd language/tools/corpus/scripts
dart pub get
dart run bin/download_packages.dart
```

This downloads recent packages from pub.dev into `language/tools/corpus/scripts/download/pub/`.

#### Copy Dart files (filtering out generated code)

```sh
dart run bin/copy_corpus.dart pub
```

This copies `.dart` files into `language/tools/corpus/scripts/out/pub/`, discarding
generated files and other uninteresting sources.

#### Run the parser against the corpus

```sh
find language/tools/corpus -name '*.dart' -type f | xargs npx tree-sitter parse --quiet
```

To count failures:

```sh
find language/tools/corpus -name '*.dart' -type f | xargs npx tree-sitter parse --quiet 2>&1 | grep -c ERROR
```
