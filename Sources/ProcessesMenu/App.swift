import AppKit

#if !PROCESS_UI_CHECKS
@main
enum ProcessesMenuApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private let controller = ProcessListController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Процессы")
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.delegate = self
        controller.onContentSize = { [weak self] size in self?.popover.contentSize = size }
        controller.onSnapshot = { [weak self] snapshot in
            guard let button = self?.item.button else { return }
            let count = snapshot.leftoverCount
            button.title = count > 0 ? " \(count)" : ""
            button.contentTintColor = count > 0 ? .systemOrange : nil
            button.toolTip = count > 0 ? "Остались после агентов: \(count)" : "Процессы · агенты ничего не оставили"
            button.setAccessibilityLabel(button.toolTip)
        }
        controller.startBackgroundUpdating()
    }

    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            controller.startUpdating()
        }
    }

    func popoverDidClose(_ notification: Notification) { controller.stopUpdating() }
}
