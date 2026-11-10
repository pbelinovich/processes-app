import AppKit

@MainActor
final class UISectionCell: NSTableCellView {
    private var handler: (() -> Void)?

    init(title: String, subtitle: String? = nil, accent: Bool = false, secondary: Bool = false, buttonTitle: String? = nil, handler: (() -> Void)? = nil) {
        super.init(frame: .zero)
        self.handler = handler
        wantsLayer = true
        layer?.cornerRadius = 7
        if accent { layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: secondary ? 11 : 12, weight: secondary ? .regular : .semibold)
        label.textColor = accent ? .systemOrange : secondary ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = title
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let trailing: NSLayoutXAxisAnchor
        if let buttonTitle {
            let button = NSButton(title: buttonTitle, target: self, action: #selector(performAction))
            button.bezelStyle = .inline
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = .systemOrange
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 103)
            ])
            trailing = button.leadingAnchor
        } else { trailing = trailingAnchor }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: secondary ? 24 : 10),
            label.trailingAnchor.constraint(equalTo: trailing, constant: -8)
        ])
        if let subtitle {
            let detail = NSTextField(labelWithString: subtitle)
            detail.font = .systemFont(ofSize: 10)
            detail.textColor = .tertiaryLabelColor
            detail.lineBreakMode = .byTruncatingTail
            detail.toolTip = subtitle
            detail.translatesAutoresizingMaskIntoConstraints = false
            addSubview(detail)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                detail.leadingAnchor.constraint(equalTo: label.leadingAnchor),
                detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                detail.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2)
            ])
            setAccessibilityLabel(title + ": " + subtitle)
        } else { label.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func performAction() { handler?() }
}

@MainActor
final class ProcessCell: NSTableCellView {
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let metadata = NSTextField(labelWithString: "")
    private let memoryLabel = NSTextField(labelWithString: "")
    private let pidLabel = NSTextField(labelWithString: "")
    private let portStack = NSStackView()
    private let stop = NSButton(title: "Остановить", target: nil, action: nil)
    private var tracking: NSTrackingArea?
    private var nameCenter: NSLayoutConstraint!
    private var metadataCenter: NSLayoutConstraint!
    private var hoverOverride: Bool?
    var onStop: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metadata.font = .systemFont(ofSize: 10)
        metadata.textColor = .secondaryLabelColor
        metadata.lineBreakMode = .byTruncatingMiddle
        memoryLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        memoryLabel.textColor = .secondaryLabelColor
        memoryLabel.alignment = .right
        pidLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        pidLabel.textColor = .tertiaryLabelColor
        pidLabel.alignment = .right
        portStack.orientation = .horizontal
        portStack.spacing = 3
        portStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        stop.bezelStyle = .inline
        stop.font = .systemFont(ofSize: 10)
        stop.contentTintColor = .systemRed
        stop.target = self
        stop.action = #selector(stopClicked)
        stop.alphaValue = 0
        for child in [icon, nameLabel, metadata, portStack, memoryLabel, pidLabel, stop] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        nameCenter = nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        metadataCenter = metadata.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 11)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            icon.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            nameLabel.trailingAnchor.constraint(equalTo: portStack.leadingAnchor, constant: -6),
            nameCenter,
            portStack.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            portStack.trailingAnchor.constraint(equalTo: pidLabel.leadingAnchor, constant: -5),
            pidLabel.widthAnchor.constraint(equalToConstant: 0).withPriority(749),
            pidLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            pidLabel.trailingAnchor.constraint(equalTo: memoryLabel.leadingAnchor, constant: -6),
            memoryLabel.widthAnchor.constraint(equalToConstant: 56),
            memoryLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            memoryLabel.trailingAnchor.constraint(equalTo: stop.leadingAnchor, constant: -5),
            stop.widthAnchor.constraint(equalToConstant: 69),
            stop.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            stop.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            metadata.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            metadata.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            metadataCenter
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: AttributedProcess, session: AgentSession?, showPID: Bool, stopping: Bool) {
        let entry = item.entry
        nameLabel.stringValue = entry.name
        memoryLabel.stringValue = entry.memoryLabel
        pidLabel.stringValue = showPID ? "\(entry.pid)" : ""
        pidLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let isLeftover: Bool
        switch session?.state {
        case .ended, .idle: isLeftover = true
        default: isLeftover = false
        }
        nameCenter.constant = isLeftover ? -9 : 0
        metadata.isHidden = !isLeftover
        if let session, isLeftover {
            let age = ProcessEntry.durationLabel(seconds: max(0, Int(Date().timeIntervalSince1970) - Int(entry.startedSeconds)))
            metadata.stringValue = "\(session.projectName) · \(session.kind.displayName)\(session.state.uiSuffix) · \(age)"
            metadata.toolTip = session.projectPath + "\n" + metadata.stringValue
        }
        let muted = item.role == .mcp && !isLeftover
        nameLabel.textColor = muted ? .secondaryLabelColor : .labelColor
        icon.contentTintColor = muted ? .tertiaryLabelColor : isLeftover ? .systemOrange : .secondaryLabelColor
        icon.image = NSImage(systemSymbolName: item.role.symbol, accessibilityDescription: item.role.accessibilityName)
        portStack.arrangedSubviews.forEach { portStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for port in entry.listeningPorts {
            let button = PortButton(port: port)
            portStack.addArrangedSubview(button)
        }
        stop.title = stopping ? "Остановка…" : "Остановить"
        stop.isEnabled = !stopping && entry.canTerminate
        stop.toolTip = entry.canTerminate ? "Остановить процесс и его дочерние задачи" : "Нет прав на остановку процесса"
        stop.setAccessibilityLabel("Остановить \(entry.name), PID \(entry.pid)")
        toolTip = "\(entry.name) · PID \(entry.pid) · PPID \(entry.parentPID)\n\(entry.workingDirectory)\n\(entry.command)\nНажмите для подробностей"
        setAccessibilityLabel("\(entry.name), PID \(entry.pid), \(entry.memoryLabel)" + entry.listeningPorts.map { ", порт " + $0 }.joined())
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
        let hovered = hoverOverride ?? (window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false)
        // Alpha keeps the button in the accessibility tree and preserves the name/port layout.
        stop.alphaValue = hovered ? 1 : 0
        layer?.backgroundColor = hovered ? NSColor.quaternaryLabelColor.cgColor : NSColor.clear.cgColor
    }

    override func mouseEntered(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) { updateHover() }
    @objc private func stopClicked() { onStop?() }

    #if PROCESS_UI_CHECKS
    func setHoveredForCheck(_ hovered: Bool) { hoverOverride = hovered; updateHover() }
    #endif
}

private extension NSLayoutConstraint {
    func withPriority(_ value: Float) -> NSLayoutConstraint { priority = .init(value); return self }
}

@MainActor
private final class PortButton: NSButton {
    let port: String
    init(port: String) {
        self.port = port
        super.init(frame: .zero)
        title = ":" + port
        bezelStyle = .inline
        isBordered = false
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        contentTintColor = .linkColor
        target = self
        action = #selector(openPort)
        toolTip = "Открыть http://localhost:\(port)"
        setAccessibilityLabel("Открыть localhost, порт \(port)")
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openPort() {
        guard let number = Int(port), (1...65535).contains(number), let url = URL(string: "http://localhost:\(number)") else { return }
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
    var accessibilityName: String {
        switch self {
        case .server: "Сервер"
        case .browser: "Браузер"
        case .mcp: "MCP"
        case .agent: "Агент"
        case .helper: "Помощник"
        case .other: "Процесс"
        }
    }
}
