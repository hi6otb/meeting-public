import AppKit
import SwiftUI
import Combine

/// Keep window actions in AppKit's titlebar layout rather than drawing SwiftUI
/// controls underneath the native titlebar in a full-size content view.
@MainActor
final class MainWindowToolbar: NSObject, NSToolbarDelegate {
    private static let sidebar = NSToolbarItem.Identifier("Interview.sidebar")
    private static let recording = NSToolbarItem.Identifier("Interview.recording")
    private static let export = NSToolbarItem.Identifier("Interview.export")
    private let model: AppModel
    private weak var window: NSWindow?
    private var appearanceObservation: AnyCancellable?
    private var recordingObservation: AnyCancellable?
    private var blink: AnyCancellable?
    private weak var recordingButton: NSButton?

    init(model: AppModel, window: NSWindow) {
        self.model = model
        self.window = window
        super.init()
        let toolbar = NSToolbar(identifier: "Interview.windowActions")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.titlebarSeparatorStyle = .line
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
        toolbar.isVisible = true
        updateAppearance()
        appearanceObservation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateAppearance() }
        recordingObservation = model.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateRecordingButton() }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebar, .flexibleSpace, Self.recording, Self.export]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.visibilityPriority = .high
        item.isBordered = false
        item.style = .plain
        switch identifier {
        case Self.sidebar:
            item.label = "サイドバー"
            item.view = button(symbol: "sidebar.left", label: "サイドバーを切り替え", action: #selector(toggleSidebar))
        case Self.recording:
            item.label = "録音"
            let control = button(symbol: "record.circle", label: "記録を開始", action: #selector(toggleRecording))
            recordingButton = control
            item.view = control
            updateRecordingButton()
        case Self.export:
            item.label = "会話を書き出す"
            item.view = button(symbol: "square.and.arrow.up", label: "会話を書き出す", action: #selector(exportTranscript))
        default:
            return nil
        }
        return item
    }
    private func button(symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .inline
        button.isBordered = false
        button.focusRingType = .none
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        size(button, width: 32)
        return button
    }
    private func size(_ view: NSView, width: CGFloat) {
        view.frame = NSRect(x: 0, y: 0, width: width, height: 30)
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: width),
                                     view.heightAnchor.constraint(equalToConstant: 30)])
    }
    private func updateAppearance() {
        window?.appearance = NSAppearance(named: UserDefaults.standard.bool(forKey: "dark") ? .darkAqua : .aqua)
    }
    @objc private func toggleSidebar() {
        let defaults = UserDefaults.standard
        let visible = defaults.object(forKey: "sidebarVisible") as? Bool ?? true
        defaults.set(!visible, forKey: "sidebarVisible")
    }
    private func updateRecordingButton() {
        guard let button = recordingButton else { return }
        let waiting = model.preparing || model.stopping
        let symbol = waiting ? "hourglass" : (model.recording ? "stop.fill" : "record.circle")
        let label = model.preparing ? model.status : (model.stopping ? "停止中…" : (model.recording ? "記録を停止" : "記録を開始"))
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        button.contentTintColor = .systemRed
        button.isEnabled = !waiting
        button.toolTip = label
        button.setAccessibilityLabel(label)
        if model.recording && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            if blink == nil {
                blink = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
                    .sink { [weak self] _ in
                        guard let button = self?.recordingButton else { return }
                        button.alphaValue = button.alphaValue > 0.5 ? 0.22 : 1
                    }
            }
        } else { blink?.cancel(); blink = nil; button.alphaValue = 1 }
    }
    @objc private func toggleRecording() {
        Task { if model.recording { await model.stopRecording() } else { await model.startRecording() } }
    }
    @objc private func exportTranscript() { model.exportTranscript() }
}
