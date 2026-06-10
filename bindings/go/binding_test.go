package tree_sitter_dart_test

import (
	"testing"

	tree_sitter "github.com/tree-sitter/go-tree-sitter"
	tree_sitter_dart "github.com/tree-sitter/tree-sitter-dart/bindings/go"
)

func TestCanLoadGrammar(t *testing.T) {
	language := tree_sitter.NewLanguage(tree_sitter_dart.Language())
	if language == nil {
		t.Errorf("Error loading Dart grammar")
	}
	parser := tree_sitter.NewParser()
	defer parser.Close()
	if err := parser.SetLanguage(language); err != nil {
		t.Fatalf("Error setting language (ABI mismatch?): %v", err)
	}
	tree := parser.Parse([]byte("class A {}"), nil)
	defer tree.Close()
	if tree.RootNode().HasError() {
		t.Errorf("Error parsing Dart source")
	}
}
