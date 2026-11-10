import AppKit

@MainActor
final class ProcessDetailsController: NSViewController {
    private let item: AttributedProcess
    init(item: AttributedProcess) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 350))
        preferredContentSize = view.frame.size
        let title = NSTextField(labelWithString: item.entry.displayName)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.toolTip = item.entry.displayName
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 408, height: 260))
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .labelColor
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let entry = item.entry
        text.string = "PID \(entry.pid) · PPID \(entry.parentPID) · \(entry.owner)\nRSS \(entry.memoryLabel) · работает \(entry.ageLabel)\nПорты: \(entry.listeningPorts.isEmpty ? "—" : entry.listeningPorts.joined(separator: ", "))\n\nРабочая папка:\n\(entry.workingDirectory.isEmpty ? "Недоступна" : entry.workingDirectory)\n\nКоманда:\n\(entry.command.isEmpty ? "Недоступна" : entry.command)\n\nДерево (\(item.tree.count)):\n" + item.tree.map { "PID \($0.pid) ← PPID \($0.parentPID)  \($0.displayName)\n  \($0.command)" }.joined(separator: "\n")
        scroll.documentView = text
        let copy = NSButton(title: "Скопировать команду", target: self, action: #selector(copyCommand))
        copy.bezelStyle = .rounded
        copy.isEnabled = !entry.command.isEmpty
        for child in [title, scroll, copy] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: copy.topAnchor, constant: -12),
            copy.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            copy.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
        ])
    }

    @objc private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.entry.command, forType: .string)
    }
}

/// Session inspection keeps collapsed MCP tasks discoverable without adding rows to the main list.
@MainActor
final class SessionDetailsController: NSViewController {
    private let session: AgentSession
    init(session: AgentSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = UIBackgroundView(frame: NSRect(x: 0, y: 0, width: 440, height: 350))
        preferredContentSize = view.frame.size
        let title = NSTextField(labelWithString: "\(session.kind.displayName) · \(session.uiProjectName)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.toolTip = title.stringValue
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 408, height: 294))
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .labelColor
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let items = session.processes.filter { $0.depth == 0 }
        text.string = "Проект: \(session.uiProjectName)\n" + (session.projectPath.isEmpty || session.projectPath == "/" ? "" : session.projectPath + "\n")
            + "MCP: \(session.uiMCPProcesses.count) · задач: \(items.count)\(session.state.uiSuffix)\n\n"
            + (items.isEmpty ? "Ничего не запущено" : items.map { item in
                let entry = item.entry
                return "\(item.role == .mcp ? "MCP · " : "")\(entry.displayName)\nPID \(entry.pid) · PPID \(entry.parentPID) · RSS \(entry.memoryLabel)"
                    + (entry.listeningPorts.isEmpty ? "" : " · :" + entry.listeningPorts.joined(separator: ", :"))
                    + "\nПапка: \(entry.workingDirectory.isEmpty ? "—" : entry.workingDirectory)\n\(entry.command)\nДерево: "
                    + item.tree.map { "\($0.displayName) (\($0.pid))" }.joined(separator: " → ")
            }.joined(separator: "\n\n"))
        scroll.documentView = text
        for child in [title, scroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14)
        ])
    }
}
