import XCTest
import SwiftTreeSitter
import TreeSitterDart

final class TreeSitterDartTests: XCTestCase {
    func testCanLoadGrammar() throws {
        let parser = Parser()
        let language = Language(language: tree_sitter_dart())
        XCTAssertNoThrow(try parser.setLanguage(language),
                         "Error loading Dart grammar")
    }
}
