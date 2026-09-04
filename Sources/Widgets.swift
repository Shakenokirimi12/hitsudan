import AppKit

/// Lucide icons, rendered from their path data. macOS decodes SVG natively, so
/// the icon set costs nothing but the few paths actually used.
enum Lucide {
    static let check = ["M20 6 9 17l-5-5"]
    static let loaderCircle = ["M21 12a9 9 0 1 1-6.219-8.56"]
    static let send = ["M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635l-19 6.5a.5.5 0 0 0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z",
                       "m21.854 2.147-10.94 10.939"]
    static let clock = ["M12 6v6l4 2"]
    static let terminal = ["m4 17 6-6-6-6", "M12 19h8"]

    private static var cache: [String: NSImage] = [:]

    static func image(_ paths: [String], size: CGFloat, color: NSColor,
                      strokeWidth: CGFloat = 2, circle: Bool = false) -> NSImage? {
        let hex = color.usingColorSpace(.sRGB).map {
            String(format: "#%02X%02X%02X", Int($0.redComponent * 255),
                   Int($0.greenComponent * 255), Int($0.blueComponent * 255))
        } ?? "#000000"
        let key = "\(paths.joined())|\(size)|\(hex)|\(strokeWidth)|\(circle)"
        if let hit = cache[key] { return hit }

        let body = (circle ? "<circle cx=\"12\" cy=\"12\" r=\"10\"/>" : "")
            + paths.map { "<path d=\"\($0)\"/>" }.joined()
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="\(Int(size))" height="\(Int(size))" \
        fill="none" stroke="\(hex)" stroke-width="\(strokeWidth)" stroke-linecap="round" stroke-linejoin="round">\
        \(body)</svg>
        """
        guard let data = svg.data(using: .utf8) else { return nil }
        var image = NSImage(data: data)
        if image == nil {
            // Some builds only decode SVG from a URL.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("lucide-\(abs(key.hashValue)).svg")
            try? data.write(to: tmp)
            image = NSImage(contentsOf: tmp)
        }
        if let image { cache[key] = image }
        return image
    }
}

/// A card in the side column. Subclasses fill in `refresh`.
class WidgetView: NSView {
    static let allIDs = ["clock", "sessions", "board", "input"]

    let id: String
    private let titleLabel = NSTextField(labelWithString: "")
    let bodyLabel = NSTextField(labelWithString: "")

    init(id: String, title: String, icon: [String], iconCircle: Bool = false) {
        self.id = id
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = Lucide.image(icon, size: 15, color: .secondaryLabelColor,
                                      strokeWidth: 2, circle: iconCircle)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 15).isActive = true

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        let head = NSStackView(views: [iconView, titleLabel])
        head.orientation = .horizontal
        head.spacing = 6
        head.alignment = .centerY

        bodyLabel.font = NSFont.systemFont(ofSize: 15)
        bodyLabel.textColor = .labelColor
        bodyLabel.maximumNumberOfLines = 8
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.cell?.wraps = true

        let stack = NSStackView(views: [head, bodyLabel])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    func refresh() {}
}

final class ClockWidget: WidgetView {
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日(E)"
        return f
    }()

    init() {
        super.init(id: "clock", title: "時刻", icon: Lucide.clock, iconCircle: true)
        bodyLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .medium)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func refresh() {
        let now = Date()
        let text = NSMutableAttributedString(
            string: clock.string(from: now),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .medium),
                         .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(
            string: "   " + day.string(from: now),
            attributes: [.font: NSFont.systemFont(ofSize: 13),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        bodyLabel.attributedStringValue = text
    }
}

/// The Claude sessions running on this machine, straight from `claude agents`.
final class SessionsWidget: WidgetView {
    private var claudePath: String?
    private var resolving = false
    private var lastFetch = Date.distantPast

    init() {
        super.init(id: "sessions", title: "Claude セッション", icon: Lucide.terminal)
        bodyLabel.font = NSFont.systemFont(ofSize: 13)
        bodyLabel.stringValue = "読み込み中…"
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func refresh() {
        guard Date().timeIntervalSince(lastFetch) > 5 else { return }
        lastFetch = Date()
        guard let claude = claudePath else { resolveClaude(); return }

        DispatchQueue.global().async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: claude)
            task.arguments = ["agents", "--json"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            DispatchQueue.main.async { self?.render(rows) }
        }
    }

    private func render(_ rows: [[String: Any]]) {
        guard !rows.isEmpty else {
            bodyLabel.stringValue = "実行中のセッションなし"
            bodyLabel.textColor = .secondaryLabelColor
            return
        }
        let text = NSMutableAttributedString()
        for row in rows.prefix(6) {
            let name = (row["name"] as? String) ?? "?"
            let status = (row["status"] as? String) ?? ""
            let colour: NSColor
            switch status {
            case "busy": colour = NSColor.systemGreen
            case "waiting": colour = NSColor.systemOrange
            default: colour = NSColor.tertiaryLabelColor
            }
            text.append(NSAttributedString(string: "● ", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: colour]))
            text.append(NSAttributedString(string: name, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
            let label = status == "waiting" ? "入力待ち" : (status == "busy" ? "実行中" : "待機")
            text.append(NSAttributedString(string: "  \(label)\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        bodyLabel.attributedStringValue = text
    }

    /// The CLI usually lives on a PATH only a login shell knows about.
    private func resolveClaude() {
        guard !resolving else { return }
        resolving = true
        DispatchQueue.global().async { [weak self] in
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
            shell.arguments = ["-lc", "command -v claude"]
            let pipe = Pipe()
            shell.standardOutput = pipe
            shell.standardError = FileHandle.nullDevice
            try? shell.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            shell.waitUntilExit()
            let found = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                self?.resolving = false
                if found.isEmpty {
                    self?.bodyLabel.stringValue = "claude が見つかりません"
                } else {
                    self?.claudePath = found
                    self?.lastFetch = .distantPast
                    self?.refresh()
                }
            }
        }
    }
}

/// Whatever the board itself wants to say about its state.
final class BoardWidget: WidgetView {
    var provider: (() -> NSAttributedString)?

    init() {
        super.init(id: "board", title: "ボード", icon: Lucide.send)
        bodyLabel.font = NSFont.systemFont(ofSize: 13)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func refresh() {
        if let text = provider?() { bodyLabel.attributedStringValue = text }
    }
}


/// What the tablet's own controls are sending. Doubles as the way to discover
/// which key a button is wired to: press it and read it here.
final class InputWidget: WidgetView {
    private var lines: [String] = []

    init() {
        super.init(id: "input", title: "入力", icon: Lucide.terminal)
        bodyLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        bodyLabel.stringValue = "本体キーやスライダーを触ると出ます"
        bodyLabel.textColor = .secondaryLabelColor
    }
    required init?(coder: NSCoder) { fatalError() }

    func record(_ line: String) {
        lines.insert(line, at: 0)
        if lines.count > 4 { lines.removeLast() }
        bodyLabel.textColor = .labelColor
        bodyLabel.stringValue = lines.joined(separator: "\n")
    }
}

/// A knob for the stroke width. Spin it with the pen — the rotation is
/// continuous and relative, so it never jumps to wherever you happened to
/// touch, and the dot in the middle is the actual nib you are about to draw
/// with rather than a number to interpret.
final class DialControl: NSView {

    var minValue = 2.0
    var maxValue = 140.0
    var onChange: (() -> Void)?

    /// Rotation drives `t`, and the width is `t` squared across the range. A
    /// linear dial over a 2–140 span would make every thin nib the same flick;
    /// the curve keeps the fine end usable while still reaching a fat marker.
    private var t: Double = 0.19

    var doubleValue: Double {
        get { minValue + (maxValue - minValue) * t * t }
        set {
            let clamped = min(max(newValue, minValue), maxValue)
            t = ((clamped - minValue) / (maxValue - minValue)).squareRoot()
            needsDisplay = true
        }
    }

    /// Move along the curve rather than along the value, so a nudge feels the
    /// same size wherever the dial happens to be.
    func nudge(_ amount: Double) {
        t = min(max(t + amount, 0), 1)
        needsDisplay = true
        onChange?()
    }

    private var lastAngle: CGFloat?
    private let ringRadius: CGFloat = 33
    private var centre: CGPoint { CGPoint(x: bounds.midX, y: bounds.maxY - ringRadius - 5) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 96).isActive = true
        heightAnchor.constraint(equalToConstant: 96).isActive = true
        toolTip = "線の太さ — 回して変えます"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let fraction = t
        let accent = NSColor(srgbRed: 0.04, green: 0.44, blue: 0.37, alpha: 1)

        let track = NSBezierPath()
        track.appendArc(withCenter: centre, radius: ringRadius,
                        startAngle: 225, endAngle: -45, clockwise: true)
        track.lineWidth = 6
        track.lineCapStyle = .round
        NSColor.separatorColor.setStroke()
        track.stroke()

        if fraction > 0.001 {
            let progress = NSBezierPath()
            progress.appendArc(withCenter: centre, radius: ringRadius,
                               startAngle: 225, endAngle: 225 - 270 * fraction, clockwise: true)
            progress.lineWidth = 6
            progress.lineCapStyle = .round
            accent.setStroke()
            progress.stroke()
        }

        // The knob's handle, so it reads as something you turn.
        let handleAngle = (225 - 270 * fraction) * .pi / 180
        let handle = CGPoint(x: centre.x + cos(handleAngle) * ringRadius,
                             y: centre.y + sin(handleAngle) * ringRadius)
        accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: handle.x - 5, y: handle.y - 5, width: 10, height: 10)).fill()

        // The nib itself, at the size it will draw.
        let dot = max(min(doubleValue / 2, 19), 1)
        NSColor.labelColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: centre.x - dot, y: centre.y - dot,
                                    width: dot * 2, height: dot * 2)).fill()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let label = String(format: doubleValue < 10 ? "%.1f" : "%.0f", doubleValue)
        (label as NSString).draw(in: NSRect(x: 0, y: 1, width: bounds.width, height: 16),
                                 withAttributes: [
                                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                    .foregroundColor: NSColor.secondaryLabelColor,
                                    .paragraphStyle: style,
                                 ])
    }

    private func angle(of point: CGPoint) -> CGFloat {
        atan2(point.y - centre.y, point.x - centre.x)
    }

    override func mouseDown(with event: NSEvent) {
        lastAngle = angle(of: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let previous = lastAngle else { return }
        let now = angle(of: convert(event.locationInWindow, from: nil))
        var delta = now - previous
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        lastAngle = now
        // Clockwise thickens; about one and a half turns spans the whole range.
        nudge(-Double(delta) / (1.5 * 2 * .pi))
    }

    override func mouseUp(with event: NSEvent) { lastAngle = nil }

    override func scrollWheel(with event: NSEvent) {
        nudge(Double(event.scrollingDeltaY) * 0.004)
    }
}


/// The one control that lives on the sheet itself: add a page.
final class PlusButton: NSButton {
    init(target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 68).isActive = true
        heightAnchor.constraint(equalToConstant: 68).isActive = true
        toolTip = "新しいページ（⌘N）"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath(ovalIn: circle)

        NSGraphicsContext.saveGraphicsState()
        NSShadow().set()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        let green = NSColor(srgbRed: 0.13, green: 0.62, blue: 0.38, alpha: 1)
        (isHighlighted ? green.blended(withFraction: 0.2, of: .black) ?? green : green).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        let arm: CGFloat = 15
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: circle.midX - arm, y: circle.midY))
        cross.line(to: CGPoint(x: circle.midX + arm, y: circle.midY))
        cross.move(to: CGPoint(x: circle.midX, y: circle.midY - arm))
        cross.line(to: CGPoint(x: circle.midX, y: circle.midY + arm))
        cross.lineWidth = 4
        cross.lineCapStyle = .round
        NSColor.white.setStroke()
        cross.stroke()
    }
}
