import AppKit

@main
enum RefreshChecks {
    @MainActor
    static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }

        let controller = ProcessListController()
        let window = NSWindow(contentViewController: controller)
        controller.selectTab(1)
        controller.setQuery(String(child.processIdentifier))
        controller.view.layoutSubtreeIfNeeded()
        let mouse = NSEvent.mouseLocation
        let center = controller.table.convert(NSPoint(x: 150, y: 80), to: nil)
        let origin = window.convertPoint(toScreen: center)
        window.setFrameOrigin(NSPoint(x: window.frame.minX + mouse.x - origin.x, y: window.frame.minY + mouse.y - origin.y))
        controller.startUpdating()
        defer { controller.stopUpdating() }

        func representedChild() -> AttributedProcess? {
            controller.rows.compactMap { row -> AttributedProcess? in
                if case .process(let item, _) = row, item.id == child.processIdentifier { return item }
                return nil
            }.first
        }
        for _ in 0..<80 {
            if representedChild() != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(representedChild() != nil, "Child must appear in all processes")
        precondition(controller.table.visibleRect.contains(controller.table.convert(window.mouseLocationOutsideOfEventStream, from: nil)),
                     "Regression check requires a pointer over the table")
        let cell = controller.tableView(controller.table, viewFor: controller.table.tableColumns.first, row: 0) as! ProcessCell
        cell.onStop?()
        for _ in 0..<100 {
            if representedChild() == nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(representedChild() == nil, "Stopped process must disappear while pointer remains over table")
        precondition(!window.isVisible && app.windows.allSatisfy { !$0.isVisible }, "Checks must never show windows")
        print("PASS: all-processes refresh after stop with pointer over table, offscreen")
        withExtendedLifetime(window) {}
    }
}
