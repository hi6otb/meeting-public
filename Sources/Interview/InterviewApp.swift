import AppKit
import SwiftUI

@main
struct InterviewApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel!
    var window: NSWindow!
    private var terminating = false
    private var windowToolbar: MainWindowToolbar?
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 840), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Interview"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1020, height: 620)
        window.setFrameAutosaveName("InterviewMainWindow")
        window.delegate = self
        let hosting = NSHostingView(rootView: ContentView(app: model))
        hosting.focusRingType = .none
        window.contentView = hosting
        windowToolbar = MainWindowToolbar(model: model, window: window)
        window.center()
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let applicationMenu = NSMenu(); item.submenu = applicationMenu
        applicationMenu.addItem(withTitle: "設定…", action: #selector(settings), keyEquivalent: ",").target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Interviewを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(); menu.addItem(edit); let editMenu = NSMenu(title: "編集"); edit.submenu = editMenu
        for (title, action, key) in [("取り消す", "undo:", "z"), ("切り取り", "cut:", "x"), ("コピー", "copy:", "c"), ("貼り付け", "paste:", "v"), ("すべて選択", "selectAll:", "a")] { editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key) }
        NSApplication.shared.mainMenu = menu
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.configureSplitViews() }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    private func configureSplitViews() {
        func visit(_ view: NSView) {
            if let split = view as? NSSplitView {
                if split.isVertical, split.arrangedSubviews.count == 3 {
                    split.autosaveName = "InterviewColumns"
                    if !UserDefaults.standard.bool(forKey: "initialColumnsSet") {
                        split.setPosition(250, ofDividerAt: 0)
                        split.setPosition(split.bounds.width - 340, ofDividerAt: 1)
                        UserDefaults.standard.set(true, forKey: "initialColumnsSet")
                    }
                } else if !split.isVertical { split.autosaveName = "InterviewRows" }
            }
            for child in view.subviews { visit(child) }
        }
        if let content = window.contentView { visit(content) }
    }
    @objc func settings() { model.showSettings = true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        terminating = true
        Task { await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
