import XCTest
import AVFoundation
import Speech
import CoreMedia
@testable import Interview

final class IntegrationTests: XCTestCase {
    @MainActor
    func testLiveTimelineDeltaRetainsEarlierContext() async throws {
        guard ProcessInfo.processInfo.environment["INTERVIEW_LIVE_DELTA_TEST"] == "1" else { throw XCTSkip("Opt-in: tests timeline deltas") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = AppModel(root: root)
        defer { app.codex.shutdown(); try? FileManager.default.removeItem(at: root) }
        await app.connect()
        let model = try XCTUnwrap(app.codex.models.first)
        app.selectModel(model, effort: try XCTUnwrap(model.efforts.first?.id))
        app.append(.me, "合言葉はアオゾラです。")
        app.append(.partner, "集合時間は午前九時です。")
        app.draft = "合言葉と集合時間を教えてください。"
        app.sendDraft()
        try await waitForIdle(app)
        XCTAssertNil(app.error)
        let reply = try XCTUnwrap(app.session?.messages.last(where: { $0.speaker == .codex })?.text)
        XCTAssertTrue(reply.contains("アオゾラ"))
        let thread = try XCTUnwrap(app.session?.codexThread)
        let before = try XCTUnwrap(app.session?.deliveryState)
        XCTAssertEqual(before.versions.count, 3)
        XCTAssertTrue(try ContextSync.batches(session: app.session!, threadID: thread).isEmpty)
        app.append(.partner, "集合時間は午前十時に変更です。")
        XCTAssertEqual(try ContextSync.batches(session: app.session!, threadID: thread).flatMap(\.changes).count, 1)
        app.draft = "変更後の集合時間と合言葉を教えてください。"
        app.sendDraft()
        try await waitForIdle(app)
        XCTAssertNil(app.error)
        let updated = try XCTUnwrap(app.session?.messages.last(where: { $0.speaker == .codex })?.text)
        XCTAssertTrue(updated.contains("アオゾラ"))
        XCTAssertTrue(updated.contains("十時") || updated.contains("10時"))
        XCTAssertEqual(app.session?.codexThread, thread)
        XCTAssertEqual(app.session?.deliveryState?.versions.count, 4)
        XCTAssertTrue(try ContextSync.batches(session: app.session!, threadID: thread).isEmpty)
        let restored = try SessionStore(root: root).load().first
        XCTAssertEqual(restored?.deliveryState, app.session?.deliveryState)
        _ = try? await app.codex.request("thread/archive", ["threadId": thread])
    }

    @MainActor
    func testLiveTemplateChangeUpdatesInstructionsWithoutShowingPrompt() async throws {
        guard ProcessInfo.processInfo.environment["INTERVIEW_LIVE_TEMPLATE_TEST"] == "1" else { throw XCTSkip("Opt-in: tests real template injection") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = AppModel(root: root)
        defer { app.codex.shutdown(); try? FileManager.default.removeItem(at: root) }
        await app.connect()
        XCTAssertNil(app.error)
        let model = try XCTUnwrap(app.codex.models.first)
        app.selectModel(model, effort: try XCTUnwrap(model.efforts.first?.id))
        let first = try XCTUnwrap(app.saveTemplate(id: nil, name: "検証A", prompt: "ユーザーへの返答は必ず ALPHA の1単語だけにしてください。"))
        app.selectTemplate(first)
        XCTAssertNil(app.session?.appliedTemplate)
        app.draft = "接続確認です。"
        app.sendDraft()
        try await waitForIdle(app)
        XCTAssertNil(app.error)
        XCTAssertEqual(app.session?.messages.last(where: { $0.speaker == .codex })?.text.trimmingCharacters(in: .whitespacesAndNewlines), "ALPHA")
        let thread = try XCTUnwrap(app.session?.codexThread)
        let second = try XCTUnwrap(app.saveTemplate(id: nil, name: "検証B", prompt: "ユーザーへの返答は必ず BRAVO の1単語だけにしてください。"))
        app.selectTemplate(second)
        try await waitForIdle(app)
        XCTAssertEqual(app.session?.appliedTemplate?.id, second)
        XCTAssertEqual(app.session?.codexThread, thread)
        XCTAssertTrue(app.session?.messages.contains(where: { $0.speaker == .system && $0.text.contains("変更しました") }) == true)
        XCTAssertFalse(app.session?.messages.contains(where: { $0.speaker == .system && $0.text.contains("1単語") }) == true)
        app.draft = "もう一度お願いします。"
        app.sendDraft()
        try await waitForIdle(app)
        XCTAssertNil(app.error)
        XCTAssertEqual(app.session?.messages.last(where: { $0.speaker == .codex })?.text.trimmingCharacters(in: .whitespacesAndNewlines), "BRAVO")
        _ = try? await app.codex.request("thread/archive", ["threadId": thread])
    }

    @MainActor
    private func waitForIdle(_ app: AppModel) async throws {
        let deadline = Date().addingTimeInterval(60)
        while app.busy || app.applyingTemplate {
            if Date() > deadline { throw AppFailure("Template integration timed out") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor
    func testLiveCodexSubscriptionAndStream() async throws {
        guard ProcessInfo.processInfo.environment["INTERVIEW_LIVE_CODEX_TEST"] == "1" else { throw XCTSkip("Opt-in: consumes a small amount of the Codex subscription") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = CodexClient()
        defer { client.shutdown() }
        try await client.connect(cwd: root)
        XCTAssertTrue(client.connected)
        XCTAssertFalse(client.models.isEmpty)
        let initial = try XCTUnwrap(client.models.first)
        let initialEffort = try XCTUnwrap(initial.efforts.first?.id)
        let thread = try await client.prepareThread(existing: nil, cwd: root, model: initial.id, effort: initialEffort)
        XCTAssertEqual(client.threadConfigurations[thread]?.model, initial.id)
        XCTAssertEqual(client.threadConfigurations[thread]?.effort, initialEffort)
        let completed = expectation(description: "turn/completed")
        var reply = ""
        var terminalStatus = ""
        var toolUsed = false
        var usage: ContextUsage?
        client.onEvent = { method, params in
            guard params["threadId"] as? String == thread else { return }
            if method == "item/agentMessage/delta" { reply += params["delta"] as? String ?? "" }
            if method == "thread/tokenUsage/updated" { usage = ContextUsage(notification: params) }
            if method == "item/started", let item = params["item"] as? [String: Any], let type = item["type"] as? String,
               !["userMessage", "agentMessage", "reasoning"].contains(type) { toolUsed = true }
            if method == "turn/completed" {
                terminalStatus = (params["turn"] as? [String: Any])?["status"] as? String ?? ""
                completed.fulfill()
            }
        }
        _ = try await client.startTurn(thread: thread, text: "これは接続確認の架空の面接です。相手: 自己紹介をお願いします。自分: 大学で情報工学を学んでいます。短く1文だけ改善点を教えてください。ツールは使わないでください。", model: initial.id, effort: initialEffort)
        await fulfillment(of: [completed], timeout: 70)
        XCTAssertEqual(terminalStatus, "completed")
        XCTAssertFalse(reply.isEmpty)
        XCTAssertFalse(toolUsed)
        XCTAssertNotNil(usage?.fraction)
        let alternate = try XCTUnwrap(client.models.first { $0.id != initial.id })
        let alternateEffort = try XCTUnwrap(alternate.efforts.first(where: { $0.id != initialEffort })?.id)
        let resumed = try await client.prepareThread(existing: thread, cwd: root, model: alternate.id, effort: alternateEffort)
        XCTAssertEqual(resumed, thread)
        // A loaded thread can echo its old settings on resume. The turn-level
        // overrides are authoritative; verify the effective state after generation.
        let continued = expectation(description: "switched model completed")
        client.onEvent = { method, params in
            guard params["threadId"] as? String == thread else { return }
            if method == "turn/completed" {
                terminalStatus = (params["turn"] as? [String: Any])?["status"] as? String ?? ""
                continued.fulfill()
            }
        }
        _ = try await client.startTurn(thread: thread, text: "先ほどの会話を踏まえて、一言だけ助言してください。", model: alternate.id, effort: alternateEffort)
        await fulfillment(of: [continued], timeout: 70)
        XCTAssertEqual(terminalStatus, "completed")
        let read = try await client.request("thread/read", ["threadId": thread, "includeTurns": false])
        let effectiveThread = try XCTUnwrap(read["thread"] as? [String: Any])
        XCTAssertEqual(effectiveThread["model"] as? String, alternate.id)
        XCTAssertEqual(effectiveThread["reasoningEffort"] as? String, alternateEffort)
        let compacted = expectation(description: "compaction completed")
        var compactionItemFinished = false
        var compactUsage: ContextUsage?
        client.onEvent = { method, params in
            guard params["threadId"] as? String == thread else { return }
            if method == "thread/tokenUsage/updated" { compactUsage = ContextUsage(notification: params) }
            if method == "item/completed", let item = params["item"] as? [String: Any], item["type"] as? String == "contextCompaction" { compactionItemFinished = true }
            if method == "turn/completed" {
                terminalStatus = (params["turn"] as? [String: Any])?["status"] as? String ?? ""
                compacted.fulfill()
            }
        }
        try await client.compact(thread: thread)
        await fulfillment(of: [compacted], timeout: 90)
        XCTAssertEqual(terminalStatus, "completed")
        XCTAssertTrue(compactionItemFinished)
        print("Model switched on same thread: \(initial.id)/\(initialEffort) -> \(alternate.id)/\(alternateEffort). Compaction item complete: \(compactionItemFinished). Updated context: \(compactUsage?.usedTokens.description ?? "not emitted")")
        _ = try? await client.request("thread/archive", ["threadId": thread])
        print("Codex subscription streaming: \(terminalStatus), response characters: \(reply.count), tools: \(toolUsed)")
    }

    func testRealAppleTranscriptionFromSyntheticFile() async throws {
        guard let path = ProcessInfo.processInfo.environment["INTERVIEW_SPEECH_FIXTURE"] else { throw XCTSkip("Opt-in: requires a synthetic Japanese audio fixture") }
        let transcriber = try await LocalTranscriber.make(locale: Locale(identifier: "ja-JP"))
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let result = LockedTranscript()
        transcriber.onResult = { _, _, text, final in if final { result.append(text) } }
        transcriber.onError = { error in result.fail(error.localizedDescription) }
        while file.framePosition < file.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            var description: CMAudioFormatDescription?
            XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: buffer.format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(buffer.format.sampleRate)), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: description!, sampleCount: Int(buffer.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
            XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: buffer.audioBufferList), noErr)
            transcriber.append(sample!)
        }
        await transcriber.finish()
        XCTAssertTrue(result.failure.isEmpty, result.failure)
        XCTAssertTrue(result.text.contains("面接"), "Unexpected synthetic transcription: \(result.text)")
        print("Apple on-device transcription: \(result.text)")
    }
}

private final class LockedTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    private var error = ""
    var text: String { lock.lock(); defer { lock.unlock() }; return value }
    var failure: String { lock.lock(); defer { lock.unlock() }; return error }
    func append(_ text: String) { lock.lock(); defer { lock.unlock() }; value += text }
    func fail(_ text: String) { lock.lock(); defer { lock.unlock() }; error = text }
}
