import AppKit

@main
enum ScreenshotUIChecks {
    @MainActor
    static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = ProcessInfo.processInfo.environment["PROCESSES_SCREENSHOT_DIR"] ?? "/tmp/processes-ui-02"
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
            controller.view.displayIfNeeded()
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
                precondition(controller.rows.count == 13, "Fixture must include three leftovers, six compact live sessions, two meaningful tasks and collapsed other servers")
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

        let real = await Task.detached(priority: .utility) { Attribution.snapshot() }.value
        try render("real-agents", snapshot: real)

        let controller = ProcessListController()
        _ = controller.view
        controller.receive(UIFixtures.agents)
        let normalProcesses = controller.rows.compactMap { row -> AttributedProcess? in if case .process(let item, _) = row { return item }; return nil }
        precondition(Set(normalProcesses.map(\.id)) == [91_001, 91_003, 91_015, 91_010, 91_014], "Only leftover MCP may occupy ordinary process rows")
        let sessions = controller.rows.compactMap { row -> AgentSession? in if case .session(let session) = row { return session }; return nil }
        precondition(sessions.count == 6 && sessions.prefix(2).allSatisfy { $0.uiPriority == 2 }, "Server/browser sessions must come first")
        precondition(sessions.filter { $0.uiPriority == 0 }.count == 4, "MCP-only and empty sessions stay compact")
        let threeMCP = sessions.first { $0.id == "live-vite" }!
        let header = SessionHeaderCell(session: threeMCP)
        precondition(header.mcpLabel.stringValue == "· MCP 3")
        precondition(header.mcpLabel.toolTip?.contains(threeMCP.uiMCPProcesses[0].entry.displayName) == true)
        let unknownProject = UIFixtures.agents.leftoverSessions.first { $0.projectPath.isEmpty }!
        precondition(unknownProject.uiProjectName == "—", "Unknown projects must never render as root")
        let idle = UIFixtures.session("idle", .codex, "", minutes: 5, state: .idle(seconds: 180), items: [])
        precondition(SessionHeaderCell(session: idle).titleLabel.stringValue.contains("неактивна 3 мин"))
        for (query, expected) in [("8000", [91_001]), ("91003", [91_003]), ("vglub-landing", [91_005, 91_010, 91_011, 91_012, 91_013]), ("Chrome", [91_003, 91_014]), ("8080", [91_006]), ("figma-mcp", [91_012])] {
            controller.setQuery(query)
            let ids = controller.rows.compactMap { row -> pid_t? in if case .process(let item, _) = row { return item.id }; return nil }
            precondition(Set(ids) == Set(expected.map { pid_t($0) }), "Agents search must match port, PID and session project")
        }
        controller.selectTab(1)
        controller.setQuery("3001")
        let portIDs = controller.rows.compactMap { row -> pid_t? in if case .process(let item, _) = row { return item.id }; return nil }
        precondition(portIDs == [91_008], "All-processes search must match a listening port")
        controller.setQuery("sessions-online-third/frontend")
        let ids = controller.rows.compactMap { row -> pid_t? in if case .process(let item, _) = row { return item.id }; return nil }
        precondition(ids == [91_001, 91_002], "All-processes search must match project path, including session children")
        controller.setQuery("vglub-landing")
        let projectIDs = controller.rows.compactMap { row -> pid_t? in if case .process(let item, _) = row { return item.id }; return nil }
        precondition(Set(projectIDs) == [91_005, 91_010, 91_011, 91_012, 91_013], "All-processes search must retain session project context even when process cwd is unavailable")
        controller.setQuery("no-such-fixture")
        guard case .message("Ничего не найдено") = controller.rows.first else { fatalError("No-result search must be explicit") }
        precondition(app.windows.allSatisfy { !$0.isVisible }, "No test window may be visible")
        print("PASS: agent and all-processes search")
    }
}
