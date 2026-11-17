import XCTest
@testable import Interview

final class ContextSyncTests: XCTestCase {
    @MainActor
    func testOverlappingSpeakersAppearBeforeEitherUtteranceFinishes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(root: root)
        app.receiveTranscript(.me, start: 0, end: 1, text: "話している", final: false)
        let firstID = try XCTUnwrap(app.session?.messages.first?.id)
        XCTAssertEqual(app.session?.messages.count, 1)
        app.receiveTranscript(.partner, start: 0.5, end: 1.2, text: "少し待って", final: false)
        XCTAssertEqual(app.session?.messages.map(\.speaker), [.me, .partner])
        XCTAssertTrue(app.session?.messages.allSatisfy { $0.isProvisional == true } == true)
        let secondID = try XCTUnwrap(app.session?.messages.last?.id)
        app.receiveTranscript(.me, start: 0, end: 2, text: "話している途中です。", final: true)
        XCTAssertEqual(app.session?.messages.map(\.id), [firstID, secondID])
        XCTAssertEqual(app.session?.messages.first?.text, "話している途中です。")
        app.finalizeUtterance(.me)
        XCTAssertEqual(app.session?.messages.count, 2)
        XCTAssertEqual(app.session?.messages.first?.isProvisional, false)
        app.receiveTranscript(.me, start: 3, end: 4, text: "はい、どうぞ", final: false)
        XCTAssertEqual(app.session?.messages.map(\.speaker), [.me, .partner, .me])
        app.finalizeUtterance(.me, force: true)
        app.finalizeUtterance(.partner, force: true)
        await app.shutdown()
    }

    func testOnlyNewOrRevisedUtterancesAreSent() throws {
        var session = Session()
        session.messages = [Message(speaker: .me, text: "途中", isProvisional: true), Message(speaker: .partner, text: "はい"),
                            Message(speaker: .codex, text: "既存の回答"), Message(speaker: .me, text: "入力した質問", isCoachQuestion: true)]
        var state = ContextDeliveryState(threadID: "thread")
        let first = try ContextSync.batches(session: session, threadID: "thread")
        XCTAssertEqual(first.flatMap(\.changes).count, 3) // notes + two audio utterances
        XCTAssertFalse(first.map(\.text).joined().contains("既存の回答"))
        XCTAssertFalse(first.map(\.text).joined().contains("入力した質問"))
        first.forEach { $0.acknowledge(into: &state) }
        session.deliveryState = state
        XCTAssertTrue(try ContextSync.batches(session: session, threadID: "thread").isEmpty)
        session.messages[0].text = "途中から確定しました"
        session.messages[0].isProvisional = false
        let revised = try ContextSync.batches(session: session, threadID: "thread")
        XCTAssertEqual(revised.flatMap(\.changes).map(\.key), ["speech/" + session.messages[0].id.uuidString])
        revised.forEach { $0.acknowledge(into: &state) }; session.deliveryState = state
        session.messages.append(Message(speaker: .partner, text: "新しい発言"))
        let next = try ContextSync.batches(session: session, threadID: "thread")
        XCTAssertEqual(next.flatMap(\.changes).count, 1)
        XCTAssertFalse(next.map(\.text).joined().contains("途中から確定しました"))
    }

    func testPartialAcknowledgementKeepsUnsentRecordsAndNewThreadResyncs() throws {
        var session = Session()
        session.messages = (0..<35).map { Message(speaker: .partner, text: "発言\($0) " + String(repeating: "あ", count: 100)) }
        let batches = try ContextSync.batches(session: session, threadID: "a", maximumBytes: 1000)
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertEqual(batches.flatMap(\.changes).count, 36)
        var state = ContextDeliveryState(threadID: "a")
        batches[0].acknowledge(into: &state)
        session.deliveryState = state
        let retry = try ContextSync.batches(session: session, threadID: "a")
        XCTAssertEqual(Set(retry.flatMap(\.changes).map(\.key)), Set(batches.dropFirst().flatMap(\.changes).map(\.key)))
        XCTAssertEqual(try ContextSync.batches(session: session, threadID: "b").flatMap(\.changes).count, 36)
    }

    func testNotesAndReferenceChangesHaveIndependentVersions() throws {
        var session = Session()
        session.notes = "元のメモ"
        let reference = Reference(name: "資料", path: "/tmp/example", text: "本文")
        session.references = [reference]
        var state = ContextDeliveryState(threadID: "a")
        try ContextSync.batches(session: session, threadID: "a").forEach { $0.acknowledge(into: &state) }
        session.deliveryState = state
        session.notes = "新しいメモ"
        session.references[0].isClosed = true
        let changes = try ContextSync.batches(session: session, threadID: "a")
        XCTAssertEqual(Set(changes.flatMap(\.changes).map(\.key)), Set(["notes", "reference/" + reference.id.uuidString]))
        changes.forEach { $0.acknowledge(into: &state) }
        XCTAssertNil(state.versions["reference/" + reference.id.uuidString])
    }
}
