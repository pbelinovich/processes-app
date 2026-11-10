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
        let title = NSTextField(labelWithString: item.entry.name)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.toolTip = item.entry.name
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
        text.string = "PID \(entry.pid) · PPID \(entry.parentPID) · \(entry.owner)\nRSS \(entry.memoryLabel) · работает \(entry.ageLabel)\nПорты: \(entry.listeningPorts.isEmpty ? "—" : entry.listeningPorts.joined(separator: ", "))\n\nРабочая папка:\n\(entry.workingDirectory.isEmpty ? "Недоступна" : entry.workingDirectory)\n\nКоманда:\n\(entry.command.isEmpty ? "Недоступна" : entry.command)\n\nДерево (\(item.tree.count)):\n" + item.tree.map { "PID \($0.pid) ← PPID \($0.parentPID)  \($0.name)\n  \($0.command)" }.joined(separator: "\n")
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
