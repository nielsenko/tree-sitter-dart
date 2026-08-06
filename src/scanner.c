#include "tree_sitter/parser.h"

enum TokenType {
  TEMPLATE_CHARS_SINGLE,
  TEMPLATE_CHARS_DOUBLE,
  TEMPLATE_CHARS_SINGLE_SINGLE,
  TEMPLATE_CHARS_DOUBLE_SINGLE,
  TEMPLATE_CHARS_RAW_SLASH,
  BLOCK_COMMENT,
  DOCUMENTATION_BLOCK_COMMENT,
  ANNOTATION_OPEN_PAREN,
  // Never emitted: valid only while the parser is in error recovery
  // (recovery marks every symbol valid), so testing it alone detects
  // recovery exactly. Must stay last in the grammar's externals list.
  ERROR_SENTINEL,
};

void *tree_sitter_dart_external_scanner_create() { return NULL; }
void tree_sitter_dart_external_scanner_destroy(void *p) { (void)p; }
void tree_sitter_dart_external_scanner_reset(void *p) { (void)p; }
unsigned tree_sitter_dart_external_scanner_serialize(void *p, char *buffer) { (void)p; (void)buffer; return 0; }
void tree_sitter_dart_external_scanner_deserialize(void *p, const char *b, unsigned n) { (void)p; (void)b; (void)n; }

static void advance(TSLexer *lexer) { lexer->advance(lexer, false); }

// Explicit ASCII whitespace instead of iswspace: wint_t is 16 bits on
// Windows, so supplementary-plane lookahead truncates (U+10020 -> 0x0020)
// and would be silently skipped. ASCII is the whole set anyway - Dart's
// WHITESPACE production is ASCII-only, and so is the grammar's /\s/ extra.
static bool is_whitespace(int32_t c) {
  return c == ' ' || (c >= '\t' && c <= '\r');
}


static bool scan_multiline_comments(TSLexer *lexer) {

    bool documentation_comment = false;
    advance(lexer);
    if (lexer->lookahead != '*') return false;
    advance(lexer);
    if (lexer->lookahead == '*') documentation_comment = true;

    bool after_star = false;
    unsigned nesting_depth = 1;
    for (;;) {
      switch (lexer->lookahead) {
        case '\0':
          // '\0' is also a valid content character; only stop at real EOF.
          if (lexer->eof(lexer)) return false;
          advance(lexer);
          after_star = false;
          break;
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
        default:
          advance(lexer);
          after_star = false;
          break;
      }
    }
  return false;
}


// `recovery` scans a string body reached while the parser is in error
// recovery, where valid_symbols says nothing (every symbol is valid). Such a
// run only counts as string content when it ends at a delimiter on the same
// line; a run that reaches a line terminator or EOF is ordinary code after a
// syntax error and must not be swallowed as template chars.
static bool scan_templates(TSLexer *lexer, const bool *valid_symbols,
                           bool recovery) {
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
      case '\0':
        // '\0' is also a valid content character; only stop at real EOF.
        if (lexer->eof(lexer)) return false;
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
      default:
        advance(lexer);
    }
  }
  return true;
}



bool tree_sitter_dart_external_scanner_scan(void *payload, TSLexer *lexer,
                                                  const bool *valid_symbols) {
  (void)payload;
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
      return scan_templates(lexer, valid_symbols, true);
    }
  } else {
    if (valid_symbols[TEMPLATE_CHARS_DOUBLE] ||
        valid_symbols[TEMPLATE_CHARS_SINGLE] ||
        valid_symbols[TEMPLATE_CHARS_DOUBLE_SINGLE] ||
        valid_symbols[TEMPLATE_CHARS_SINGLE_SINGLE]) {
      return scan_templates(lexer, valid_symbols, false);
    }

    // Annotation open paren: only match '(' immediately (no whitespace).
    // This disambiguates @Foo(args) from @override (RecordType).
    if (valid_symbols[ANNOTATION_OPEN_PAREN] && lexer->lookahead == '(') {
      advance(lexer);
      lexer->mark_end(lexer);
      lexer->result_symbol = ANNOTATION_OPEN_PAREN;
      return true;
    }
  }

  while (is_whitespace(lexer->lookahead)) lexer->advance(lexer, true);

  if (lexer->lookahead == '/') {
    return scan_multiline_comments(lexer);
  }
  return false;
}
