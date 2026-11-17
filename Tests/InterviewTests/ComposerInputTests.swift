import XCTest
import AppKit
@testable import Interview

final class ComposerInputTests: XCTestCase {
    @MainActor
    private func enter(_ modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false, keypad: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                        windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                        isARepeat: repeatKey, keyCode: keypad ? 76 : 36)!
    }

    @MainActor
    func testJapaneseCommitDoesNotSubmitAndNextReturnSubmitsOnce() {
        _ = NSApplication.shared
        let view = SubmitTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        var submissions = 0
        view.onSubmit = { submissions += 1 }
        view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        view.keyDown(with: enter())
        XCTAssertEqual(submissions, 0)
        // A headless XCTest has no active system IME. Model its subsequent
        // commit callback explicitly instead of relying on input-source state.
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
        view.keyDown(with: enter(repeatKey: true))
        XCTAssertEqual(submissions, 0)
        view.keyDown(with: enter())
        XCTAssertEqual(submissions, 1)
    }

    @MainActor
    func testModifiedReturnDoesNotSubmitAndKeypadReturnCanSubmit() {
        _ = NSApplication.shared
        let view = SubmitTextView(frame: .zero)
        var submissions = 0
        view.onSubmit = { submissions += 1 }
        view.keyDown(with: enter(.shift))
        view.keyDown(with: enter(.option))
        XCTAssertEqual(submissions, 0)
        view.keyDown(with: enter(keypad: true))
        XCTAssertEqual(submissions, 1)
    }

    @MainActor
    func testPhraseOrderAndDefaultSurviveRestartAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(root: root)
        let first = try XCTUnwrap(app.quickPhraseLibrary.defaultPhrase?.id)
        let second = try XCTUnwrap(app.saveQuickPhrase(id: nil, text: "二つ目"))
        let third = try XCTUnwrap(app.saveQuickPhrase(id: nil, text: "三つ目"))
        app.setDefaultQuickPhrase(second)
        app.moveQuickPhrase(third, offset: -1)
        XCTAssertEqual(app.quickPhraseLibrary.phrases.map(\.id), [first, third, second])
        app.selectQuickPhrase(third)
        XCTAssertEqual(app.quickPhraseLibrary.defaultPhrase?.id, second)
        await app.shutdown()
        let restored = AppModel(root: root)
        XCTAssertEqual(restored.quickPhraseLibrary.phrases.map(\.id), [first, third, second])
        XCTAssertEqual(restored.quickPhraseLibrary.selected?.id, second)
        restored.deleteQuickPhrase(second)
        XCTAssertEqual(restored.quickPhraseLibrary.defaultPhrase?.id, first)
        XCTAssertEqual(restored.quickPhraseLibrary.selected?.id, first)
        await restored.shutdown()
    }
    @MainActor
    func testPlaceholderTracksMarkedTextAndReturnsOnlyWhenEmpty() {
        _ = NSApplication.shared
        let view = SubmitTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.placeholder = "Codexに質問…"
        var liveText = ""
        view.onTextChange = { liveText = $0 }
        XCTAssertTrue(view.shouldShowPlaceholder)
        view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.shouldShowPlaceholder)
        XCTAssertEqual(liveText, "にほん")
        view.unmarkText()
        XCTAssertFalse(view.shouldShowPlaceholder)
        view.string = ""
        view.didChangeText()
        XCTAssertTrue(view.shouldShowPlaceholder)
        view.insertText("貼り付けた文章", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertFalse(view.shouldShowPlaceholder)
    }

}
