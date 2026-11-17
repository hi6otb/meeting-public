import SwiftUI

/// Compare grapheme clusters so revisions never split Japanese combining marks
/// or emoji. The unchanged suffix is kept still for corrections in mid-sentence.
struct TextRevision: Equatable {
    let prefix: String
    let changed: String
    let suffix: String
    init(previous: String, current: String) {
        let old = Array(previous), new = Array(current)
        var start = 0
        while start < min(old.count, new.count), old[start] == new[start] { start += 1 }
        var tail = 0
        while tail < min(old.count, new.count) - start,
              old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        prefix = String(new[..<start])
        changed = String(new[start..<(new.count - tail)])
        suffix = String(new[(new.count - tail)...])
    }
}

private struct RevealAttribute: TextAttribute {}

private struct BlurRevealRenderer: TextRenderer {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let runs = layout.flatMap { $0 }
        let count = runs.filter { $0[RevealAttribute.self] != nil }.reduce(0) { $0 + $1.count }
        var index = 0
        for run in runs {
            guard run[RevealAttribute.self] != nil else { context.draw(run); continue }
            for slice in run {
                // A travelling, soft reveal. Width changes never affect timing.
                let offset = Double(index) / Double(max(1, count - 1)) * 0.65
                let visible = min(1, max(0, (progress - offset) / 0.35))
                var copy = context
                copy.opacity *= visible
                if visible < 1 { copy.addFilter(.blur(radius: (1 - visible) * 3.5)) }
                copy.draw(slice, options: .disablesSubpixelQuantization)
                index += 1
            }
        }
    }
}

struct BlurRevealText: View {
    let text: String
    var animateInitial = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayed: String?
    @State private var revision = TextRevision(previous: "", current: "")
    @State private var progress = 1.0

    var body: some View {
        let parts = displayed == nil ? TextRevision(previous: text, current: text) : revision
        Text("\(Text(parts.prefix))\(Text(parts.changed).customAttribute(RevealAttribute()))\(Text(parts.suffix))")
            .textRenderer(BlurRevealRenderer(progress: progress))
            .task(id: text) {
                let previous = displayed ?? (animateInitial ? "" : text)
                let next = TextRevision(previous: previous, current: text)
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) {
                    displayed = text; revision = next
                    progress = reduceMotion || next.changed.isEmpty ? 1 : 0
                }
                guard progress == 0 else { return }
                // Separate the initial state from the animation transaction.
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                let duration = min(0.65, 0.22 + Double(next.changed.count) * 0.008)
                withAnimation(.easeOut(duration: duration)) { progress = 1 }
            }
    }
}
