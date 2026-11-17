import XCTest
@testable import Interview

final class LocalTitleTests: XCTestCase {
    func testLongConversationIncludesEveryPartBeforeGeneratingTitle() async throws {
        let transcript = String(repeating: "自分: 企画の目的と今後の予定を話しています。\n", count: 160) + "相手: 最終決定は来月に延期します。"
        var summarized: [String] = []
        var finalInputs: [String] = []
        let title = try await LocalTitleGenerator.reduceAndTitle(transcript) { input, final in
            if final { finalInputs.append(input); return "企画の予定と延期の決定" }
            summarized.append(input)
            return "企画の予定と延期を確認"
        }
        XCTAssertEqual(summarized.joined(), transcript)
        XCTAssertEqual(finalInputs.count, 1)
        XCTAssertEqual(title, "企画の予定と延期の決定")
    }

    @MainActor
    func testStoppingFinalizesSpeechThenUpdatesAndPersistsTitle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var input: [Message] = []
        let app = AppModel(root: root, titleGenerator: { messages in input = messages; return "次の旅行の計画" })
        let id = try XCTUnwrap(app.selection)
        app.recording = true // No capture device is opened in this unit test.
        app.receiveTranscript(.partner, start: 0, end: 1, text: "次は京都に旅行したいです。", final: false)
        await app.stopRecording()
        await app.titleTasks[id]?.value
        XCTAssertEqual(input.first?.text, "次は京都に旅行したいです。")
        XCTAssertEqual(input.first?.isProvisional, false)
        XCTAssertEqual(app.session?.title, "次の旅行の計画")
        XCTAssertEqual(app.session?.titleGenerationPending, false)
        XCTAssertEqual(try SessionStore(root: root).load().first?.title, "次の旅行の計画")
        await app.shutdown()
    }

    @MainActor
    func testDelayedTitleTargetsOriginalSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let began = expectation(description: "generation started")
        var continuation: CheckedContinuation<String?, Never>?
        let app = AppModel(root: root, titleGenerator: { _ in
            await withCheckedContinuation { continuation = $0; began.fulfill() }
        })
        app.append(.me, "予算について相談しましょう")
        let originalID = try XCTUnwrap(app.selection)
        app.scheduleTitleGeneration(for: originalID)
        let task = app.titleTasks[originalID]
        await fulfillment(of: [began], timeout: 2)
        app.newSession()
        continuation?.resume(returning: "予算の相談")
        await task?.value
        XCTAssertEqual(app.sessions.first { $0.id == originalID }?.title, "予算の相談")
        XCTAssertEqual(app.session?.title, "新しいセッション")
        await app.shutdown()
    }

    @MainActor
    func testManualRenameWinsOverAlreadyRunningGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let began = expectation(description: "generation started")
        var continuation: CheckedContinuation<String?, Never>?
        let app = AppModel(root: root, titleGenerator: { _ in
            await withCheckedContinuation { continuation = $0; began.fulfill() }
        })
        app.append(.partner, "打ち合わせを始めます")
        let id = try XCTUnwrap(app.selection)
        app.scheduleTitleGeneration(for: id)
        let task = app.titleTasks[id]
        await fulfillment(of: [began], timeout: 2)
        XCTAssertTrue(app.renameSession(id, title: "自分で決めた名前"))
        continuation?.resume(returning: "自動生成された名前")
        await task?.value
        XCTAssertEqual(app.session?.title, "自分で決めた名前")
        XCTAssertEqual(app.session?.titleGenerationPending, false)
        app.scheduleTitleGeneration(for: id)
        XCTAssertNil(app.titleTasks[id])
        await app.shutdown()
    }

    @MainActor
    func testUnavailableModelKeepsExistingTitleAndExplainsFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(root: root, titleGenerator: { _ in throw AppFailure("Apple Intelligenceがオフです。") })
        app.append(.me, "元のタイトル")
        let id = try XCTUnwrap(app.selection)
        app.scheduleTitleGeneration(for: id)
        await app.titleTasks[id]?.value
        XCTAssertEqual(app.session?.title, "元のタイトル")
        XCTAssertTrue(app.error?.contains("Apple Intelligenceがオフ") == true)
        XCTAssertEqual(app.session?.titleGenerationPending, false)
        await app.shutdown()
    }
}
