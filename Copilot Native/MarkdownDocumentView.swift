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
        case .code(_, let content):
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal) {
                    Text(verbatim: content)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)) }
            }
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
