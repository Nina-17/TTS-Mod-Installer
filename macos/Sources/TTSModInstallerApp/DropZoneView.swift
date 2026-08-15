import AppKit

final class DropZoneView: NSView {
    var onURLs: (([URL]) -> Void)?
    private let titleLabel = NSTextField(labelWithString: "把图包拖到这里吧～ 📦")
    private let detailLabel = NSTextField(labelWithString: "支持文件夹、ZIP、TTSMOD、7Z、RAR，可一次拖入多个")
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedRed: 0.72, green: 0.37, blue: 0.50, alpha: 1)
        titleLabel.alignment = .center
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
        ])
        setAccessibilityLabel("图包拖放区域")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 14, yRadius: 14)
        (highlighted
            ? NSColor(calibratedRed: 0.96, green: 0.78, blue: 0.84, alpha: 0.45)
            : NSColor(calibratedRed: 0.98, green: 0.91, blue: 0.94, alpha: 0.5)).setFill()
        path.fill()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 14, yRadius: 14)
        border.setLineDash([7, 5], count: 2, phase: 0)
        border.lineWidth = 2
        NSColor(calibratedRed: 0.85, green: 0.58, blue: 0.68, alpha: highlighted ? 1 : 0.7).setStroke()
        border.stroke()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onURLs?(urls)
        return true
    }
}
