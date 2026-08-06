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
    use tree_sitter::{InputEdit, Node, Parser, Point, Tree};

    fn parser() -> Parser {
        let mut parser = Parser::new();
        parser
            .set_language(&super::LANGUAGE.into())
            .expect("Error loading Dart parser");
        parser
    }

    /// Named nodes that consume no input. Error recovery inserts MISSING
    /// tokens. When the missing token is a *hidden* rule (e.g. `_name`), the
    /// visible tree keeps a zero-width named node and `has_error()` stays
    /// false, so exit-code acceptance counts the parse as a success. Mirrors
    /// the invariant in tools/check_zero_width.mjs.
    fn zero_width_named_nodes(tree: &Tree) -> Vec<String> {
        fn walk(node: Node, out: &mut Vec<String>) {
            if node.is_named() && node.start_byte() == node.end_byte() && node.parent().is_some() {
                out.push(format!("{} at byte {}", node.kind(), node.start_byte()));
            }
            let mut cursor = node.walk();
            for child in node.children(&mut cursor) {
                walk(child, out);
            }
        }
        let mut out = Vec::new();
        walk(tree.root_node(), &mut out);
        out
    }

    #[test]
    fn test_can_load_grammar() {
        let mut parser = Parser::new();
        parser
            .set_language(&super::LANGUAGE.into())
            .expect("Error loading Dart parser");
    }

    /// A clean parse never contains a zero-width named node. Recovery can
    /// still produce one, as the ignored test below and the corpus pin
    /// "Known limitation: variance keyword with no name recovers to a
    /// zero-width name" show. This test guards the inputs that must stay
    /// clean.
    #[test]
    fn valid_code_has_no_zero_width_named_nodes() {
        for source in [
            "class C<in T> {}",
            "class D<out> {}",
            "@Foo(1) int g() => 1;",
            "var s = 'a$b';",
        ] {
            let tree = parser().parse(source, None).unwrap();
            assert!(!tree.root_node().has_error(), "{source} should parse clean");
            assert_eq!(
                zero_width_named_nodes(&tree),
                Vec::<String>::new(),
                "{source} -> {}",
                tree.root_node().to_sexp()
            );
        }
    }

    /// KNOWN LIMITATION (kept as a runnable repro: `cargo test -- --ignored`).
    ///
    /// `class C<in> {}` is invalid Dart — `in` is reserved, so it can only be
    /// the variance modifier, leaving the type parameter without a name. The
    /// parse is accepted silently: recovery supplies a MISSING *hidden*
    /// `_name`, which leaves a zero-width `type_identifier` behind and does
    /// not set `has_error()`. This is a general tree-sitter recovery property,
    /// not something this grammar can express away — `void f({}) {}` behaves
    /// the same — so tools/check_zero_width.mjs is what catches it in bulk.
    #[test]
    #[ignore = "known limitation: MISSING hidden token leaves a silent zero-width node"]
    fn variance_keyword_without_a_name_is_not_accepted_silently() {
        let tree = parser().parse("class C<in> {}", None).unwrap();
        assert_eq!(
            zero_width_named_nodes(&tree),
            Vec::<String>::new(),
            "tree: {}",
            tree.root_node().to_sexp()
        );
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
