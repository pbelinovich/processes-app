import AppKit

@main
enum PointerUIChecks {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = ProcessListController()
        let window = NSWindow(contentViewController: controller)
        controller.view.layoutSubtreeIfNeeded()
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: .zero,
                                      modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 0, pressure: 0)!
        let checkbox = controller.preventSleep
        checkbox.updateTrackingAreas()
        precondition(checkbox.trackingAreas.contains { $0.options.contains(.cursorUpdate) })
        for enabled in [false, true, false, true] {
            checkbox.isEnabled = enabled
            NSCursor.arrow.set()
            checkbox.cursorUpdate(with: event)
            precondition(NSCursor.current == (enabled ? .pointingHand : .arrow),
                         "Checkbox cursor must reflect enabled state")
        }
        for selected in [0, 1] {
            controller.tabs.selectedSegment = selected
            controller.tabs.updateTrackingAreas()
            precondition(controller.tabs.trackingAreas.contains { $0.options.contains(.cursorUpdate) })
            NSCursor.arrow.set()
            controller.tabs.cursorUpdate(with: event)
            precondition(NSCursor.current == .pointingHand,
                         "Tab hover cursor must not depend on the selected tab")
        }
        controller.tabs.mouseExited(with: event)
        precondition(NSCursor.current == .arrow)
        precondition(!window.isVisible)
        print("PASS: checkbox cursor after enable/disable, both tab selections, pointer exit")
    }
}
