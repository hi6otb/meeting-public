import XCTest
@testable import Interview

final class SessionMenuTests: XCTestCase {
    @MainActor
    func testRenamePersistsAndFirstUtteranceDoesNotOverwriteIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(root: root)
        let id = try XCTUnwrap(app.selection)
        XCTAssertTrue(app.renameSession(id, title: "  打ち合わせ  "))
        XCTAssertFalse(app.renameSession(id, title: " \n "))
        app.append(.me, "発言の内容")
        XCTAssertEqual(app.session?.title, "打ち合わせ")
        XCTAssertEqual(try SessionStore(root: root).load().first?.title, "打ち合わせ")
        await app.shutdown()
    }

    @MainActor
    func testArchiveKeepsHistoryAndRestoresItWithoutSelectingOnLaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(root: root)
        let id = try XCTUnwrap(app.selection)
        app.append(.partner, "保存しておく会話")
        app.updateSession { $0.notes = "資料メモ"; $0.codexThread = "saved-thread" }
        app.setSessionArchived(id, archived: true)
        XCTAssertNotEqual(app.selection, id)
        let archived = try XCTUnwrap(app.sessions.first { $0.id == id })
        XCTAssertEqual(archived.isArchived, true)
        XCTAssertEqual(archived.messages.first?.text, "保存しておく会話")
        XCTAssertEqual(archived.notes, "資料メモ")
        XCTAssertEqual(archived.codexThread, "saved-thread")
        let reloaded = AppModel(root: root)
        XCTAssertNotEqual(reloaded.selection, id)
        XCTAssertEqual(reloaded.sessions.first { $0.id == id }?.isArchived, true)
        reloaded.setSessionArchived(id, archived: false)
        XCTAssertEqual(try SessionStore(root: root).load().first { $0.id == id }?.isArchived, false)
        await app.shutdown()
        await reloaded.shutdown()
    }

    @MainActor
    func testDeleteSwitchesToAnotherSessionAndGuardsActiveWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(root: root)
        let first = try XCTUnwrap(app.selection)
        app.newSession()
        let second = try XCTUnwrap(app.selection)
        app.busy = true
        app.deleteSession(second)
        app.setSessionArchived(second, archived: true)
        XCTAssertFalse(app.renameSession(second, title: "変更禁止"))
        XCTAssertEqual(app.sessions.count, 2)
        XCTAssertNotEqual(app.session?.isArchived, true)
        app.busy = false
        app.deleteSession(second)
        XCTAssertEqual(app.selection, first)
        XCTAssertFalse(try SessionStore(root: root).load().contains { $0.id == second })
        app.deleteSession(first)
        XCTAssertEqual(app.sessions.count, 1)
        XCTAssertNotEqual(app.selection, first)
        XCTAssertNotNil(app.session)
        await app.shutdown()
    }
}
