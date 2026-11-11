import AppKit

@MainActor
final class GridOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let colors: [NSColor] = [.systemPink, .systemYellow, .systemCyan, .systemPurple, .systemPink]
        for (index, x) in [CGFloat(12), 28, 42, 62, bounds.width - 12].enumerated() {
            colors[index].withAlphaComponent(0.8).setStroke()
            let line = NSBezierPath()
            line.lineWidth = 0.5
            line.move(to: NSPoint(x: x, y: 0))
            line.line(to: NSPoint(x: x, y: bounds.height))
            line.stroke()
        }
    }
}

@MainActor
final class SpacingOverlay: NSView {
    let gaps: [NSRect]
    init(frame: NSRect, gaps: [NSRect]) { self.gaps = gaps; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        for gap in gaps {
            NSColor.systemPink.withAlphaComponent(0.22).setFill()
            gap.fill()
            ("4 pt" as NSString).draw(at: NSPoint(x: 2, y: gap.minY - 3), withAttributes: [.font: NSFont.systemFont(ofSize: 7), .foregroundColor: NSColor.systemPink])
        }
    }
}

@main
enum ScreenshotUIChecks {
    @MainActor
    static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = ProcessInfo.processInfo.environment["PROCESSES_SCREENSHOT_DIR"] ?? "/tmp/processes-ui-04"
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

        func cache(_ view: NSView, name: String, rect: NSRect? = nil) throws {
            let area = rect ?? view.bounds
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: area) else { fatalError("No bitmap") }
            view.appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: area, to: bitmap) }
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        }
        func render(_ name: String, snapshot: AttributedSnapshot, dark: Bool = true, query: String = "", all: Bool = false, expandedPID: pid_t? = nil, hoverPID: pid_t? = nil, grid: Bool = false, fullCommand: Bool = false) throws {
            let controller = ProcessListController()
            let window = NSWindow(contentViewController: controller)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            controller.view.appearance = window.appearance
            controller.receive(snapshot)
            controller.selectTab(all ? 1 : 0)
            controller.setQuery(query)
            if let expandedPID { controller.toggleProcess(expandedPID) }
            if fullCommand {
                let index = controller.rows.firstIndex { if case .details = $0 { return true }; return false }!
                let cell = controller.tableView(controller.table, viewFor: nil, row: index)!
                cell.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Показать всё" }!.performClick(nil)
            }
            window.setContentSize(controller.preferredContentSize)
            controller.view.layoutSubtreeIfNeeded()
            controller.table.layoutSubtreeIfNeeded()
            if let hoverPID, let row = controller.rows.firstIndex(where: { if case .process(let item, _) = $0 { return item.id == hoverPID }; return false }) {
                let cell = controller.table.view(atColumn: 0, row: row, makeIfNecessary: true) as! ProcessCell
                cell.setHoveredForCheck(true)
                precondition(cell.memoryLabel.isHidden && !cell.stop.isHidden, "Hover must replace memory with Stop")
            }
            var overlay: NSView?
            if grid {
                let lines = GridOverlay(frame: controller.view.bounds)
                controller.view.addSubview(lines)
                overlay = lines
            }
            if name == "session-spacing" {
                let gaps = controller.rows.indices.compactMap { index -> NSRect? in
                    guard case .gap = controller.rows[index] else { return nil }
                    return controller.table.convert(controller.table.rect(ofRow: index), to: controller.view)
                }
                let lines = SpacingOverlay(frame: controller.view.bounds, gaps: gaps)
                controller.view.addSubview(lines)
                overlay = lines
            }
            controller.view.displayIfNeeded()
            try cache(controller.view, name: name)
            if name == "agents-dark" {
                let total = controller.rows.reduce(CGFloat.zero) { $0 + $1.height }
                precondition(total <= controller.table.enclosingScrollView!.contentSize.height + 1, "Default six-session fixture must fit")
                try cache(controller.view, name: "agents-dark-crop", rect: NSRect(x: 0, y: controller.view.bounds.height - 300, width: 560, height: 214))
                let pixels = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: output).appendingPathComponent(name + ".png")))!
                func glyphBottom(in rect: NSRect, blue: Bool) -> Int {
                    let scale = CGFloat(pixels.pixelsWide) / controller.view.bounds.width
                    let top = Int(floor((controller.view.bounds.height - rect.maxY) * scale))
                    let bottom = Int(ceil((controller.view.bounds.height - rect.minY) * scale))
                    var result: Int?
                    for y in max(0, top)..<min(pixels.pixelsHigh, bottom) {
                        for x in max(0, Int(rect.minX * scale))..<min(pixels.pixelsWide, Int(ceil(rect.maxX * scale))) {
                            guard let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                            let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                            let ink = blue ? b > 0.7 && r < 0.5 && g > 0.2 : min(r, g, b) > 0.7 && max(r, g, b) - min(r, g, b) < 0.05
                            if ink { result = y }
                        }
                    }
                    guard let result else { fatalError("Expected rendered glyph pixels") }
                    return result
                }
                for row in controller.rows.indices where row > 0 {
                    if case .gap = controller.rows[row] {
                        let previous = controller.table.rect(ofRow: row - 1)
                        let next = controller.table.rect(ofRow: row + 1)
                        precondition(abs(next.minY - previous.maxY - 4) < 0.01, "Session groups must have exactly 4pt between row bounds")
                    }
                    if case .process = controller.rows[row] { precondition(controller.table.rect(ofRow: row).height == 24) }
                }
                for row in controller.rows.indices {
                    guard let cell = controller.table.view(atColumn: 0, row: row, makeIfNecessary: true) else { continue }
                    cell.layoutSubtreeIfNeeded()
                    if let header = cell as? SessionHeaderCell {
                        precondition(abs(header.chevron.convert(header.chevron.bounds, to: controller.view).minX - 12) < 0.1)
                        precondition(abs(header.convert(header.dot.frame.origin, to: controller.view).x - 28) < 0.1)
                        precondition(abs(header.convert(header.titleLabel.frame.origin, to: controller.view).x - 42) < 0.1)
                        if !header.mcpLabel.stringValue.isEmpty { precondition(abs(header.convert(header.mcpLabel.frame, to: controller.view).maxX - 548) < 0.1) }
                    }
                    if let process = cell as? ProcessCell {
                        precondition(abs(process.convert(process.icon.frame.origin, to: controller.view).x - 42) < 0.1)
                        precondition(abs(process.convert(process.nameLabel.frame.origin, to: controller.view).x - 62) < 0.1)
                        precondition(abs(process.convert(process.memoryLabel.frame, to: controller.view).maxX - 548) < 0.1)
                        precondition(abs(process.convert(process.stop.frame, to: controller.view).maxX - 548) < 0.1)
                        if process.nameLabel.stringValue == "vite" {
                            let nameBottom = glyphBottom(in: process.nameLabel.convert(process.nameLabel.bounds, to: controller.view), blue: false)
                            for port in process.subviews.compactMap({ $0 as? PortButton }) {
                                let portBottom = glyphBottom(in: port.convert(port.bounds, to: controller.view), blue: true)
                                precondition(abs(nameBottom - portBottom) <= 1, "Rendered port digits and process name must share the baseline within one pixel")
                                print("PASS: PNG name/link baseline delta \(abs(nameBottom - portBottom))px")
                            }
                        }
                        precondition(process.subviews.compactMap { $0 as? NSTextField }.count == 2, "Process rows must not repeat session metadata")
                    }
                }
                print("PASS: grid 12/28/42/62/548; content \(total)pt / \(controller.table.enclosingScrollView!.contentSize.height)pt; window \(controller.preferredContentSize.height)pt")
            }
            if name == "process-expanded-dark" {
                let detail = controller.rows.firstIndex { if case .details = $0 { return true }; return false }!
                let cell = controller.table.view(atColumn: 0, row: detail, makeIfNecessary: true)!
                cell.layoutSubtreeIfNeeded()
                let buttons = cell.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
                let bordered = buttons.filter(\.isBordered).sorted { $0.frame.minX < $1.frame.minX }
                for pair in zip(bordered, bordered.dropFirst()) { precondition(pair.1.frame.minX - pair.0.frame.maxX >= 7.5, "Inline buttons need at least 8pt gaps") }
                precondition(bordered.last!.frame.maxX == 548)
                let rect = cell.convert(cell.bounds, to: controller.view)
                try cache(controller.view, name: "process-expanded-crop", rect: rect)
            }
            overlay?.removeFromSuperview()
            precondition(!window.isVisible && (320...640).contains(controller.preferredContentSize.height))
            print("PASS: offscreen \(name) → \(output)/\(name).png")
            withExtendedLifetime(window) {}
        }

        let fixture = UIFixtures.agents
        try render("agents-dark", snapshot: fixture)
        try render("agents-light", snapshot: fixture, dark: false)
        try render("session-collapsed-expanded", snapshot: fixture)
        try render("process-expanded-dark", snapshot: fixture, query: "8000", expandedPID: 91_001)
        try render("hover-stop", snapshot: fixture, hoverPID: 91_001)
        try render("empty-dark", snapshot: .empty)
        try render("grid-check", snapshot: fixture, grid: true)
        try render("session-spacing", snapshot: fixture)
        try render("all-processes", snapshot: fixture, all: true)
        let real = await Task.detached(priority: .utility) { Attribution.snapshot() }.value
        try render("real-dark", snapshot: real)

        let controller = ProcessListController()
        _ = controller.view
        controller.receive(fixture)
        func sessionRow(_ id: String) -> Int {
            controller.rows.firstIndex { if case .session(let session, _, _) = $0 { return session.id == id }; return false }!
        }
        func processIDs() -> Set<pid_t> {
            Set(controller.rows.compactMap { if case .process(let item, _) = $0 { return item.id }; return nil })
        }
        precondition(processIDs().contains(91_011), "Expanded significant sessions include MCP")
        precondition(!processIDs().contains(91_004), "MCP-only session is collapsed by default")
        let defaults = ProcessListController()
        _ = defaults.view
        defaults.receive(fixture)
        let original = fixture.liveSessions.first { $0.id == "live-vite" }!
        let nowEmpty = AgentSession(id: original.id, kind: original.kind, sessionID: original.sessionID, agentPID: original.agentPID, projectPath: original.projectPath, startedSeconds: original.startedSeconds, state: original.state, processes: [])
        defaults.receive(AttributedSnapshot(liveSessions: [nowEmpty], leftoverSessions: [], otherServers: [], all: []))
        precondition(defaults.rows.contains { if case .session(let session, let expanded, _) = $0 { return session.id == original.id && expanded }; return false }, "Initial disclosure state must survive changes to session processes")
        controller.activateRow(sessionRow("live-codex"))
        precondition(processIDs().contains(91_004))
        let emptyRow = sessionRow("live-empty")
        let emptyRows = controller.rows.count
        controller.activateRow(emptyRow)
        precondition(controller.rows.count == emptyRows, "Sessions without tasks do not toggle")
        let emptyCell = controller.tableView(controller.table, viewFor: nil, row: emptyRow) as! SessionHeaderCell
        precondition(emptyCell.chevron.isHidden, "Sessions without tasks have no disclosure chevron")
        controller.receive(fixture)
        precondition(processIDs().contains(91_004), "Expansion must survive snapshots")
        controller.activateRow(sessionRow("live-vite"))
        controller.receive(fixture)
        precondition(!processIDs().contains(91_010), "Explicit collapse must survive snapshots")
        let otherIndex = controller.rows.firstIndex { if case .other = $0 { return true }; return false }!
        controller.activateRow(otherIndex)
        controller.receive(fixture)
        precondition(processIDs().contains(91_006), "Other servers disclosure survives refresh")
        controller.toggleProcess(91_001)
        controller.toggleProcess(91_015)
        precondition(controller.rows.filter { if case .details = $0 { return true }; return false }.count == 1, "Only one process may expand")
        for (query, expected) in [("8000", [91_001]), ("91015", [91_015]), ("figma-mcp", [91_012]), ("8080", [91_006])] {
            controller.setQuery(query)
            precondition(processIDs() == Set(expected.map { pid_t($0) }), "Search must reveal matching processes even in collapsed sessions")
        }
        controller.setQuery("figma-mcp")
        controller.activateRow(sessionRow("live-vite"))
        precondition(processIDs().isEmpty, "Search headers still respond to collapse")
        controller.receive(fixture)
        precondition(processIDs().isEmpty, "Search collapse survives refresh")
        controller.setQuery("")
        precondition(!processIDs().contains(91_010), "Search disclosure must not overwrite ordinary disclosure")

        var longEntry = UIFixtures.entry(91_020, "vite", ports: ["8000"], cwd: "/fixture/project")
        longEntry.command = "/fixture/bin/vite " + Array(repeating: "--fixture-option=long-value", count: 64).joined(separator: " ")
        let longItem = UIFixtures.item(longEntry, role: .server)
        let longSession = UIFixtures.session("long-command", .codex, "project", minutes: 1, items: [longItem])
        let longSnapshot = AttributedSnapshot(liveSessions: [longSession], leftoverSessions: [], otherServers: [], all: [longEntry])
        let longController = ProcessListController()
        _ = longController.view
        longController.receive(longSnapshot)
        longController.toggleProcess(longEntry.pid)
        let detailRow = longController.rows.firstIndex { if case .details = $0 { return true }; return false }!
        let detail = longController.tableView(longController.table, viewFor: nil, row: detailRow) as! InlineDetailsCell
        let command = detail.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == longEntry.command }!
        precondition(command.isSelectable && command.maximumNumberOfLines == 3)
        let showAll = detail.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Показать всё" }!
        precondition(!showAll.isHidden)
        let initialHeight = longController.rows[detailRow].height
        showAll.performClick(nil)
        precondition(longController.rows[detailRow].height > initialHeight, "Show all expands the full command inline")
        precondition(longController.preferredContentSize.height == 640, "Long details cap the window and scroll")
        try render("command-preview-dark", snapshot: longSnapshot, expandedPID: 91_020)
        try render("command-full-dark", snapshot: longSnapshot, expandedPID: 91_020, fullCommand: true)
        controller.selectTab(1)
        controller.setQuery("sessions-online-third/frontend")
        precondition(processIDs() == [91_001, 91_002], "All processes retains session project context")
        controller.setQuery("no-such-fixture")
        precondition(processIDs().isEmpty)
        precondition(controller.preferredContentSize.height == 320, "Empty lists shrink to minimum height")
        precondition(app.windows.allSatisfy { !$0.isVisible }, "No windows may be shown")
        print("PASS: persistent session disclosure, one inline process, search and content sizing")
    }
}
