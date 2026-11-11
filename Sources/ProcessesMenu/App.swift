import AppKit
import ServiceManagement

#if !PROCESS_UI_CHECKS
@main
enum ProcessesMenuApp {
    static func main() {
        if CommandLine.arguments.contains("--enable-login-item") {
            do {
                try SMAppService.mainApp.register()
                guard SMAppService.mainApp.status == .enabled else {
                    fputs("Allow launch at login in System Settings → General → Login Items.\n", stderr)
                    exit(1)
                }
                print("Launch at login enabled: \(Bundle.main.bundleURL.path)")
                return
            } catch {
                fputs("Could not enable launch at login: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
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
    private var sleepDisabled: Bool?
    private var appearanceObservation: NSKeyValueObservation?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private let quickMenu = NSMenu()
    private let quickSleepItem = NSMenuItem(title: "Keep Mac awake", action: nil, keyEquivalent: "")
    private var quickMenuTask: Task<Void, Never>?

    /// Status bars ignore contentTintColor for template symbols once the button has a title,
    /// so the icon and count are pre-colored for the menu bar's current light or dark appearance.
    private func updateButton() {
        guard let button = item?.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color: NSColor = leftoverCount > 0 ? .systemOrange : dark ? .white : .black
        button.image = StatusIcon.make(color: color, sleepDisabled: sleepDisabled == true)
        button.attributedTitle = NSAttributedString(string: leftoverCount > 0 ? " \(leftoverCount)" : "", attributes: [
            .foregroundColor: color,
            .font: NSFont.menuBarFont(ofSize: 0)
        ])
        let tasks = leftoverCount > 0 ? "Left behind by agents: \(leftoverCount)" : "Processes · no processes left behind by agents"
        let sleep = sleepDisabled.map { $0 ? "Mac sleep disabled" : "Normal Mac sleep" } ?? "Sleep status unknown"
        button.toolTip = tasks + "\n" + sleep
        button.setAccessibilityLabel(button.toolTip)
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
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseUp])
        quickMenu.autoenablesItems = false
        quickSleepItem.target = self
        quickSleepItem.action = #selector(toggleSleepFromMenu)
        quickSleepItem.isEnabled = false
        quickMenu.addItem(quickSleepItem)
        // Handle left clicks on mouse-down and own dismissal, so closing the
        // popover cannot turn the same click into another open on mouse-up.
        popover.behavior = .applicationDefined
        popover.contentViewController = controller
        popover.delegate = self
        controller.onContentSize = { [weak self] size in self?.popover.contentSize = size }
        controller.onSnapshot = { [weak self] snapshot in
            let count = snapshot.leftoverCount
            self?.leftoverCount = count
            self?.updateButton()
        }
        controller.onSleepState = { [weak self] disabled in
            self?.sleepDisabled = disabled
            self?.quickSleepItem.state = disabled == true ? .on : .off
            self?.quickSleepItem.isEnabled = disabled != nil
            self?.updateButton()
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return false }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.popover.performClose(nil); return true }
                } else if !self.isInsidePopoverOrButton(event) {
                    self.popover.performClose(nil)
                }
                return false
            }
            return consumed ? nil : event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                // On newer macOS the system can route menu-bar events through another
                // process. The status button still owns toggling clicks in its bounds.
                if self.isOverStatusButton { return }
                self.popover.performClose(nil)
            }
        }
        controller.startBackgroundUpdating()
    }

    private func isInsidePopoverOrButton(_ event: NSEvent) -> Bool {
        if controller.isViewLoaded, let window = controller.view.window, event.window === window { return true }
        return isOverStatusButton
    }

    private var isOverStatusButton: Bool {
        guard let button = item?.button, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation)
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Clicking the menu bar can deactivate the app before the button action.
        // Keep the popover open until that action handles the same click.
        if isOverStatusButton && NSEvent.pressedMouseButtons != 0 { return }
        popover.performClose(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let globalEventMonitor { NSEvent.removeMonitor(globalEventMonitor) }
    }

    @objc private func toggle() {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showQuickMenu()
            return
        }
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            controller.startUpdating()
        }
    }

    private func showQuickMenu() {
        guard quickMenuTask == nil else { return }
        popover.performClose(nil)
        quickMenuTask = Task { [weak self] in
            guard let self else { return }
            async let systemInformation = SystemInformation.read()
            await controller.prepareSleepMenu()
            let information = await systemInformation
            defer { quickMenuTask = nil }
            guard let button = item.button else { return }
            quickSleepItem.isEnabled = controller.preventSleep.isEnabled
            while quickMenu.items.count > 1 { quickMenu.removeItem(at: 1) }
            quickMenu.addItem(.separator())
            let version = ProcessInfo.processInfo.operatingSystemVersion
            let heading = NSMenuItem(title: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            quickMenu.addItem(heading)
            for row in information.menuRows {
                let menuItem = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
                menuItem.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)
                menuItem.isEnabled = false
                quickMenu.addItem(menuItem)
            }
            quickMenu.addItem(.separator())
            let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            quitItem.target = NSApp
            quickMenu.addItem(quitItem)
            // Let the status item place its menu below the menu bar. Positioning a
            // standalone popup in the button's coordinates can clip its first row
            // at the screen edge and introduce scrolling even for this short menu.
            item.menu = quickMenu
            defer { item.menu = nil }
            button.performClick(nil)
        }
    }

    @objc private func toggleSleepFromMenu() {
        Task { [weak self] in
            guard let self else { return }
            // Serialize with any background state read started while the menu tracked.
            await controller.prepareSleepMenu()
            guard controller.preventSleep.isEnabled else {
                showSleepError("Could not read the sleep setting. Try again.")
                return
            }
            controller.setPreventSleepDisabled(controller.preventSleep.state != .on) { [weak self] message in
                self?.showSleepError(message)
            }
        }
    }

    private func showSleepError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not change the sleep setting"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func popoverDidClose(_ notification: Notification) { controller.stopUpdating() }
}
