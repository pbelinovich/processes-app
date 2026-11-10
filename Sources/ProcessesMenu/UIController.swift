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
        case .session: 34
        case .process(_, let session): session?.state == .ended || isIdle(session?.state) ? 48 : 30
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
    private(set) var rows: [ProcessRow] = []
    private var otherExpanded = false
    private var timer: Timer?
    private var backgroundUpdates = false
    private var refreshTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var followupTask: Task<Void, Never>?
    private var statusMessage: String?
    private var stoppingPIDs: Set<pid_t> = []
    private let details = NSPopover()
    var onSnapshot: ((AttributedSnapshot) -> Void)?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 640))
        view.wantsLayer = true
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
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfNeeded() }
        }
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
        return query.isEmpty || [entry.name, entry.command, entry.workingDirectory, String(entry.pid), project]
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
            for session in snapshot.liveSessions {
                let items = matchingProcesses(session)
                let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let projectMatches = (session.projectPath + " " + session.kind.displayName).localizedCaseInsensitiveContains(query)
                guard query.isEmpty || !items.isEmpty || projectMatches else { continue }
                rows.append(.session(session))
                if items.isEmpty { rows.append(.message(query.isEmpty || session.processes.isEmpty ? "ничего не запущено" : "Нет совпадений в сессии")) }
                else { rows += items.map { .process($0, session) } }
            }
            let other = snapshot.otherServers.filter { matches($0.entry) }
            if !other.isEmpty {
                let expanded = otherExpanded || !search.stringValue.isEmpty
                let summary = other.map { $0.entry.name + $0.entry.listeningPorts.map { " :" + $0 }.joined(separator: ",") }.joined(separator: ", ")
                rows.append(.other(summary, expanded))
                if expanded { rows += other.map { .process($0, nil) } }
            }
        }
        if rows.isEmpty { rows = [.message("Ничего не найдено")] }
        status.stringValue = statusMessage ?? (tabs.selectedSegment == 1
            ? "Процессов: \(snapshot.all.filter { matches($0) }.count) · RSS · каждые 3 с"
            : "Сессий: \(snapshot.liveSessions.count) · осталось: \(snapshot.leftoverCount) · каждые 3 с")
        status.toolTip = status.stringValue
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
            let age = ProcessEntry.durationLabel(seconds: max(0, Int(Date().timeIntervalSince1970) - Int(session.startedSeconds)))
            return UISectionCell(title: "● \(session.kind.displayName) · \(session.projectName) · \(age)" + session.state.uiSuffix, accent: false)
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
        case .process(let item, _):
            guard let cell = table.view(atColumn: 0, row: table.clickedRow, makeIfNecessary: true) else { return }
            details.close()
            details.behavior = .transient
            details.contentViewController = ProcessDetailsController(item: item)
            details.show(relativeTo: cell.bounds, of: cell, preferredEdge: .maxX)
        default: break
        }
    }

    private func confirmStopAll() {
        let items = snapshot.leftoverSessions.flatMap { $0.processes.filter { $0.depth == 0 } }
        guard !items.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Остановить всё, что осталось после агентов?"
        alert.informativeText = "Будут остановлены процессы и их дочерние задачи:\n\n" + snapshot.leftoverSessions.flatMap { session in
            session.processes.filter { $0.depth == 0 }.map { "• \($0.entry.name)\($0.entry.listeningPorts.map { " :" + $0 }.joined()) · \(session.kind.displayName) · \(session.projectName) · PID \($0.id)" }
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
        statusMessage = "Останавливаем \(items.count)…"
        rebuildRows()
        stopTask = Task { [weak self] in
            let result = await ProcessService.stop(tree)
            guard let self else { return }
            stoppingPIDs = []
            let total = result.stopped.count + result.killed.count
            statusMessage = "Остановлено \(total) процесса, \(result.killed.count) принудительно"
                + (result.failed.isEmpty ? "" : " · ошибок: \(result.failed.count)")
            status.toolTip = result.failed.sorted { $0.key < $1.key }.map { "PID \($0.key): \($0.value)" }.joined(separator: "\n")
            stopTask = nil
            rebuildRows()
            refreshNow()
            // The stub returns after SIGTERM; the real implementation waits for exit.
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
