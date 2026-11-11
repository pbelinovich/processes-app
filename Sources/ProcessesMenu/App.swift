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
    private var leftoverCount = 0
    private var appearanceObservation: NSKeyValueObservation?

    /// Status bars ignore contentTintColor for template symbols once the button has a title,
    /// so the icon and count are pre-colored for the menu bar's current light or dark appearance.
    private func updateButton() {
        guard let button = item?.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color: NSColor = leftoverCount > 0 ? .systemOrange : dark ? .white : .black
        let icon = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Процессы")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
        icon?.isTemplate = false
        button.image = icon
        button.attributedTitle = NSAttributedString(string: leftoverCount > 0 ? " \(leftoverCount)" : "", attributes: [
            .foregroundColor: color,
            .font: NSFont.menuBarFont(ofSize: 0)
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updateButton() }
        }
        updateButton()
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.delegate = self
        controller.onContentSize = { [weak self] size in self?.popover.contentSize = size }
        controller.onSnapshot = { [weak self] snapshot in
            guard let button = self?.item.button else { return }
            let count = snapshot.leftoverCount
            self?.leftoverCount = count
            self?.updateButton()
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
