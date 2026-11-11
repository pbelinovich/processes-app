import AppKit

@MainActor
enum FooterTextStyle {
    static func apply(to label: NSTextField) {
        label.font = .systemFont(ofSize: 10, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
    }
}

/// Secondary system context in the footer, beneath process status.
@MainActor
final class SystemSummaryView: NSView {
    private let label = NSTextField(labelWithString: "CPU — · Memory — · Free — · Uptime —")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        FooterTextStyle.apply(to: label)
        label.setContentHuggingPriority(NSLayoutConstraint.Priority(249), for: .horizontal)
        label.setAccessibilityLabel("Mac status")
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ information: SystemInformation) {
        let text = "CPU \(information.cpuText) · Memory \(information.compactMemoryText) · Free \(information.diskText) · Uptime \(information.uptimeText)"
        label.stringValue = text
        label.setAccessibilityValue(text)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        label.toolTip = (["macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"]
                         + information.menuRows.map(\.title)
                         + ["Memory: used / installed, excluding file cache. Updates every 3 seconds."])
            .joined(separator: "\n")
    }
}
