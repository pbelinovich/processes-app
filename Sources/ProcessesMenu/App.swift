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

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Процессы")
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.toolTip = "Процессы"
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.delegate = self
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

@MainActor
final class ProcessListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let search = NSSearchField()
    private let table = NSTableView()
    private let countLabel = NSTextField(labelWithString: "Загрузка процессов…")
    private let emptyLabel = NSTextField(labelWithString: "Ничего не найдено")
    private let scope = NSSegmentedControl(labels: ["Мои процессы", "TCP-серверы", "Все"], trackingMode: .selectOne, target: nil, action: nil)
    private let sort = NSPopUpButton()
    private var processes: [ProcessEntry] = []
    private var filtered: [ProcessEntry] = []
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var terminationRefreshTask: Task<Void, Never>?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 660))
        preferredContentSize = view.frame.size
        let title = NSTextField(labelWithString: "Процессы")
        title.font = .systemFont(ofSize: 21, weight: .bold)
        let subtitle = NSTextField(labelWithString: "Память, серверы и фоновые задачи · двойной клик — подробности")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        search.placeholderString = "Имя, команда, путь проекта, PID или порт"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        scope.selectedSegment = 0
        scope.target = self
        scope.action = #selector(filtersChanged)
        sort.addItems(withTitles: ["По памяти", "По имени", "Сначала новые"])
        sort.target = self
        sort.action = #selector(filtersChanged)
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Обновить")!, target: self, action: #selector(refreshNow))
        refresh.bezelStyle = .inline
        let quit = NSButton(title: "Выйти", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .inline
        quit.font = .systemFont(ofSize: 11)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let column = NSTableColumn(identifier: .init("process"))
        column.width = 612
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 86
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(showDetails)
        scroll.documentView = table
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        let separator = NSBox()
        separator.boxType = .separator
        for child in [title, subtitle, search, scope, sort, refresh, scroll, separator, countLabel, quit, emptyLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            refresh.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            refresh.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            search.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            search.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            search.heightAnchor.constraint(equalToConstant: 28),
            scope.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            scope.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            sort.centerYAnchor.constraint(equalTo: scope.centerYAnchor),
            sort.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            sort.widthAnchor.constraint(equalToConstant: 145),
            scope.trailingAnchor.constraint(lessThanOrEqualTo: sort.leadingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: scope.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -8),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -38),
            countLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            countLabel.centerYAnchor.constraint(equalTo: quit.centerYAnchor),
            quit.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            quit.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -11),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
    }

    func startUpdating() {
        refreshNow()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfNeeded() }
        }
        view.window?.makeFirstResponder(search)
    }

    func stopUpdating() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        terminationRefreshTask?.cancel()
        terminationRefreshTask = nil
    }

    @objc private func refreshNow() {
        // Explicit actions must not reuse a snapshot started before the action.
        refreshTask?.cancel()
        refreshTask = nil
        refreshIfNeeded()
    }

    private func refreshIfNeeded() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) { ProcessService.snapshot() }.value
            guard !Task.isCancelled, let self else { return }
            processes = snapshot
            applyFilter()
            refreshTask = nil
        }
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }
    @objc private func filtersChanged() { applyFilter() }

    private func applyFilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = processes.filter {
            let inScope = scope.selectedSegment == 2 || (scope.selectedSegment == 0 ? $0.uid == getuid() : !$0.listeningPorts.isEmpty)
            return inScope && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || String($0.pid).contains(query) || $0.owner.localizedCaseInsensitiveContains(query)
                || $0.command.localizedCaseInsensitiveContains(query) || $0.workingDirectory.localizedCaseInsensitiveContains(query)
                || $0.listeningPorts.contains { $0.contains(query) })
        }
        filtered.sort {
            switch sort.indexOfSelectedItem {
            case 1:
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.pid < $1.pid : order == .orderedAscending
            case 2:
                return $0.startedSeconds == $1.startedSeconds ? $0.pid > $1.pid : $0.startedSeconds > $1.startedSeconds
            default:
                let left = $0.residentBytes ?? 0, right = $1.residentBytes ?? 0
                return left == right ? $0.pid < $1.pid : left > right
            }
        }
        countLabel.stringValue = "Процессов: \(filtered.count) · RSS · обновление каждые 3 с"
        emptyLabel.isHidden = !filtered.isEmpty
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    @objc private func showDetails() {
        guard filtered.indices.contains(table.clickedRow) else { return }
        let process = filtered[table.clickedRow]
        let alert = NSAlert()
        alert.messageText = process.name
        alert.informativeText = "PID \(process.pid) · родитель \(process.parentPID) · \(process.owner)\nПамять RSS: \(process.memoryLabel) · работает \(process.ageLabel)\nTCP LISTEN: \(process.listeningPorts.isEmpty ? "нет доступных данных" : process.listeningPorts.joined(separator: ", "))"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 140))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = "Рабочая папка:\n\(process.workingDirectory.isEmpty ? "Недоступна" : process.workingDirectory)\n\nКоманда:\n\(process.command.isEmpty ? "Недоступна" : process.command)"
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Закрыть")
        alert.addButton(withTitle: "Скопировать команду")
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(process.command, forType: .string)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("row"), owner: self) as? ProcessCell ?? ProcessCell()
        cell.identifier = .init("row")
        let process = filtered[row]
        cell.configure(process)
        cell.onTerminate = { [weak self] force in self?.terminate(process, force: force) }
        return cell
    }

    private func terminate(_ process: ProcessEntry, force: Bool) {
        if force {
            let alert = NSAlert()
            alert.messageText = "Завершить \(process.name) принудительно?"
            alert.informativeText = "PID \(process.pid). Несохранённые данные процесса могут быть потеряны."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Отмена")
            alert.addButton(withTitle: "Завершить принудительно")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        do {
            try ProcessService.terminate(process, force: force)
            countLabel.stringValue = "\(force ? "SIGKILL" : "SIGTERM") отправлен · PID \(process.pid)"
            refreshNow()
            // Sending a signal succeeds before the process has necessarily exited.
            terminationRefreshTask?.cancel()
            terminationRefreshTask = Task { [weak self] in
                for delay in [250_000_000, 750_000_000] {
                    do { try await Task.sleep(nanoseconds: UInt64(delay)) }
                    catch { return }
                    self?.refreshNow()
                }
                self?.terminationRefreshTask = nil
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            refreshNow()
        }
    }
}

@MainActor
final class ProcessCell: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let commandLabel = NSTextField(labelWithString: "")
    private let memoryLabel = NSTextField(labelWithString: "")
    private let action = NSButton()
    private var tracking: NSTrackingArea?
    private var allowed = false
    var onTerminate: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        commandLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        commandLabel.textColor = .secondaryLabelColor
        commandLabel.lineBreakMode = .byTruncatingMiddle
        memoryLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        memoryLabel.alignment = .right
        memoryLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        action.title = "Завершить"
        action.bezelStyle = .inline
        action.font = .systemFont(ofSize: 11, weight: .medium)
        action.contentTintColor = .systemRed
        action.target = self
        action.action = #selector(showActions)
        action.isHidden = true
        for child in [nameLabel, detailLabel, commandLabel, memoryLabel, action] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: memoryLabel.leadingAnchor, constant: -12),
            memoryLabel.trailingAnchor.constraint(equalTo: action.trailingAnchor),
            memoryLabel.topAnchor.constraint(equalTo: nameLabel.topAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            commandLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            commandLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 5),
            commandLabel.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -8),
            action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            action.centerYAnchor.constraint(equalTo: commandLabel.centerYAnchor),
            action.widthAnchor.constraint(equalToConstant: 88)
        ])
        action.setAccessibilityLabel("Завершить процесс")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ process: ProcessEntry) {
        nameLabel.stringValue = process.name
        memoryLabel.stringValue = process.memoryLabel
        let ports = process.listeningPorts.isEmpty ? "" : " · TCP :" + process.listeningPorts.joined(separator: ", :")
        detailLabel.stringValue = "PID \(process.pid) · PPID \(process.parentPID) · \(process.ageLabel)" + ports
        commandLabel.stringValue = process.command.isEmpty ? "Команда недоступна · \(process.owner)" : process.command
        allowed = process.canTerminate
        action.isEnabled = allowed
        action.toolTip = allowed ? "Выбрать способ завершения" : "Нет прав на завершение этого процесса"
        toolTip = "\(process.name) · \(process.owner)\n\(process.workingDirectory)\n\(process.command)\nДвойной клик — подробности" + (allowed ? "" : "\nЗавершение недоступно")
        action.setAccessibilityLabel("Завершить \(process.name), PID \(process.pid)")
        updateHover()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        updateHover()
    }

    private func updateHover() {
        let hovered = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        action.isHidden = !hovered
        layer?.backgroundColor = hovered ? NSColor.quaternaryLabelColor.cgColor : NSColor.clear.cgColor
    }

    override func mouseEntered(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) { updateHover() }

    @objc private func showActions() {
        // Table updates may reuse this cell while its menu is open.
        // Keep the actions bound to the process selected when the menu opened.
        let target = ProcessActionTarget(handler: onTerminate)
        let menu = NSMenu()
        let stop = NSMenuItem(title: "Завершить (SIGTERM)", action: #selector(ProcessActionTarget.stopProcess), keyEquivalent: "")
        let force = NSMenuItem(title: "Завершить принудительно…", action: #selector(ProcessActionTarget.forceProcess), keyEquivalent: "")
        stop.target = target
        force.target = target
        menu.addItem(stop)
        menu.addItem(force)
        menu.popUp(positioning: nil, at: NSPoint(x: action.frame.minX, y: action.frame.minY), in: self)
        withExtendedLifetime(target) {}
    }
}

@MainActor
private final class ProcessActionTarget: NSObject {
    private let handler: ((Bool) -> Void)?
    init(handler: ((Bool) -> Void)?) { self.handler = handler }
    @objc func stopProcess() { handler?(false) }
    @objc func forceProcess() { handler?(true) }
}
