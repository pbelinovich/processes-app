import AppKit

@MainActor
class HoverCell: NSTableCellView {
    private var tracking: NSTrackingArea?
    private var forcedHover: Bool?
    private(set) var hovered = false
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        updateHover()
    }
    private func updateHover() {
        hovered = forcedHover ?? (window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false)
        hoverChanged()
        needsDisplay = true
    }
    func hoverChanged() {}
    override func mouseEntered(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) { updateHover() }
    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: 6, yRadius: 6).fill()
        }
    }
    #if PROCESS_UI_CHECKS
    func setHoveredForCheck(_ value: Bool) { forcedHover = value; updateHover() }
    #endif
}

@MainActor
final class SessionHeaderCell: HoverCell {
    let chevron = NSImageView()
    let dot = NSView()
    let titleLabel = NSTextField(labelWithString: "")
    let mcpLabel = NSTextField(labelWithString: "")
    private let dotColor: NSColor
    private let expanded: Bool

    init(session: AgentSession, expanded: Bool, leftover: Bool = false) {
        self.expanded = expanded
        dotColor = leftover ? .systemOrange : session.state == .active ? .systemGreen : .systemGray
        super.init(frame: .zero)
        let age = ProcessEntry.durationLabel(seconds: max(0, Int(Date().timeIntervalSince1970) - Int(session.startedSeconds)))
        let text = NSMutableAttributedString(string: session.kind.displayName, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: " " + session.uiProjectName, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
        text.append(NSAttributedString(string: " · " + age + session.state.uiSuffix, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        titleLabel.attributedStringValue = text
        prepare(mcp: session.uiMCPProcesses, title: text.string)
    }

    init(otherCount: Int, expanded: Bool) {
        self.expanded = expanded
        dotColor = .systemGray
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.stringValue = "Прочие серверы (\(otherCount))"
        prepare(mcp: [], title: titleLabel.stringValue)
    }

    private func prepare(mcp: [AttributedProcess], title: String) {
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: expanded ? "Свернуть" : "Раскрыть")
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        chevron.contentTintColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        mcpLabel.font = .systemFont(ofSize: 11)
        mcpLabel.textColor = .secondaryLabelColor
        mcpLabel.stringValue = mcp.isEmpty ? "" : "MCP \(mcp.count)"
        mcpLabel.alignment = .center
        let names = mcp.map { "\($0.entry.displayName) · PID \($0.id)" }.joined(separator: "\n")
        mcpLabel.toolTip = names.isEmpty ? nil : names
        titleLabel.toolTip = title + (names.isEmpty ? "" : "\nMCP:\n" + names) + "\nНажмите, чтобы " + (expanded ? "свернуть" : "раскрыть")
        setAccessibilityLabel(title + (mcp.isEmpty ? "" : ", MCP \(mcp.count)") + (expanded ? ", раскрыто" : ", свёрнуто"))
        for child in [chevron, dot, titleLabel, mcpLabel] { addSubview(child) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        chevron.frameCenterRotation = 0
        chevron.frame = NSRect(x: 12, y: 9, width: 10, height: 10)
        chevron.frameCenterRotation = expanded ? 90 : 0
        dot.frame = NSRect(x: 28, y: 10.5, width: 7, height: 7)
        let capsuleWidth: CGFloat = mcpLabel.stringValue.isEmpty ? 0 : ceil(mcpLabel.intrinsicContentSize.width) + 12
        mcpLabel.frame = NSRect(x: bounds.width - 12 - capsuleWidth, y: 6, width: capsuleWidth, height: 16)
        titleLabel.frame = NSRect(x: 42, y: 5, width: max(0, bounds.width - 54 - (capsuleWidth > 0 ? capsuleWidth + 8 : 0)), height: 19)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        dotColor.setFill()
        NSBezierPath(ovalIn: dot.frame).fill()
        if !mcpLabel.stringValue.isEmpty {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: mcpLabel.frame.insetBy(dx: 0, dy: -2), xRadius: 6, yRadius: 6).fill()
        }
    }
}

@MainActor
final class UISectionCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let button: NSButton?
    private let success: Bool
    private var handler: (() -> Void)?
    override var isFlipped: Bool { true }
    init(title: String, success: Bool = false, buttonTitle: String? = nil, handler: (() -> Void)? = nil) {
        self.success = success
        self.handler = handler
        button = buttonTitle.map { NSButton(title: $0, target: nil, action: nil) }
        super.init(frame: .zero)
        label.stringValue = title
        label.font = .systemFont(ofSize: 11, weight: success ? .regular : .semibold)
        label.textColor = success ? .systemGreen : buttonTitle != nil ? .systemOrange : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        if let button {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.target = self
            button.action = #selector(performAction)
            addSubview(button)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let width = button.map { max(112, ceil($0.fittingSize.width)) } ?? 0
        button?.frame = NSRect(x: bounds.width - 12 - width, y: (bounds.height - 24) / 2, width: width, height: 24)
        label.frame = NSRect(x: 24, y: (bounds.height - 16) / 2, width: bounds.width - 48 - (width > 0 ? width + 8 : 0), height: 16)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard success || button != nil else { return }
        (success ? NSColor.systemGreen : NSColor.systemOrange).withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 12, dy: 0), xRadius: 6, yRadius: 6).fill()
    }
    @objc private func performAction() { handler?() }
}

@MainActor
final class ProcessCell: HoverCell {
    let icon = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    let memoryLabel = NSTextField(labelWithString: "")
    let stop = NSButton(title: "Остановить", target: nil, action: nil)
    private let metadata = NSTextField(labelWithString: "")
    private var ports: [NSButton] = []
    private var leftover = false
    var onStop: (() -> Void)?
    var onDetails: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        metadata.font = .systemFont(ofSize: 11)
        metadata.textColor = .secondaryLabelColor
        metadata.lineBreakMode = .byTruncatingMiddle
        memoryLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        memoryLabel.textColor = .secondaryLabelColor
        memoryLabel.alignment = .right
        stop.bezelStyle = .rounded
        stop.controlSize = .mini
        stop.font = .systemFont(ofSize: 11)
        stop.target = self
        stop.action = #selector(stopClicked)
        for child in [icon, nameLabel, metadata, memoryLabel, stop] { addSubview(child) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ item: AttributedProcess, session: AgentSession?, stopping: Bool) {
        let entry = item.entry
        switch session?.state { case .ended, .idle: leftover = true; default: leftover = false }
        nameLabel.stringValue = entry.displayName
        nameLabel.textColor = item.role == .mcp && !leftover ? .secondaryLabelColor : .labelColor
        memoryLabel.stringValue = entry.memoryLabel
        icon.image = NSImage(systemSymbolName: item.role.symbol, accessibilityDescription: nil)
        icon.contentTintColor = leftover ? .systemOrange : .secondaryLabelColor
        metadata.isHidden = !leftover
        if let session, leftover {
            metadata.stringValue = "\(session.uiProjectName) · \(session.kind.displayName)\(session.state.uiSuffix) · \(entry.ageLabel)"
            metadata.toolTip = metadata.stringValue
        }
        ports.forEach { $0.removeFromSuperview() }
        ports = entry.listeningPorts.prefix(3).map { PortButton(port: $0) }
        if entry.listeningPorts.count > 3 {
            let more = NSButton(title: "+\(entry.listeningPorts.count - 3)", target: self, action: #selector(detailsClicked))
            more.isBordered = false
            more.font = .systemFont(ofSize: 12)
            more.toolTip = entry.listeningPorts.map { ":" + $0 }.joined(separator: ", ")
            ports.append(more)
        }
        ports.forEach { addSubview($0) }
        stop.title = stopping ? "Остановка…" : "Остановить"
        stop.isEnabled = !stopping && entry.canTerminate
        stop.attributedTitle = NSAttributedString(string: stop.title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: stop.isEnabled ? NSColor.systemRed : NSColor.secondaryLabelColor])
        stop.setAccessibilityLabel("Остановить \(entry.displayName), PID \(entry.pid)")
        toolTip = "\(entry.displayName) · PID \(entry.pid)\n\(entry.command)\nНажмите, чтобы раскрыть подробности"
        hoverChanged()
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let y: CGFloat = leftover ? 1 : 2
        icon.frame = NSRect(x: 42, y: y + 3, width: 14, height: 14)
        let portWidth = ports.reduce(CGFloat.zero) { $0 + ceil($1.intrinsicContentSize.width) + 4 }
        let available = bounds.width - 12 - 92 - 8 - 62
        let naturalWidth = ceil((nameLabel.stringValue as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width) + 4
        let nameWidth = max(30, min(naturalWidth, available - portWidth - (ports.isEmpty ? 0 : 6)))
        nameLabel.frame = NSRect(x: 62, y: y, width: nameWidth, height: 20)
        var x = nameLabel.frame.maxX + 6
        for port in ports {
            let width = ceil(port.intrinsicContentSize.width)
            port.frame = NSRect(x: x, y: y - 1, width: width, height: 22)
            x += width + 4
        }
        memoryLabel.frame = NSRect(x: bounds.width - 12 - 92, y: y + 1, width: 92, height: 18)
        stop.frame = NSRect(x: bounds.width - 12 - 92, y: y - 1, width: 92, height: 23)
        metadata.frame = NSRect(x: 62, y: 21, width: max(0, bounds.width - 74), height: 16)
    }
    override func hoverChanged() {
        stop.isHidden = !hovered
        memoryLabel.isHidden = hovered
    }
    @objc private func stopClicked() { onStop?() }
    @objc private func detailsClicked() { onDetails?() }
}

@MainActor
final class PortButton: NSButton {
    let port: String
    init(port: String) {
        self.port = port
        super.init(frame: .zero)
        title = ":" + port
        bezelStyle = .inline
        isBordered = false
        font = .systemFont(ofSize: 12)
        contentTintColor = .linkColor
        target = self
        action = #selector(openPort)
        toolTip = "Открыть http://localhost:\(port)"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openPort() { Self.open(port) }
    static func open(_ port: String) {
        guard let value = Int(port), (1...65535).contains(value), let url = URL(string: "http://localhost:\(value)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private extension ProcessRole {
    var symbol: String {
        switch self {
        case .server: "server.rack"
        case .browser: "globe"
        case .mcp: "puzzlepiece.extension"
        case .agent: "terminal"
        case .helper: "gearshape.2"
        case .other: "app.dashed"
        }
    }
}
