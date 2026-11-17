import Foundation
import AVFoundation
import ScreenCaptureKit
import Speech
import CoreMedia

/// One independent analyzer per input. Audio is never written to disk or uploaded.
final class LocalTranscriber: @unchecked Sendable {
    let transcriber: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var resultTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "interview.audio.convert")
    private var accepting = true
    var onResult: ((Double, Double, String, Bool) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onError: ((Error) -> Void)?

    static func make(locale: Locale) async throws -> LocalTranscriber {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AppFailure("このMacでは選択した言語の端末内文字起こしを利用できません。")
        }
        let module = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw AppFailure("音声認識の入力フォーマットを準備できません。")
        }
        let instance = LocalTranscriber(module: module, format: format)
        try await instance.analyzer.prepareToAnalyze(in: format)
        return instance
    }

    private init(module: SpeechTranscriber, format: AVAudioFormat) {
        transcriber = module
        self.format = format
        analyzer = SpeechAnalyzer(modules: [module])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(500))
        self.continuation = continuation
        resultTask = Task { [weak self, module, analyzer] in
            do {
                try await analyzer.start(inputSequence: stream)
                for try await result in module.results {
                    self?.onResult?(result.range.start.seconds, CMTimeRangeGetEnd(result.range).seconds,
                                    String(result.text.characters), result.isFinal)
                }
            } catch {
                if !Task.isCancelled { self?.onError?(error) }
            }
        }
    }

    func append(_ sample: CMSampleBuffer) {
        // Retain the sample across dispatch; CoreMedia owns the backing memory.
        queue.async { [weak self] in
            guard let self, self.accepting else { return }
            do { try self.convert(sample) } catch { self.onError?(error) }
        }
    }

    private func convert(_ sample: CMSampleBuffer) throws {
        guard let description = sample.formatDescription else { return }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        input.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList)
        guard status == noErr else { throw AppFailure("音声バッファを読み取れません（\(status)）。") }
        if sourceFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: format)
            sourceFormat = inputFormat
        }
        guard let converter else { throw AppFailure("音声フォーマットを変換できません。") }
        let capacity = AVAudioFrameCount(ceil(Double(frames) * format.sampleRate / inputFormat.sampleRate) + 256)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let converted = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard converted != .error, output.frameLength > 0 else { return }
        if let samples = output.floatChannelData?[0] {
            var sum = 0.0
            for i in 0..<Int(output.frameLength) { sum += Double(samples[i] * samples[i]) }
            onLevel?(sqrt(sum / Double(output.frameLength)))
        } else if let samples = output.int16ChannelData?[0] {
            var sum = 0.0
            for i in 0..<Int(output.frameLength) { let v = Double(samples[i]) / 32768; sum += v * v }
            onLevel?(sqrt(sum / Double(output.frameLength)))
        }
        if case .dropped = continuation.yield(AnalyzerInput(buffer: output)) {
            throw AppFailure("文字起こしが音声に追いつきません。記録を停止して再開してください。")
        }
    }

    func finalizePause() async {
        do { try await analyzer.finalize(through: nil) }
        catch { onError?(error) }
    }

    func finish() async {
        await withCheckedContinuation { done in
            queue.async { [self] in accepting = false; continuation.finish(); done.resume() }
        }
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        catch { onError?(error) }
        await resultTask?.value
        resultTask = nil
    }

    func cancel() async {
        await withCheckedContinuation { done in
            queue.async { [self] in accepting = false; continuation.finish(); done.resume() }
        }
        await analyzer.cancelAndFinishNow()
        resultTask?.cancel()
        resultTask = nil
    }
}

final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var me: LocalTranscriber?
    private var partner: LocalTranscriber?
    private let queue = DispatchQueue(label: "interview.capture")
    var onResult: ((Speaker, Double, Double, String, Bool) -> Void)?
    var onLevel: ((Speaker, Double) -> Void)?
    var onError: ((Error) -> Void)?

    func start(locale: String, microphoneID: String?, applicationID: String?) async throws {
        try await RecordingPermissions.ensureMicrophone(status: AVCaptureDevice.authorizationStatus(for: .audio)) {
            await AVCaptureDevice.requestAccess(for: .audio)
        }
        // ScreenCaptureKit owns the system-audio authorization. Do not cache a
        // Boolean grant or issue an additional CGRequestScreenCaptureAccess call.
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw RecordingPermissions.explainCaptureError(error) }
        guard let display = content.displays.first else { throw AppFailure("音声を取得できるディスプレイがありません。") }
        let filter: SCContentFilter
        if let applicationID, !applicationID.isEmpty {
            guard let application = content.applications.first(where: { $0.bundleIdentifier == applicationID }) else {
                throw AppFailure("選択した会議アプリを起動してください。")
            }
            filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }
        do {
            me = try await LocalTranscriber.make(locale: Locale(identifier: locale))
            partner = try await LocalTranscriber.make(locale: Locale(identifier: locale))
            for (speaker, pipe) in [(Speaker.me, me!), (Speaker.partner, partner!)] {
                pipe.onResult = { [weak self] start, end, text, final in self?.onResult?(speaker, start, end, text, final) }
                pipe.onLevel = { [weak self] level in self?.onLevel?(speaker, level) }
                pipe.onError = { [weak self] error in self?.onError?(error) }
            }
            let config = SCStreamConfiguration()
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 3
            config.showsCursor = false
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 1
            config.captureMicrophone = true
            if let microphoneID, !microphoneID.isEmpty { config.microphoneCaptureDeviceID = microphoneID }
            let capture = SCStream(filter: filter, configuration: config, delegate: self)
            try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try capture.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
            // No screen output is attached: video frames are never consumed or stored.
            stream = capture
            try await capture.startCapture()
        } catch {
            await me?.cancel(); await partner?.cancel()
            me = nil; partner = nil; stream = nil
            throw RecordingPermissions.explainCaptureError(error)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if type == .audio { partner?.append(sampleBuffer) }
        if type == .microphone { me?.append(sampleBuffer) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error) }
    func finalize(_ speaker: Speaker) async {
        if speaker == .me { await me?.finalizePause() } else { await partner?.finalizePause() }
    }
    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        // Drain capture callbacks before releasing the two pipelines.
        await withCheckedContinuation { done in queue.async { done.resume() } }
        await me?.finish(); await partner?.finish()
        me = nil; partner = nil
    }
}
