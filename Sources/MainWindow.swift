import AppKit

extension NSColor {
    /// Open Color values are published as hex, so read them as written.
    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
    }
}

final class SwatchView: NSView {
    let color: NSColor
    /// The fifth slot is not ink at all: it points instead of marking.
    let isLaser: Bool
    var isSelected = false { didSet { needsDisplay = true } }
    var onPick: ((SwatchView) -> Void)?

    init(color: NSColor, isLaser: Bool = false) {
        self.color = color
        self.isLaser = isLaser
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 40).isActive = true
        heightAnchor.constraint(equalToConstant: 40).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let dot = bounds.insetBy(dx: 6, dy: 6)
        if isLaser {
            // Drawn as what it does: a hot point inside a halo.
            for (inset, alpha) in [(2.0, 0.16), (5.0, 0.28)] {
                color.withAlphaComponent(CGFloat(alpha)).setFill()
                NSBezierPath(ovalIn: bounds.insetBy(dx: CGFloat(inset), dy: CGFloat(inset))).fill()
            }
            color.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 13, dy: 13)).fill()
        } else {
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            NSColor.separatorColor.setStroke()
            let edge = NSBezierPath(ovalIn: dot)
            edge.lineWidth = 1
            edge.stroke()
        }
        if isSelected {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
            ring.lineWidth = 3
            ring.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { onPick?(self) }
}

/// The stock bezels cap out around 32 pt tall, which is small for a target you
/// hit with a pen on a 13-inch tablet. This draws its own.
final class BigButton: NSButton {
    var fill: NSColor = .hex(0x0CA678)   // Open Color teal 6
    var isSecondary = false
    var icon: NSImage? { didSet { needsDisplay = true } }
    /// Radians. The loader spins by advancing this.
    var iconAngle: CGFloat = 0 { didSet { needsDisplay = true } }

    init(title: String, height: CGFloat, fontSize: CGFloat, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12)

        if isSecondary {
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            (isEnabled ? fill : fill.withAlphaComponent(0.3)).setFill()
            path.fill()
        }
        if isHighlighted {
            NSColor.black.withAlphaComponent(0.16).setFill()
            path.fill()
        }

        let color: NSColor = isSecondary ? .labelColor : .white
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: isEnabled ? color : color.withAlphaComponent(0.4),
            .paragraphStyle: style,
        ]
        let size = (title as NSString).size(withAttributes: attrs)

        guard let icon else {
            (title as NSString).draw(in: NSRect(x: 0, y: bounds.midY - size.height / 2,
                                                width: bounds.width, height: size.height),
                                     withAttributes: attrs)
            return
        }

        let gap: CGFloat = 12
        let total = icon.size.width + gap + size.width
        let originX = bounds.midX - total / 2

        NSGraphicsContext.saveGraphicsState()
        let centre = CGPoint(x: originX + icon.size.width / 2, y: bounds.midY)
        let transform = NSAffineTransform()
        transform.translateX(by: centre.x, yBy: centre.y)
        transform.rotate(byRadians: iconAngle)
        transform.translateX(by: -icon.size.width / 2, yBy: -icon.size.height / 2)
        transform.concat()
        icon.draw(in: NSRect(origin: .zero, size: icon.size))
        NSGraphicsContext.restoreGraphicsState()

        let leftAligned = NSMutableParagraphStyle()
        leftAligned.alignment = .left
        var textAttrs = attrs
        textAttrs[.paragraphStyle] = leftAligned
        (title as NSString).draw(in: NSRect(x: originX + icon.size.width + gap,
                                            y: bounds.midY - size.height / 2,
                                            width: size.width + 2, height: size.height),
                                 withAttributes: textAttrs)
    }
}

final class BoardWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class MainWindowController: NSWindowController, NSWindowDelegate {

    private let canvas = CanvasView()
    private let hid = TabletHID()
    private let pointer = PenPointer()
    private let bridge = BoardBridge()

    private let telemetry = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var sendButton: BigButton!
    private var clearButton: BigButton!
    private var applyButton: BigButton!
    private var discardButton: BigButton!
    private let proposalLabel = NSTextField(labelWithString: "")

    /// What a session has asked to put on the sheet, waiting for a decision.
    private struct Proposal {
        let summary: String
        let apply: () -> Void
    }
    private var proposal: Proposal?

    private enum SendState { case ready, sending, sent }
    private var sendState: SendState = .ready { didSet { applySendState() } }
    private var spinTimer: Timer?

    private let inputs = InputMap()
    private var modeControl: NSSegmentedControl!
    private var pressedKeys: Set<UInt8> = []
    private var previousPenButtons = (false, false, false)
    private var previousStripButton = false
    private var stripCarry = 0.0
    private var settingsSheet: NSWindow?

    private let pages = PageStore()
    private var prevPageButton: BigButton!
    private var nextPageButton: BigButton!
    private var newPageButton: BigButton!
    private let pageLabel = NSTextField(labelWithString: "")
    private var saveWork: DispatchWorkItem?
    private var eraserHeldFrom: Bool?
    private var lastInputNote = "なし"
    private var panelView: NSView?
    private var bottomBar: NSView?
    private var cleanMode = false

    private let widgetStack = NSStackView()
    private var widgets: [WidgetView] = []
    private let displayPopup = NSPopUpButton()
    private let pointerBox = NSButton()
    private let shapeBox = NSButton()
    private let curvePopup = NSPopUpButton()
    private let widthDial = DialControl()
    private var swatches: [SwatchView] = []

    private var lastSampleAt = Date.distantPast
    private var answerText = ""
    private var isPresent = false
    private var penScreen: NSScreen?
    private var penIsDown = false
    private var screenChoices: [NSScreen?] = []
    var onPresenceChange: ((Bool) -> Void)?

    /// Gamma applied to raw pressure. Below 1 gives light strokes more width.
    private let curves: [(String, CGFloat)] = [
        ("筆圧 リニア", 1.0),
        ("筆圧 標準", 0.65),
        ("筆圧 軽め", 0.42),
    ]

    // MARK: - Construction

    private var isFullScreen = false
    private var hideAfterExitingFullScreen = false

    init() {
        let window = BoardWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "筆談ボード"
        window.minSize = NSSize(width: 1000, height: 640)
        window.collectionBehavior = [.fullScreenPrimary]
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        wireUp()
        installEscapeHatch()
    }

    /// The board fills the tablet, so give the keyboard a way out. The agent
    /// stays resident; only the board goes away.
    private func installEscapeHatch() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // esc
            // Escape backs out one step at a time: panels first, board second.
            if self?.cleanMode == true {
                self?.toggleCleanMode(nil)
            } else {
                self?.hideBoard(nil)
            }
            return nil
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { isFullScreen = true }

    func windowDidExitFullScreen(_ notification: Notification) {
        isFullScreen = false
        if hideAfterExitingFullScreen {
            hideAfterExitingFullScreen = false
            window?.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideBoard(nil)
        return false
    }

    /// Leaving full screen is animated, so the window can only be ordered out
    /// once that has finished — hence the flag.
    /// Sharing a screen in a call means the sheet is the only thing worth
    /// showing — the panels are for working, not for an audience.
    @objc func toggleCleanMode(_ sender: Any?) {
        setCleanMode(!cleanMode)
        UserDefaults.standard.set(cleanMode, forKey: "cleanMode")
    }

    private func setCleanMode(_ on: Bool) {
        cleanMode = on
        panelView?.isHidden = on
        bottomBar?.isHidden = on
        statusLabel.stringValue = on ? "" : "操作パネルを表示しました"
    }

    @objc func hideBoard(_ sender: Any?) {
        if isFullScreen {
            hideAfterExitingFullScreen = true
            window?.toggleFullScreen(nil)
        } else {
            window?.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let window else { return }
        let root = NSView()
        window.contentView = root

        let tools = buildToolbar()
        canvas.translatesAutoresizingMaskIntoConstraints = false

        telemetry.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        telemetry.textColor = .secondaryLabelColor
        telemetry.lineBreakMode = .byTruncatingTail
        telemetry.stringValue = "タブレットを探しています…"
        telemetry.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        displayPopup.controlSize = .large
        displayPopup.font = NSFont.systemFont(ofSize: 14)
        displayPopup.target = self
        displayPopup.action = #selector(displayChoiceChanged(_:))
        displayPopup.toolTip = "ペンの絶対座標を割り当てるディスプレイ"
        displayPopup.widthAnchor.constraint(equalToConstant: 280).isActive = true

        pointerBox.setButtonType(.switch)
        pointerBox.title = "カーソル操作"
        pointerBox.controlSize = .large
        pointerBox.font = NSFont.systemFont(ofSize: 14)
        pointerBox.target = self
        pointerBox.action = #selector(pointerToggled(_:))
        pointerBox.toolTip = "ペンでシステム全体のカーソルとクリックを動かします"

        shapeBox.setButtonType(.switch)
        shapeBox.title = "図形補正"
        shapeBox.state = .on
        shapeBox.controlSize = .large
        shapeBox.font = NSFont.systemFont(ofSize: 14)
        shapeBox.target = self
        shapeBox.action = #selector(shapeSnapToggled(_:))
        shapeBox.toolTip = "描いたあと、離さずに止めると直線・円・四角に整形します"

        let bottomRow = NSStackView(views: [displayPopup, pointerBox, shapeBox, telemetry])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 14
        bottomRow.alignment = .centerY

        let plus = PlusButton(target: self, action: #selector(newPage(_:)))
        canvas.addSubview(plus)
        NSLayoutConstraint.activate([
            plus.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -30),
            plus.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: 30),
        ])

        let left = NSStackView(views: [tools, canvas, bottomRow])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 10
        left.edgeInsets = NSEdgeInsets(top: 22, left: 20, bottom: 18, right: 8)
        left.setHuggingPriority(.defaultLow, for: .horizontal)
        tools.setContentHuggingPriority(.defaultHigh, for: .vertical)
        bottomRow.setContentHuggingPriority(.defaultHigh, for: .vertical)
        for row in [tools, canvas, bottomRow] as [NSView] {
            row.widthAnchor.constraint(equalTo: left.widthAnchor, constant: -28).isActive = true
        }
        canvas.setContentHuggingPriority(.defaultLow, for: .vertical)
        canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

        let panel = buildPanel()
        panelView = panel
        bottomBar = bottomRow

        let split = NSStackView(views: [left, panel])
        split.orientation = .horizontal
        split.spacing = 0
        split.distribution = .fill
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)

        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panel.widthAnchor.constraint(equalToConstant: 320),
        ])
    }

    private func iconButton(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
        let b = NSButton()
        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        b.bezelStyle = .texturedRounded
        b.imagePosition = .imageOnly
        b.controlSize = .large
        b.toolTip = tooltip
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 54).isActive = true
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return b
    }

    private func buildToolbar() -> NSView {
        let mode = NSSegmentedControl(labels: ["ペン", "消しゴム"], trackingMode: .selectOne,
                                      target: self, action: #selector(modeChanged(_:)))
        mode.selectedSegment = 0
        mode.controlSize = .large
        mode.font = NSFont.systemFont(ofSize: 15)
        mode.heightAnchor.constraint(equalToConstant: 48).isActive = true
        modeControl = mode

        // Open Color (MIT) — an OSS palette built for UI, so the inks stay
        // legible on both light and dark grounds without hand-mixing.
        let inks: [NSColor] = [
            .hex(0x1E1E1E),   // 墨   gray 9 相当
            .hex(0xE03131),   // 朱   red 8
            .hex(0x1971C2),   // 青   blue 8
            .hex(0x2F9E44),   // 緑   green 8
        ]
        let swatchStack = NSStackView()
        swatchStack.orientation = .horizontal
        swatchStack.spacing = 4
        for (i, c) in inks.enumerated() {
            let s = SwatchView(color: c)
            s.isSelected = (i == 0)
            s.onPick = { [weak self] picked in self?.pickColor(picked) }
            swatches.append(s)
            swatchStack.addArrangedSubview(s)
        }
        let laser = SwatchView(color: .hex(0xF03E3E), isLaser: true)   // red 7
        laser.toolTip = "レーザーポインタ — インクを残さず光点で指します"
        laser.onPick = { [weak self] picked in self?.pickColor(picked) }
        swatches.append(laser)
        swatchStack.addArrangedSubview(laser)

        widthDial.doubleValue = 7
        widthDial.onChange = { [weak self] in self?.applyWidth() }

        for (title, _) in curves { curvePopup.addItem(withTitle: title) }
        curvePopup.selectItem(at: 1)
        curvePopup.controlSize = .large
        curvePopup.font = NSFont.systemFont(ofSize: 14)
        curvePopup.target = self
        curvePopup.action = #selector(curveChanged(_:))
        curvePopup.toolTip = "筆圧カーブ"
        curvePopup.widthAnchor.constraint(equalToConstant: 160).isActive = true

        // Paging sits with the drawing tools, not off in the side column: it is
        // part of working on the sheet.
        prevPageButton = BigButton(title: "◀", height: 48, fontSize: 20,
                                   target: self, action: #selector(previousPage(_:)))
        prevPageButton.isSecondary = true
        prevPageButton.widthAnchor.constraint(equalToConstant: 62).isActive = true
        nextPageButton = BigButton(title: "▶", height: 48, fontSize: 20,
                                   target: self, action: #selector(nextPage(_:)))
        nextPageButton.isSecondary = true
        nextPageButton.widthAnchor.constraint(equalToConstant: 62).isActive = true

        pageLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .medium)
        pageLabel.alignment = .center
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [mode, swatchStack, widthDial, curvePopup,
                                      prevPageButton, pageLabel, nextPageButton, spacer])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        return row
    }

    private func actionButton(_ title: String, _ action: Selector) -> BigButton {
        let button = BigButton(title: title, height: 58, fontSize: 16, target: self, action: action)
        button.isSecondary = true
        return button
    }

    private func buildPanel() -> NSView {
        sendButton = BigButton(title: "送る", height: 88, fontSize: 26,
                               target: self, action: #selector(send(_:)))

        proposalLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        proposalLabel.textColor = .labelColor
        proposalLabel.maximumNumberOfLines = 3
        proposalLabel.lineBreakMode = .byWordWrapping
        applyButton = BigButton(title: "適用", height: 72, fontSize: 22,
                                target: self, action: #selector(applyProposal(_:)))
        discardButton = BigButton(title: "破棄", height: 56, fontSize: 17,
                                  target: self, action: #selector(discardProposal(_:)))
        discardButton.isSecondary = true
        for v in [proposalLabel, applyButton, discardButton] as [NSView] { v.isHidden = true }

        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "準備中…"
        statusLabel.lineBreakMode = .byTruncatingTail

        widgetStack.orientation = .vertical
        widgetStack.spacing = 10
        widgetStack.alignment = .leading
        widgetStack.translatesAutoresizingMaskIntoConstraints = false
        widgets = [ClockWidget(), SessionsWidget()]
        for w in widgets { widgetStack.addArrangedSubview(w) }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)

        // The everyday tools, at a size worth hitting with a pen, down in the
        // corner where the hand already is.
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.spacing = 8
        grid.alignment = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false
        let pairs: [[(String, Selector)]] = [
            [("元に戻す", #selector(undoStroke(_:))), ("やり直す", #selector(redoStroke(_:)))],
            [("画像", #selector(openImage(_:))), ("全消去", #selector(clearCanvas(_:)))],
            [("設定", #selector(openInputSettings(_:))), ("書き出し", #selector(exportPNG(_:)))],
            [("このページを削除", #selector(deletePage(_:)))],
        ]
        var gridRows: [NSStackView] = []
        for pair in pairs {
            let row = NSStackView(views: pair.map { actionButton($0.0, $0.1) })
            row.orientation = .horizontal
            row.spacing = 8
            row.distribution = .fillEqually
            grid.addArrangedSubview(row)
            gridRows.append(row)
        }

        let stack = NSStackView(views: [proposalLabel, applyButton, discardButton,
                                        sendButton, statusLabel, widgetStack, spacer, grid])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 8, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [proposalLabel, applyButton, discardButton, sendButton,
                  widgetStack, spacer, grid] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        for w in widgets { w.widthAnchor.constraint(equalTo: widgetStack.widthAnchor).isActive = true }
        for r in gridRows { r.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true }
        applyWidgetVisibility()
        applySendState()
        openPage(pages.current)
        return stack
    }

    // MARK: - Send button state

    private func applySendState() {
        spinTimer?.invalidate()
        spinTimer = nil
        sendButton.iconAngle = 0
        switch sendState {
        case .ready:
            sendButton.title = "送る"
            sendButton.icon = Lucide.image(Lucide.send, size: 24, color: .white)
            sendButton.fill = .hex(0x0CA678)
        case .sending:
            sendButton.title = "送信中"
            sendButton.icon = Lucide.image(Lucide.loaderCircle, size: 24, color: .white, strokeWidth: 2.4)
            sendButton.fill = .hex(0x0CA678)
            let spin = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                self?.sendButton.iconAngle -= .pi / 15
            }
            RunLoop.main.add(spin, forMode: .common)
            spinTimer = spin
        case .sent:
            sendButton.title = "送信済み"
            sendButton.icon = Lucide.image(Lucide.check, size: 26, color: .white, strokeWidth: 2.6)
            sendButton.fill = .hex(0x2F9E44)   // Open Color green 8
        }
        sendButton.needsDisplay = true
    }

    // MARK: - Pages

    /// Saving is debounced: a stroke lands, and a moment later the page on disk
    /// matches what is on the sheet.
    private func schedulePageSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.savePage() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func savePage() {
        guard let id = pages.currentID else { return }
        var page = pages.load(id) ?? PageData(id: id, created: Date(), updated: Date(),
                                              strokes: [], background: nil)
        page.strokes = canvas.storedStrokes
        if let background = canvas.backgroundImage,
           let png = NSBitmapImageRep(cgImage: background).representation(using: .png, properties: [:]) {
            page.background = pages.storeBackground(png, for: id)
        } else {
            page.background = nil
        }
        pages.save(page)
    }

    private func openPage(_ index: Int) {
        saveWork?.cancel()
        pages.go(to: index)
        guard let id = pages.currentID, let page = pages.load(id) else { return }
        canvas.restore(strokes: page.strokes,
                       background: page.background.flatMap { pages.background(named: $0) })
        refreshPageBar()
    }

    /// The outgoing sheet swings away on its spine while the new one is already
    /// underneath — the turn reads as one page leaving, not two views swapping.
    private func animatePageTurn(forward: Bool, from snapshot: CGImage) {
        guard let content = window?.contentView else { return }
        let rect = canvas.convert(canvas.paperRect, to: content)
        guard rect.width > 1, rect.height > 1 else { return }

        let sheet = NSImageView(frame: rect)
        sheet.image = NSImage(cgImage: snapshot, size: rect.size)
        sheet.imageScaling = .scaleAxesIndependently
        sheet.wantsLayer = true
        content.addSubview(sheet)

        guard let layer = sheet.layer else { sheet.removeFromSuperview(); return }
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 16
        layer.shadowOffset = .zero

        // Lifted by the bottom-right corner and thrown up and to the left, the
        // way you actually flick a page over. Going back runs the other way.
        let corner: CGPoint = forward ? CGPoint(x: 1, y: 0) : CGPoint(x: 0, y: 1)
        layer.anchorPoint = corner
        layer.position = CGPoint(x: rect.minX + rect.width * corner.x,
                                 y: rect.minY + rect.height * corner.y)

        let travel: CGFloat = forward ? 1 : -1
        var peel = CATransform3DIdentity
        peel.m34 = -1 / 900
        // The axis runs along the other diagonal, so the corner is what lifts.
        peel = CATransform3DRotate(peel, travel * .pi * 0.62, 1, 1, 0)
        let shrink = CATransform3DMakeScale(0.82, 0.82, 1)
        let fly = CATransform3DMakeTranslation(-travel * rect.width * 0.8,
                                               travel * rect.height * 0.8, 0)
        let end = CATransform3DConcat(CATransform3DConcat(peel, shrink), fly)

        let turn = CABasicAnimation(keyPath: "transform")
        turn.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        turn.toValue = NSValue(caTransform3D: end)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.beginTime = 0.12
        fade.duration = 0.28

        let group = CAAnimationGroup()
        group.animations = [turn, fade]
        group.duration = 0.4
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "pageTurn")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { sheet.removeFromSuperview() }
    }

    private func refreshPageBar() {
        pageLabel.stringValue = "\(pages.current + 1) / \(pages.count)"
        prevPageButton.isEnabled = pages.current > 0
        nextPageButton.isEnabled = pages.current < pages.count - 1
    }

    @objc func previousPage(_ sender: Any?) {
        guard pages.current > 0 else { return }
        savePage()
        let leaving = canvas.flattenedImage()
        openPage(pages.current - 1)
        if let leaving { animatePageTurn(forward: false, from: leaving) }
        statusLabel.stringValue = "ページ \(pages.current + 1)"
    }

    @objc func nextPage(_ sender: Any?) {
        guard pages.current < pages.count - 1 else { return }
        savePage()
        let leaving = canvas.flattenedImage()
        openPage(pages.current + 1)
        if let leaving { animatePageTurn(forward: true, from: leaving) }
        statusLabel.stringValue = "ページ \(pages.current + 1)"
    }

    @objc func newPage(_ sender: Any?) {
        // Adding a page while sitting on an untouched last page just makes
        // blanks pile up — there is already an empty page here.
        if canvas.isEmpty, pages.current == pages.count - 1 {
            statusLabel.stringValue = "このページはまだ空です"
            return
        }
        savePage()
        let leaving = canvas.flattenedImage()
        pages.appendPage()
        openPage(pages.count - 1)
        if let leaving { animatePageTurn(forward: true, from: leaving) }
        statusLabel.stringValue = "新しいページ \(pages.current + 1)"
    }

    @objc func deletePage(_ sender: Any?) {
        guard let id = pages.currentID else { return }
        // An empty page is not worth a confirmation; anything drawn on is.
        if !canvas.isEmpty {
            let alert = NSAlert()
            alert.messageText = "このページを削除しますか？"
            alert.informativeText = "ページ \(pages.current + 1) / \(pages.count) を消します。取り消せません。"
            alert.addButton(withTitle: "削除")
            alert.addButton(withTitle: "やめる")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        saveWork?.cancel()
        pages.delete(id)
        openPage(pages.current)
        statusLabel.stringValue = "ページを削除しました（残り \(pages.count)）"
    }

    /// Sweep out pages that were never drawn on, apart from the one in hand.
    @objc func purgeEmptyPages(_ sender: Any?) {
        savePage()
        let keep = pages.currentID
        var removed = 0
        for id in pages.order where id != keep {
            guard let page = pages.load(id) else { continue }
            if page.strokes.isEmpty && page.background == nil {
                pages.delete(id)
                removed += 1
            }
        }
        openPage(pages.current)
        statusLabel.stringValue = removed == 0 ? "空のページはありません" : "空のページを \(removed) 枚削除しました"
    }

    // MARK: - Assignable inputs

    private func penButton(_ index: Int, _ id: String, down: Bool) {
        let action = inputs.action(for: id)
        guard down || action.isMomentary else { return }
        if down {
            // Measured: bit1 is the upper side button, bit2 the lower, bit3 the tail.
            let names = ["", "上", "下", "お尻"]
            lastInputNote = "pen\(index)→\(action.rawValue)"
            statusLabel.stringValue = "ペン \(names[min(index, 3)])ボタン → \(action.label)"
        }
        run(action, down: down)
    }

    private func run(_ action: BoardAction, down: Bool = true) {
        // Held actions are the only ones that care about the release.
        if action == .laserWhileHeld { setLaser(down); return }

        if action == .eraseWhileHeld {
            if down {
                // A second press while already held must not overwrite the state
                // we owe the person when they let go.
                if eraserHeldFrom == nil { eraserHeldFrom = canvas.eraserSelected }
                canvas.eraserSelected = true
            } else if let previous = eraserHeldFrom {
                canvas.eraserSelected = previous
                eraserHeldFrom = nil
            }
            modeControl?.selectedSegment = canvas.eraserSelected ? 1 : 0
            return
        }
        guard down else { return }

        // Toggling mid-hold would fight the release, which restores the old
        // state — so record the flip for the release to honour instead.
        if action == .toggleEraser, let held = eraserHeldFrom {
            eraserHeldFrom = !held
            return
        }

        if action == .laserWhileHeld {
            setLaser(down)
            return
        }

        if let index = action.colourIndex, swatches.indices.contains(index) {
            pickColor(swatches[index])
            modeControl?.selectedSegment = 0
            return
        }

        switch action {
        case .previousPage: previousPage(nil)
        case .nextPage: nextPage(nil)
        case .newPage: newPage(nil)
        case .undo: canvas.undo()
        case .redo: canvas.redo()
        case .clear: canvas.clearAll()
        case .send: send(nil)
        case .toggleEraser:
            canvas.eraserSelected.toggle()
            modeControl?.selectedSegment = canvas.eraserSelected ? 1 : 0
        case .nextColor:
            guard let current = swatches.firstIndex(where: { $0.isSelected }) else { return }
            pickColor(swatches[(current + 1) % swatches.count])
            modeControl?.selectedSegment = 0
        case .thicker, .thinner:
            widthDial.doubleValue += action == .thicker ? 2 : -2
            applyWidth()
        case .rightClick: inputs.click(.right)
        case .middleClick: inputs.click(.center)
        case .toggleLaser: setLaser(!canvas.laserMode)
        case .passthrough, .none, .eraseWhileHeld, .laserWhileHeld: break
        case .color1, .color2, .color3, .color4, .color5: break   // handled above
        }
    }

    @objc func openInputSettings(_ sender: Any?) {
        guard let host = window, settingsSheet == nil else { return }

        var rows: [(String, String)] = [
            ("pen.button1", "ペン 上ボタン"),
            ("pen.button2", "ペン 下ボタン"),
            ("pen.button3", "ペン お尻（消しゴム側）"),
            ("slider.button", "スライダー内ボタン"),
        ]
        rows += inputs.seenKeys.map {
            (String(format: "key.%02x", $0), "本体キー \(InputMap.name(forUsage: $0))")
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "ボタン割り当て")
        heading.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(heading)

        let hint = NSTextField(labelWithString:
            "本体キーは一度押すと一覧に出ます。5つとも押してから下のボタンで色に割り当てられます。\n"
            + "「そのまま通す」は元のキーをそのまま送ります。本体スライダーは常に線の太さです。")
        hint.font = NSFont.systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)

        for (id, title) in rows {
            let label = NSTextField(labelWithString: title)
            label.font = NSFont.systemFont(ofSize: 15)
            label.widthAnchor.constraint(equalToConstant: 200).isActive = true

            let popup = NSPopUpButton()
            popup.controlSize = .large
            popup.font = NSFont.systemFont(ofSize: 14)
            for action in BoardAction.allCases { popup.addItem(withTitle: action.label) }
            popup.selectItem(at: BoardAction.allCases.firstIndex(of: inputs.action(for: id)) ?? 0)
            popup.target = self
            popup.action = #selector(assignmentChanged(_:))
            popup.identifier = NSUserInterfaceItemIdentifier(id)
            popup.widthAnchor.constraint(equalToConstant: 200).isActive = true

            let row = NSStackView(views: [label, popup])
            row.orientation = .horizontal
            row.spacing = 16
            row.alignment = .centerY
            stack.addArrangedSubview(row)
        }

        let assignColours = BigButton(title: "本体キーを押した順に色1〜5へ割り当て", height: 52, fontSize: 15,
                                      target: self, action: #selector(assignColoursToKeys(_:)))
        assignColours.isSecondary = true
        assignColours.isEnabled = inputs.seenKeys.count >= 2
        assignColours.widthAnchor.constraint(equalToConstant: 416).isActive = true
        stack.addArrangedSubview(assignColours)

        let forget = BigButton(title: "覚えた本体キーを忘れる", height: 44, fontSize: 13,
                               target: self, action: #selector(forgetKeys(_:)))
        forget.isSecondary = true
        forget.widthAnchor.constraint(equalToConstant: 416).isActive = true
        stack.addArrangedSubview(forget)

        let done = BigButton(title: "閉じる", height: 52, fontSize: 16,
                             target: self, action: #selector(closeInputSettings(_:)))
        done.widthAnchor.constraint(equalToConstant: 416).isActive = true
        stack.addArrangedSubview(done)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentView = content
        settingsSheet = sheet
        host.beginSheet(sheet)
    }

    @objc private func assignmentChanged(_ sender: NSPopUpButton) {
        guard let id = sender.identifier?.rawValue else { return }
        inputs.setAction(BoardAction.allCases[sender.indexOfSelectedItem], for: id)
    }

    /// The five keys sit in a row on the tablet; the five colours sit in a row
    /// in the toolbar. Pair them up in the order the keys were first pressed.
    @objc private func assignColoursToKeys(_ sender: Any?) {
        for (index, usage) in inputs.seenKeys.prefix(BoardAction.colourActions.count).enumerated() {
            inputs.setAction(BoardAction.colourActions[index], for: String(format: "key.%02x", usage))
        }
        reopenInputSettings()
        statusLabel.stringValue = "本体キーを色に割り当てました"
    }

    @objc private func forgetKeys(_ sender: Any?) {
        inputs.forgetKeys()
        reopenInputSettings()
        statusLabel.stringValue = "本体キーの記録を消しました — もう一度押すと順番に登録されます"
    }

    private func reopenInputSettings() {
        closeInputSettings(nil)
        DispatchQueue.main.async { [weak self] in self?.openInputSettings(nil) }
    }

    @objc private func closeInputSettings(_ sender: Any?) {
        guard let sheet = settingsSheet else { return }
        window?.endSheet(sheet)
        settingsSheet = nil
    }

    // MARK: - Widgets

    private func applyWidgetVisibility() {
        let d = UserDefaults.standard
        for w in widgets {
            let key = "widget.\(w.id)"
            w.isHidden = d.object(forKey: key) == nil ? false : !d.bool(forKey: key)
        }
    }

    var widgetMenuItems: [(id: String, title: String, visible: Bool)] {
        widgets.map { ($0.id, widgetTitle($0.id), !$0.isHidden) }
    }

    private func widgetTitle(_ id: String) -> String {
        switch id {
        case "clock": return "時刻"
        case "sessions": return "Claude セッション"
        default: return "時刻"
        }
    }

    func toggleWidget(_ id: String) {
        guard let w = widgets.first(where: { $0.id == id }) else { return }
        w.isHidden.toggle()
        UserDefaults.standard.set(!w.isHidden, forKey: "widget.\(id)")
    }

    // MARK: - Presence

    var isTabletPresent: Bool { isPresent }

    private func evaluatePresence() {
        let present = hid.isReadable
        guard present != isPresent else { return }
        isPresent = present
        if present { comeForward() } else { standDown() }
        onPresenceChange?(present)
    }

    func comeForward() {
        rebuildDisplayChoices()
        hideAfterExitingFullScreen = false
        let target = penScreen ?? NSScreen.main ?? NSScreen.screens.first
        // Full screen needs a regular app, and it lands on whichever display the
        // window is already on — so place it first, then let the run loop settle
        // before asking for the transition.
        NSApp.setActivationPolicy(.regular)
        if let target, !isFullScreen {
            window?.setFrame(target.visibleFrame.insetBy(dx: 60, dy: 40), display: true)
        }
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        restoreSettings()

        guard !isFullScreen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.isFullScreen, self.window?.isVisible == true else { return }
            self.window?.toggleFullScreen(nil)
        }
    }

    func standDown() {
        pointer.surrender()
        pointer.isEnabled = false
        pointerBox.state = .off
        hid.setSeizing(false)
        canvas.ignoresMouse = false
        hideBoard(nil)
    }

    // MARK: - Settings

    private enum Key {
        static let pointer = "pointerEnabled"
        static let curve = "curveIndex"
        static let width = "baseWidth"
    }

    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(pointerBox.state == .on, forKey: Key.pointer)
        d.set(curvePopup.indexOfSelectedItem, forKey: Key.curve)
        d.set(widthDial.doubleValue, forKey: Key.width)
    }

    private func restoreSettings() {
        let d = UserDefaults.standard
        if d.object(forKey: Key.curve) != nil {
            let i = min(max(d.integer(forKey: Key.curve), 0), curves.count - 1)
            curvePopup.selectItem(at: i)
            canvas.pressureCurve = curves[i].1
        }
        if d.object(forKey: Key.width) != nil {
            let w = d.double(forKey: Key.width)
            if w > 0 { widthDial.doubleValue = w; canvas.baseWidth = CGFloat(w) }
        }
        // Cursor takeover is the point of the app, so it is on unless turned off.
        setCleanMode(d.bool(forKey: "cleanMode"))
        let wantsPointer = d.object(forKey: Key.pointer) == nil ? true : d.bool(forKey: Key.pointer)
        if wantsPointer, penScreen != nil {
            pointerBox.state = .on
            pointerToggled(pointerBox)
        }
    }

    // MARK: - Wiring

    private func wireUp() {
        canvas.onSnap = { [weak self] note in
            self?.statusLabel.stringValue = note
            self?.lastInputNote = note
        }
        if UserDefaults.standard.object(forKey: "shapeSnap") != nil {
            canvas.snapsShapes = UserDefaults.standard.bool(forKey: "shapeSnap")
            shapeBox.state = canvas.snapsShapes ? .on : .off
        }

        canvas.onChange = { [weak self] in
            guard let self else { return }
            if self.sendState == .sent { self.sendState = .ready }
            self.schedulePageSave()
        }

        canvas.pressureSource = { [weak self] in
            guard let self, self.hid.isConnected else { return nil }
            guard Date().timeIntervalSince(self.lastSampleAt) < 0.4 else { return nil }
            let s = self.hid.latest
            guard s.inRange else { return nil }
            return (s.pressure, false)
        }

        rebuildDisplayChoices()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.rebuildDisplayChoices() }

        hid.onStatus = { [weak self] message in
            self?.telemetry.stringValue = message
            self?.evaluatePresence()
        }
        hid.onSample = { [weak self] s in
            guard let self else { return }
            self.lastSampleAt = Date()
            self.pointer.screen = self.penScreen
            self.pointer.handle(s)

            if self.canvas.laserMode {
                self.canvas.updateLaser(paper: s.inRange ? self.canvasPaperPoint(for: s) : nil)
            }

            let now = (s.button1, s.button2, s.button3)
            if now.0 != self.previousPenButtons.0 { self.penButton(1, "pen.button1", down: now.0) }
            if now.1 != self.previousPenButtons.1 { self.penButton(2, "pen.button2", down: now.1) }
            if now.2 != self.previousPenButtons.2 { self.penButton(3, "pen.button3", down: now.2) }
            self.previousPenButtons = now
            self.drivePen(with: s)

            let buttons = [s.tip ? "先" : "・", s.button1 ? "1" : "・",
                           s.button2 ? "2" : "・", s.button3 ? "3" : "・"].joined()
            let target = self.pointer.isEnabled ? "カーソル操作" : (self.penScreen == nil ? "カーソル追従" : "絶対座標")
            self.telemetry.stringValue = String(
                format: "%@ · %@  筆圧 %5d/16383 (%3.0f%%)  ボタン %@",
                s.mode.rawValue, target, s.rawPressure, s.pressure * 100, buttons)
        }
        pointer.mapsRightButton = false   // routed through the assignments instead

        hid.onKeys = { [weak self] modifiers, down in
            guard let self else { return }
            for usage in down.subtracting(self.pressedKeys) {
                self.inputs.remember(usage: usage)
                let id = String(format: "key.%02x", usage)
                let action = self.inputs.action(for: id)
                self.lastInputNote = "key.\(String(format: "%02x", usage))→\(action.rawValue)"
                if action == .passthrough {
                    self.inputs.passThrough(usage: usage, modifiers: modifiers, down: true)
                } else {
                    self.run(action, down: true)
                }
            }
            for usage in self.pressedKeys.subtracting(down) {
                let id = String(format: "key.%02x", usage)
                let action = self.inputs.action(for: id)
                if action == .passthrough {
                    self.inputs.passThrough(usage: usage, modifiers: modifiers, down: false)
                } else if action.isMomentary {
                    self.run(action, down: false)
                }
            }
            self.pressedKeys = down
        }

        hid.onStrip = { [weak self] delta, touching, button in
            guard let self else { return }
            if button != self.previousStripButton {
                self.previousStripButton = button
                self.run(self.inputs.action(for: "slider.button"), down: button)
            }
            self.lastInputNote = "strip d=\(delta) btn=\(button)"
            guard delta != 0 else { return }
            // The strip is the width control, always — not something to assign away.
            self.stripCarry += Double(delta) / 24
            let step = self.stripCarry.rounded(.towardZero)
            guard step != 0 else { return }
            self.stripCarry -= step
            self.widthDial.doubleValue += step
            self.applyWidth()
        }

        hid.start()

        let watchdog = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            for w in self.widgets where !w.isHidden { w.refresh() }
            guard Date().timeIntervalSince(self.lastSampleAt) > 2.5 else { return }
            if self.canvas.ignoresMouse {
                self.canvas.ignoresMouse = false
                self.canvas.finishStroke()
                self.penIsDown = false
            }
            self.pointer.surrender()
            if !self.hid.isReadable {
                self.telemetry.stringValue = "生HID未受信 — \(self.hid.diagnostics)"
            }
        }
        RunLoop.main.add(watchdog, forMode: .common)

        let logger = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let age = Date().timeIntervalSince(self.lastSampleAt)
            let line = [
                ISO8601DateFormatter().string(from: Date()),
                self.hid.diagnostics,
                "デバイス=\(self.hid.isConnected ? "検出" : "未検出")",
                age > 60 ? "最終サンプル=なし" : String(format: "最終サンプル=%.1f秒前", age),
                "モード=\(self.hid.latest.mode.rawValue)",
                "割当=\(self.penScreen?.localizedName ?? "なし")",
                "カーソル操作=\(self.pointer.isEnabled ? "ON" : "OFF")",
                "アクセシビリティ=\(self.pointer.isTrusted ? "許可" : "未許可")",
                "前面=\(self.isPresent ? "表示" : "常駐")",
                "最後の入力=\(self.lastInputNote)",
                "覚えたキー=\(self.inputs.seenKeys.map { String(format: "%02x", $0) }.joined(separator: ","))",
            ].joined(separator: "  ")
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".hitsudan", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? line.write(to: dir.appendingPathComponent("hid-status.log"),
                            atomically: true, encoding: .utf8)
            self.bridge.publish(state: [
                "tabletPresent": self.isPresent,
                "strokes": self.canvas.strokeCount,
                "hasBackground": self.canvas.backgroundImage != nil,
                "pointerEnabled": self.pointer.isEnabled,
            ])
            self.evaluatePresence()
        }
        RunLoop.main.add(logger, forMode: .common)

        bridge.onCommand = { [weak self] op, args in self?.handle(op, args) ?? ["ok": false, "error": "not ready"] }
        bridge.start()
        statusLabel.stringValue = "書いて「送る」— セッションが read_board で読みます"
    }

    // MARK: - Commands from a Claude session

    /// Everything the MCP server can ask the board to do. Runs on the main
    /// thread; the reply goes straight back to the waiting session.
    private func handle(_ op: String, _ args: [String: Any]) -> [String: Any] {
        switch op {
        case "capture":
            guard let png = canvas.flattenedPNG() else { return ["ok": false, "error": "書き出せません"] }
            bridge.publish(png: png, note: "capture", bump: false)
            return ["ok": true]

        case "clear":
            propose("セッションがボードの消去を求めています") { [weak self] in
                self?.canvas.clearAll()
                self?.canvas.notice = nil
            }
            return ["ok": true, "pending": true]

        case "focus":
            comeForward()
            NSApp.activate(ignoringOtherApps: true)
            return ["ok": true]

        case "notice":
            canvas.notice = args["text"] as? String
            return ["ok": true]

        case "show":
            var underlay: CGImage?
            if let svg = args["svg"] as? String {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hitsudan-\(UUID().uuidString).svg")
                try? Data(svg.utf8).write(to: tmp)
                defer { try? FileManager.default.removeItem(at: tmp) }
                guard let image = NSImage(contentsOf: tmp) else {
                    return ["ok": false, "error": "SVG を描画できませんでした"]
                }
                underlay = rasterize(image)
            } else if let path = args["image_path"] as? String {
                guard let image = NSImage(contentsOfFile: path) else {
                    return ["ok": false, "error": "画像を開けません: \(path)"]
                }
                underlay = rasterize(image)
            } else if let text = args["text"] as? String {
                let clearInk = args["clear_ink"] as? Bool == true
                let note = args["notice"] as? String
                propose(args["notice"] as? String ?? "セッションがテキストを送ってきました") { [weak self] in
                    guard let self else { return }
                    if clearInk { self.canvas.clearInkOnly() }
                    self.canvas.setBackgroundText(text)
                    self.canvas.notice = note
                }
                return ["ok": true, "pending": true]
            } else {
                return ["ok": false, "error": "svg / image_path / text のいずれかが必要です"]
            }
            guard let underlay else { return ["ok": false, "error": "描画に失敗しました"] }
            let clearInk = args["clear_ink"] as? Bool == true
            let note = args["notice"] as? String
            canvas.preview = underlay
            propose(note ?? "セッションが下敷きを送ってきました") { [weak self] in
                guard let self else { return }
                if clearInk { self.canvas.clearInkOnly() }
                self.canvas.setBackground(underlay)
                self.canvas.notice = note
            }
            return ["ok": true, "pending": true]

        case "status":
            return [
                "ok": true,
                "pendingProposal": proposal != nil,
                "tabletPresent": isPresent,
                "strokes": canvas.strokeCount,
                "hasBackground": canvas.backgroundImage != nil,
                "pointerEnabled": pointer.isEnabled,
            ]

        default:
            return ["ok": false, "error": "unknown op: \(op)"]
        }
    }

    /// A session never overwrites the sheet on its own: it offers, and the
    /// person decides with a button big enough to hit with a pen.
    private func propose(_ summary: String, _ apply: @escaping () -> Void) {
        proposal = Proposal(summary: summary, apply: apply)
        proposalLabel.stringValue = summary
        for v in [proposalLabel, applyButton, discardButton] as [NSView] { v.isHidden = false }
        canvas.notice = summary
        comeForward()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func endProposal() {
        proposal = nil
        canvas.preview = nil
        for v in [proposalLabel, applyButton, discardButton] as [NSView] { v.isHidden = true }
    }

    @objc private func applyProposal(_ sender: Any?) {
        guard let proposal else { return }
        canvas.preview = nil
        proposal.apply()
        endProposal()
        statusLabel.stringValue = "適用しました"
    }

    @objc private func discardProposal(_ sender: Any?) {
        canvas.notice = nil
        endProposal()
        statusLabel.stringValue = "破棄しました"
    }

    /// Rasterise at sheet resolution — an SVG's natural size is usually tiny.
    private func rasterize(_ image: NSImage) -> CGImage? {
        let scale: CGFloat = 2
        let w = Int(CanvasView.paperSize.width * scale), h = Int(CanvasView.paperSize.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let source = image.size
        let ratio = source.width > 0 && source.height > 0 ? source.width / source.height : 1
        var dw = CGFloat(w), dh = CGFloat(w) / ratio
        if dh > CGFloat(h) { dh = CGFloat(h); dw = dh * ratio }
        image.draw(in: NSRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2, width: dw, height: dh))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    // MARK: - Tool actions

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        canvas.eraserSelected = sender.selectedSegment == 1
        if canvas.laserMode { setLaser(false) }
    }

    private func setLaser(_ on: Bool) {
        canvas.laserMode = on
        if on {
            canvas.eraserSelected = false
            modeControl?.selectedSegment = 0
        }
        for s in swatches where s.isLaser { s.isSelected = on }
        if !on, let ink = swatches.first(where: { !$0.isLaser && $0.color == canvas.inkColor }) {
            for s in swatches { s.isSelected = (s === ink) }
        }
    }

    private func pickColor(_ picked: SwatchView) {
        for s in swatches { s.isSelected = (s === picked) }
        canvas.eraserSelected = false
        modeControl?.selectedSegment = 0

        if picked.isLaser {
            canvas.laserMode = true
            lastInputNote = "レーザー"
            statusLabel.stringValue = "レーザーポインタ"
            return
        }
        canvas.laserMode = false
        canvas.inkColor = picked.color
        let index = (swatches.firstIndex(of: picked) ?? 0) + 1
        lastInputNote = "色\(index)"
        statusLabel.stringValue = "色\(index) を選択"
    }

    private func applyWidth() {
        canvas.baseWidth = CGFloat(widthDial.doubleValue)
        saveSettings()
    }

    @objc private func curveChanged(_ sender: NSPopUpButton) {
        canvas.pressureCurve = curves[sender.indexOfSelectedItem].1
        saveSettings()
    }

    @objc func undoStroke(_ sender: Any?) { canvas.undo() }
    @objc func redoStroke(_ sender: Any?) { canvas.redo() }
    @objc func clearCanvas(_ sender: Any?) { canvas.clearAll() }

    @objc func openImage(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .pdf]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
            self?.canvas.setBackground(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
    }

    @objc func exportPNG(_ sender: Any?) {
        guard let data = canvas.flattenedPNG() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "board.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    // MARK: - Publishing the sheet

    @objc func send(_ sender: Any?) {
        guard sendState != .sending else { return }
        guard !canvas.isEmpty else {
            statusLabel.stringValue = "キャンバスが空です"
            return
        }
        sendState = .sending
        statusLabel.stringValue = "書き出しています…"
        canvas.notice = nil

        // The canvas bitmap is main-thread state, so the flatten stays here; the
        // async hop just lets the spinner paint before it starts.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let png = self.canvas.flattenedPNG() else {
                self.sendState = .ready
                self.statusLabel.stringValue = "画像を書き出せません"
                return
            }
            self.bridge.publish(png: png, note: "送る", bump: true)
            // Also on the clipboard, for a session with no MCP server.
            let pb = NSPasteboard.general
            pb.clearContents()
            if let image = NSImage(data: png) { pb.writeObjects([image]) }

            // Hold the spinner long enough to be read as a state, not a flicker.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.sendState = .sent
                self.statusLabel.stringValue = "送信しました（⌘V でも貼れます）"
            }
        }
    }

    // MARK: - Absolute pen mapping

    private func rebuildDisplayChoices() {
        let previous = displayPopup.indexOfSelectedItem
        displayPopup.removeAllItems()
        screenChoices = []
        displayPopup.addItem(withTitle: "ペン割当: 自動")
        screenChoices.append(nil)
        for screen in NSScreen.screens {
            displayPopup.addItem(withTitle: "ペン割当: \(screen.localizedName)")
            screenChoices.append(screen)
        }
        displayPopup.addItem(withTitle: "ペン割当: カーソル追従")
        screenChoices.append(nil)
        displayPopup.selectItem(at: (previous >= 0 && previous < displayPopup.numberOfItems) ? previous : 0)
        resolvePenScreen()
    }

    private func detectTabletScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            let name = screen.localizedName.lowercased()
            return name.contains("kamvas") || name.contains("huion") || name.contains("gs1333")
        }
    }

    private func resolvePenScreen() {
        let index = displayPopup.indexOfSelectedItem
        if index == 0 {
            penScreen = detectTabletScreen()
            displayPopup.item(at: 0)?.title = penScreen.map { "ペン割当: 自動（\($0.localizedName)）" }
                ?? "ペン割当: 自動（未検出）"
        } else if index == displayPopup.numberOfItems - 1 {
            penScreen = nil
        } else if index < screenChoices.count {
            penScreen = screenChoices[index]
        }
        if penScreen == nil, canvas.ignoresMouse {
            canvas.ignoresMouse = false
            canvas.finishStroke()
            penIsDown = false
        }
    }

    @objc private func displayChoiceChanged(_ sender: NSPopUpButton) { resolvePenScreen() }

    @objc private func shapeSnapToggled(_ sender: NSButton) {
        canvas.snapsShapes = sender.state == .on
        UserDefaults.standard.set(canvas.snapsShapes, forKey: "shapeSnap")
    }

    @objc private func pointerToggled(_ sender: NSButton) {
        guard sender.state == .on else {
            pointer.isEnabled = false
            hid.setSeizing(false)
            saveSettings()
            statusLabel.stringValue = "カーソル操作を停止しました"
            return
        }
        guard penScreen != nil else {
            sender.state = .off
            statusLabel.stringValue = "先に「ペン割当」でディスプレイを選んでください"
            return
        }
        if !pointer.isTrusted {
            pointer.requestTrust()
            sender.state = .off
            statusLabel.stringValue = "アクセシビリティを許可してから、もう一度チェックしてください"
            return
        }
        hid.setSeizing(true)
        pointer.isEnabled = true
        canvas.ignoresMouse = false
        saveSettings()
        statusLabel.stringValue = "ペンでカーソル操作中"
    }

    /// Where this sample lands on the sheet, in paper coordinates.
    private func canvasPaperPoint(for s: PenSample) -> CGPoint? {
        guard let screen = penScreen, let window = self.window else { return nil }
        let frame = screen.frame
        let screenPoint = CGPoint(x: frame.minX + s.x * frame.width,
                                  y: frame.maxY - s.y * frame.height)
        return canvas.paperPoint(from: canvas.convert(window.convertPoint(fromScreen: screenPoint), from: nil))
    }

    private func drivePen(with s: PenSample) {
        guard !pointer.isEnabled else {
            canvas.ignoresMouse = false
            return
        }
        guard let screen = penScreen, let window = self.window else { return }
        canvas.ignoresMouse = true
        let frame = screen.frame
        let screenPoint = CGPoint(x: frame.minX + s.x * frame.width,
                                  y: frame.maxY - s.y * frame.height)
        let viewPoint = canvas.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        let width = canvas.width(forPressure: CGFloat(s.pressure))
        switch (s.tip, penIsDown) {
        case (true, false):
            canvas.beginStroke(at: viewPoint, width: width, eraser: s.eraser)
            penIsDown = true
        case (true, true):
            canvas.extendStroke(to: viewPoint, width: width)
        case (false, true):
            canvas.finishStroke()
            penIsDown = false
        case (false, false):
            break
        }
    }

    // MARK: - Menu bar access

    var isPointerEnabled: Bool { pointer.isEnabled }

    func setPointerEnabled(_ on: Bool) {
        pointerBox.state = on ? .on : .off
        pointerToggled(pointerBox)
    }

    func releasePointer() {
        pointer.surrender()
        hid.setSeizing(false)
    }
}
