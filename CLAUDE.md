## Planning

When given a task, always iterate on a plan with the user, before commencing.
Setup clear goals for "definition of done".

## Revision control

- This repository uses jj (jujutsu).

- Make sure to make small incremental commits.

- Make sure use [conventional commit](https://www.conventionalcommits.org/en/v1.0.0/) messages, of the form:
  ```
  <type>[optional scope]: <description>

  [optional body]

  [optional footer(s)]
  ```

## How to test

- `npm run build-test` (runs `tree-sitter generate && node-gyp build && tree-sitter test`)
- For tag tests: `dart run tester/test.dart test/tags parse`

## Project: New tree-sitter-dart grammar from the Dart language specification

### Context

This is a **fresh tree-sitter grammar for Dart**, built from scratch using the official
[Dart language specification](https://github.com/dart-lang/language/blob/main/specification/dartLangSpec.tex).

It replaces an older grammar at `/Users/kasper/Projects/3rd_party/tree-sitter/tree-sitter-dart`
which had 394 rules, 67 conflicts, and structural debt from being ported from a Java grammar.

### Goal

Fresh `grammar.js` following the spec, ~250 rules, minimal conflicts (<20), covering Dart through 3.11.

### Key reference material

The dart-lang/language repo should be added as a git submodule at `language/`:
```
git submodule add https://github.com/dart-lang/language.git language
```

This provides:
- `language/specification/dartLangSpec.tex` - the formal Dart grammar (version 2.13-dev)
- `language/tools/plaintext_grammar.dart` - extracts clean plaintext grammar from the LaTeX spec:
  `dart run language/tools/plaintext_grammar.dart language/specification/dartLangSpec.tex`
- `language/accepted/{3.0,3.3,3.7,3.8,3.10}/` - feature specs for Dart 3.x additions
- `language/specification/Makefile` - `make terse` for simplified spec

The spec is at version 2.13-dev and does NOT include Dart 3.0+ features. Those are in separate
feature spec documents under `language/accepted/`:

| Version | Feature | Grammar impact |
|---------|---------|---------------|
| 3.0 | Class modifiers (sealed/base/interface/final) | 3 new productions |
| 3.0 | Patterns | ~15 new productions |
| 3.0 | Records | 6 new productions |
| 3.3 | Extension types | 3 new productions |
| 3.6 | Digit separators | Tokenizer only |
| 3.7 | Wildcard variables | Semantic only, no grammar change |
| 3.8 | Null-aware elements | 2 new productions |
| 3.10 | Dot shorthands | 3 new productions |
| 2.12 | Abstract/external fields | 2 new productions |
| 2.15 | Constructor tearoffs | 4+ new productions |
| 2.17 | Enhanced enums | 2 new productions |
| 2.17 | Super parameters | 1 new production |
| 2.19 | Unnamed libraries | 1 modification |

### What to copy from old repo

- **`src/scanner.c`** - external scanner handling nested block comments and string template chars.
  Located at `/Users/kasper/Projects/3rd_party/tree-sitter/tree-sitter-dart/src/scanner.c`.
  7 token types: `TEMPLATE_CHARS_SINGLE`, `TEMPLATE_CHARS_DOUBLE`, `TEMPLATE_CHARS_SINGLE_SINGLE`,
  `TEMPLATE_CHARS_DOUBLE_SINGLE`, `TEMPLATE_CHARS_RAW_SLASH`, `BLOCK_COMMENT`, `DOCUMENTATION_BLOCK_COMMENT`.
  Stateless (serialize/deserialize are no-ops). Works correctly, copy as-is.

- **Test corpus Dart input code** - reuse the Dart source from old `test/corpus/*.txt` files,
  but rewrite the expected parse trees from scratch.

### Design decisions

1. **Expressions**: Use flat precedence with `prec.left(PREC, seq($._expression, op, $._expression))`
   - the standard tree-sitter pattern. NOT the spec's chained approach which creates deep nesting.

2. **Types**: Use spec's clean 4-rule hierarchy: `_type`, `_type_not_void`, `_type_not_function`,
   `_type_not_void_not_function`. Handle `var`/`final`/`const`/`late` as modifiers in declaration context.

3. **Node names**: Follow spec naturally in snake_case (e.g., `class_declaration`, `mixin_declaration`).
   No backward compatibility with old grammar's names.

4. **Keywords**: Inline as string literals. Only create named keyword nodes where highlighting needs them.

### Build order (phases)

1. **Skeleton + lexical foundations** - identifiers, keywords, comments, externals
2. **Types** - type hierarchy, generics, function types, record types
3. **Literals** - numbers, booleans, null, strings (using external scanner), symbols, collections
4. **Expressions** - primary, selectors, cascades, unary/postfix, binary (all precedence levels),
   assignment, conditional, throw, await, constructor invocation/tearoff, dot shorthands
5. **Formal parameters** - normal, optional positional, named, super parameters
6. **Statements** - block, control flow, exception handling, jumps, assert, labels
7. **Declarations and class members** - declaration rule, method/function/getter/setter signatures,
   constructors, abstract/external fields
8. **Top-level declarations** - classes (with modifiers), mixins, extensions, extension types,
   enums (enhanced), typedefs
9. **Library structure** - imports, exports, parts, metadata/annotations
10. **Patterns** (Dart 3.0) - full pattern hierarchy
11. **Remaining Dart 3.x features** - null-aware elements, etc.
12. **Queries and polish** - highlights.scm, tags.scm, conflict audit

### Definition of done

1. `npm run build-test` passes
2. Tag tests pass
3. highlights.scm and tags.scm work
4. Conflicts < 20
5. Rule count ~250
6. All Dart features through 3.11 supported
