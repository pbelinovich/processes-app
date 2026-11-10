import AppKit

@main
enum RefreshChecks {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }

        let controller = ProcessListController()
        let window = NSWindow(contentViewController: controller)
        let mouse = NSEvent.mouseLocation
        // Put the table under the pointer without showing or activating the window.
        window.setFrameOrigin(NSPoint(x: mouse.x - 300, y: mouse.y - 300))
        controller.view.layoutSubtreeIfNeeded()
        let search = controller.view.subviews.compactMap { $0 as? NSSearchField }.first!
        let table = controller.view.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTableView }.first!
        search.stringValue = String(child.processIdentifier)
        controller.startUpdating()
        defer { controller.stopUpdating() }
        for _ in 0..<50 {
            if controller.numberOfRows(in: table) == 1 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(controller.numberOfRows(in: table) == 1, "Child must appear in the list")
        precondition(table.visibleRect.contains(table.convert(window.mouseLocationOutsideOfEventStream, from: nil)),
                     "Regression check requires a pointer over the table")
        let cell = controller.tableView(table, viewFor: table.tableColumns.first, row: 0) as! ProcessCell
        cell.onTerminate?(false)
        child.waitUntilExit()
        for _ in 0..<50 {
            if controller.numberOfRows(in: table) == 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(controller.numberOfRows(in: table) == 0,
                     "Terminated process must disappear while pointer remains over the table")
        print("PASS: list refresh after termination with pointer over table")
        withExtendedLifetime(window) {}
    }
}
