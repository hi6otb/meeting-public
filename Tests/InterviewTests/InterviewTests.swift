import XCTest
@testable import Interview

final class InterviewTests: XCTestCase {
    @MainActor
    func testTemplateDefaultsPersistenceAndEmptyNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(root: root)
        XCTAssertEqual(app.session?.notes, "")
        XCTAssertFalse(app.selectedTemplate.prompt.contains("面接"))
        let id = try XCTUnwrap(app.saveTemplate(id: nil, name: "要約", prompt: "会話を簡潔に要約してください。"))
        app.setDefaultTemplate(id)
        app.newSession()
        XCTAssertEqual(app.selectedTemplate.id, id)
        XCTAssertNil(app.session?.appliedTemplate)
        let restored = AppModel(root: root)
        XCTAssertEqual(restored.templateLibrary.defaultID, id)
        XCTAssertEqual(restored.selectedTemplate.prompt, "会話を簡潔に要約してください。")
    }

    func testSystemNoticesAreOnlyInCodexChat() {
        let notice = Message(speaker: .system, text: "テンプレートを変更しました。")
        XCTAssertFalse(notice.isConversation)
        XCTAssertTrue(notice.isCoachChat)
    }
    func testContextGaugeUsesLatestContextNotCumulativeBilling() throws {
        let usage = try XCTUnwrap(ContextUsage(notification: ["tokenUsage": [
            "last": ["totalTokens": 2400], "total": ["totalTokens": 99000], "modelContextWindow": 10000
        ]]))
        XCTAssertEqual(usage.usedTokens, 2400)
        XCTAssertEqual(usage.fraction, 0.24)
        let unknown = try XCTUnwrap(ContextUsage(notification: ["tokenUsage": ["last": ["totalTokens": 10]]]))
        XCTAssertNil(unknown.fraction)
    }

    @MainActor
    func testTurnOverridesKeepSameThreadWithModelAndEffort() {
        let params = CodexClient.turnParameters(thread: "existing-thread", text: "続き", model: "catalog-model", effort: "high")
        XCTAssertEqual(params["threadId"] as? String, "existing-thread")
        XCTAssertEqual(params["model"] as? String, "catalog-model")
        XCTAssertEqual(params["effort"] as? String, "high")
    }

    @MainActor
    func testClosedFileTabsPersistAndAutoCoachStartsOff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(root: root)
        XCTAssertFalse(app.autoCoach)
        let reference = Reference(name: "面接資料.txt", path: "/tmp/面接資料.txt", text: "メモ")
        app.updateSession { $0.references.append(reference) }
        app.referenceTab = reference.id.uuidString
        app.closeReference(reference.id)
        XCTAssertTrue(app.session?.openReferences.isEmpty == true)
        XCTAssertEqual(app.referenceTab, "notes")
        let restored = AppModel(root: root)
        XCTAssertTrue(restored.session?.openReferences.isEmpty == true)
        XCTAssertEqual(restored.session?.references.first?.path, reference.path)
        restored.autoCoach = true
        restored.newSession()
        XCTAssertFalse(restored.autoCoach)
    }

    func testVolatileReplacementDoesNotDuplicateWords() {
        var assembler = TranscriptAssembler()
        assembler.receive(start: 0, end: 1, text: "私の", final: false)
        assembler.receive(start: 0, end: 2, text: "私の強みは", final: false)
        XCTAssertNil(assembler.commit())
        assembler.receive(start: 0, end: 2.2, text: "私の強みは継続力です。", final: true)
        XCTAssertEqual(assembler.commit(), "私の強みは継続力です。")
        XCTAssertEqual(assembler.text, "")
    }
    func testOverlappingVolatileRangeIsReplaced() {
        var assembler = TranscriptAssembler()
        assembler.receive(start: 0, end: 1, text: "一", final: false)
        assembler.receive(start: 1, end: 2, text: "二", final: false)
        assembler.receive(start: 0, end: 2, text: "一二。", final: true)
        XCTAssertEqual(assembler.commit(), "一二。")
    }
    func testLateResultsAfterCommitAreIgnored() {
        var assembler = TranscriptAssembler()
        assembler.receive(start: 0, end: 1, text: "最初。", final: true)
        XCTAssertEqual(assembler.commit(), "最初。")
        assembler.receive(start: 0, end: 1, text: "最初。", final: true)
        XCTAssertNil(assembler.commit())
        assembler.receive(start: 1, end: 2, text: "次。", final: true)
        XCTAssertEqual(assembler.commit(), "次。")
    }
    func testIndependentSimultaneousSpeakers() {
        var me = TranscriptAssembler(), partner = TranscriptAssembler()
        me.receive(start: 0, end: 2, text: "回答です", final: true)
        partner.receive(start: 0, end: 3, text: "質問です", final: false)
        XCTAssertEqual(me.commit(), "回答です")
        XCTAssertNil(partner.commit())
        XCTAssertEqual(partner.commit(force: true), "質問です")
    }
    func testHistoryRoundTripIncludesMaterialsAndThread() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = Session()
        session.messages = [Message(speaker: .me, text: "日本語の会話"), Message(speaker: .codex, text: "コメント")]
        session.notes = "経歴"
        session.codexThread = "thread-owned-by-interview"
        session.references = [Reference(name: "資料.pdf", path: "/tmp/資料.pdf", text: "資料の内容")]
        try store.save([session])
        XCTAssertEqual(try store.load(), [session])
    }
    func testCorruptHistoryIsNotSilentlyDiscarded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        let url = root.appendingPathComponent("sessions.json")
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "broken")
    }
}
