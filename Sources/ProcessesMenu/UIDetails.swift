import AppKit

/// Structured details stay directly below their process; only one block is open at a time.
@MainActor
final class InlineDetailsCell: NSTableCellView {
    private let item: AttributedProcess
    private let fullCommand: Bool
    private var fields: [(NSTextField, NSTextField, CGFloat)] = []
    private let more = NSButton(title: "Показать всё", target: nil, action: nil)
    private let copy = NSButton(title: "Скопировать команду", target: nil, action: nil)
    private let finder = NSButton(title: "Показать в Finder", target: nil, action: nil)
    private let stop = NSButton(title: "Остановить", target: nil, action: nil)
    private var open: NSButton?
    var onStop: (() -> Void)?
    var onShowAll: (() -> Void)?
    override var isFlipped: Bool { true }

    static func textHeight(_ string: String, font: NSFont, width: CGFloat = 414) -> CGFloat {
        ceil((string as NSString).boundingRect(with: NSSize(width: width, height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height) + 4
    }
    static func commandHeight(_ item: AttributedProcess, full: Bool) -> CGFloat {
        let height = max(16, textHeight(item.entry.command, font: .monospacedSystemFont(ofSize: 11, weight: .regular)))
        return full ? height : min(46, height)
    }
    static func height(for item: AttributedProcess, fullCommand: Bool) -> CGFloat {
        let folder = min(32, max(16, textHeight(item.entry.workingDirectory, font: .systemFont(ofSize: 12))))
        let ports = max(16, textHeight(item.entry.listeningPorts.map { ":" + $0 }.joined(separator: ", "), font: .systemFont(ofSize: 12)))
        let moreHeight: CGFloat = commandHeight(item, full: true) > 46 ? 22 : 0
        return 6 + folder + 4 + commandHeight(item, full: fullCommand) + moreHeight + 4 + 16 + 4 + ports + 4 + 16 + 8 + 24 + 8
    }

    init(item: AttributedProcess, fullCommand: Bool) {
        self.item = item
        self.fullCommand = fullCommand
        super.init(frame: .zero)
        let entry = item.entry
        addField("Папка", entry.workingDirectory.isEmpty ? "Недоступна" : entry.workingDirectory, height: min(32, max(16, Self.textHeight(entry.workingDirectory, font: .systemFont(ofSize: 12)))))
        addField("Команда", entry.command.isEmpty ? "Недоступна" : entry.command, height: Self.commandHeight(item, full: fullCommand), mono: true)
        addField("PID / PPID", "\(entry.pid) / \(entry.parentPID)", height: 16)
        let ports = entry.listeningPorts.map { ":" + $0 }.joined(separator: ", ")
        addField("Порты", ports.isEmpty ? "—" : ports, height: max(16, Self.textHeight(ports, font: .systemFont(ofSize: 12))))
        addField("Дерево", "\(item.tree.count) процессов", height: 16)
        fields.last?.1.toolTip = item.tree.map { "\($0.displayName) · PID \($0.pid) ← \($0.parentPID)" }.joined(separator: "\n")
        more.title = fullCommand ? "Свернуть команду" : "Показать всё"
        more.isBordered = false
        more.font = .systemFont(ofSize: 11)
        more.target = self
        more.action = #selector(showAll)
        more.isHidden = Self.commandHeight(item, full: true) <= 46
        addSubview(more)
        if let port = entry.listeningPorts.first {
            let button = NSButton(title: "Открыть :\(port)", target: self, action: #selector(openPort))
            open = button
            addSubview(button)
        }
        copy.target = self
        copy.action = #selector(copyCommand)
        copy.isEnabled = !entry.command.isEmpty
        finder.target = self
        finder.action = #selector(showInFinder)
        finder.isEnabled = !entry.workingDirectory.isEmpty
        stop.target = self
        stop.action = #selector(stopProcess)
        stop.isEnabled = entry.canTerminate
        stop.attributedTitle = NSAttributedString(string: stop.title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.systemRed])
        for button in ([open].compactMap { $0 } + [copy, finder, stop]) {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            if button.superview == nil { addSubview(button) }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func addField(_ title: String, _ value: String, height: CGFloat, mono: Bool = false) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let text = NSTextField(wrappingLabelWithString: value)
        text.font = mono ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 12)
        text.isSelectable = true
        text.usesSingleLineMode = false
        text.cell?.wraps = true
        text.cell?.isScrollable = false
        text.maximumNumberOfLines = mono && !fullCommand ? 3 : 0
        text.lineBreakMode = .byWordWrapping
        text.toolTip = value
        fields.append((label, text, height))
        addSubview(label)
        addSubview(text)
    }
    override func layout() {
        super.layout()
        var y: CGFloat = 6
        for (index, field) in fields.enumerated() {
            field.0.frame = NSRect(x: 62, y: y, width: 66, height: 16)
            field.1.frame = NSRect(x: 134, y: y, width: max(0, bounds.width - 146), height: field.2)
            y += field.2 + 4
            if index == 1 && !more.isHidden {
                more.frame = NSRect(x: 134, y: y - 2, width: 140, height: 20)
                y += 22
            }
        }
        y += 4
        var x: CGFloat = 62
        for button in ([open].compactMap { $0 } + [copy, finder]) {
            let width = ceil(button.fittingSize.width)
            button.frame = NSRect(x: x, y: y, width: width, height: 24)
            x += width + 8
        }
        let stopWidth = max(82, ceil(stop.fittingSize.width))
        stop.frame = NSRect(x: bounds.width - 12 - stopWidth, y: y, width: stopWidth, height: 24)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: NSRect(x: 58, y: 0, width: max(0, bounds.width - 66), height: bounds.height), xRadius: 6, yRadius: 6).fill()
    }
    @objc private func showAll() { onShowAll?() }
    @objc private func stopProcess() { onStop?() }
    @objc private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.entry.command, forType: .string)
    }
    @objc private func openPort() { if let port = item.entry.listeningPorts.first { PortButton.open(port) } }
    @objc private func showInFinder() {
        guard !item.entry.workingDirectory.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.entry.workingDirectory, isDirectory: true)])
    }
}
