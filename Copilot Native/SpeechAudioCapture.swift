@preconcurrency import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

struct SpeechAudioFrame: Sendable {
    let pcm: Data
    let level: Float
}

struct SpeechApplicationOption: Identifiable {
    let id: String
    let name: String
}

enum SpeechAudioSource: String, CaseIterable, Identifiable {
    case system, microphone
    var id: String { rawValue }
    var title: String { self == .system ? "会议 / 系统声音" : "麦克风" }
}

/// The encoder is called by AVAudioEngine's tap or ScreenCaptureKit's serial audio queue.
/// Its lock also serializes termination against the last audio callback.
private final class SpeechPCMEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<SpeechAudioFrame, Error>.Continuation
    private var converter: AVAudioConverter?
    private var pending = Data()
    private var finished = false
    private var lastPacketAt = Date()
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init(_ continuation: AsyncThrowingStream<SpeechAudioFrame, Error>.Continuation) {
        self.continuation = continuation
    }

    func accept(_ input: AVAudioPCMBuffer) {
        lock.withLock {
            guard !finished, input.frameLength > 0 else { return }
            if converter?.inputFormat != input.format {
                converter = AVAudioConverter(from: input.format, to: outputFormat)
            }
            guard let converter,
                  let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate)) + 32)
            else { fail(SpeechError.message("无法转换当前音频设备的格式")); return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true
                state.pointee = .haveData
                return input
            }
            if status == .error { fail(error ?? SpeechError.message("音频转换失败") as NSError); return }
            guard let floats = output.floatChannelData?[0] else { return }
            var samples = [Int16]()
            samples.reserveCapacity(Int(output.frameLength))
            for i in 0..<Int(output.frameLength) {
                let value = floats[i].isFinite ? max(-1, min(1, floats[i])) : 0
                samples.append(Int16(value * 32_767).littleEndian)
            }
            samples.withUnsafeBytes { pending.append(contentsOf: $0) }
            while pending.count >= 6_400 {
                let pcm = Data(pending.prefix(6_400))
                pending.removeFirst(6_400)
                let level: Float = pcm.withUnsafeBytes { raw in
                    let samples = raw.bindMemory(to: Int16.self)
                    let sum = samples.reduce(Float(0)) { $0 + pow(Float(Int16(littleEndian: $1)) / 32_768, 2) }
                    return sqrt(sum / Float(samples.count))
                }
                lastPacketAt = Date()
                if case .dropped = continuation.yield(.init(pcm: pcm, level: level)) {
                    fail(SpeechError.audioBacklog)
                    return
                }
            }
        }
    }

    func accept(_ sample: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sample),
              let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample)))
        else { return }
        buffer.frameLength = buffer.frameCapacity
        let result = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(buffer.frameLength), into: buffer.mutableAudioBufferList)
        guard result == noErr else {
            finish(throwing: SpeechError.message("无法读取系统音频：\(result)"))
            return
        }
        accept(buffer)
    }

    func keepAlive() {
        lock.withLock {
            guard !finished, Date().timeIntervalSince(lastPacketAt) >= 0.35 else { return }
            lastPacketAt = Date()
            if case .dropped = continuation.yield(.init(pcm: Data(repeating: 0, count: 6_400), level: 0)) {
                fail(SpeechError.audioBacklog)
            }
        }
    }

    func finish(throwing error: Error? = nil) {
        lock.withLock {
            guard !finished else { return }
            if let error { fail(error); return }
            // Pad the final short packet so no spoken tail is discarded.
            if !pending.isEmpty {
                pending.append(Data(repeating: 0, count: 6_400 - pending.count))
                continuation.yield(.init(pcm: pending, level: 0))
                pending.removeAll()
            }
            finished = true
            continuation.finish()
        }
    }

    private func fail(_ error: Error) {
        finished = true
        continuation.finish(throwing: error)
    }
}

private final class SystemSpeechOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let encoder: SpeechPCMEncoder
    init(encoder: SpeechPCMEncoder) { self.encoder = encoder }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { encoder.accept(sampleBuffer) }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        encoder.finish(throwing: SpeechAudioCapture.classifiedCaptureError(error))
    }
}

@MainActor
final class SpeechAudioCapture {
    private var engine: AVAudioEngine?
    private var stream: SCStream?
    private var output: SystemSpeechOutput?
    private var encoder: SpeechPCMEncoder?
    private var deviceObserver: NSObjectProtocol?
    private var keepAlive: DispatchSourceTimer?
    private var tapInstalled = false

    nonisolated static func classifiedCaptureError(_ error: Error) -> Error {
        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain else { return error }
        switch nsError.code {
        case SCStreamError.Code.userDeclined.rawValue: return SpeechError.permissionRequired
        case SCStreamError.Code.missingEntitlements.rawValue:
            return SpeechError.message("当前 App 缺少系统音频采集权限配置，请重新构建已签名的 App")
        case SCStreamError.Code.userStopped.rawValue:
            return SpeechError.message("系统音频录制已停止，请手动重新开始监听")
        default: return error
        }
    }

    private func requireSystemAudioPermission() throws {
        // Preflight never prompts. Consent is requested only by the explicit permissions button,
        // so reconnects and application-list refreshes cannot repeatedly show the system dialog.
        guard CGPreflightScreenCaptureAccess() else { throw SpeechError.permissionRequired }
    }

    func applications() async throws -> [SCRunningApplication] {
        try requireSystemAudioPermission()
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        catch { throw Self.classifiedCaptureError(error) }
        return content.applications.filter { $0.processID != ProcessInfo.processInfo.processIdentifier }
            .sorted { $0.applicationName.localizedStandardCompare($1.applicationName) == .orderedAscending }
    }

    func start(source: SpeechAudioSource, applicationID: String?) async throws -> AsyncThrowingStream<SpeechAudioFrame, Error> {
        let (frames, continuation) = AsyncThrowingStream<SpeechAudioFrame, Error>.makeStream(bufferingPolicy: .bufferingOldest(50))
        let encoder = SpeechPCMEncoder(continuation)
        self.encoder = encoder
        do {
            if source == .microphone {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw SpeechError.message("请在系统设置 → 隐私与安全性 → 麦克风中允许 Copilot Native 使用麦克风")
                }
                try Task.checkCancellation()
                let engine = AVAudioEngine()
                self.engine = engine
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    throw SpeechError.message("没有可用的麦克风，请检查系统声音输入设置")
                }
                input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in encoder.accept(buffer) }
                tapInstalled = true
                deviceObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { @Sendable _ in
                    encoder.finish(throwing: SpeechError.audioBacklog)
                }
                engine.prepare()
                try engine.start()
            } else {
                try requireSystemAudioPermission()
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                try Task.checkCancellation()
                guard let display = content.displays.first else { throw SpeechError.message("没有可用的显示器，无法采集系统声音") }
                let filter: SCContentFilter
                if let applicationID {
                    guard let app = content.applications.first(where: { $0.bundleIdentifier == applicationID }) else {
                        throw SpeechError.message("所选会议应用未运行，请打开应用或改选全部系统声音")
                    }
                    filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
                } else {
                    let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                    filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                }
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 16_000
                config.channelCount = 1
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
                let output = SystemSpeechOutput(encoder: encoder)
                self.output = output
                let stream = SCStream(filter: filter, configuration: config, delegate: output)
                self.stream = stream
                // Register only audio output; no screen frames are read or stored.
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.eli.CopilotNative.speech-audio"))
                try await stream.startCapture()
            }
            try Task.checkCancellation()
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.eli.CopilotNative.speech-silence"))
            timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
            // DispatchSource's legacy handler does not require Sendable. Mark it explicitly
            // so Swift 6 does not inherit this method's MainActor isolation: the timer
            // executes on speech-silence, while the encoder synchronizes its own state.
            timer.setEventHandler { @Sendable in encoder.keepAlive() }
            timer.resume()
            keepAlive = timer
            return frames
        } catch {
            await stop()
            throw Self.classifiedCaptureError(error)
        }
    }

    func stop() async {
        keepAlive?.cancel()
        keepAlive = nil
        if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver) }
        deviceObserver = nil
        if let engine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        engine = nil
        tapInstalled = false
        let oldStream = stream
        stream = nil
        if let oldStream { try? await oldStream.stopCapture() }
        encoder?.finish()
        encoder = nil
        output = nil
    }
}
