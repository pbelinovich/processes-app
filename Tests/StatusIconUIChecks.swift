import AppKit

@main
enum StatusIconUIChecks {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for color in [NSColor.black, .white, .systemOrange] {
            let plain = StatusIcon.make(color: color, sleepDisabled: false)!
            let marked = StatusIcon.make(color: color, sleepDisabled: true)!
            precondition(plain.size == marked.size, "Sleep indicator must not resize the status icon")
            precondition(plain.alignmentRect == marked.alignmentRect,
                         "Sleep indicator must preserve layout alignment, including the baseline")
            for title in ["", " 2", " 12"] {
                let button = NSButton()
                button.imagePosition = .imageLeading
                button.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.menuBarFont(ofSize: 0)])
                button.image = plain
                let originalSize = button.fittingSize
                let originalRect = button.cell!.imageRect(forBounds: NSRect(x: 0, y: 0, width: 64, height: 24))
                for image in [marked, plain, marked, plain] {
                    button.image = image
                    precondition(button.fittingSize == originalSize, "Repeated toggles must preserve the menu button size")
                    precondition(button.cell!.imageRect(forBounds: NSRect(x: 0, y: 0, width: 64, height: 24)) == originalRect,
                                 "Repeated toggles must preserve image placement")
                }
            }
        }
        print("PASS: status icon alignment, size and placement remain stable across repeated sleep toggles")
    }
}
