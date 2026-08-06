//! This crate provides Dart language support for the [tree-sitter] parsing library.
//!
//! Typically, you will use the [`LANGUAGE`] constant to add this language to a
//! tree-sitter [`Parser`], and then use the parser to parse some code:
//!
//! ```
//! let code = r#"
//! "#;
//! let mut parser = tree_sitter::Parser::new();
//! let language = tree_sitter_dart::LANGUAGE;
//! parser
//!     .set_language(&language.into())
//!     .expect("Error loading Dart parser");
//! let tree = parser.parse(code, None).unwrap();
//! assert!(!tree.root_node().has_error());
//! ```
//!
//! [`Parser`]: https://docs.rs/tree-sitter/0.25.4/tree_sitter/struct.Parser.html
//! [tree-sitter]: https://tree-sitter.github.io/

use tree_sitter_language::LanguageFn;

extern "C" {
    fn tree_sitter_dart() -> *const ();
}

/// The tree-sitter [`LanguageFn`] for this grammar.
pub const LANGUAGE: LanguageFn = unsafe { LanguageFn::from_raw(tree_sitter_dart) };

/// The content of the [`node-types.json`] file for this grammar.
///
/// [`node-types.json`]: https://tree-sitter.github.io/tree-sitter/using-parsers/6-static-node-types
pub const NODE_TYPES: &str = include_str!("../../src/node-types.json");

pub const HIGHLIGHTS_QUERY: &str = include_str!("../../queries/highlights.scm");
// pub const INJECTIONS_QUERY: &str = include_str!("../../queries/injections.scm");
pub const LOCALS_QUERY: &str = include_str!("../../queries/locals.scm");
pub const TAGS_QUERY: &str = include_str!("../../queries/tags.scm");

#[cfg(test)]
mod tests {
    use tree_sitter::{InputEdit, Parser, Point};

    fn parser() -> Parser {
        let mut parser = Parser::new();
        parser
            .set_language(&super::LANGUAGE.into())
            .expect("Error loading Dart parser");
        parser
    }

    #[test]
    fn test_can_load_grammar() {
        let mut parser = Parser::new();
        parser
            .set_language(&super::LANGUAGE.into())
            .expect("Error loading Dart parser");
    }

    /// KNOWN LIMITATION (kept as a runnable repro: `cargo test -- --ignored`).
    ///
    /// The annotation-paren veto compares `lexer.get_column()` on a scan that
    /// returns false. tree-sitter records a token's column dependency only for
    /// scans that emit, so the token produced under that decision is not
    /// invalidated when its column changes, and re-indenting the line holding
    /// a vetoed annotation reuses the old shape instead of re-lexing it.
    /// Same root cause as the corpus pin "Known limitation: a poisoned
    /// annotation-paren veto degrades every later annotation at that column":
    /// the veto can only be cleared by emitting an external token, and the
    /// vetoing scan emits nothing.
    #[test]
    #[ignore = "known limitation: annotation-paren veto is not cleared by a non-emitting scan"]
    fn reindenting_a_vetoed_annotation_reparses_like_a_fresh_parse() {
        let before = "@a/*c*/(int, int) f() => (1, 2);\n@bcdefg(1) int g() => 1;\n";
        let indent = "  ";
        let line_start = before.find('\n').expect("two lines") + 1;
        let after = format!("{}{}{}", &before[..line_start], indent, &before[line_start..]);

        let mut parser = parser();
        let mut tree = parser.parse(before, None).unwrap();
        tree.edit(&InputEdit {
            start_byte: line_start,
            old_end_byte: line_start,
            new_end_byte: line_start + indent.len(),
            start_position: Point::new(1, 0),
            old_end_position: Point::new(1, 0),
            new_end_position: Point::new(1, indent.len()),
        });

        let incremental = parser.parse(&after, Some(&tree)).unwrap();
        let fresh = parser.parse(&after, None).unwrap();
        assert_eq!(
            incremental.root_node().to_sexp(),
            fresh.root_node().to_sexp()
        );
    }
}
