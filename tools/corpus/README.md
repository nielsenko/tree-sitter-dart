# Corpus tooling

Parses large real-world Dart corpora with this repository's grammar and
reports pass/fail rates. Used as the regression gate for grammar changes.

```sh
cd tools/corpus
dart pub get
dart run bin/download_packages.dart   # top pub.dev packages -> download/pub/
dart run bin/clone_curated.dart       # curated GitHub repos -> download/curated/
dart run bin/report.dart              # parse everything, print summary
dart run bin/report.dart --details    # also list failing file paths
```

`report.dart` clears the tree-sitter cache and writes a parser-directories
config pointing at this repository, so it always tests the local grammar.
`check_syntax.dart` filters files that the Dart analyzer itself rejects
(reads paths from stdin). The `download/` and `out/` directories are
git-ignored.

## Provenance

`bin/download_packages.dart`, `bin/clone_flutter_apps.dart`,
`bin/clone_widgets.dart`, `bin/copy_corpus.dart`, and `lib/utils.dart`
originate from [dart-lang/language](https://github.com/dart-lang/language)
`tools/corpus` (BSD 3-Clause, Copyright the Dart project authors) with
local modifications. `bin/report.dart`, `bin/clone_curated.dart`, and
`bin/check_syntax.dart` are original to this repository.
