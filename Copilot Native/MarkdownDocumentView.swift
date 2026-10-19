import SwiftUI

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet([String])
    case numbered([String])
    case code(language: String, content: String)
    case table(MarkdownTable)
}

struct MarkdownTable: Equatable {
    let headers: [String]
    let alignments: [MarkdownTableAlignment]
    let rows: [[String]]
}

enum MarkdownTableAlignment: Equatable {
    case leading
    case center
    case trailing

    var swiftUIAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

enum MarkdownBlocks {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var position = 0

        while position < lines.count {
            let line = lines[position]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                position += 1
                continue
            }
            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                position += 1
                var code: [String] = []
                while position < lines.count, !lines[position].hasPrefix("```") {
                    code.append(lines[position])
                    position += 1
                }
                if position < lines.count { position += 1 }
                blocks.append(.code(language: language, content: code.joined(separator: "\n")))
                continue
            }
            if let (table, nextPosition) = table(startingAt: position, in: lines) {
                blocks.append(.table(table))
                position = nextPosition
                continue
            }
            if let heading = heading(from: line) {
                blocks.append(heading)
                position += 1
                continue
            }
            if let first = bulletText(line) {
                var values = [first]
                position += 1
                while position < lines.count, let value = bulletText(lines[position]) {
                    values.append(value)
                    position += 1
                }
                blocks.append(.bullet(values))
                continue
            }
            if let first = numberedText(line) {
                var values = [first]
                position += 1
                while position < lines.count, let value = numberedText(lines[position]) {
                    values.append(value)
                    position += 1
                }
                blocks.append(.numbered(values))
                continue
            }
            var paragraph = [line]
            position += 1
            while position < lines.count {
                let next = lines[position]
                if next.trimmingCharacters(in: .whitespaces).isEmpty
                    || next.hasPrefix("```")
                    || heading(from: next) != nil
                    || bulletText(next) != nil
                    || numberedText(next) != nil
                    || table(startingAt: position, in: lines) != nil { break }
                paragraph.append(next)
                position += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }
        return blocks
    }

    private static func heading(from line: String) -> MarkdownBlock? {
        let marks = line.prefix { $0 == "#" }.count
        guard (1...6).contains(marks), line.dropFirst(marks).first == " " else { return nil }
        return .heading(level: marks, text: String(line.dropFirst(marks + 1)))
    }

    private static func bulletText(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return nil }
        return String(trimmed.dropFirst(2))
    }

    private static func numberedText(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, trimmed.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return String(trimmed.dropFirst(digits.count + 2))
    }

    private static func table(startingAt start: Int, in lines: [String]) -> (MarkdownTable, Int)? {
        guard start + 1 < lines.count,
              let headers = pipeCells(lines[start]),
              let separators = pipeCells(lines[start + 1]),
              !headers.isEmpty,
              headers.count == separators.count else { return nil }

        let parsedAlignments = separators.map(tableAlignment)
        guard parsedAlignments.allSatisfy({ $0 != nil }) else { return nil }

        var rows: [[String]] = []
        var position = start + 2
        while position < lines.count,
              !lines[position].trimmingCharacters(in: .whitespaces).isEmpty,
              let cells = pipeCells(lines[position]) {
            let normalized = Array(cells.prefix(headers.count))
                + Array(repeating: "", count: max(0, headers.count - cells.count))
            rows.append(normalized)
            position += 1
        }
        return (MarkdownTable(headers: headers, alignments: parsedAlignments.compactMap { $0 }, rows: rows), position)
    }

    private static func tableAlignment(_ marker: String) -> MarkdownTableAlignment? {
        let marker = marker.trimmingCharacters(in: .whitespaces)
        let left = marker.hasPrefix(":")
        let right = marker.hasSuffix(":")
        let dashes = marker.dropFirst(left ? 1 : 0).dropLast(right ? 1 : 0)
        guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
        if left && right { return .center }
        if right { return .trailing }
        return .leading
    }

    private static func pipeCells(_ line: String) -> [String]? {
        var cells: [String] = []
        var current = ""
        var isEscaping = false
        var hasPipe = false
        var lastWasPipe = false

        for character in line {
            if isEscaping {
                if character != "|" { current.append("\\") }
                current.append(character)
                isEscaping = false
                lastWasPipe = false
            } else if character == "\\" {
                isEscaping = true
            } else if character == "|" {
                hasPipe = true
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                lastWasPipe = true
            } else {
                current.append(character)
                if !character.isWhitespace { lastWasPipe = false }
            }
        }
        if isEscaping { current.append("\\") }
        guard hasPipe else { return nil }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") { cells.removeFirst() }
        if lastWasPipe, cells.last == "" { cells.removeLast() }
        return cells
    }
}

struct MarkdownDocumentView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(MarkdownBlocks.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        case .paragraph(let text):
            inline(text)
                .font(.body)
                .lineSpacing(4)
        case .bullet(let values):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•").foregroundStyle(.secondary)
                        inline(value)
                    }
                }
            }
        case .numbered(let values):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1).").foregroundStyle(.secondary)
                        inline(value)
                    }
                }
            }
        case .code(let language, let content):
            HighlightedCodeBlock(language: language, content: content).equatable()
        case .table(let table):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(table.headers.indices, id: \.self) { column in
                            tableCell(table.headers[column], alignment: table.alignments[column], isHeader: true)
                        }
                    }
                    .background(Color.primary.opacity(0.07))

                    ForEach(table.rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(table.rows[row].indices, id: \.self) { column in
                                tableCell(table.rows[row][column], alignment: table.alignments[column], isHeader: false)
                            }
                        }
                        .background(row.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)) }
            }
        }
    }

    private func tableCell(_ content: String, alignment: MarkdownTableAlignment, isHeader: Bool) -> some View {
        inline(content)
            .font(isHeader ? .body.weight(.semibold) : .body)
            .frame(minWidth: 130, maxWidth: 320, alignment: alignment.swiftUIAlignment)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Color.primary.opacity(0.1).frame(height: 1) }
    }

    private func inline(_ source: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(verbatim: source)
    }
}

private struct HighlightedCodeBlock: View, Equatable {
    let language: String
    let content: String
    @Environment(\.colorScheme) private var colorScheme

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.language == rhs.language && lhs.content == rhs.content
    }

    var body: some View {
        ScrollView(.horizontal) {
            Text(CodeSyntaxHighlighter.highlight(content, language: language, dark: colorScheme == .dark))
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .textSelection(.enabled)
        }
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)) }
    }
}

/// Lightweight lexical highlighting. All ranges refer to the original source,
/// including incomplete code fences while an answer is streaming.
enum CodeSyntaxHighlighter {
    enum Kind: String { case comment, string, number, keyword, type, function, tag }
    struct Token { let range: NSRange; let kind: Kind }

    private static let keywords = Set("""
    as async await break case catch class const continue debugger default defer def del do elif else enum except export extends extension fallthrough false False finally fn for from func function go guard if impl import in init instanceof interface is lambda let match mut namespace new nil None nonlocal not null of operator or override package pass private protected protocol public raise ref repeat return select self Self static struct super switch synchronized this throw throws trait true True try type typealias typeof undefined var void volatile when where while with yield abstract actor any assert associatedtype auto boolean byte char double dynamic final float get global implements inline int internal lazy long nonisolated open optional out readonly required rethrows set short signed some throws transient typealias unsigned using val virtual weak and then fi done echo local esac export sizeof typedef union include define pragma end unless until rescue ensure module require attr_reader
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    private static let builtins = Set("""
    Array Boolean Data Date Dictionary Double Error Float Int JSON Map Math Number Object Optional Promise Record Result Set String URL URLSession UUID Void abort console document window print println len range enumerate zip map filter reduce sorted sum max min list dict tuple str bool bytes object super type isinstance input open setTimeout clearTimeout fetch useState useEffect useRef useMemo useCallback SELECT FROM WHERE JOIN LEFT RIGHT INNER OUTER ON AS INSERT INTO VALUES UPDATE DELETE CREATE TABLE DROP ALTER GROUP BY ORDER HAVING LIMIT OFFSET DISTINCT AND OR NOT NULL IS IN LIKE BETWEEN EXISTS UNION ALL ASC DESC COUNT SUM AVG MIN MAX CASE WHEN THEN ELSE END TRUE FALSE select from where join left right inner outer on insert into values update delete create table drop alter group by order having limit offset distinct like between exists union all asc desc count avg
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init))

    static func tokens(_ source: String, language: String) -> [Token] {
        let language = language.lowercased().split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        if ["text", "txt", "plaintext", "plain", "output"].contains(language) { return [] }
        let hashComments = ["python", "py", "bash", "sh", "shell", "zsh", "ruby", "rb", "yaml", "yml", "toml", "r", "powershell", "ps1"].contains(language)
            || (language.isEmpty && source.range(of: #"(?m)^\s*(def |from |import |#!)"#, options: .regularExpression) != nil)
        let sql = ["sql", "postgresql", "mysql", "sqlite"].contains(language)
        let markup = ["html", "xml", "svg", "vue", "jsx", "tsx"].contains(language)
        let comments = #"/\*[\s\S]*?(?:\*/|\z)|<!--[\s\S]*?(?:-->|\z)"#
            + (hashComments ? #"|#[^\r\n]*"# : sql ? #"|--[^\r\n]*"# : #"|//[^\r\n]*"#)
        let strings = #"\"\"\"[\s\S]*?(?:\"\"\"|\z)|'''[\s\S]*?(?:'''|\z)|\"(?:\\[\s\S]|[^\"\\])*(?:\"|\z)|'(?:\\[\s\S]|[^'\\])*(?:'|\z)|`(?:\\[\s\S]|[^`\\])*(?:`|\z)"#
        let pattern = "(?<comment>" + comments + ")|(?<string>" + strings + ")"
            + (markup ? #"|(?<tag></?[A-Za-z][\w:-]*|/?>)"# : "")
            + #"|(?<number>\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)(?:[nLfF])?\b)|(?<identifier>[\p{L}_$][\p{L}\p{N}_$]*)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            for kind in [Kind.comment, .string, .number, .tag] {
                let range = match.range(withName: kind.rawValue)
                if range.location != NSNotFound { return Token(range: range, kind: kind) }
            }
            let range = match.range(withName: "identifier")
            guard let swiftRange = Range(range, in: source) else { return nil }
            let word = String(source[swiftRange])
            if keywords.contains(word) { return Token(range: range, kind: .keyword) }
            if builtins.contains(word) || word.first?.isUppercase == true { return Token(range: range, kind: .type) }
            if source[swiftRange.upperBound...].first(where: { !$0.isWhitespace }) == "(" {
                return Token(range: range, kind: .function)
            }
            return nil
        }
    }

    static func highlight(_ source: String, language: String, dark: Bool) -> AttributedString {
        var result = AttributedString(source)
        for token in tokens(source, language: language) {
            guard let range = Range(token.range, in: source),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result) else { continue }
            let color: Color
            switch token.kind {
            case .comment: color = dark ? Color(red: 0.57, green: 0.65, blue: 0.56) : Color(red: 0.34, green: 0.43, blue: 0.34)
            case .string: color = dark ? Color(red: 0.96, green: 0.65, blue: 0.55) : Color(red: 0.66, green: 0.15, blue: 0.15)
            case .number: color = dark ? Color(red: 0.70, green: 0.83, blue: 0.59) : Color(red: 0.10, green: 0.43, blue: 0.31)
            case .keyword, .tag: color = dark ? Color(red: 0.81, green: 0.60, blue: 0.94) : Color(red: 0.58, green: 0.16, blue: 0.62)
            case .type: color = dark ? Color(red: 0.40, green: 0.80, blue: 0.85) : Color(red: 0.05, green: 0.38, blue: 0.55)
            case .function: color = dark ? Color(red: 0.92, green: 0.82, blue: 0.55) : Color(red: 0.46, green: 0.32, blue: 0.05)
            }
            result[start..<end].foregroundColor = color
        }
        return result
    }
}
