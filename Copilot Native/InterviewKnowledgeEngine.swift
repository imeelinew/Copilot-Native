import Foundation
import NaturalLanguage
import SwiftData

struct KnowledgeIndexStatus: Sendable {
    let passageCount: Int
    let projectCount: Int
    let staleCount: Int
    let vectorCount: Int
}

actor InterviewKnowledgeEngine {
    static let shared = InterviewKnowledgeEngine()
    private var store: SwiftData.ModelContainer?
    private var context: ModelContext?
    private var passages: [KnowledgePassage] = []
    private var vectors: [String: [Float]] = [:]
    private var termCounts: [String: [String: Int]] = [:]
    private var documentFrequency: [String: Int] = [:]
    private var averageDocumentLength = 1.0
    private var staleCount = 0
    private var semanticReady = false
    private var preparingVectors = false
    private let embedder = LocalKnowledgeEmbedding()

    private struct FactDocument: Decodable { let facts: [Fact] }
    private struct Fact: Decodable {
        let id: String
        let projectID: String
        let title: String
        let keywords: [String]
        let content: String
        let boundary: String
        let sources: [KnowledgeSource]

        enum CodingKeys: String, CodingKey {
            case id, title, keywords, content, boundary, sources
            case projectID = "project_id"
        }

        var passage: KnowledgePassage {
            .init(id: id, projectID: projectID, title: title, keywords: keywords,
                  content: content, boundary: boundary, sources: sources)
        }
    }

    private var home: URL { URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory) }
    private var factsURL: URL { home.appending(path: "Resumes/AI面试知识库/项目事实.json") }
    private let generalNames = [
        "01.css.md", "02.html.md", "03.Html5.md", "04.js.md", "05.git.md", "06.vue.md",
        "07.vue3.md", "08.webpack.md", "09.react1.0.md", "10.react2.0.md", "11.浏览器.md", "React diff.md"
    ]

    func load() throws -> KnowledgeIndexStatus {
        guard !preparingVectors else { return status() }
        if context == nil {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appending(path: "com.eli.CopilotNative")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let schema = Schema([InterviewKnowledgeRecord.self])
            let configuration = ModelConfiguration("InterviewKnowledge", schema: schema,
                url: support.appending(path: "InterviewKnowledge.store"))
            let container = try SwiftData.ModelContainer(for: schema, configurations: configuration)
            store = container
            context = ModelContext(container)
        }
        guard let context else { throw AIClientError.invalidResponse }
        let document = try JSONDecoder().decode(FactDocument.self, from: Data(contentsOf: factsURL))
        var freshPassages: [KnowledgePassage] = []
        var hashes: [String: String] = [:]
        staleCount = 0
        for fact in document.facts {
            guard ["mobile-shop", "datapilot-rebuild"].contains(fact.projectID), !fact.sources.isEmpty else { continue }
            let valid = fact.sources.allSatisfy { source in
                guard isProjectSource(source, projectID: fact.projectID) else { return false }
                if hashes[source.path] == nil {
                    hashes[source.path] = (try? Data(contentsOf: URL(filePath: source.path))).map(KnowledgeDigest.hash) ?? "missing"
                }
                return hashes[source.path] == source.sha256
            }
            if valid { freshPassages.append(fact.passage) } else { staleCount += 1 }
        }

        let generalRoot = home.appending(path: "Resumes/前端面试题2025")
        for name in generalNames {
            let url = generalRoot.appending(path: name)
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { continue }
            freshPassages += splitGeneralDocument(text, url: url, hash: KnowledgeDigest.hash(data))
        }

        let records = try context.fetch(FetchDescriptor<InterviewKnowledgeRecord>())
        var existing = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let freshIDs = Set(freshPassages.map(\.id))
        for record in records where !freshIDs.contains(record.id) { context.delete(record) }
        vectors = [:]
        for passage in freshPassages {
            if let record = existing[passage.id] {
                if record.fingerprint != passage.fingerprint {
                    record.passageData = try JSONEncoder().encode(passage)
                    record.fingerprint = passage.fingerprint
                    record.vectorData = nil
                    record.vectorModel = nil
                }
                if record.vectorModel == LocalKnowledgeEmbedding.modelID, let data = record.vectorData,
                   let vector = try? JSONDecoder().decode([Float].self, from: data),
                   vector.count == 512, vector.allSatisfy(\.isFinite) {
                    vectors[record.id] = vector
                }
            } else {
                let record = try InterviewKnowledgeRecord(passage: passage)
                context.insert(record)
                existing[passage.id] = record
            }
        }
        try context.save()
        passages = freshPassages
        rebuildLexicalIndex()
        return status()
    }

    func prepareVectors(progress: @escaping @Sendable (String) -> Void) async throws -> KnowledgeIndexStatus {
        guard !preparingVectors else { return status() }
        preparingVectors = true
        defer { preparingVectors = false }
        progress("正在准备本地中文检索模型…")
        try await embedder.prepare { fraction in
            progress("正在准备本地模型 \(Int(fraction * 100))%…")
        }
        semanticReady = true
        let missing = passages.filter { vectors[$0.id] == nil }
        guard let context else { return status() }
        let records = try context.fetch(FetchDescriptor<InterviewKnowledgeRecord>())
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for offset in stride(from: 0, to: missing.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(missing[offset..<min(offset + 4, missing.count)])
            let computed = try await embedder.embed(batch.map(\.embeddingText))
            for (passage, vector) in zip(batch, computed) {
                guard let record = byID[passage.id], record.fingerprint == passage.fingerprint else { continue }
                record.vectorData = try JSONEncoder().encode(vector)
                record.vectorModel = LocalKnowledgeEmbedding.modelID
                vectors[passage.id] = vector
            }
            try context.save()
            progress("正在建立向量索引 \(min(offset + 4, missing.count))/\(missing.count)…")
        }
        return status()
    }

    func retrieve(question: String, scope: InterviewProjectScope, previousProject: String?, previousQuestion: String?) async throws -> KnowledgeRetrieval {
        try Task.checkCancellation()
        if passages.isEmpty { _ = try load() }
        let lower = question.lowercased()
        var projects: [String] = []
        if scope != .general {
            if lower.contains("两个项目") || lower.contains("这两个") { projects = ["mobile-shop", "datapilot-rebuild"] }
            if lower.contains("轻购") || lower.contains("mobile-shop") { projects.append("mobile-shop") }
            if lower.contains("城市视图") || lower.contains("datapilot") { projects.append("datapilot-rebuild") }
            if projects.isEmpty, let selected = scope.projectID { projects = [selected] }
            if projects.isEmpty, let previousProject, isFollowUp(lower) { projects = [previousProject] }
        }
        projects = Array(Set(projects)).sorted()
        let projectQuestion = scope != .general && (!projects.isEmpty || ["项目", "你做", "你用", "你负责"].contains(where: lower.contains))
        // Broad introductions need their overview; relevance ranking alone would omit it.
        let overviewQuestion = ["介绍", "整体", "架构", "技术栈"].contains(where: lower.contains)
        let followUp: String?
        if let previousProject, isFollowUp(lower), projects == [previousProject] {
            followUp = previousQuestion
        } else { followUp = nil }
        let retrievalQuestion = followUp.map { $0 + "。追问：" + question } ?? question
        let queryTerms = tokenize(retrievalQuestion)
        var candidates = passages.filter { passage in
            if scope == .general { return passage.projectID == nil }
            if let project = passage.projectID { return projects.isEmpty ? projectQuestion : projects.contains(project) }
            return true
        }
        // Re-check evidence on each request so an edited/deleted implementation cannot be reused.
        var sourceHashes: [String: String] = [:]
        var invalidIDs = Set<String>()
        candidates = candidates.filter { passage in
            guard let project = passage.projectID else { return true }
            let valid = passage.sources.allSatisfy { source in
                guard isProjectSource(source, projectID: project) else { return false }
                if sourceHashes[source.path] == nil {
                    sourceHashes[source.path] = (try? Data(contentsOf: URL(filePath: source.path))).map(KnowledgeDigest.hash) ?? "missing"
                }
                return sourceHashes[source.path] == source.sha256
            }
            if !valid { invalidIDs.insert(passage.id) }
            return valid
        }
        let lexical = candidates.map { passage -> (KnowledgePassage, Double) in
            var score = lexicalScore(queryTerms, passage: passage)
            for keyword in passage.keywords where lower.contains(keyword.lowercased()) { score += 2.5 }
            if overviewQuestion && !projects.isEmpty && ["QG-01", "CITY-01"].contains(passage.id) { score += 6 }
            return (passage, score)
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }

        var semantic: [(KnowledgePassage, Double)] = []
        var semanticWarning: String?
        if semanticReady, !vectors.isEmpty {
            do {
                let queryVector = try await embedder.embed([retrievalQuestion], isQuery: true)[0]
                try Task.checkCancellation()
                semantic = candidates.compactMap { passage in
                    guard let vector = vectors[passage.id], vector.count == queryVector.count else { return nil }
                    let cosine = zip(vector, queryVector).reduce(Float.zero) { $0 + $1.0 * $1.1 }
                    return cosine >= 0.5 ? (passage, Double(cosine)) : nil
                }.sorted { $0.1 > $1.1 }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                semanticWarning = "本次向量检索不可用，已使用关键词检索"
            }
        }
        var fused: [String: Double] = [:]
        for (rank, item) in lexical.prefix(24).enumerated() { fused[item.0.id, default: 0] += 1 / Double(30 + rank) }
        for (rank, item) in semantic.prefix(24).enumerated() { fused[item.0.id, default: 0] += 1 / Double(30 + rank) }
        var ordered = candidates.filter { fused[$0.id] != nil }.sorted {
            let first = (fused[$0.id] ?? 0) * (projectQuestion && $0.projectID != nil ? 1.6 : 1)
            let second = (fused[$1.id] ?? 0) * (projectQuestion && $1.projectID != nil ? 1.6 : 1)
            return first == second ? $0.id < $1.id : first > second
        }
        // Keep closely related implementation steps together instead of extrapolating from one fragment.
        let relatedGroups = [["QG-02", "QG-03"], ["QG-05", "QG-06"], ["QG-08", "QG-09"],
                             ["QG-10", "QG-11"], ["CITY-07", "CITY-08"], ["CITY-09", "CITY-10"]]
        let leadingIDs = Set(ordered.prefix(2).map(\.id))
        let neighbors = relatedGroups.filter { $0.contains(where: leadingIDs.contains) }.flatMap { $0 }
        let forced = candidates.filter { passage in
            neighbors.contains(passage.id) || (overviewQuestion && projects.contains(passage.projectID ?? "") && ["QG-01", "CITY-01"].contains(passage.id))
        }
        let forcedIDs = Set(forced.map(\.id))
        ordered = forced + ordered.filter { !forcedIDs.contains($0.id) }
        var selected: [KnowledgePassage] = []
        var characters = 0
        for passage in ordered {
            if passage.projectID == nil && projectQuestion && selected.filter({ $0.projectID == nil }).count >= 2 { continue }
            let size = passage.content.count + passage.boundary.count
            if characters + size > 4800 || selected.count >= 8 { continue }
            selected.append(passage)
            characters += size
        }
        if projects.isEmpty, projectQuestion {
            let matchedProjects = Set(selected.compactMap(\.projectID))
            if matchedProjects.count == 1 { projects = Array(matchedProjects) }
        }
        var warnings: [String] = []
        if let semanticWarning { warnings.append(semanticWarning) }
        if staleCount + invalidIDs.count > 0 { warnings.append("部分项目依据已变化或无法读取，已排除") }
        if projectQuestion && selected.allSatisfy({ $0.projectID == nil }) { warnings.append("没有找到与问题相关的当前项目证据") }
        return .init(passages: selected, projectIDs: projects, usedVectors: !semantic.isEmpty,
                     warning: warnings.isEmpty ? nil : warnings.joined(separator: "；"), previousQuestion: followUp)
    }

    private func status() -> KnowledgeIndexStatus {
        .init(passageCount: passages.count, projectCount: passages.filter { $0.projectID != nil }.count,
              staleCount: staleCount, vectorCount: vectors.count)
    }

    private func isProjectSource(_ source: KnowledgeSource, projectID: String) -> Bool {
        let root = home.appending(path: "Dev/\(projectID)").resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let path = URL(filePath: source.path).resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(root) && !path.components(separatedBy: "/").contains(where: { $0.hasPrefix(".env") })
    }

    private func splitGeneralDocument(_ text: String, url: URL, hash: String) -> [KnowledgePassage] {
        var sections: [(String, Int, [String])] = []
        var title = url.deletingPathExtension().lastPathComponent
        var lineNumber = 1
        var body: [String] = []
        var insideCode = false
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { insideCode.toggle() }
            if !insideCode && line.hasPrefix("## ") {
                sections.append((title, lineNumber, body))
                title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                lineNumber = index + 1
                body = []
            } else { body.append(line) }
        }
        sections.append((title, lineNumber, body))
        var output: [KnowledgePassage] = []
        for (title, line, lines) in sections where title != "目录" {
            let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard content.count >= 30 else { continue }
            // Keep code fences intact by splitting on paragraphs before the hard length bound.
            var parts: [String] = []
            var current = ""
            for paragraph in content.components(separatedBy: "\n\n") {
                if current.count + paragraph.count > 700 && !current.isEmpty { parts.append(current); current = "" }
                current += (current.isEmpty ? "" : "\n\n") + paragraph
            }
            if !current.isEmpty { parts.append(current) }
            for (index, part) in parts.enumerated() {
                // Oversized code/example sections are references, not entire source dumps.
                let excerpt = String(part.prefix(900))
                let id = "GENERAL-" + KnowledgeDigest.hash(Data((url.path + title + String(line) + String(index)).utf8)).prefix(20)
                output.append(.init(id: String(id), projectID: nil, title: title, keywords: [title], content: excerpt,
                    boundary: "通用题库可能包含旧版本或示例经历，仅用于原理参考；不得当成这两个项目的实现或个人经历。",
                    sources: [.init(path: url.path, line: line, anchor: title, sha256: hash)]))
            }
        }
        return output
    }

    private func tokenize(_ text: String) -> [String] {
        let lower = text.lowercased()
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = lower
        var terms: [String] = []
        let stop = Set(["的", "了", "是", "我", "你", "怎么", "如何", "什么", "一个", "这个", "项目", "中", "和", "在", "吗", "为什么", "有", "the", "a", "is"])
        tokenizer.enumerateTokens(in: lower.startIndex..<lower.endIndex) { range, _ in
            let token = String(lower[range])
            if token.count > 1 && !stop.contains(token) { terms.append(token) }
            return true
        }
        // Chinese bigrams preserve matches for domain words that the system tokenizer splits differently.
        var run: [Character] = []
        for character in lower + " " {
            if character.unicodeScalars.allSatisfy({ (0x4E00...0x9FFF).contains(Int($0.value)) }) {
                run.append(character)
            } else {
                if run.count >= 2 {
                    for index in 0..<(run.count - 1) {
                        let pair = String(run[index...index + 1])
                        if !stop.contains(pair) { terms.append(pair) }
                    }
                }
                run = []
            }
        }
        return terms
    }

    private func rebuildLexicalIndex() {
        termCounts = [:]
        documentFrequency = [:]
        for passage in passages {
            var counts: [String: Int] = [:]
            for term in tokenize(passage.searchText) { counts[term, default: 0] += 1 }
            termCounts[passage.id] = counts
            for term in counts.keys { documentFrequency[term, default: 0] += 1 }
        }
        averageDocumentLength = Double(termCounts.values.reduce(0) { $0 + $1.values.reduce(0, +) }) / Double(max(passages.count, 1))
    }

    private func lexicalScore(_ queryTerms: [String], passage: KnowledgePassage) -> Double {
        guard let counts = termCounts[passage.id] else { return 0 }
        let length = Double(counts.values.reduce(0, +))
        let average = averageDocumentLength
        return Set(queryTerms).reduce(0) { score, term in
            let tf = Double(counts[term] ?? 0)
            guard tf > 0 else { return score }
            let df = Double(documentFrequency[term] ?? 0)
            let idf = log(1 + (Double(passages.count) - df + 0.5) / (df + 0.5))
            return score + idf * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * length / max(average, 1)))
        }
    }

    private func isFollowUp(_ question: String) -> Bool {
        ["那", "这个", "这里", "它", "为什么这样", "怎么实现", "还有", "继续", "展开", "改进", "不足"].contains(where: question.hasPrefix)
    }
}
