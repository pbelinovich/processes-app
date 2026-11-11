import AppKit

/// Table rows preserve process identity across refreshes; actions capture the represented item.
@MainActor
enum ProcessRow {
    case leftovers(Int)
    case session(AgentSession, Bool, Bool)
    case process(AttributedProcess, AgentSession?)
    case details(AttributedProcess, Bool)
    case message(String)
    case other(Int, Bool)
    case gap

    var height: CGFloat {
        switch self {
        case .leftovers: 30
        case .session, .other: 28
        case .process: 24
        case .details(let item, let full): InlineDetailsCell.height(for: item, fullCommand: full)
        case .message: 26
        case .gap: 4
        }
    }

}

@MainActor
final class ProcessListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let search = NSSearchField()
    let table = NSTableView()
    let tabs = PointerSegmentedControl(labels: ["Agents", "All processes"], trackingMode: .selectOne, target: nil, action: nil)
    private let status = NSTextField(labelWithString: "Loading…")
    private let scroll = NSScrollView()
    let systemSummary = SystemSummaryView()
    private var systemTask: Task<Void, Never>?
    private var panelIsOpen = false
    let preventSleep = PointerButton(checkboxWithTitle: "Keep Mac awake with the lid closed", target: nil, action: nil)
    private let sleepControl = SleepControl()
    private var sleepTask: Task<Void, Never>?
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
    private var expandedSessions: [String: Bool] = [:]
    private var searchDisclosure: [String: Bool] = [:]
    private var searchOtherExpanded: Bool?
    private var expandedProcess: pid_t?
    private var fullCommand = false
    var onContentSize: ((NSSize) -> Void)?
    var onSnapshot: ((AttributedSnapshot) -> Void)?
    var onSleepState: ((Bool?) -> Void)?

    override func loadView() {
        view = UIBackgroundView(frame: NSRect(x: 0, y: 0, width: 560, height: 640))
        preferredContentSize = view.frame.size
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(filtersChanged)
        tabs.segmentStyle = .rounded
        search.placeholderString = "Name, port, project, or PID"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        let refresh = PointerButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!, target: self, action: #selector(refreshNow))
        refresh.bezelStyle = .rounded
        refresh.controlSize = .regular
        refresh.toolTip = "Refresh now"
        let quit = PointerButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        quit.controlSize = .small
        quit.font = .systemFont(ofSize: 11)
        FooterTextStyle.apply(to: status)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preventSleep.cell = AlignedCheckboxCell(textCell: preventSleep.title)
        preventSleep.setButtonType(.switch)
        preventSleep.target = self
        preventSleep.action = #selector(togglePreventSleep)
        preventSleep.font = .systemFont(ofSize: 12)
        preventSleep.isEnabled = false
        preventSleep.toolTip = "The first change requires an administrator password to set up access. Later changes need no password. Works on power and battery. Do not put an awake Mac in a bag."
        let column = NSTableColumn(identifier: .init("process"))
        column.width = 560
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowSizeStyle = .custom
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
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.documentView = table
        let separator = NSBox()
        separator.boxType = .separator
        for child in [tabs, search, refresh, scroll, separator, systemSummary, preventSleep, status, quit] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            tabs.heightAnchor.constraint(equalToConstant: 28),
            search.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: refresh.leadingAnchor, constant: -8),
            search.heightAnchor.constraint(equalToConstant: 28),
            refresh.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),
            refresh.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            refresh.widthAnchor.constraint(equalToConstant: 28),
            refresh.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -65),
            systemSummary.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            systemSummary.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            systemSummary.trailingAnchor.constraint(equalTo: quit.leadingAnchor, constant: -8),
            systemSummary.heightAnchor.constraint(equalToConstant: 14),
            preventSleep.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            preventSleep.trailingAnchor.constraint(lessThanOrEqualTo: tabs.trailingAnchor),
            preventSleep.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            status.bottomAnchor.constraint(equalTo: systemSummary.topAnchor, constant: -2),
            status.trailingAnchor.constraint(lessThanOrEqualTo: quit.leadingAnchor, constant: -8),
            quit.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),
            quit.centerYAnchor.constraint(equalTo: view.bottomAnchor, constant: -22),
            quit.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            quit.heightAnchor.constraint(equalToConstant: 24)
        ])
        rebuildRows()
    }

    private func refreshSleepState() {
        guard sleepTask == nil else { return }
        sleepTask = Task { [weak self, sleepControl] in
            do {
                let disabled = try await sleepControl.read()
                guard let self else { return }
                preventSleep.state = disabled ? .on : .off
                preventSleep.isEnabled = true
                onSleepState?(disabled)
            } catch {
                self?.onSleepState?(nil)
                self?.preventSleep.isEnabled = false
                self?.statusMessage = "Could not read the sleep setting. Reopen this window."
                self?.rebuildRows()
            }
            self?.sleepTask = nil
        }
    }

    @objc private func togglePreventSleep() {
        let disabled = preventSleep.state == .on
        // Show confirmed state until authorization and read-back succeed.
        preventSleep.state = disabled ? .off : .on
        setPreventSleepDisabled(disabled)
    }

    func prepareSleepMenu() async {
        _ = view
        refreshSleepState()
        await sleepTask?.value
    }

    func setPreventSleepDisabled(_ disabled: Bool, onError: ((String) -> Void)? = nil) {
        guard sleepTask == nil else { return }
        preventSleep.isEnabled = false
        sleepTask = Task { [weak self, sleepControl] in
            var message: String?
            var failure: String?
            do {
                try await sleepControl.setDisabled(disabled)
            } catch {
                message = error.localizedDescription
                failure = message
            }
            guard let self else { return }
            do {
                let confirmedDisabled = try await sleepControl.read()
                preventSleep.state = confirmedDisabled ? .on : .off
                preventSleep.isEnabled = true
                onSleepState?(confirmedDisabled)
            } catch {
                onSleepState?(nil)
                preventSleep.isEnabled = false
                message = "Could not verify the sleep setting: \(error.localizedDescription)"
                failure = message
            }
            if let message {
                statusMessage = message
                rebuildRows()
            }
            sleepTask = nil
            if let failure { onError?(failure) }
        }
    }

    func startBackgroundUpdating() {
        backgroundUpdates = true
        scheduleRefresh(every: 15)
        refreshNow()
    }

    func startUpdating() {
        _ = view
        panelIsOpen = true
        refreshSleepState()
        scheduleRefresh(every: 3)
        refreshNow()
        view.window?.makeFirstResponder(search)
    }

    func stopUpdating() {
        panelIsOpen = false
        systemTask?.cancel()
        systemTask = nil
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
        refreshSleepState()
        refreshTask?.cancel()
        refreshTask = nil
        refreshIfNeeded()
    }

    private func refreshIfNeeded() {
        if panelIsOpen { refreshSystemInformation() }
        guard refreshTask == nil else { return }
        refreshSleepState()
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Attribution.snapshot() }.value
            guard !Task.isCancelled, let self else { return }
            receive(result)
            refreshTask = nil
        }
    }

    private func refreshSystemInformation() {
        guard systemTask == nil else { return }
        systemTask = Task { [weak self] in
            let information = await SystemInformation.read()
            guard !Task.isCancelled, let self else { return }
            systemSummary.update(information)
            systemTask = nil
        }
    }

    func receive(_ result: AttributedSnapshot) {
        snapshot = result
        projectByPID = [:]
        let leftovers = Set(result.leftoverSessions.map(\.id))
        for session in result.liveSessions + result.leftoverSessions {
            if expandedSessions[session.id] == nil {
                expandedSessions[session.id] = leftovers.contains(session.id) || session.uiPriority == 2
            }
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
        if search.stringValue != value { searchDisclosure = [:]; searchOtherExpanded = nil }
        search.stringValue = value
        rebuildRows()
    }

    func controlTextDidChange(_ obj: Notification) { searchDisclosure = [:]; searchOtherExpanded = nil; rebuildRows() }
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
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        func appendProcess(_ item: AttributedProcess, session: AgentSession?) {
            rows.append(.process(item, session))
            if expandedProcess == item.id { rows.append(.details(item, fullCommand)) }
        }
        func appendSession(_ session: AgentSession, leftover: Bool) {
            let items = matchingProcesses(session)
            let projectMatches = (session.projectPath + " " + session.kind.displayName).localizedCaseInsensitiveContains(query)
            guard query.isEmpty || !items.isEmpty || projectMatches else { return }
            if let last = rows.last {
                switch last {
                case .leftovers, .message: break
                default: rows.append(.gap)
                }
            }
            let expanded = query.isEmpty ? (expandedSessions[session.id] ?? (leftover || session.uiPriority == 2)) : (searchDisclosure[session.id] ?? true)
            rows.append(.session(session, expanded, leftover))
            if expanded {
                let ordered = items.enumerated().sorted {
                    let l = $0.element.role == .mcp, r = $1.element.role == .mcp
                    return l == r ? $0.offset < $1.offset : !l
                }.map(\.element)
                for item in ordered { appendProcess(item, session: session) }
            }
        }
        if tabs.selectedSegment == 1 {
            for entry in snapshot.all.filter({ matches($0) }).sorted(by: {
                let l = $0.residentBytes ?? 0, r = $1.residentBytes ?? 0
                return l == r ? $0.pid < $1.pid : l > r
            }) {
                appendProcess(AttributedProcess(entry: entry, role: entry.listeningPorts.isEmpty ? .other : .server, depth: 0, tree: [entry]), session: nil)
            }
        } else {
            let count = snapshot.leftoverSessions.reduce(0) { $0 + matchingProcesses($1).count }
            if count > 0 {
                rows.append(.leftovers(count))
                for session in snapshot.leftoverSessions where !matchingProcesses(session).isEmpty { appendSession(session, leftover: true) }
            } else if query.isEmpty && snapshot.leftoverCount == 0 {
                rows.append(.message("No processes left behind by agents ✓"))
            }
            let ordered = snapshot.liveSessions.enumerated().sorted {
                let l = $0.element.uiPriority, r = $1.element.uiPriority
                return l == r ? $0.offset < $1.offset : l > r
            }.map(\.element)
            for session in ordered { appendSession(session, leftover: false) }
            let other = snapshot.otherServers.filter { matches($0.entry) }
            if !other.isEmpty {
                if !rows.isEmpty { rows.append(.gap) }
                let expanded = query.isEmpty ? otherExpanded : (searchOtherExpanded ?? true)
                rows.append(.other(other.count, expanded))
                if expanded { for item in other { appendProcess(item, session: nil) } }
            }
        }
        if rows.isEmpty { rows = [.message("No results found")] }
        status.stringValue = statusMessage ?? (tabs.selectedSegment == 1
            ? "Processes: \(snapshot.all.filter { matches($0) }.count) · RSS · every 3 s"
            : "Sessions: \(snapshot.liveSessions.count) · left behind: \(snapshot.leftoverCount) · every 3 s")
        status.toolTip = stopErrors ?? status.stringValue
        table.reloadData()
        let height = min(688, max(368, 152 + rows.reduce(CGFloat.zero) { $0 + $1.height }))
        let size = NSSize(width: 560, height: height)
        if preferredContentSize != size {
            preferredContentSize = size
            // Inside a popover the host owns the view frame; resizing it here detaches the view from the popover.
            if let onContentSize { onContentSize(size) } else { view.setFrameSize(size) }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].height }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .process(let item, let session):
            let cell = tableView.makeView(withIdentifier: .init("process"), owner: self) as? ProcessCell ?? ProcessCell()
            cell.identifier = .init("process")
            cell.configure(item, session: session, stopping: stoppingPIDs.contains(item.id))
            cell.onStop = { [weak self] in self?.stopItems([item]) }
            cell.onDetails = { [weak self] in self?.toggleProcess(item.id) }
            return cell
        case .details(let item, let full):
            let cell = InlineDetailsCell(item: item, fullCommand: full)
            cell.onStop = { [weak self] in self?.stopItems([item]) }
            cell.onShowAll = { [weak self] in self?.fullCommand.toggle(); self?.rebuildRows() }
            return cell
        case .leftovers(let count):
            return UISectionCell(title: "⚠ Left behind by agents (\(count))", buttonTitle: "Stop all") { [weak self] in self?.confirmStopAll() }
        case .session(let session, let expanded, let leftover):
            return SessionHeaderCell(session: session, expanded: expanded, leftover: leftover)
        case .message(let text):
            return UISectionCell(title: text, success: text.contains("✓"))
        case .other(let count, let expanded):
            return SessionHeaderCell(otherCount: count, expanded: expanded)
        case .gap: return NSView()
        }
    }

    @objc private func rowClicked() { activateRow(table.clickedRow) }

    func activateRow(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        switch rows[index] {
        case .other(_, let expanded):
            if search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { otherExpanded = !expanded }
            else { searchOtherExpanded = !expanded }
            rebuildRows()
        case .session(let session, let expanded, _):
            guard session.processes.contains(where: { $0.depth == 0 }) else { return }
            if search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { expandedSessions[session.id] = !expanded }
            else { searchDisclosure[session.id] = !expanded }
            rebuildRows()
        case .process(let item, _): toggleProcess(item.id)
        default: break
        }
    }

    func toggleProcess(_ pid: pid_t) {
        expandedProcess = expandedProcess == pid ? nil : pid
        fullCommand = false
        rebuildRows()
    }

    private func confirmStopAll() {
        let items = snapshot.leftoverSessions.flatMap { $0.processes.filter { $0.depth == 0 } }
        guard !items.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop all processes left behind by agents?"
        alert.informativeText = "The following processes and their children will be stopped:\n\n" + snapshot.leftoverSessions.flatMap { session in
            session.processes.filter { $0.depth == 0 }.map { "• \($0.entry.displayName)\($0.entry.listeningPorts.map { " :" + $0 }.joined()) · \(session.kind.displayName) · \(session.uiProjectName) · PID \($0.id)" }
        }.joined(separator: "\n") + "\n\nUnresponsive processes will be force quit."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Stop all")
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
        statusMessage = "Stopping \(items.count)…"
        rebuildRows()
        stopTask = Task { [weak self] in
            let result = await ProcessService.stop(tree)
            guard let self else { return }
            stoppingPIDs = []
            let total = result.stopped.count + result.killed.count
            statusMessage = "Stopped: \(uiProcessCount(total)), \(result.killed.count) force quit"
                + (result.failed.isEmpty ? "" : " · errors: \(result.failed.count)")
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
        case .ended: " · session ended"
        case .host: ""
        case .idle(let seconds): " · idle for \(ProcessEntry.durationLabel(seconds: seconds))"
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
        // The daemon's working directory is incidental; its tasks serve every thread of the app.
        if state == .host { return "app" }
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

func uiProcessCount(_ count: Int) -> String {
    "\(count) " + (count == 1 ? "process" : "processes")
}
