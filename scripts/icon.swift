import AppKit
import Foundation
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        NSColor(white: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: Double(pixels) * 0.06, dy: Double(pixels) * 0.06), xRadius: Double(pixels) * 0.20, yRadius: Double(pixels) * 0.20).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: Double(pixels) * 0.48, weight: .regular).applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            let aspect = symbol.size.width / symbol.size.height
            let width = Double(pixels) * 0.62
            let height = width / aspect
            symbol.draw(in: NSRect(x: (Double(pixels) - width) / 2, y: (Double(pixels) - height) / 2, width: width, height: height))
        }
        image.unlockFocus()
        let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try representation.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
    }
}
