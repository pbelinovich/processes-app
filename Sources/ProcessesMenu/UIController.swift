import AppKit

/// Table rows preserve process identity across refreshes; actions capture the represented item.
enum ProcessRow {
    case leftovers(Int)
    case session(AgentSession)
    case process(AttributedProcess, AgentSession?)
    case message(String)
    case other(String, Bool)

    var height: CGFloat {
        switch self {
        case .leftovers: 38
        case .session: 32
        case .process(_, let session): session?.state == .ended || isIdle(session?.state) ? 48 : 28
        case .message: 30
        case .other: 40
        }
    }

    private func isIdle(_ state: SessionState?) -> Bool {
        if case .idle = state { return true }
        return false
    }
}

@MainActor
final class ProcessListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let search = NSSearchField()
    let table = NSTableView()
    let tabs = NSSegmentedControl(labels: ["Агенты", "Все процессы"], trackingMode: .selectOne, target: nil, action: nil)
    private let status = NSTextField(labelWithString: "Загрузка…")
    private let scroll = NSScrollView()
    private var snapshot: AttributedSnapshot = .empty
    private var projectByPID: [pid_t: String] = [:]
    private(set) var rows: [ProcessRow] = []
    private var otherExpanded = false
    private var timer: Timer?
    private var backgroundUpdates = false
    private var refreshTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var followupTask: Task<Void, Never>?
    private var statusMessage: String?
    private var stopErrors: String?
    private var stoppingPIDs: Set<pid_t> = []
    private let details = NSPopover()
    var onSnapshot: ((AttributedSnapshot) -> Void)?

    override func loadView() {
        view = UIBackgroundView(frame: NSRect(x: 0, y: 0, width: 560, height: 640))
        preferredContentSize = view.frame.size
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(filtersChanged)
        tabs.segmentStyle = .rounded
        search.placeholderString = "Имя, порт, проект или PID"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Обновить")!, target: self, action: #selector(refreshNow))
        refresh.bezelStyle = .inline
        refresh.toolTip = "Обновить сейчас"
        let quit = NSButton(title: "Выйти", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .inline
        quit.font = .systemFont(ofSize: 11)
        status.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let column = NSTableColumn(identifier: .init("process"))
        column.width = 536
        table.addTableColumn(column)
        table.headerView = nil
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = table
        let separator = NSBox()
        separator.boxType = .separator
        for child in [tabs, search, refresh, scroll, separator, status, quit] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            search.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: refresh.leadingAnchor, constant: -8),
            search.heightAnchor.constraint(equalToConstant: 28),
            refresh.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),
            refresh.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            refresh.widthAnchor.constraint(equalToConstant: 24),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -5),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -34),
            status.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            status.centerYAnchor.constraint(equalTo: quit.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: quit.leadingAnchor, constant: -8),
            quit.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),
            quit.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -9)
        ])
        rebuildRows()
    }

    func startBackgroundUpdating() {
        backgroundUpdates = true
        scheduleRefresh(every: 15)
        refreshNow()
    }

    func startUpdating() {
        _ = view
        scheduleRefresh(every: 3)
        refreshNow()
        view.window?.makeFirstResponder(search)
    }

    func stopUpdating() {
        timer?.invalidate()
        timer = nil
        if backgroundUpdates { scheduleRefresh(every: 15) }
        // A pending snapshot and stop continue when the popover closes.
    }

    private func scheduleRefresh(every seconds: TimeInterval) {
        timer?.invalidate()
        let refreshTimer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfNeeded() }
        }
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer
    }

    @objc func refreshNow() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshIfNeeded()
    }

    private func refreshIfNeeded() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Attribution.snapshot() }.value
            guard !Task.isCancelled, let self else { return }
            receive(result)
            refreshTask = nil
        }
    }

    func receive(_ result: AttributedSnapshot) {
        snapshot = result
        projectByPID = [:]
        for session in result.liveSessions + result.leftoverSessions {
            for item in session.processes {
                projectByPID[item.id] = session.projectPath
                for entry in item.tree { projectByPID[entry.pid] = session.projectPath }
            }
            if let pid = session.agentPID { projectByPID[pid] = session.projectPath }
        }
        onSnapshot?(result)
        if isViewLoaded { rebuildRows() }
    }

    func selectTab(_ index: Int) {
        _ = view
        tabs.selectedSegment = index
        rebuildRows()
    }

    func setQuery(_ value: String) {
        search.stringValue = value
        rebuildRows()
    }

    func controlTextDidChange(_ obj: Notification) { rebuildRows() }
    @objc private func filtersChanged() { rebuildRows() }

    private func matches(_ entry: ProcessEntry, project: String = "") -> Bool {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || [entry.displayName, entry.name, entry.command, entry.workingDirectory, String(entry.pid), project, projectByPID[entry.pid] ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(query) }
            || entry.listeningPorts.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func matchingProcesses(_ session: AgentSession) -> [AttributedProcess] {
        session.processes.filter { $0.depth == 0 && matches($0.entry, project: session.projectPath + " " + session.kind.displayName) }
    }

    private func rebuildRows() {
        rows = []
        if tabs.selectedSegment == 1 {
            rows = snapshot.all.filter { matches($0) }.sorted {
                let left = $0.residentBytes ?? 0, right = $1.residentBytes ?? 0
                return left == right ? $0.pid < $1.pid : left > right
            }.map { .process(AttributedProcess(entry: $0, role: $0.listeningPorts.isEmpty ? .other : .server, depth: 0, tree: [$0]), nil) }
        } else {
            let leftovers = snapshot.leftoverSessions.flatMap { session in matchingProcesses(session).map { ProcessRow.process($0, session) } }
            if !leftovers.isEmpty {
                rows.append(.leftovers(leftovers.count))
                rows += leftovers
            } else if search.stringValue.isEmpty && snapshot.leftoverCount == 0 {
                rows.append(.message("Агенты ничего не оставили ✓"))
            }
            let orderedSessions = snapshot.liveSessions.enumerated().sorted {
                let left = $0.element.uiPriority, right = $1.element.uiPriority
                return left == right ? $0.offset < $1.offset : left > right
            }.map(\.element)
            for session in orderedSessions {
                let items = matchingProcesses(session)
                let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let projectMatches = (session.projectPath + " " + session.kind.displayName).localizedCaseInsensitiveContains(query)
                guard query.isEmpty || !items.isEmpty || projectMatches else { continue }
                rows.append(.session(session))
                // MCP stays discoverable through explicit search and session details.
                let visible = query.isEmpty ? items.filter { $0.role != .mcp } : items
                rows += visible.map { .process($0, session) }
            }
            let other = snapshot.otherServers.filter { matches($0.entry) }
            if !other.isEmpty {
                let expanded = otherExpanded || !search.stringValue.isEmpty
                let summary = other.map { $0.entry.displayName + $0.entry.listeningPorts.map { " :" + $0 }.joined(separator: ",") }.joined(separator: ", ")
                rows.append(.other(summary, expanded))
                if expanded { rows += other.map { .process($0, nil) } }
            }
        }
        if rows.isEmpty { rows = [.message("Ничего не найдено")] }
        status.stringValue = statusMessage ?? (tabs.selectedSegment == 1
            ? "Процессов: \(snapshot.all.filter { matches($0) }.count) · RSS · каждые 3 с"
            : "Сессий: \(snapshot.liveSessions.count) · осталось: \(snapshot.leftoverCount) · каждые 3 с")
        status.toolTip = stopErrors ?? status.stringValue
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].height }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .process(let item, let session):
            let cell = tableView.makeView(withIdentifier: .init("process"), owner: self) as? ProcessCell ?? ProcessCell()
            cell.identifier = .init("process")
            cell.configure(item, session: session, showPID: tabs.selectedSegment == 1, stopping: stoppingPIDs.contains(item.id))
            cell.onStop = { [weak self] in self?.stopItems([item]) }
            return cell
        case .leftovers(let count):
            return UISectionCell(title: "⚠ Остались после агентов (\(count))", accent: true, buttonTitle: "Остановить все") { [weak self] in self?.confirmStopAll() }
        case .session(let session):
            return SessionHeaderCell(session: session)
        case .message(let text):
            return UISectionCell(title: text, secondary: true)
        case .other(let summary, let expanded):
            return UISectionCell(title: "\(expanded ? "▾" : "▸") Прочие серверы (не от агентов)", subtitle: summary, secondary: true)
        }
    }

    @objc private func rowClicked() {
        guard rows.indices.contains(table.clickedRow) else { return }
        switch rows[table.clickedRow] {
        case .other:
            otherExpanded.toggle()
            rebuildRows()
        case .session(let session):
            guard let cell = table.view(atColumn: 0, row: table.clickedRow, makeIfNecessary: true) else { return }
            showPopover(SessionDetailsController(session: session), from: cell)
        case .process(let item, _):
            guard let cell = table.view(atColumn: 0, row: table.clickedRow, makeIfNecessary: true) else { return }
            showPopover(ProcessDetailsController(item: item), from: cell)
        default: break
        }
    }

    private func showPopover(_ controller: NSViewController, from cell: NSView) {
        details.close()
        details.behavior = .transient
        details.contentViewController = controller
        details.show(relativeTo: cell.bounds, of: cell, preferredEdge: .maxX)
    }

    private func confirmStopAll() {
        let items = snapshot.leftoverSessions.flatMap { $0.processes.filter { $0.depth == 0 } }
        guard !items.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Остановить всё, что осталось после агентов?"
        alert.informativeText = "Будут остановлены процессы и их дочерние задачи:\n\n" + snapshot.leftoverSessions.flatMap { session in
            session.processes.filter { $0.depth == 0 }.map { "• \($0.entry.displayName)\($0.entry.listeningPorts.map { " :" + $0 }.joined()) · \(session.kind.displayName) · \(session.uiProjectName) · PID \($0.id)" }
        }.joined(separator: "\n") + "\n\nЕсли процесс не ответит, он будет завершён принудительно."
        alert.addButton(withTitle: "Отмена")
        alert.addButton(withTitle: "Остановить все")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        stopItems(items)
    }

    func stopItems(_ items: [AttributedProcess]) {
        guard stopTask == nil else { return }
        var seen: Set<pid_t> = []
        let tree = items.flatMap(\.tree).filter { seen.insert($0.pid).inserted }
        guard !tree.isEmpty else { return }
        stoppingPIDs = Set(items.map(\.id))
        stopErrors = nil
        statusMessage = "Останавливаем \(items.count)…"
        rebuildRows()
        stopTask = Task { [weak self] in
            let result = await ProcessService.stop(tree)
            guard let self else { return }
            stoppingPIDs = []
            let total = result.stopped.count + result.killed.count
            statusMessage = "Остановлено \(total) процесса, \(result.killed.count) принудительно"
                + (result.failed.isEmpty ? "" : " · ошибок: \(result.failed.count)")
            stopErrors = result.failed.isEmpty ? nil : result.failed.sorted { $0.key < $1.key }.map { "PID \($0.key): \($0.value)" }.joined(separator: "\n")
            stopTask = nil
            rebuildRows()
            refreshNow()
            // Collect follow-up snapshots after asynchronous process exit and regrouping.
            followupTask?.cancel()
            followupTask = Task { [weak self] in
                for delay in [300_000_000, 800_000_000] {
                    do { try await Task.sleep(nanoseconds: UInt64(delay)) } catch { return }
                    self?.refreshNow()
                }
            }
        }
    }
}

extension SessionState {
    var uiSuffix: String {
        switch self {
        case .active: ""
        case .ended: " · сессия завершена"
        case .idle(let seconds): " · неактивна \(ProcessEntry.durationLabel(seconds: seconds))"
        }
    }
}

/// An opaque AppKit surface also makes cacheDisplay screenshots match the popover.
@MainActor
final class UIBackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}

extension AgentSession {
    /// Preserve the containing project when a session is rooted in a common subdirectory.
    var uiProjectName: String {
        let path = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path != "/" else { return "—" }
        if ["frontend", "backend", "client", "server", "web"].contains(projectName) {
            let parent = (projectPath as NSString).deletingLastPathComponent
            let prefix = (parent as NSString).lastPathComponent
            if !prefix.isEmpty { return prefix + "/" + projectName }
        }
        return projectName == "/" || projectName.isEmpty ? "—" : projectName
    }

    var uiMCPProcesses: [AttributedProcess] { processes.filter { $0.depth == 0 && $0.role == .mcp } }

    var uiPriority: Int {
        let items = processes.filter { $0.depth == 0 }
        if items.contains(where: { $0.role == .server || $0.role == .browser }) { return 2 }
        return items.contains(where: { $0.role != .mcp }) ? 1 : 0
    }
}
