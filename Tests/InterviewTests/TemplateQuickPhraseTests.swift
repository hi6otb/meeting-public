import XCTest
@testable import Interview

final class TemplateQuickPhraseTests: XCTestCase {
    @MainActor
    func testLegacyMigrationIsOnceAndEditsStayWithinTheirTemplate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        let first = PromptTemplate.standard
        let second = PromptTemplate(name: "相談", prompt: "相談に回答してください。")
        try store.saveTemplates(TemplateLibrary(templates: [first, second], defaultID: first.id))
        let a = QuickPhrase(text: "要約してください。"), b = QuickPhrase(text: "次の行動は？")
        let old = QuickPhraseLibrary(phrases: [a, b], selectedID: b.id, defaultID: b.id)
        try store.saveQuickPhrases(old)
        let backup = try Data(contentsOf: root.appendingPathComponent("quick-phrases.json"))
        let app = AppModel(root: root)
        XCTAssertEqual(app.quickPhrases(for: first.id).phrases, old.phrases)
        XCTAssertEqual(app.quickPhrases(for: second.id).phrases, old.phrases)
        let prompts = app.templateLibrary
        XCTAssertEqual(app.saveQuickPhrase(id: a.id, text: "相談の要点だけ", templateID: second.id), a.id)
        app.moveQuickPhrase(b.id, offset: -1, templateID: second.id)
        app.setDefaultQuickPhrase(a.id, templateID: second.id)
        XCTAssertEqual(app.quickPhraseLibrary.phrases, old.phrases)
        XCTAssertEqual(app.quickPhraseLibrary.defaultID, b.id)
        XCTAssertEqual(app.templateLibrary, prompts)
        XCTAssertFalse(app.applyingTemplate)
        app.selectTemplate(second.id)
        XCTAssertEqual(app.quickPhraseLibrary.phrases.map(\.id), [b.id, a.id])
        XCTAssertEqual(app.quickPhraseLibrary.defaultPhrase?.text, "相談の要点だけ")
        app.openQuickPhraseSettings()
        XCTAssertEqual(app.settingsTemplateID, second.id)
        XCTAssertEqual(app.settingsTemplateSection, 1)
        XCTAssertEqual(app.settingsTab, 1)
        app.deleteQuickPhrase(a.id, templateID: first.id)
        app.deleteQuickPhrase(b.id, templateID: first.id)
        await app.shutdown()
        let reloaded = AppModel(root: root)
        XCTAssertTrue(reloaded.quickPhrases(for: first.id).phrases.isEmpty)
        XCTAssertEqual(reloaded.quickPhrases(for: second.id).phrases.map(\.id), [b.id, a.id])
        XCTAssertEqual(reloaded.quickPhrases(for: second.id).defaultID, a.id)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("quick-phrases.json")), backup)
        await reloaded.shutdown()
    }

    @MainActor
    func testNewTemplateStartsEmptyAndPromptEditsKeepItsPhrases() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(root: root)
        let active = app.selectedTemplate.id
        let templateID = try XCTUnwrap(app.saveTemplate(id: nil, name: "新規", prompt: "質問に回答"))
        XCTAssertTrue(app.quickPhrases(for: templateID).phrases.isEmpty)
        let phraseID = try XCTUnwrap(app.saveQuickPhrase(id: nil, text: "このテンプレート専用", templateID: templateID))
        XCTAssertEqual(app.selectedTemplate.id, active)
        XCTAssertFalse(app.quickPhraseLibrary.phrases.contains { $0.id == phraseID })
        XCTAssertEqual(app.saveTemplate(id: templateID, name: "新しい名前", prompt: "変更したプロンプト"), templateID)
        XCTAssertEqual(app.quickPhrases(for: templateID).phrases.first?.text, "このテンプレート専用")
        app.selectTemplate(templateID)
        XCTAssertEqual(app.quickPhraseLibrary.phrases.first?.id, phraseID)
        await app.shutdown()
    }
}
