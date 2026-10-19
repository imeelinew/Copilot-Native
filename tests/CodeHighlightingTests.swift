import Foundation
import SwiftUI

@main
struct CodeHighlightingTests {
    static func main() {
        let cases: [(String, String, String, CodeSyntaxHighlighter.Kind)] = [
            ("typescript", "const message = \"中文😀 // not a comment\"; // actual comment", "\"中文😀 // not a comment\"", .string),
            ("js", "// const 123\nlet value = 42;", "// const 123", .comment),
            ("python", "def solve(x):\n    # 中文注释\n    return \"#文字\"", "# 中文注释", .comment),
            ("swift", "let text = \"\"\"\nreturn // text\n\"\"\"", "\"\"\"\nreturn // text\n\"\"\"", .string),
            ("sql", "SELECT count(*) FROM users -- note", "SELECT", .type),
            ("tsx", "return <Button value={42} />;", "<Button", .tag),
            ("javascript", "const value = \"unfinished", "\"unfinished", .string),
            ("python", "number = 3.14\nvalue = 0xFF", "0xFF", .number)
        ]
        for (language, source, expected, kind) in cases {
            let tokens = CodeSyntaxHighlighter.tokens(source, language: language)
            precondition(tokens.contains { token in
                guard let range = Range(token.range, in: source) else { return false }
                return String(source[range]) == expected && token.kind == kind
            }, "Missing token in " + language)
            for dark in [false, true] {
                let highlighted = CodeSyntaxHighlighter.highlight(source, language: language, dark: dark)
                precondition(String(highlighted.characters) == source, "Highlighting changed code")
                precondition(highlighted.runs.contains { $0.foregroundColor != nil })
            }
        }
        precondition(CodeSyntaxHighlighter.tokens("return 42", language: "text").isEmpty)
        precondition(String(CodeSyntaxHighlighter.highlight("", language: "", dark: false).characters).isEmpty)
        let streaming = MarkdownBlocks.parse("```ts\nconst text = \"incomplete")
        precondition(streaming == [.code(language: "ts", content: "const text = \"incomplete")])
        print("PASS: lexical token precedence, Unicode, multiline/streaming code, language tags, light/dark colors, source preservation")
    }
}
