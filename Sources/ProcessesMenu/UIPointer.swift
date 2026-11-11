import AppKit

@MainActor
class PointerButton: NSButton {
    override var isEnabled: Bool {
        didSet {
            window?.invalidateCursorRects(for: self)
            if let window, visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                (isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
        }
    }

    private var pointerTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        pointerTracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        (isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseEntered(with event: NSEvent) { cursorUpdate(with: event) }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(visibleRect, cursor: isEnabled ? .pointingHand : .arrow)
    }
}

@MainActor
final class PointerSegmentedControl: NSSegmentedControl {
    override var isEnabled: Bool {
        didSet {
            window?.invalidateCursorRects(for: self)
            if let window, visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                (isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
        }
    }

    private var pointerTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        pointerTracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        (isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseEntered(with event: NSEvent) { cursorUpdate(with: event) }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(visibleRect, cursor: isEnabled ? .pointingHand : .arrow)
    }
}
