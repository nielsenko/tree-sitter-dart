#include "tree_sitter/parser.h"

#include <stdlib.h>
#include <string.h>

enum TokenType {
  TEMPLATE_CHARS_SINGLE,
  TEMPLATE_CHARS_DOUBLE,
  TEMPLATE_CHARS_SINGLE_SINGLE,
  TEMPLATE_CHARS_DOUBLE_SINGLE,
  TEMPLATE_CHARS_RAW_SLASH,
  BLOCK_COMMENT,
  DOCUMENTATION_BLOCK_COMMENT,
  ANNOTATION_OPEN_PAREN,
  COMMENT_SEPARATED_OPEN_PAREN,
  // Never emitted: valid only while the parser is in error recovery
  // (recovery marks every symbol valid), so testing it alone detects
  // recovery exactly. Must stay last in the grammar's externals list.
  ERROR_SENTINEL,
};

// ANNOTATION_OPEN_PAREN matches '(' only when it directly follows the
// annotation name. That is the analyzer's rule for annotation arguments
// vs a record return type. Whitespace needs no help. The scan that starts
// on the whitespace sees no '(', and the internal lexer takes the '('.
// A block comment is different. It is emitted as its own extra token, so
// the next scan starts exactly on the '('. When a comment in annotation
// position ends touching a '(', set_annotation_paren_veto records a veto
// and that paren's column. The scan at that '(' then emits
// COMMENT_SEPARATED_OPEN_PAREN, which clears the veto.
typedef struct {
  bool veto_annotation_paren;
  uint32_t veto_column;
} Scanner;

static void clear_annotation_paren_veto(Scanner *scanner) {
  scanner->veto_annotation_paren = false;
  scanner->veto_column = 0;
}

void *tree_sitter_dart_external_scanner_create() {
  return calloc(1, sizeof(Scanner));
}
void tree_sitter_dart_external_scanner_destroy(void *p) { free(p); }
void tree_sitter_dart_external_scanner_reset(void *p) {
  clear_annotation_paren_veto((Scanner *)p);
}
unsigned tree_sitter_dart_external_scanner_serialize(void *p, char *buffer) {
  Scanner *scanner = (Scanner *)p;
  buffer[0] = (char)scanner->veto_annotation_paren;
  memcpy(&buffer[1], &scanner->veto_column, sizeof(uint32_t));
  return 1 + sizeof(uint32_t);
}
void tree_sitter_dart_external_scanner_deserialize(void *p, const char *b, unsigned n) {
  Scanner *scanner = (Scanner *)p;
  clear_annotation_paren_veto(scanner);
  if (n >= 1 + sizeof(uint32_t)) {
    scanner->veto_annotation_paren = b[0] != 0;
    memcpy(&scanner->veto_column, &b[1], sizeof(uint32_t));
  }
}

static void advance(TSLexer *lexer) { lexer->advance(lexer, false); }

// Explicit ASCII whitespace instead of iswspace: wint_t is 16 bits on
// Windows, so supplementary-plane lookahead truncates (U+10020 -> 0x0020)
// and would be silently skipped. ASCII is the whole set anyway — Dart's
// WHITESPACE production is ASCII-only, and so is the grammar's /\s/ extra.
static bool is_whitespace(int32_t c) {
  return c == ' ' || (c >= '\t' && c <= '\r');
}

// Called when a comment token is about to be emitted: if the comment sits
// in annotation position and closes touching a '(', that paren must not
// become ANNOTATION_OPEN_PAREN (trivia ends the annotation). Emitting a
// non-poisoned comment clears any previous veto.
static void set_annotation_paren_veto(Scanner *scanner, TSLexer *lexer,
                                      const bool *valid_symbols) {
  // Error recovery marks every symbol valid, so valid_symbols cannot say
  // "annotation position" there. Arming from a recovery scan would poison
  // an unrelated later annotation whose '(' shares the column.
  scanner->veto_annotation_paren =
      !valid_symbols[ERROR_SENTINEL] &&
      valid_symbols[ANNOTATION_OPEN_PAREN] && lexer->lookahead == '(';
  scanner->veto_column =
      scanner->veto_annotation_paren ? lexer->get_column(lexer) : 0;
}


static bool scan_multiline_comments(Scanner *scanner, TSLexer *lexer,
                                    const bool *valid_symbols) {

    bool documentation_comment = false;
    advance(lexer);
    if (lexer->lookahead != '*') return false;
    advance(lexer);
    bool after_star = false;
    if (lexer->lookahead == '*') {
      // A second '*' opens a doc comment, terminator or not: the analyzer's
      // tokenizeMultiLineComment sets `dartdoc = $STAR == next` after one
      // advance, so '/**/' is an empty DOC comment. Priming after_star lets
      // the shared close path below emit it.
      advance(lexer);
      documentation_comment = true;
      if (lexer->lookahead == '/') {
        after_star = true;
      }
    }

    unsigned nesting_depth = 1;
    for (;;) {
      switch (lexer->lookahead) {
        case '*':
          advance(lexer);
          after_star = true;
          break;
        case '/':
          if (after_star) {
            advance(lexer);
            after_star = false;
            nesting_depth--;
            if (nesting_depth == 0) {
              if (!documentation_comment) {
                lexer->result_symbol = BLOCK_COMMENT;
              } else {
                lexer->result_symbol = DOCUMENTATION_BLOCK_COMMENT;
              }
              set_annotation_paren_veto(scanner, lexer, valid_symbols);
              return true;
            }
          } else {
            advance(lexer);
            after_star = false;
            if (lexer->lookahead == '*') {
              nesting_depth++;
              advance(lexer);
            }
          }
          break;
        case '\0':
          // '\0' is also a valid content character; only stop at real EOF.
          if (lexer->eof(lexer)) return false;
          // fall through
        default:
          advance(lexer);
          after_star = false;
          break;
      }
    }
}


// `recovery` scans a string body reached while the parser is in error
// recovery, where valid_symbols says nothing (every symbol is valid). Such a
// run only counts as string content when it ends at a delimiter on the same
// line; a run that reaches a line terminator or EOF is ordinary code after a
// syntax error and must not be swallowed as template chars.
static bool scan_templates(Scanner *scanner, TSLexer *lexer,
                           const bool *valid_symbols, bool recovery) {
  // Durable only if a token is emitted; template chars can never
  // immediately precede an annotation's '('.
  clear_annotation_paren_veto(scanner);
  if(valid_symbols[TEMPLATE_CHARS_DOUBLE]) {
              lexer->result_symbol = TEMPLATE_CHARS_DOUBLE;
  } else if (valid_symbols[TEMPLATE_CHARS_SINGLE]) {
              lexer->result_symbol = TEMPLATE_CHARS_SINGLE;
  } else if (valid_symbols[TEMPLATE_CHARS_SINGLE_SINGLE]) {
              lexer->result_symbol = TEMPLATE_CHARS_SINGLE_SINGLE;
  } else {
              lexer->result_symbol = TEMPLATE_CHARS_DOUBLE_SINGLE;
  }
  for (bool has_content = false;; has_content = true) {
    lexer->mark_end(lexer);
    switch (lexer->lookahead) {
      case '\'':
      case '"':
        return has_content;
      case '\n':
      case '\r':
        if (recovery) return false;
        // A line terminator ends a single-line string. Emit what was already
        // scanned so the string body stays string content and the error
        // lands on the terminator itself.
        if (valid_symbols[TEMPLATE_CHARS_DOUBLE_SINGLE] || valid_symbols[TEMPLATE_CHARS_SINGLE_SINGLE]) return has_content;
        advance(lexer);
        break;
      case '$':
        return has_content;
      case '\\':
        if (valid_symbols[TEMPLATE_CHARS_RAW_SLASH]) {
            lexer->result_symbol = TEMPLATE_CHARS_RAW_SLASH;
            advance(lexer);
        } else {
            return has_content;
        }
        break;
      case '\0':
        // '\0' is also a valid content character; only stop at real EOF.
        if (lexer->eof(lexer)) return false;
        // fall through
      default:
        advance(lexer);
    }
  }
}



bool tree_sitter_dart_external_scanner_scan(void *payload, TSLexer *lexer,
                                                  const bool *valid_symbols) {
  Scanner *scanner = (Scanner *)payload;
  // During error recovery the parser marks every external symbol valid,
  // including the never-emitted sentinel. Running the ordinary template
  // branch there would lex arbitrary code as string content and starve the
  // comment branch (comments adjacent to a syntax error would vanish into
  // the ERROR node), so recovery dispatches on the lookahead instead: a
  // comment where one can start, otherwise a delimiter-terminated string
  // body, which keeps a real string's text out of the recovered code.
  if (valid_symbols[ERROR_SENTINEL]) {
    // Neither a comment nor whitespace can start here, so this is either a
    // string body or code; only the former emits. Anything else falls
    // through to the shared comment tail below.
    if (lexer->lookahead != '/' && !is_whitespace(lexer->lookahead)) {
      return scan_templates(scanner, lexer, valid_symbols, true);
    }
  } else {
    if (valid_symbols[TEMPLATE_CHARS_DOUBLE] ||
        valid_symbols[TEMPLATE_CHARS_SINGLE] ||
        valid_symbols[TEMPLATE_CHARS_DOUBLE_SINGLE] ||
        valid_symbols[TEMPLATE_CHARS_SINGLE_SINGLE]) {
      return scan_templates(scanner, lexer, valid_symbols, false);
    }

    // Annotation open paren: only match '(' immediately (no whitespace).
    // This disambiguates @Foo(args) from @override (RecordType).
    if (valid_symbols[ANNOTATION_OPEN_PAREN] && lexer->lookahead == '(') {
      if (scanner->veto_annotation_paren &&
          lexer->get_column(lexer) == scanner->veto_column) {
        // A block comment separates this '(' from the annotation name; the
        // analyzer treats that trivia as ending the annotation. Emit the
        // paren as the record-type variant instead of declining: only an
        // emission serializes the cleared veto (so it cannot suppress a
        // later annotation at this column) and registers the column this
        // decision read (so an incremental re-indent re-lexes it).
        if (!valid_symbols[COMMENT_SEPARATED_OPEN_PAREN]) return false;
        clear_annotation_paren_veto(scanner);
        advance(lexer);
        lexer->mark_end(lexer);
        lexer->result_symbol = COMMENT_SEPARATED_OPEN_PAREN;
        return true;
      }
      clear_annotation_paren_veto(scanner);
      advance(lexer);
      lexer->mark_end(lexer);
      lexer->result_symbol = ANNOTATION_OPEN_PAREN;
      return true;
    }
  }

  while (is_whitespace(lexer->lookahead)) lexer->advance(lexer, true);

  if (lexer->lookahead == '/') {
    return scan_multiline_comments(scanner, lexer, valid_symbols);
  }
  return false;
}
