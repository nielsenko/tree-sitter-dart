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

    /// Invalid Dart is flagged by the library even where `tree-sitter parse`
    /// exits 0. The CLI's exit code reflects only VISIBLE ERROR and MISSING
    /// nodes, so a MISSING *hidden* token (`_name`) leaves it claiming
    /// success while `has_error()` is true. That CLI gap, not the grammar, is
    /// why the corpus gate cannot judge on the exit code alone. See
    /// tools/check_zero_width.mjs.
    #[test]
    fn invalid_code_is_flagged_as_an_error() {
        for source in ["class C<in> {}", "void f({}) {}", "var s = 'a$';"] {
            let tree = parser().parse(source, None).unwrap();
            assert!(
                tree.root_node().has_error(),
                "{source} should be flagged: {}",
                tree.root_node().to_sexp()
            );
        }
    }

    /// KNOWN LIMITATION (runnable repro: `cargo test -- --ignored`).
    ///
    /// `class C<in> {}` is invalid Dart. `in` is reserved, so it can only be
    /// the variance modifier, which leaves the type parameter without a name,
    /// and the analyzer calls it a syntax error. We flag it (asserted above).
    /// What remains is the SHAPE. Recovery supplies a MISSING hidden `_name`,
    /// leaving a zero-width `type_identifier` in the tree. That is general
    /// tree-sitter recovery behaviour rather than a grammar choice, and
    /// `void f({}) {}` does the same, so it is documented, not worked around.
    #[test]
    #[ignore = "known limitation: recovery leaves a zero-width node for a MISSING hidden token"]
    fn variance_keyword_without_a_name_leaves_no_zero_width_node() {
        let tree = parser().parse("class C<in> {}", None).unwrap();
        assert_eq!(
            zero_width_named_nodes(&tree),
            Vec::<String>::new(),
            "tree: {}",
            tree.root_node().to_sexp()
        );
    }

    /// tree-sitter records a token's column dependency only for scans that
    /// emit, so a vetoed annotation paren has to be emitted (as the
    /// record-type variant) rather than declined - otherwise re-indenting
    /// the line changes the column the veto compared against without
    /// invalidating the reused subtree, and the incremental tree disagrees
    /// with a fresh parse of the same buffer.
    #[test]
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
