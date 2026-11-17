import AppKit
import SwiftUI

/// Return is handled before the input method sees the key. In particular, a
/// Return that starts with marked text can never also submit after committing it.
class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onTextChange: ((String) -> Void)?
    var placeholder = "" { didSet { needsDisplay = true } }
    var shouldShowPlaceholder: Bool { string.isEmpty && !hasMarkedText() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard shouldShowPlaceholder, !placeholder.isEmpty else { return }
        (placeholder as NSString).draw(at: textContainerOrigin, withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor
        ])
    }
    override func didChangeText() {
        super.didChangeText()
        onTextChange?(string)
        needsDisplay = true
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onTextChange?(self.string)
        needsDisplay = true
    }
    override func unmarkText() {
        super.unmarkText()
        onTextChange?(string)
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && hasMarkedText() { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if isReturn && modifiers.isEmpty {
            if !event.isARepeat { onSubmit?() }
            return
        }
        super.keyDown(with: event)
    }
}

struct SubmitTextEditor: NSViewRepresentable {
    @Binding var text: String
    var compact = false
    var focusRequest = 0
    var accessibilityLabel: String
    var placeholder = ""
    var onSubmit: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SubmitTextEditor
        var focusRequest = 0
        init(_ parent: SubmitTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if parent.text != view.string { parent.text = view.string }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.focusRingType = .none
        let view = SubmitTextView(frame: .zero)
        view.isRichText = false; view.importsGraphics = false
        view.isEditable = true; view.isSelectable = true
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainerInset = NSSize(width: 0, height: 6)
        view.font = .systemFont(ofSize: 13)
        view.drawsBackground = false; view.focusRingType = .none
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.allowsUndo = true
        view.delegate = context.coordinator
        view.string = text
        view.onTextChange = { [weak coordinator = context.coordinator] value in
            guard let coordinator, coordinator.parent.text != value else { return }
            coordinator.parent.text = value
        }
        view.onSubmit = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            if coordinator.parent.text != view.string { coordinator.parent.text = view.string }
            coordinator.parent.onSubmit()
        }
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? SubmitTextView else { return }
        view.textColor = .labelColor; view.insertionPointColor = .labelColor
        view.setAccessibilityLabel(accessibilityLabel)
        view.placeholder = placeholder
        if view.string != text && !view.hasMarkedText() {
            let cursor = min(view.selectedRange().location, (text as NSString).length)
            view.string = text
            view.needsDisplay = true
            view.setSelectedRange(NSRange(location: cursor, length: 0))
        }
        if focusRequest != context.coordinator.focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard compact, let width = proposal.width else { return nil }
        let font = NSFont.systemFont(ofSize: 13)
        let measured = (text.isEmpty ? " " : text + " ") as NSString
        let height = measured.boundingRect(with: NSSize(width: max(1, width - 16), height: CGFloat.greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        return CGSize(width: width, height: min(126, max(30, ceil(height) + 12)))
    }
}

/// A legacy scroller stays visible even when macOS is set to hide overlay
/// scrollbars. These rows have a fixed height, so the document height is exact.
struct PersistentPhraseScrollView<Content: View>: NSViewRepresentable {
    let contentHeight: CGFloat
    @ViewBuilder var content: () -> Content
    static var gutter: CGFloat { NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) }
    func makeNSView(context: Context) -> PhraseScrollView<Content> {
        PhraseScrollView(content: content(), height: contentHeight)
    }
    func updateNSView(_ view: PhraseScrollView<Content>, context: Context) {
        view.host.rootView = content()
        view.documentHeight = contentHeight
        view.needsLayout = true
    }
}
final class PhraseScrollView<Content: View>: NSScrollView {
    let host: NSHostingView<Content>
    var documentHeight: CGFloat
    init(content: Content, height: CGFloat) {
        host = NSHostingView(rootView: content)
        documentHeight = height
        super.init(frame: .zero)
        drawsBackground = false; borderType = .noBorder
        hasVerticalScroller = true; hasHorizontalScroller = false
        autohidesScrollers = false; scrollerStyle = .legacy
        verticalScroller?.controlSize = .regular
        focusRingType = .none
        host.sizingOptions = []; host.focusRingType = .none
        documentView = host
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let size = NSSize(width: contentView.bounds.width, height: documentHeight)
        if host.frame.size != size { host.setFrameSize(size) }
    }
}
