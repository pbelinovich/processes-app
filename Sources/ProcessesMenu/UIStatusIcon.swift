import AppKit

@MainActor
enum StatusIcon {
    static func make(color: NSColor, sleepDisabled: Bool) -> NSImage? {
        guard let pulse = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Процессы")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])) else { return nil }
        pulse.isTemplate = false
        // Both states must be ordinary images with identical alignment metadata.
        // Switching between an SF Symbol and a drawn image shifts AppKit's anchor.
        let icon = NSImage(size: pulse.size, flipped: false) { rect in
            pulse.draw(in: NSRect(origin: .zero, size: pulse.size))
            if sleepDisabled {
                NSColor.systemBlue.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5, y: rect.minY, width: 5, height: 5)).fill()
            }
            return true
        }
        icon.alignmentRect = pulse.alignmentRect
        icon.isTemplate = false
        return icon
    }
}
