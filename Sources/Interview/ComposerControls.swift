import SwiftUI
import AppKit

struct ComposerControls: View {
    @ObservedObject var app: AppModel
    @ObservedObject var codex: CodexClient
    @State private var showContext = false
    @State private var hoverDismissal: Task<Void, Never>?

    private var contextText: String {
        guard let usage = app.session?.contextUsage else { return "使用量は次の応答後に取得します" }
        if let capacity = usage.contextWindow, let fraction = usage.fraction {
            return "使用 \(String(format: "%.1f", fraction * 100))% · \(usage.usedTokens.formatted()) / \(capacity.formatted()) tokens"
        }
        return "使用 \(usage.usedTokens.formatted()) tokens · 上限未取得"
    }
    var body: some View {
        HStack(spacing: 6) {
            Button { showContext = true } label: {
                ZStack {
                    if app.compacting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Circle().stroke(Color.primary.opacity(0.14), lineWidth: 2.5)
                        if let fraction = app.session?.contextUsage?.fraction {
                            Circle().trim(from: 0, to: fraction)
                                .stroke(fraction >= 0.9 ? Color.orange : Color.secondary,
                                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        } else {
                            Circle().stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [2, 3]))
                        }
                    }
                }.frame(width: 15, height: 15).frame(width: 24, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("コンテキスト").accessibilityValue(contextText)
                .onHover { hovering in
                    hoverDismissal?.cancel()
                    if hovering { showContext = true }
                    else { scheduleContextDismissal() }
                }
                .popover(isPresented: $showContext, arrowEdge: .top) {
                    Button {
                        hoverDismissal?.cancel()
                        showContext = false
                        app.compactContext()
                    } label: { Text("圧縮").font(.system(size: 12)).frame(width: 52, height: 24) }
                        .buttonStyle(.plain)
                        .disabled(app.busy || app.applyingTemplate || app.session?.codexThread == nil)
                        .padding(6)
                        .onHover { hovering in
                            hoverDismissal?.cancel()
                            if !hovering { scheduleContextDismissal() }
                        }
                }
            NativeModelPicker(app: app, codex: codex) {
                hoverDismissal?.cancel()
                showContext = false
            }.fixedSize(horizontal: true, vertical: false).frame(height: 28)
        }.onDisappear { hoverDismissal?.cancel() }
    }
    private func scheduleContextDismissal() {
        hoverDismissal = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { showContext = false }
        }
    }
}

/// A single panel whose left edge stays fixed while the effort area grows rightward.
private struct NativeModelPicker: NSViewRepresentable {
    @ObservedObject var app: AppModel
    @ObservedObject var codex: CodexClient
    var onOpen: () -> Void

    func makeCoordinator() -> ModelMenuCoordinator { ModelMenuCoordinator(app: app) }
    func makeNSView(context: Context) -> ModelPickerButton {
        let button = ModelPickerButton(frame: .zero)
        button.isBordered = false
        button.focusRingType = .none
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 12)
        button.alignment = .left
        button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        button.imagePosition = .imageTrailing
        button.imageScaling = .scaleProportionallyDown
        button.target = context.coordinator
        button.action = #selector(ModelMenuCoordinator.toggle(_:))
        button.setAccessibilityLabel("モデルとeffortを選択")
        return button
    }
    func updateNSView(_ button: ModelPickerButton, context: Context) {
        context.coordinator.app = app
        context.coordinator.onOpen = onOpen
        button.isEnabled = !app.busy && !app.applyingTemplate && codex.connected && !codex.models.isEmpty
        let title = NSMutableAttributedString(string: app.modelLabel + " ", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor
        ])
        title.append(NSAttributedString(string: EffortLabel.name(app.resolvedEffort), attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor
        ]))
        button.attributedTitle = title
        button.setAccessibilityValue(app.modelLabel + " · " + EffortLabel.name(app.resolvedEffort))
        button.invalidateIntrinsicContentSize()
        if !button.isEnabled { context.coordinator.close() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ModelPickerButton, context: Context) -> CGSize? {
        CGSize(width: nsView.intrinsicContentSize.width, height: 28)
    }
    static func dismantleNSView(_ nsView: ModelPickerButton, coordinator: ModelMenuCoordinator) { coordinator.close() }
}

@MainActor
private final class ModelMenuCoordinator: NSObject, ObservableObject {
    var app: AppModel
    var onOpen: (() -> Void)?
    @Published var hoveredModel: String?
    @Published var hoveredEffort: String?
    private var modelUnderPointer: String?
    private var pointerInEfforts = false
    var modelScrollOffset: CGFloat = 0
    private var dismissal: Task<Void, Never>?
    private var panel: NSPanel?
    private weak var button: NSButton?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var anchor = NSPoint.zero
    let modelWidth: CGFloat = 185
    let effortWidth: CGFloat = 125
    var height: CGFloat { min(300, CGFloat(app.codex.models.count) * 31 + 10) }
    var highlighted: CodexClient.Model? { app.codex.models.first { $0.id == hoveredModel } }
    init(app: AppModel) { self.app = app }

    @objc func toggle(_ sender: NSButton) {
        if panel != nil { close(); return }
        guard let parent = sender.window else { return }
        onOpen?()
        button = sender
        hoveredModel = nil; hoveredEffort = nil
        modelUnderPointer = nil; pointerInEfforts = false
        let screenRect = parent.convertToScreen(sender.convert(sender.bounds, to: nil))
        let screen = parent.screen?.visibleFrame ?? screenRect
        // Reserve room for expansion before opening, never move the model column on hover.
        let x = min(max(screen.minX + 8, screenRect.minX), screen.maxX - modelWidth - effortWidth - 8)
        let y = min(screenRect.maxY + 6, screen.maxY - height - 8)
        anchor = NSPoint(x: x, y: y)
        let panel = ModelMenuPanel(contentRect: NSRect(origin: anchor, size: NSSize(width: modelWidth, height: height)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.acceptsMouseMovedEvents = true
        panel.appearance = parent.effectiveAppearance
        let hosting = NSHostingView(rootView: ModelMenuContents(menu: self).focusEffectDisabled())
        hosting.sizingOptions = []
        hosting.focusRingType = .none
        panel.contentView = hosting
        self.panel = panel
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .mouseMoved, .leftMouseDragged, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if [.mouseMoved, .leftMouseDragged, .scrollWheel].contains(event.type) {
                self.trackEffortPointer(event)
                return event
            }
            if event.type == .keyDown && event.keyCode == 53 { self.close(); return nil }
            if event.type != .keyDown && event.window !== self.panel {
                if let button = self.button, event.window === button.window {
                    let point = button.convert(event.locationInWindow, from: nil)
                    if button.bounds.contains(point) { return event }
                }
                self.close()
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }
    func hoverModel(_ id: String, inside: Bool) {
        if inside {
            dismissal?.cancel()
            modelUnderPointer = id
            hoveredModel = id
            hoveredEffort = nil
            resize()
        } else if modelUnderPointer == id {
            modelUnderPointer = nil
            scheduleCloseEfforts()
        }
    }
    func openModel(_ id: String) { dismissal?.cancel(); hoveredModel = id; resize() }
    func hoverEfforts(_ inside: Bool) {
        pointerInEfforts = inside
        if inside { dismissal?.cancel() }
        else { hoveredEffort = nil; scheduleCloseEfforts() }
    }
    private func trackEffortPointer(_ event: NSEvent) {
        guard let panel, let hosting = panel.contentView else { return }
        guard event.window === panel else {
            if !panel.frame.contains(NSEvent.mouseLocation) { leavePanel() }
            return
        }
        let point = hosting.convert(event.locationInWindow, from: nil)
        let top = hosting.isFlipped ? point.y : hosting.bounds.height - point.y
        if point.x < modelWidth {
            pointerInEfforts = false
            hoveredEffort = nil
            let offset = top - 5 + modelScrollOffset
            let index = Int(floor(offset / 31))
            if point.x >= 0, offset >= 0, top < height,
               app.codex.models.indices.contains(index), offset.truncatingRemainder(dividingBy: 31) < 29 {
                hoverModel(app.codex.models[index].id, inside: true)
            } else {
                modelUnderPointer = nil
                scheduleCloseEfforts()
            }
            return
        }
        guard let model = highlighted else { return }
        modelUnderPointer = nil
        let index = Int(floor((top - 5) / 31))
        pointerInEfforts = point.x < modelWidth + effortWidth && top >= 0 && top < CGFloat(model.efforts.count) * 31 + 10
        if pointerInEfforts {
            dismissal?.cancel()
            hoveredEffort = model.efforts.indices.contains(index) ? model.efforts[index].id : nil
        } else {
            hoveredEffort = nil
            scheduleCloseEfforts()
        }
    }
    func leavePanel() {
        modelUnderPointer = nil; pointerInEfforts = false; hoveredEffort = nil
        scheduleCloseEfforts()
    }
    func select(_ model: CodexClient.Model, effort: String) { app.selectModel(model, effort: effort); close() }
    private func resize() {
        panel?.setFrame(NSRect(origin: anchor, size: NSSize(width: modelWidth + (highlighted == nil ? 0 : effortWidth), height: height)), display: true)
    }
    private func scheduleCloseEfforts() {
        dismissal?.cancel()
        dismissal = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, modelUnderPointer == nil, !pointerInEfforts else { return }
            hoveredModel = nil; hoveredEffort = nil
            resize()
        }
    }
    func close() {
        dismissal?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        panel = nil
        hoveredModel = nil; hoveredEffort = nil; modelUnderPointer = nil; pointerInEfforts = false
    }
}

private struct ModelMenuContents: View {
    @ObservedObject var menu: ModelMenuCoordinator
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(menu.app.codex.models) { model in
                        Button { menu.openModel(model.id) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark").font(.system(size: 10)).frame(width: 12)
                                    .opacity(model.id == menu.app.resolvedModelID ? 1 : 0)
                                Text(model.label).lineLimit(1)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                            }.font(.system(size: 12)).padding(.horizontal, 8).frame(height: 29).contentShape(Rectangle())
                                .background(menu.highlighted?.id == model.id ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).onHover { menu.hoverModel(model.id, inside: $0) }
                    }
                }.padding(5)
            }.frame(width: menu.modelWidth, height: menu.height)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                    menu.modelScrollOffset = offset
                }
            if let model = menu.highlighted {
                VStack(spacing: 2) {
                    ForEach(model.efforts) { effort in
                        Button { menu.select(model, effort: effort.id) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark").font(.system(size: 10)).frame(width: 12)
                                    .opacity(model.id == menu.app.resolvedModelID && effort.id == menu.app.resolvedEffort ? 1 : 0)
                                Text(effort.label).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 8).frame(height: 29).contentShape(Rectangle())
                                .background(menu.hoveredEffort == effort.id ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).onHover { inside in
                            if inside { menu.hoveredEffort = effort.id }
                            else if menu.hoveredEffort == effort.id { menu.hoveredEffort = nil }
                        }
                    }
                }.padding(5).frame(width: menu.effortWidth, alignment: .topLeading)
                    .onHover { menu.hoverEfforts($0) }
            }
        }.frame(width: menu.modelWidth + (menu.highlighted == nil ? 0 : menu.effortWidth), height: menu.height, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onHover { if !$0 { menu.leavePanel() } }
    }
}

private final class ModelPickerButton: NSButton {
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributedTitle.size().width) + 20, height: 28)
    }
}

private final class ModelMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
