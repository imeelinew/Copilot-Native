import Foundation
import MLX
import MLXEmbedders

actor LocalKnowledgeEmbedding {
    static let modelID = "BAAI/bge-small-zh-v1.5@7999e1d3359715c523056ef9478215996d62a620/cls-v1"
    private static let revision = "7999e1d3359715c523056ef9478215996d62a620"
    private var container: MLXEmbedders.ModelContainer?

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard container == nil else { return }
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appending(path: "com.eli.CopilotNative/Embedding/bge-small-zh-v1.5-\(Self.revision)")
        let files = ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "vocab.txt"]
        for (index, name) in files.enumerated() {
            try Task.checkCancellation()
            let destination = root.appending(path: name)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let url = URL(string: "https://huggingface.co/BAAI/bge-small-zh-v1.5/resolve/\(Self.revision)/\(name)")!
                var request = URLRequest(url: url)
                request.timeoutInterval = 300
                let (temporary, response) = try await URLSession.shared.download(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw AIClientError.invalidResponse
                }
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            progress(Double(index + 1) / Double(files.count))
        }
        container = try await MLXEmbedders.loadModelContainer(configuration: .init(directory: root))
    }

    func embed(_ texts: [String], isQuery: Bool = false) async throws -> [[Float]] {
        guard let container else { throw AIClientError.invalidResponse }
        try Task.checkCancellation()
        let inputTexts = texts.map { isQuery ? "为这个句子生成表示以用于检索相关文章：" + $0 : $0 }
        let vectors = await container.perform { model, tokenizer, _ -> [[Float]] in
            let tokens = inputTexts.map { text -> [Int] in
                let encoded = tokenizer.encode(text: text, addSpecialTokens: true)
                guard encoded.count > 512 else { return encoded }
                return Array(encoded.prefix(511)) + [encoded.last ?? 102]
            }
            let length = tokens.map(\.count).max() ?? 1
            let padded = stacked(tokens.map {
                MLXArray($0 + Array(repeating: 0, count: length - $0.count))
            })
            let mask = padded .!= 0
            let output = model(padded, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: padded), attentionMask: mask)
            // BGE uses the raw CLS hidden state, not BERT's tanh pooler or mean pooling.
            let pooled = Pooling(strategy: .first)(output, mask: mask, normalize: true, applyLayerNorm: false)
            pooled.eval()
            return (0..<texts.count).map { pooled[$0].asArray(Float.self) }
        }
        try Task.checkCancellation()
        guard vectors.count == texts.count, vectors.allSatisfy({ $0.count == 512 && $0.allSatisfy(\.isFinite) }) else {
            throw AIClientError.invalidResponse
        }
        return vectors
    }
}
