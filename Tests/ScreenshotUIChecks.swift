import AppKit

@main
enum ScreenshotUIChecks {
    @MainActor
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = ProcessInfo.processInfo.environment["PROCESSES_SCREENSHOT_DIR"] ?? "/tmp/processes-ui-01"
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

        func render(_ name: String, snapshot: AttributedSnapshot, dark: Bool = false, all: Bool = false, hover: Bool = false) throws {
            let controller = ProcessListController()
            let window = NSWindow(contentViewController: controller)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            controller.view.appearance = window.appearance
            controller.receive(snapshot)
            controller.selectTab(all ? 1 : 0)
            controller.view.layoutSubtreeIfNeeded()
            controller.table.layoutSubtreeIfNeeded()
            if hover {
                let cell = controller.table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? ProcessCell
                cell?.setHoveredForCheck(true)
            }
            let bounds = controller.view.bounds
            guard let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: bounds) else { fatalError("No bitmap") }
            // AppKit can render an attached view without ordering its window onscreen.
            controller.view.appearance?.performAsCurrentDrawingAppearance {
                controller.view.cacheDisplay(in: bounds, to: bitmap)
            }
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
            precondition(!window.isVisible, "Screenshot checks must never show a window")
            if name.hasPrefix("agents-") {
                precondition(controller.rows.count == 10, "Fixture must include leftovers, three live sessions and collapsed other servers")
                let totalHeight = controller.rows.reduce(CGFloat.zero) { $0 + $1.height }
                precondition(totalHeight <= controller.table.enclosingScrollView!.contentSize.height, "All agent rows must fit without scrolling")
            }
            print("PASS: offscreen \(name) → \(output)/\(name).png")
            withExtendedLifetime(window) {}
        }

        try render("agents-light", snapshot: UIFixtures.agents)
        try render("agents-dark", snapshot: UIFixtures.agents, dark: true)
        try render("empty", snapshot: .empty)
        try render("live-only", snapshot: UIFixtures.liveOnly)
        try render("hover", snapshot: UIFixtures.agents, hover: true)
        try render("all-processes", snapshot: UIFixtures.agents, all: true)
        try render("long-names", snapshot: UIFixtures.longNames)

        let controller = ProcessListController()
        _ = controller.view
        controller.receive(UIFixtures.agents)
        for (query, expected) in [("8000", 91_001), ("91003", 91_003), ("vglub-landing", 91_005)] {
            controller.setQuery(query)
            let ids = controller.rows.compactMap { row -> pid_t? in if case .process(let item, _) = row { return item.id }; return nil }
            precondition(ids == [pid_t(expected)], "Agents search must match port, PID and session project")
        }
        controller.selectTab(1)
        controller.setQuery("54321")
        precondition(controller.rows.count == 1)
        controller.setQuery("sessions-online-third/frontend")
        let ids = controller.rows.compactMap { row -> pid_t? in if case .process(let item, _) = row { return item.id }; return nil }
        precondition(ids == [91_001], "All-processes search must match project path")
        precondition(app.windows.allSatisfy { !$0.isVisible }, "No test window may be visible")
        print("PASS: agent and all-processes search")
    }
}
