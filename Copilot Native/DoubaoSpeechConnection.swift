import Foundation
import zlib

struct SpeechUtterance: Decodable, Sendable {
    let text: String
    let start_time: Int?
    let end_time: Int?
    let definite: Bool?
}

struct SpeechRecognitionResult: Decodable, Sendable {
    let text: String?
    let utterances: [SpeechUtterance]?
}

/// A single ordered, optimized bidirectional ASR session. Audio is 16 kHz mono PCM16.
@MainActor
final class DoubaoSpeechConnection {
    static let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiver: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<SpeechRecognitionResult, Error>.Continuation?

    func open(key: String, hotwords: [String]) async throws -> AsyncThrowingStream<SpeechRecognitionResult, Error> {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SpeechError.message("请在语音设置中填写 API Key") }
        var request = URLRequest(url: Self.endpoint)
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue("volc.seedasr.sauc.duration", forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        self.session = session
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        let context = try JSONSerialization.data(withJSONObject: ["hotwords": hotwords.map { ["word": $0] }])
        let body: [String: Any] = [
            "user": ["uid": "copilot-native"],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
            "request": ["model_name": "bigmodel", "enable_itn": true, "enable_punc": true,
                        "show_utterances": true, "result_type": "full", "enable_nonstream": true,
                        "context": String(decoding: context, as: UTF8.self)]
        ]
        // Gzip framing is shared by initialization and audio, as required by the wire protocol.
        let timeout = Task {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
        }
        defer { timeout.cancel() }
        do {
            try await socket.send(.data(try Self.packet(JSONSerialization.data(withJSONObject: body), header: [0x11, 0x10, 0x11, 0])))
            let first = try Self.decode(try await socket.receive())
            let (events, continuation) = AsyncThrowingStream<SpeechRecognitionResult, Error>.makeStream(bufferingPolicy: .bufferingNewest(128))
            self.continuation = continuation
            if let result = first.result { continuation.yield(result) }
            receiver = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let response = try Self.decode(try await socket.receive())
                        if let result = response.result { continuation.yield(result) }
                        if response.isFinal { continuation.finish(); break }
                    }
                } catch {
                    if !Task.isCancelled { continuation.finish(throwing: error) }
                }
                self?.continuation = nil
            }
            return events
        } catch {
            let status = (socket.response as? HTTPURLResponse)?.statusCode
            close()
            if status == 401 || status == 403 {
                throw SpeechError.message("语音服务鉴权失败，请核对 API Key、所属项目和语音识别 2.0 的开通状态")
            }
            throw error
        }
    }

    func send(_ pcm: Data, final: Bool = false) async throws {
        guard let socket else { throw SpeechError.message("语音连接已关闭") }
        try await socket.send(.data(try Self.packet(pcm, header: [0x11, final ? 0x22 : 0x20, 0x01, 0])))
    }

    func close() {
        receiver?.cancel()
        receiver = nil
        continuation?.finish()
        continuation = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private static func packet(_ payload: Data, header: [UInt8]) throws -> Data {
        let compressed = try gzip(payload, decompress: false)
        var data = Data(header)
        var size = UInt32(compressed.count).bigEndian
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        data.append(compressed)
        return data
    }

    private static func decode(_ message: URLSessionWebSocketTask.Message) throws -> (result: SpeechRecognitionResult?, isFinal: Bool) {
        guard case .data(let data) = message, data.count >= 8 else { throw SpeechError.invalidPacket }
        let bytes = [UInt8](data)
        guard bytes[0] >> 4 == 1 else { throw SpeechError.invalidPacket }
        let kind = bytes[1] >> 4
        let flags = bytes[1] & 0x0f
        var offset = Int(bytes[0] & 0x0f) * 4
        func integer(at index: Int) throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw SpeechError.invalidPacket }
            return bytes[index..<index + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        var errorCode: UInt32?
        if kind == 0x0f { errorCode = try integer(at: offset); offset += 4 }
        else if flags & 1 != 0 { offset += 4 }
        let size = Int(try integer(at: offset))
        offset += 4
        guard size <= 8_000_000, offset + size <= data.count else { throw SpeechError.invalidPacket }
        var payload = data.subdata(in: offset..<offset + size)
        if bytes[2] & 0x0f == 1 { payload = try gzip(payload, decompress: true) }
        if let errorCode {
            throw SpeechError.service(Int(errorCode), String(decoding: payload, as: UTF8.self))
        }
        struct Envelope: Decodable { let result: SpeechRecognitionResult?; let code: Int?; let message: String? }
        let envelope = try JSONDecoder().decode(Envelope.self, from: payload)
        if let code = envelope.code, code != 0, code != 20_000_000 {
            throw SpeechError.service(code, envelope.message ?? "请求失败")
        }
        return (envelope.result, flags & 2 != 0)
    }

    private static func gzip(_ input: Data, decompress: Bool) throws -> Data {
        var stream = z_stream()
        let status = decompress
            ? inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            : deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw SpeechError.invalidPacket }
        defer { if decompress { inflateEnd(&stream) } else { deflateEnd(&stream) } }
        return try input.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 32_768)
            while true {
                let result = chunk.withUnsafeMutableBytes { buffer -> Int32 in
                    stream.next_out = buffer.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return decompress ? inflate(&stream, Z_NO_FLUSH) : deflate(&stream, Z_FINISH)
                }
                output.append(contentsOf: chunk.prefix(chunk.count - Int(stream.avail_out)))
                guard output.count <= 8_000_000 else { throw SpeechError.invalidPacket }
                if result == Z_STREAM_END { return output }
                guard result == Z_OK else { throw SpeechError.invalidPacket }
            }
        }
    }
}
