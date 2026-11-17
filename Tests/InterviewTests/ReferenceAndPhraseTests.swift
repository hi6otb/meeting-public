import XCTest
@testable import Interview

final class ReferenceAndPhraseTests: XCTestCase {
    func testLegacyReferenceRestoresTailAndChunkedSyncPreservesEveryScalar() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("full.txt")
        let text = String(repeating: "日本語👨‍👩‍👧‍👦\n\"\\", count: 4000) + "末尾の重要情報"
        try text.write(to: url, atomically: true, encoding: .utf8)
        let old = Reference(name: "資料", path: url.path, text: String(text.prefix(20_000)))
        let restored = try ReferenceText.restoreFullText(old)
        XCTAssertEqual(restored.text, text)
        XCTAssertEqual(restored.fullTextAvailable, true)
        var session = Session(references: [restored])
        let batches = try ContextSync.batches(session: session, threadID: "a")
        XCTAssertGreaterThan(batches.count, 1)
        var parts: [(Int, String)] = []
        for batch in batches {
            let start = try XCTUnwrap(batch.text.range(of: "\n["))
            let json = Data(batch.text[start.upperBound...].dropLast(0).utf8)
            // Include the opening bracket consumed by the delimiter.
            let records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("[".utf8) + json) as? [[String: Any]])
            parts += records.filter { $0["kind"] as? String == "referencePart" }.map { ($0["part"] as! Int, $0["text"] as! String) }
        }
        XCTAssertEqual(parts.sorted { $0.0 < $1.0 }.map(\.1).joined(), text)
        var state = ContextDeliveryState(threadID: "a")
        batches[0].acknowledge(into: &state); session.deliveryState = state
        let retry = try ContextSync.batches(session: session, threadID: "a")
        XCTAssertEqual(Set(retry.flatMap(\.changes).map(\.key)), Set(batches.dropFirst().flatMap(\.changes).map(\.key)))
        retry.forEach { $0.acknowledge(into: &state) }; session.deliveryState = state
        XCTAssertTrue(try ContextSync.batches(session: session, threadID: "a").isEmpty)
        session.references[0].isClosed = true
        let removed = try ContextSync.batches(session: session, threadID: "a")
        removed.forEach { $0.acknowledge(into: &state) }
        XCTAssertTrue(state.versions.keys.filter { $0.hasPrefix("reference/") }.isEmpty)
    }

    func testTruncatedLegacyReferenceFailsExplicitlyWithoutOriginal() {
        let reference = Reference(name: "欠落", path: "/missing/\(UUID()).txt", text: String(repeating: "a", count: 20_000))
        XCTAssertThrowsError(try ReferenceText.restoreFullText(reference))
    }

    func testRevisionKeepsUnchangedSuffixAndGraphemeClusters() {
        let revision = TextRevision(previous: "今日は晴れです👨‍👩‍👧‍👦", current: "今日は雨です👨‍👩‍👧‍👦")
        XCTAssertEqual(revision.prefix, "今日は")
        XCTAssertEqual(revision.changed, "雨")
        XCTAssertEqual(revision.suffix, "です👨‍👩‍👧‍👦")
        let append = TextRevision(previous: "はい", current: "はい、どうぞ")
        XCTAssertEqual(append.changed, "、どうぞ")
        let deletion = TextRevision(previous: "あいう", current: "あう")
        XCTAssertEqual(deletion.prefix + deletion.changed + deletion.suffix, "あう")
    }

    @MainActor
    func testQuickPhrasesPersistWithoutThreeItemStorageLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(root: root)
        let original = try XCTUnwrap(app.quickPhraseLibrary.selected)
        for i in 1...5 { XCTAssertNotNil(app.saveQuickPhrase(id: nil, text: "定型文\(i)")) }
        XCTAssertEqual(app.quickPhraseLibrary.phrases.count, 6)
        XCTAssertEqual(app.saveQuickPhrase(id: original.id, text: "編集済み"), original.id)
        app.deleteQuickPhrase(app.quickPhraseLibrary.phrases.last!.id)
        let loaded = try XCTUnwrap(SessionStore(root: root).loadTemplateQuickPhrases(templates: app.templateLibrary.templates).byTemplate[app.selectedTemplate.id.uuidString])
        XCTAssertEqual(loaded.phrases.count, 5)
        XCTAssertEqual(loaded.selected?.text, "編集済み")
        await app.shutdown()
    }
    @MainActor
    func testSelectingQuickPhraseDoesNotSendOrChangeComposerDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(root: root)
        app.draft = "入力途中の文章"
        let id = try XCTUnwrap(app.saveQuickPhrase(id: nil, text: "追加した定型文"))
        app.selectQuickPhrase(id)
        XCTAssertEqual(app.quickPhraseLibrary.selected?.id, id)
        XCTAssertEqual(app.draft, "入力途中の文章")
        XCTAssertTrue(app.session?.messages.isEmpty == true)
        XCTAssertFalse(app.busy)
        XCTAssertFalse(app.applyingTemplate)
        XCTAssertEqual(try XCTUnwrap(SessionStore(root: root).loadTemplateQuickPhrases(templates: app.templateLibrary.templates).byTemplate[app.selectedTemplate.id.uuidString]).selected?.id, id)
        await app.shutdown()
    }

    @MainActor
    func testLargeTemplateAndQuickPhrasePersistBeyondOldByteLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(root: root)
        let text = String(repeating: "長い日本語の指示文です。\n", count: 4000) + "末尾まで保持"
        XCTAssertGreaterThan(text.utf8.count, 32_000)
        let templateID = try XCTUnwrap(app.saveTemplate(id: nil, name: "長文テンプレート", prompt: text))
        let phraseID = try XCTUnwrap(app.saveQuickPhrase(id: nil, text: text))
        let store = try SessionStore(root: root)
        XCTAssertEqual(try store.loadTemplates().templates.first { $0.id == templateID }?.prompt, text)
        XCTAssertEqual(try store.loadTemplateQuickPhrases(templates: app.templateLibrary.templates).byTemplate[app.selectedTemplate.id.uuidString]?.phrases.first { $0.id == phraseID }?.text, text)
        await app.shutdown()
    }

}
