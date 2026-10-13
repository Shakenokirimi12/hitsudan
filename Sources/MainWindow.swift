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

    init(title: String, height: CGFloat, fontSize: CGFloat, target: AnyObject?, action: Selector,
         heightPriority: NSLayoutConstraint.Priority = .required) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        translatesAutoresizingMaskIntoConstraints = false
        // 優先度は作る時点で決める。アクティブな制約を required から下げるのは
        // AppKit が禁じていて、環境によっては例外になる。
        let heightConstraint = heightAnchor.constraint(equalToConstant: height)
        heightConstraint.priority = heightPriority
        heightConstraint.isActive = true
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
        let textColor = isEnabled ? color : color.withAlphaComponent(0.4)
        // 収まらないぶんは末尾を省略する。これが無いと、送り先が付いて
        // 「送る → <セッション名>」になったときに自然幅のまま描かれ、
        // アイコンが左へはみ出してテキストが端で切れていた。
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: textColor,
            .paragraphStyle: style,
        ]
        let padding: CGFloat = 12
        let available = max(bounds.width - padding * 2, 0)
        let natural = (title as NSString).size(withAttributes: attrs)

        // アイコンだけのボタン（title が空）は、中央にアイコンを置いて終わり。
        guard !title.isEmpty else {
            if let icon {
                drawIcon(icon, centredAt: CGPoint(x: bounds.midX, y: bounds.midY), textColor: textColor)
            }
            return
        }

        guard let icon else {
            let width = min(natural.width, available)
            (title as NSString).draw(in: NSRect(x: bounds.midX - width / 2,
                                                y: bounds.midY - natural.height / 2,
                                                width: width, height: natural.height),
                                     withAttributes: attrs)
            return
        }

        let gap: CGFloat = 12
        // テキストに回せるのは、アイコンと隙間を引いた残りだけ。
        let textWidth = min(natural.width, max(available - icon.size.width - gap, 0))
        let total = icon.size.width + gap + textWidth
        let originX = max(bounds.midX - total / 2, padding)

        drawIcon(icon, centredAt: CGPoint(x: originX + icon.size.width / 2, y: bounds.midY),
                 textColor: textColor)

        let leftAligned = NSMutableParagraphStyle()
        leftAligned.alignment = .left
        leftAligned.lineBreakMode = .byTruncatingTail
        var textAttrs = attrs
        textAttrs[.paragraphStyle] = leftAligned
        (title as NSString).draw(in: NSRect(x: originX + icon.size.width + gap,
                                            y: bounds.midY - natural.height / 2,
                                            width: textWidth, height: natural.height),
                                 withAttributes: textAttrs)
    }

    /// `draw(in:)` ignores `isTemplate`, so a template icon is painted here:
    /// the mask goes into a transparency layer and the tint is filled
    /// `.sourceIn` over it. The tint is resolved now, against the appearance
    /// AppKit set up for this draw, so a light/dark switch (which redraws the
    /// view) repaints the icon in the new colour. `.sourceIn` keeps the tint's
    /// own alpha, so a translucent colour such as `.tertiaryLabelColor` stays
    /// translucent instead of being blended with the black mask.
    ///
    /// A disabled button paints its icon in the dimmed text colour: on an
    /// icon-only button (page arrows) that is the only cue it does nothing.
    private func drawIcon(_ icon: NSImage, centredAt centre: CGPoint, textColor: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: centre.x, yBy: centre.y)
        transform.rotate(byRadians: iconAngle)
        transform.translateX(by: -icon.size.width / 2, yBy: -icon.size.height / 2)
        transform.concat()
        let rect = NSRect(origin: .zero, size: icon.size)
        if icon.isTemplate, let context = NSGraphicsContext.current?.cgContext {
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            icon.draw(in: rect)
            (isEnabled ? (icon as? LucideIcon)?.tint ?? textColor : textColor).setFill()
            rect.fill(using: .sourceIn)
            context.endTransparencyLayer()
        } else {
            icon.draw(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class BoardWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class MainWindowController: NSWindowController, NSWindowDelegate {

    private let canvas = CanvasView()
    private let hid = TabletHID()
    private let barrier = MouseBarrier()
    private let bridge = BoardBridge()

    private let telemetry = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var sendButton: BigButton!
    private var applyButton: BigButton!
    private var discardButton: BigButton!
    private let proposalLabel = NSTextField(labelWithString: "")

    /// What a session has asked to put on the sheet, waiting for a decision.
    /// What becomes of the page a request is answered on.
    private enum Retention: String {
        case keep        // ノートに残す
        case temporary   // 送ったら消えて、元のページに戻る
        case ask         // 送ったあとユーザーに聞く
    }

    private struct Proposal {
        let id: String
        let summary: String
        var applyTitle = "適用"
        var discardTitle = "破棄"
        /// Content from a session is rarely about the page in hand, so accepting
        /// it starts a fresh page instead of burying what is already there.
        let onNewPage: Bool
        /// Shown faintly over the sheet while undecided. Each proposal sets its
        /// own, so a text or clear proposal never shows an earlier one's SVG.
        var preview: CGImage?
        /// Session key that made it, and whether its outcome is filed for that session.
        var owner = ""
        var notify = false
        /// The page retention it asked for, applied only when it is accepted.
        var retain: Retention?
        let apply: () -> Void
    }
    private var proposal: Proposal?
    private var lastProposalID = ""
    private var lastProposalOutcome = ""
    private var retention: Retention = .keep
    /// The page a request pulled up, and where to go back to afterwards.
    private var scratchPageID: String?
    private var returnToPage: Int?
    /// Which session the scratch page was made for. Another session's request
    /// never inherits it — and so can never get it deleted.
    private var scratchOwner = ""
    private var readingClearWork: DispatchWorkItem?
    /// A scratch page whose fate is being asked about ("残しますか？"). The
    /// question owns it: only an explicit 破棄 on that question deletes it.
    private var pendingScratchDrop: (id: String, back: Int?)?
    /// What the pen was before a session borrowed it, and what the session set
    /// it to — so it can be handed back untouched, and only if the person has
    /// not since chosen something else themselves.
    private var penLoan: (restoreInk: Int, restoreWidth: Double, lentInk: Int, lentWidth: Double)?

    private enum SendState { case ready, sending, sent }
    private var sendState: SendState = .ready { didSet { applySendState() } }
    private var spinTimer: Timer?

    private let inputs = InputMap()
    private var modeControl: NSSegmentedControl!
    private var pressedKeys: Set<UInt8> = []
    /// Keys we posted a key-down for, so each gets exactly one key-up — even if
    /// the seize changed, or the device went away, while it was held.
    private var postedKeys: Set<UInt8> = []
    private var previousPenButtons = (false, false, false)
    private var previousStripButton = false
    private var stripCarry = 0.0
    /// The settings, as a sheet on the board or a window on another display.
    private var settingsSheet: NSWindow?
    private var settingsCloseObserver: NSObjectProtocol?

    private let pages = PageStore()
    private var prevPageButton: BigButton!
    private var nextPageButton: BigButton!
    private let pageLabel = NSTextField(labelWithString: "")
    private var saveWork: DispatchWorkItem?
    private var eraserHeldFrom: Bool?
    private var lastInputNote = "なし"
    private var panelView: NSView?
    private var cleanMode = false
    /// Which session, if any, is sitting in wait_for_board right now.
    private var waitingLabel: String?
    /// Its file key (see hitsudan-mcp's sessionKey); "" from servers that predate it.
    private var waitingKey = ""
    private var waitingPrompt = ""
    private var waitingUntil = Date.distantPast

    private let widgetStack = NSStackView()
    private var widgets: [WidgetView] = []
    private let displayPopup = NSPopUpButton()
    private let shapeBox = NSButton()
    private let curvePopup = NSPopUpButton()
    private let widthDial = DialControl()
    private var swatches: [SwatchView] = []

    private var lastSampleAt = Date.distantPast
    private var isPresent = false
    private var penScreen: NSScreen?
    private var penIsDown = false
    /// A press that landed on a control rather than on the paper. It owns the
    /// pen until the nib lifts, so dragging off the button onto the paper does
    /// not turn into ink, and the control gets its matching mouse-up.
    private var controlPress: (window: NSWindow, at: CGPoint)?
    private var controlPressNumber = 0
    /// Where the pen last pointed, in screen coordinates.
    private var lastPenPoint: CGPoint?
    /// The pen display menu, by identity: "auto" or a display's UUID.
    /// Positions shift whenever a display comes or goes.
    private var screenChoices: [(id: String, screen: NSScreen?)] = []
    private var penDisplayChoice = UserDefaults.standard.string(forKey: "penDisplay") ?? "auto"
    /// The seize was asked for and refused while this tablet has been present.
    /// Not retried on every presence check: each attempt reopens the device,
    /// which would cut into whatever is being drawn.
    private var seizeRefused = false
    /// When the pen display went missing (system uptime, so a clock change
    /// cannot stretch it), for the grace before giving up the seize.
    private var penScreenLostAt: TimeInterval?
    private var lastBarrierState = MouseBarrier.State.off
    var onPresenceChange: ((Bool) -> Void)?

    /// Gamma applied to raw pressure. Below 1 gives light strokes more width.
    private let curves: [(String, CGFloat)] = [
        ("筆圧 リニア", 1.0),
        ("筆圧 標準", 0.65),
        ("筆圧 軽め", 0.42),
    ]

    // MARK: - Construction

    private var isFullScreen = false
    /// True from our own toggleFullScreen (or windowWill…FullScreen for one we
    /// did not start) until windowDid…FullScreen. Another toggleFullScreen
    /// during the animation is ignored by AppKit, and `isFullScreen` still
    /// describes the state being left.
    private var isChangingFullScreen = false
    /// Bumped by each toggle we start; `toggleStarted` turns true once AppKit
    /// confirms it with windowWill…FullScreen.
    private var toggleGeneration = 0
    private var toggleStarted = true
    /// What to do once the transition in flight settles. Unplugging and
    /// re-plugging can land mid-animation; the latest request wins.
    private enum AfterFullScreenChange { case nothing, hide, show }
    private var afterFullScreenChange = AfterFullScreenChange.nothing

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
        // Settings from when the pen could drive the system cursor. "follow"
        // mapped the pen onto whichever display the cursor was on, which means
        // nothing now that the pen never moves it.
        if penDisplayChoice == "follow" {
            penDisplayChoice = "auto"
            UserDefaults.standard.set(penDisplayChoice, forKey: "penDisplay")
        }
        UserDefaults.standard.removeObject(forKey: "pointerEnabled")
        buildUI()
        wireUp()
        installEscapeHatch()
    }

    /// The board fills the tablet, so give the keyboard a way out. The agent
    /// stays resident; only the board goes away.
    private func installEscapeHatch() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // esc
            // The monitor sees every window's keys. Esc in the settings sheet or
            // in a confirmation alert belongs to that window, not to the board.
            guard let self, let board = self.window, event.window === board, board.isKeyWindow,
                  board.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
            // Escape backs out one step at a time: panels first, board second.
            // A panel held up by a pending question is already showing, so
            // that step is skipped rather than silently turning clean mode off.
            if self.panelView?.isHidden == true {
                self.toggleCleanMode(nil)
            } else {
                self.hideBoard(nil)
            }
            return nil
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        isChangingFullScreen = true
        toggleStarted = true
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isChangingFullScreen = false
        isFullScreen = true
        settleFullScreenChange()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        isChangingFullScreen = false
        settleFullScreenChange()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        isChangingFullScreen = true
        toggleStarted = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isChangingFullScreen = false
        isFullScreen = false
        settleFullScreenChange()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        isChangingFullScreen = false
        // Asking to leave again could fail again, round and round. A queued
        // hide (usually the tablet going away) must still happen, so put the
        // window away as it is rather than leave it filling the main display.
        if afterFullScreenChange == .hide {
            afterFullScreenChange = .nothing
            window.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
            return
        }
        settleFullScreenChange()
    }

    /// Mark the transition as under way from the moment we ask for it, not from
    /// windowWill…FullScreen: a comeForward landing in between would otherwise
    /// see a settled full screen, drop the queued hide and leave the board
    /// windowed once the exit finishes.
    private func startFullScreenToggle() {
        guard let window else { return }
        toggleGeneration += 1
        let generation = toggleGeneration
        toggleStarted = false
        isChangingFullScreen = true
        window.toggleFullScreen(nil)
        // A toggle AppKit declines arrives at no delegate method at all, and a
        // flag that never clears would queue every later show and hide for
        // good. Treat silence as the matching failure.
        // Generous: windowWill… normally follows within a frame or two, and a
        // late one after this fires is still handled by the delegate methods.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.toggleGeneration == generation, !self.toggleStarted,
                  self.isChangingFullScreen, let window = self.window else { return }
            NSLog("hitsudan: toggleFullScreen was not taken up; settling as a failed transition")
            if self.isFullScreen {
                self.windowDidFailToExitFullScreen(window)
            } else {
                self.windowDidFailToEnterFullScreen(window)
            }
        }
    }

    /// Carry out whatever was asked for while the window was mid-animation.
    /// Only requests made through hideBoard/comeForward are queued, so leaving
    /// full screen by hand (green button, ⌃⌘F) is left alone.
    private func settleFullScreenChange() {
        let next = afterFullScreenChange
        afterFullScreenChange = .nothing
        switch next {
        case .nothing: break
        case .hide: hideBoard(nil)
        case .show: comeForward()
        }
    }

    /// Keep the side widgets live only while someone can see them. The
    /// sessions widget spawns `claude agents` to refresh, which is pointless
    /// work for an agent that sits in the menu bar all day with the board away.
    private func refreshVisibleWidgets() {
        guard let window, window.isVisible, window.occlusionState.contains(.visible) else { return }
        for w in widgets where !w.isHidden { w.refresh() }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        // Coming back into view should not show a clock that is up to a
        // second stale.
        refreshVisibleWidgets()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideBoard(nil)
        return false
    }

    /// Sharing a screen in a call means the sheet is the only thing worth
    /// showing — the panels are for working, not for an audience.
    @objc func toggleCleanMode(_ sender: Any?) {
        setCleanMode(!cleanMode)
        UserDefaults.standard.set(cleanMode, forKey: "cleanMode")
    }

    private func setCleanMode(_ on: Bool) {
        cleanMode = on
        applyPanelVisibility()
        statusLabel.stringValue = on && panelView?.isHidden == false
            ? "依頼が済むと操作パネルを隠します" : (on ? "" : "操作パネルを表示しました")
    }

    /// The panel holds 適用/破棄/送る, the only way a pen can answer. While a
    /// proposal or a request is up it is shown whatever clean mode says; the
    /// saved preference is left alone and takes over again once nothing is pending.
    private func applyPanelVisibility() {
        panelView?.isHidden = cleanMode && proposal == nil && waitingLabel == nil
    }

    /// Leaving full screen is animated, so the window can only be ordered out
    /// once that has finished — settleFullScreenChange does it from there.
    @objc func hideBoard(_ sender: Any?) {
        if isChangingFullScreen {
            // A toggle now would be dropped; hide once the animation lands.
            afterFullScreenChange = .hide
        } else if isFullScreen {
            afterFullScreenChange = .hide
            startFullScreenToggle()
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

        shapeBox.setButtonType(.switch)
        shapeBox.title = "図形補正"
        shapeBox.state = .on
        shapeBox.controlSize = .large
        shapeBox.font = NSFont.systemFont(ofSize: 14)
        shapeBox.target = self
        shapeBox.action = #selector(shapeSnapToggled(_:))
        shapeBox.toolTip = "描いたあと、離さずに止めると直線・円・四角に整形します"

        // ディスプレイ割当・図形補正・ペンの生データは、常時見えて
        // いる必要がない。画面下の帯をまるごと設定ウィンドウへ移してある
        // （openInputSettings が組み立てる）。ここでは中身の設定だけ済ませる。

        let plus = PlusButton(target: self, action: #selector(newPage(_:)))
        canvas.addSubview(plus)
        NSLayoutConstraint.activate([
            plus.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -30),
            plus.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: 30),
        ])

        let left = NSStackView(views: [tools, canvas])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 10
        left.edgeInsets = NSEdgeInsets(top: 22, left: 20, bottom: 18, right: 8)
        left.setHuggingPriority(.defaultLow, for: .horizontal)
        tools.setContentHuggingPriority(.defaultHigh, for: .vertical)
        for row in [tools, canvas] as [NSView] {
            row.widthAnchor.constraint(equalTo: left.widthAnchor, constant: -28).isActive = true
        }
        canvas.setContentHuggingPriority(.defaultLow, for: .vertical)
        canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

        let panel = buildPanel()
        panelView = panel

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

    private func pageButton(_ icon: [String], _ tooltip: String, _ action: Selector) -> BigButton {
        let button = BigButton(title: "", height: 48, fontSize: 20, target: self, action: action)
        button.isSecondary = true
        button.icon = Lucide.image(icon, size: 22, color: .labelColor, strokeWidth: 2)
        button.toolTip = tooltip
        button.widthAnchor.constraint(equalToConstant: 62).isActive = true
        return button
    }

    private func buildToolbar() -> NSView {
        // ペン/消しゴムもアイコンだけにする。文字を読ませるより形で分かるほうが
        // 速く、バーの横幅も空く。名前はツールチップに残す。
        let penIcon = Lucide.image(Lucide.pen, size: 22, color: .labelColor, strokeWidth: 1.8)
        let eraserIcon = Lucide.image(Lucide.eraser, size: 22, color: .labelColor, strokeWidth: 1.8)
        let mode: NSSegmentedControl
        if let penIcon, let eraserIcon {
            mode = NSSegmentedControl(images: [penIcon, eraserIcon], trackingMode: .selectOne,
                                      target: self, action: #selector(modeChanged(_:)))
            mode.setToolTip("ペン", forSegment: 0)
            mode.setToolTip("消しゴム", forSegment: 1)
            mode.setWidth(72, forSegment: 0)
            mode.setWidth(72, forSegment: 1)
        } else {
            // アイコンを描けない環境では、従来どおり文字で出す。
            mode = NSSegmentedControl(labels: ["ペン", "消しゴム"], trackingMode: .selectOne,
                                      target: self, action: #selector(modeChanged(_:)))
        }
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

        // 筆圧カーブは一度決めたら滅多に触らないので、設定ウィンドウへ移した。
        for (title, _) in curves { curvePopup.addItem(withTitle: title) }
        curvePopup.selectItem(at: 1)
        curvePopup.controlSize = .large
        curvePopup.font = NSFont.systemFont(ofSize: 14)
        curvePopup.target = self
        curvePopup.action = #selector(curveChanged(_:))
        curvePopup.toolTip = "筆圧カーブ"
        curvePopup.widthAnchor.constraint(equalToConstant: 220).isActive = true

        // Paging sits with the drawing tools, not off in the side column: it is
        // part of working on the sheet.
        prevPageButton = pageButton(Lucide.chevronLeft, "前のページ（[）", #selector(previousPage(_:)))
        nextPageButton = pageButton(Lucide.chevronRight, "次のページ（]）", #selector(nextPage(_:)))

        pageLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .medium)
        pageLabel.alignment = .center
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [mode, swatchStack, widthDial,
                                      prevPageButton, pageLabel, nextPageButton, spacer])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        return row
    }

    /// 右パネルの操作ボタン。ラベルを外してアイコンだけにし、そのぶん背を高く
    /// してある。ペンで狙う的なので、小さい文字を読ませるより面積を稼ぐほうが
    /// 速い。名前はツールチップに残す。
    private func iconAction(_ icon: [String], _ tooltip: String, _ action: Selector) -> BigButton {
        // 背を高くしたぶん、パネルに入りきらない画面では縮んでもらう。必須の
        // ままだと、ウィンドウを小さくしたときにレイアウトが壊れる。
        let button = BigButton(title: "", height: 118, fontSize: 16, target: self, action: action,
                               heightPriority: .defaultHigh)
        button.isSecondary = true
        // Lucide.image はテンプレート（形だけのマスク）を返し、色は BigButton が
        // 描くたびにその時の外観で解決して塗る。ライト/ダークの切り替えにも追従する。
        button.icon = Lucide.image(icon, size: 40, color: .labelColor, strokeWidth: 1.8)
        button.toolTip = tooltip
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
        grid.spacing = 10
        grid.alignment = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false
        let pairs: [[([String], String, Selector)]] = [
            [(Lucide.undo, "元に戻す（⌘Z）", #selector(undoStroke(_:))),
             (Lucide.redo, "やり直す（⇧⌘Z）", #selector(redoStroke(_:)))],
            [(Lucide.image, "画像を読み込む（⌘O）", #selector(openImage(_:))),
             (Lucide.download, "PNG で書き出す（⌘S）", #selector(exportPNG(_:)))],
            [(Lucide.brushCleaning, "すべて消去（⇧⌘K）", #selector(clearCanvas(_:))),
             (Lucide.trash, "このページを削除", #selector(deletePage(_:)))],
            [(Lucide.sliders, "設定", #selector(openInputSettings(_:)))],
        ]
        var gridRows: [NSStackView] = []
        for pair in pairs {
            let row = NSStackView(views: pair.map { iconAction($0.0, $0.1, $0.2) })
            row.orientation = .horizontal
            row.spacing = 10
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

    /// A session reading the sheet is worth seeing happen — otherwise the board
    /// is silently photographed and nothing on screen says so.
    private func showReading(_ who: String) {
        canvas.readingBy = who
        readingClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.canvas.readingBy = nil }
        readingClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    /// Once the answer is sent, decide what happens to the page it was drawn on.
    /// `false` when a page that was to be thrown away could not be.
    @discardableResult
    private func settleScratchPage(_ how: Retention) -> Bool {
        retention = .keep
        guard let scratch = scratchPageID else { return true }
        let back = returnToPage
        // The page leaves the request here either way, so a request arriving
        // while "残しますか？" is still up starts a page of its own.
        forgetScratchPage()
        switch how {
        case .keep:
            break
        case .temporary:
            return dropScratchPage(scratch, returningTo: back)
        case .ask:
            propose("この下書きページを残しますか？", onNewPage: false,
                    applyTitle: "残す", discardTitle: "破棄") { [weak self] in
                self?.pendingScratchDrop = nil
            }
            // Discarding the proposal is what throws the page away.
            pendingScratchDrop = (scratch, back)
        }
        return true
    }

    /// Stop treating the scratch page as disposable. The page itself stays.
    private func forgetScratchPage() {
        scratchPageID = nil
        returnToPage = nil
        scratchOwner = ""
    }

    /// `false` when the page could not be deleted and was left in place.
    @discardableResult
    private func dropScratchPage(_ scratch: String, returningTo back: Int?) -> Bool {
        // The person may have moved on to another page since; what is on it
        // must not be lost to the reload below.
        savePage()
        let wasOn = pages.currentID
        guard pages.delete(scratch) else {
            // The page is still there, so it stays where the person is and
            // becomes an ordinary page; the caller has already let go of it.
            statusLabel.stringValue = "一時ボードを削除できませんでした（ページは残っています）"
            return false
        }
        if wasOn == scratch {
            openPage(back.map { min($0, pages.count - 1) } ?? pages.current)
        } else if let wasOn, let index = pages.order.firstIndex(of: wasOn) {
            pages.go(to: index)
            refreshPageBar()
        }
        statusLabel.stringValue = "一時ボードを片付けました"
        return true
    }

    /// The band across the top belongs to the board, not to a page: it shows
    /// what is being asked of the person right now, so turning a page or
    /// settling one thing never makes another request vanish. With nothing
    /// pending it is empty: a proposal's line is not kept after 適用, since
    /// nothing would ever take it down again and it would sit over every page.
    private func refreshNotice() {
        if let proposal {
            canvas.notice = proposal.summary
        } else if let waitingLabel {
            canvas.notice = waitingPrompt.isEmpty ? "\(waitingLabel) が手書きを待っています" : waitingPrompt
        } else {
            canvas.notice = nil
        }
    }

    private func clearWaiting() {
        guard waitingLabel != nil else { return }
        waitingLabel = nil
        waitingKey = ""
        waitingPrompt = ""
        waitingUntil = .distantPast
        // The page retention was that request's. Left in place, a later
        // proposal that names none would inherit, say, .temporary, and its page
        // could be thrown away by an unrelated send. 送る reads it before
        // getting here.
        retention = .keep
        refreshNotice()
        // A proposal still up may have borrowed it too; endProposal hands it back.
        if proposal == nil { returnBorrowedPen() }
        applySendState()
        applyPanelVisibility()
    }

    private func currentInkIndex() -> Int {
        swatches.firstIndex(where: { $0.isSelected }) ?? 0
    }

    /// Give the pen back, unless the person has picked something else since —
    /// their own choice always outranks the loan.
    private func returnBorrowedPen() {
        guard let loan = penLoan else { return }
        penLoan = nil
        guard currentInkIndex() == loan.lentInk,
              abs(widthDial.doubleValue - loan.lentWidth) < 0.01 else { return }
        if swatches.indices.contains(loan.restoreInk) { pickColor(swatches[loan.restoreInk]) }
        widthDial.doubleValue = loan.restoreWidth
        applyWidth()
    }

    private func applySendState() {
        spinTimer?.invalidate()
        spinTimer = nil
        sendButton.iconAngle = 0
        switch sendState {
        case .ready:
            // 送るのは、待っているセッションがあるときだけ意味がある。ただし
            // 消してしまうと主役の操作が画面から居なくなり、パネルの上半分が
            // ただの空白になる（操作系が右下へ押し込まれて見える原因）。
            // 場所は残して、押せないことを見た目で示す。
            let waiting = waitingLabel
            sendButton.isHidden = false
            sendButton.isEnabled = waiting != nil
            sendButton.isSecondary = waiting == nil
            sendButton.title = waiting.map { "送る → \($0)" } ?? "送る"
            sendButton.toolTip = waiting == nil
                ? "セッションが request_board で待っている間だけ押せます"
                : "\(waiting!) が待っています"
            sendButton.icon = Lucide.image(Lucide.send, size: 24,
                                           color: waiting == nil ? .tertiaryLabelColor : .white)
            sendButton.fill = .hex(0x0CA678)
        case .sending:
            sendButton.isHidden = false
            sendButton.isEnabled = true
            sendButton.isSecondary = false
            sendButton.title = "送信中"
            sendButton.icon = Lucide.image(Lucide.loaderCircle, size: 24, color: .white, strokeWidth: 2.4)
            sendButton.fill = .hex(0x0CA678)
            let spin = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                self?.sendButton.iconAngle -= .pi / 15
            }
            RunLoop.main.add(spin, forMode: .common)
            spinTimer = spin
        case .sent:
            sendButton.isHidden = false
            sendButton.isEnabled = true
            sendButton.isSecondary = false
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
        let work = DispatchWorkItem { [weak self] in
            self?.saveWork = nil
            self?.savePage()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Write out a save that is still waiting on the debounce — on quit, the
    /// last strokes are otherwise lost with it.
    func flushPendingSave() {
        guard let work = saveWork else { return }
        work.cancel()
        saveWork = nil
        savePage()
    }

    /// The underlay as it was last read from or written to disk. Encoding a
    /// full-size PNG on the main thread is far too slow to repeat on every
    /// stroke, so it is only done when the underlay itself has changed.
    private var storedUnderlay: (page: String, image: CGImage?)?

    private func savePage() {
        guard let id = pages.currentID else { return }
        var page = pages.load(id) ?? PageData(id: id, created: Date(), updated: Date(),
                                              strokes: [], background: nil)
        page.strokes = canvas.storedStrokes
        var failed = false
        let background = canvas.backgroundImage
        let unchanged = storedUnderlay.map { $0.page == id && $0.image === background } ?? false
        if unchanged {
            // Still restate the name, in case the page file it came with could
            // not be read and is being replaced.
            page.background = background == nil ? nil : (page.background ?? "\(id).png")
        } else if let background {
            if let png = NSBitmapImageRep(cgImage: background).representation(using: .png, properties: [:]),
               let name = pages.storeBackground(png, for: id) {
                page.background = name
            } else {
                failed = true
            }
        } else {
            page.background = nil
        }
        if pages.save(page) {
            // Only once the page no longer points at the old underlay file is
            // it safe to drop it, or to stop retrying a write that failed.
            if !unchanged, !failed {
                if background == nil { pages.removeBackground(for: id) }
                storedUnderlay = (id, background)
            }
        } else {
            failed = true
        }
        if failed { statusLabel.stringValue = "ページを保存できませんでした" }
    }

    private func openPage(_ index: Int) {
        saveWork?.cancel()
        saveWork = nil
        pages.go(to: index)
        guard let id = pages.currentID else { return }
        // A page that cannot be read still has to replace what is on the
        // sheet: the sheet now stands for this page, and the next save would
        // otherwise copy the previous page's strokes into it.
        let page = pages.load(id)
        let background = page?.background.flatMap { pages.background(named: $0) }
        canvas.restore(strokes: page?.strokes ?? [], background: background)
        storedUnderlay = (id, canvas.backgroundImage)
        refreshPageBar()
        if page == nil {
            // After the caller's own "ページ N" line, which would hide it.
            let note = "ページ \(pages.current + 1) を読み込めませんでした"
            DispatchQueue.main.async { [weak self] in self?.statusLabel.stringValue = note }
        }
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
        saveWork = nil
        guard pages.delete(id) else {
            // The page stays, so what was drawn on it in the last moment must too.
            savePage()
            statusLabel.stringValue = "ページを削除できませんでした"
            return
        }
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
            if page.strokes.isEmpty && page.background == nil, pages.delete(id) {
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
        case .rightClick: penClick(.right)
        case .middleClick: penClick(.center)
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

        func sectionHeading(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
            return label
        }
        func labelled(_ text: String, _ control: NSView) -> NSStackView {
            let label = NSTextField(labelWithString: text)
            label.font = NSFont.systemFont(ofSize: 15)
            label.widthAnchor.constraint(equalToConstant: 200).isActive = true
            let row = NSStackView(views: [label, control])
            row.orientation = .horizontal
            row.spacing = 16
            row.alignment = .centerY
            return row
        }

        // 画面下にあった帯をここへ集約した。どれも一度決めたら触らないものなので、
        // 描いている間ずっと出しておく理由がない。
        stack.addArrangedSubview(sectionHeading("動作"))
        stack.addArrangedSubview(labelled("ペンの割当先", displayPopup))
        stack.addArrangedSubview(labelled("筆圧カーブ", curvePopup))
        stack.addArrangedSubview(shapeBox)
        stack.addArrangedSubview(labelled("ペンの生データ", telemetry))

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 416).isActive = true
        stack.addArrangedSubview(divider)

        let heading = sectionHeading("ボタン割り当て")
        stack.addArrangedSubview(heading)

        let hint = NSTextField(labelWithString:
            "本体キーは一度押すと一覧に出ます。5つとも押してから下のボタンで色に割り当てられます。\n"
            + "「そのまま通す」は元のキーをそのまま送ります。本体スライダーは常に線の太さです。")
        hint.font = NSFont.systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)

        for (id, title) in rows {
            let popup = NSPopUpButton()
            popup.controlSize = .large
            popup.font = NSFont.systemFont(ofSize: 14)
            for action in BoardAction.allCases { popup.addItem(withTitle: action.label) }
            popup.selectItem(at: BoardAction.allCases.firstIndex(of: inputs.action(for: id)) ?? 0)
            popup.target = self
            popup.action = #selector(assignmentChanged(_:))
            popup.identifier = NSUserInterfaceItemIdentifier(id)
            popup.widthAnchor.constraint(equalToConstant: 200).isActive = true
            stack.addArrangedSubview(labelled(title, popup))
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

        // The mouse is walled off the pen display, and a pop-up's menu runs its
        // own tracking loop that the pen's posted clicks are not known to reach.
        // A sheet on the board could leave a menu open that nothing can close,
        // so the settings go on a display the mouse can reach whenever there is one.
        let elsewhere = NSScreen.screens.first { $0 != penScreen && $0 == NSScreen.main }
            ?? NSScreen.screens.first { $0 != penScreen }
        guard penScreen != nil, let elsewhere else {
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            sheet.contentView = content
            settingsSheet = sheet
            host.beginSheet(sheet)
            return
        }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "設定"
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.layoutIfNeeded()
        let visible = elsewhere.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                     y: max(visible.minY, visible.midY - panel.frame.height / 2)))
        settingsSheet = panel
        settingsCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            self?.forgetSettingsWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
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
        if sheet.sheetParent != nil {
            window?.endSheet(sheet)
            settingsSheet = nil
        } else {
            // Cleared here rather than in willClose: a reopen queued right after
            // this would otherwise find the old window still recorded and give up.
            forgetSettingsWindow()
            sheet.close()
        }
    }

    private func forgetSettingsWindow() {
        if let observer = settingsCloseObserver { NotificationCenter.default.removeObserver(observer) }
        settingsCloseObserver = nil
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
        if present != isPresent {
            isPresent = present
            if present { comeForward() } else { standDown() }
            onPresenceChange?(present)
        }
        // Also on every periodic check: the barrier picks up an Accessibility
        // grant this way, and follows the tablet's HID coming and going.
        updatePenOwnership()
    }

    /// The pen display is the board's alone. While there is a tablet and a
    /// display to map it onto, the device is seized, so macOS never moves the
    /// cursor from the pen, and the mouse is walled off that display. Without
    /// a display the pen has nowhere to go but the OS's own handling, so both
    /// are let go and the cursor follows the pen as it would with no app.
    private func updatePenOwnership() {
        // A display reconfiguring (wake, a resolution change) can drop out
        // for a moment. Every change of seize reopens the device, so the seize
        // is only given up once the display has stayed gone for a beat; the
        // periodic presence check comes back to it.
        let displayGone = penScreen == nil
            && ProcessInfo.processInfo.systemUptime - (penScreenLostAt ?? 0) >= 1.5
        if isPresent, penScreen != nil, !hid.isSeizing, !seizeRefused {
            if !hid.setSeizing(true) {
                seizeRefused = true
                statusLabel.stringValue = "タブレットを排他確保できませんでした — macOS がペンでカーソルを動かします"
            }
        } else if !isPresent || displayGone, hid.isSeizing {
            hid.setSeizing(false)
        }

        // While macOS reads the pen itself (the seize refused, or the HID not
        // ours to read), its cursor is the pen's, and walling the display off
        // would throw the pen's own cursor back out. `isPresent` covers the
        // moment a refused seize is still reattaching unseized. Unplugged,
        // there is no pen to collide with, and the display stays the board's.
        let osDrivesPen = (hid.isConnected || isPresent) && !hid.isSeizing
        barrier.update(blocking: osDrivesPen ? nil : penScreen?.displayID)
        if barrier.state != lastBarrierState {
            let previous = lastBarrierState
            lastBarrierState = barrier.state
            // A barrier that simply works is reported in the menu bar; the
            // board only hears about one that needs something, and about that
            // being resolved, so a stale complaint does not linger there.
            switch barrier.state {
            case .off: break
            case .active:
                if previous != .off { statusLabel.stringValue = barrier.summary }
            case .needsAccessibility, .unavailable:
                statusLabel.stringValue = barrier.summary
            }
        }
    }

    /// One line each for the menu bar, where it can be read even with the
    /// board away (and with the mouse unable to reach the pen display).
    var ownershipSummary: [String] {
        let pen: String
        if !hid.isConnected {
            pen = "ペン 未接続"
        } else if hid.isSeizing {
            pen = "ペン ボード専用（\(penScreen?.localizedName ?? "")）"
        } else if penScreen == nil {
            pen = "ペン 割当先ディスプレイなし（macOS がカーソルを動かします）"
        } else if isPresent {
            pen = "ペン 排他確保できず（macOS がカーソルを動かします）"
        } else {
            pen = "ペン HID を読めません（macOS がカーソルを動かします）"
        }
        return [pen, barrier.summary]
    }

    var barrierNeedsAccessibility: Bool { barrier.state == .needsAccessibility }

    func comeForward() {
        rebuildDisplayChoices()
        if isChangingFullScreen {
            // Typically a re-plug while the unplug's exit animation is still
            // running: `isFullScreen` is still true, so carrying on would skip
            // re-entering and leave the board windowed. Come back once it lands.
            afterFullScreenChange = .show
            return
        }
        afterFullScreenChange = .nothing
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
            guard let self, !self.isFullScreen, !self.isChangingFullScreen,
                  self.window?.isVisible == true else { return }
            self.startFullScreenToggle()
        }
    }

    func standDown() {
        releaseControlPress()
        seizeRefused = false
        hid.setSeizing(false)
        releaseHeldInputs()
        canvas.ignoresMouse = false
        hideBoard(nil)
    }

    // MARK: - Settings

    private enum Key {
        static let curve = "curveIndex"
        static let width = "baseWidth"
    }

    private func saveSettings() {
        let d = UserDefaults.standard
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
        setCleanMode(d.bool(forKey: "cleanMode"))
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

            if self.canvas.laserMode {
                // Same trigger as drawing: the spot appears where the nib
                // touches, and the tail fades once it lifts.
                self.canvas.updateLaser(paper: s.tip ? self.canvasPaperPoint(for: s) : nil)
            }

            let now = (s.button1, s.button2, s.button3)
            if now.0 != self.previousPenButtons.0 { self.penButton(1, "pen.button1", down: now.0) }
            if now.1 != self.previousPenButtons.1 { self.penButton(2, "pen.button2", down: now.1) }
            if now.2 != self.previousPenButtons.2 { self.penButton(3, "pen.button3", down: now.2) }
            self.previousPenButtons = now
            self.drivePen(with: s)

            let buttons = [s.tip ? "先" : "・", s.button1 ? "1" : "・",
                           s.button2 ? "2" : "・", s.button3 ? "3" : "・"].joined()
            let target = self.penScreen == nil ? "OS任せ" : (self.hid.isSeizing ? "ボード専用" : "絶対座標")
            self.telemetry.stringValue = String(
                format: "%@ · %@  筆圧 %5d/16383 (%3.0f%%)  ボタン %@",
                s.mode.rawValue, target, s.rawPressure, s.pressure * 100, buttons)
        }

        hid.onKeys = { [weak self] modifiers, down in
            guard let self else { return }
            for usage in down.subtracting(self.pressedKeys) {
                self.inputs.remember(usage: usage)
                let id = String(format: "key.%02x", usage)
                let action = self.inputs.action(for: id)
                self.lastInputNote = "key.\(String(format: "%02x", usage))→\(action.rawValue)"
                if action == .passthrough {
                    // Unseized, macOS already delivers the key itself; posting
                    // it as well would type it twice.
                    if self.hid.isSeizing {
                        self.inputs.passThrough(usage: usage, modifiers: modifiers, down: true)
                        self.postedKeys.insert(usage)
                    }
                } else {
                    self.run(action, down: true)
                }
            }
            for usage in self.pressedKeys.subtracting(down) {
                self.keyReleased(usage, modifiers: modifiers)
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
            self.refreshVisibleWidgets()
            if self.waitingLabel != nil, Date() > self.waitingUntil { self.clearWaiting() }
            guard Date().timeIntervalSince(self.lastSampleAt) > 2.5 else { return }
            if self.canvas.ignoresMouse {
                self.canvas.ignoresMouse = false
                self.canvas.finishStroke()
                self.penIsDown = false
            }
            // The feed stopped mid-tap; the control must still get its mouse-up.
            self.releaseControlPress()
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
                "排他=\(self.hid.isSeizing ? "確保" : (self.seizeRefused ? "失敗" : "なし"))",
                "マウス制限=\(self.barrier.summary)",
                "アクセシビリティ=\(AXIsProcessTrusted() ? "許可" : "未許可")",
                "前面=\(self.isPresent ? "表示" : "常駐")",
                "待機=\(self.waitingLabel ?? "なし")",
                "最後の入力=\(self.lastInputNote)",
                "覚えたキー=\(self.inputs.seenKeys.map { String(format: "%02x", $0) }.joined(separator: ","))",
            ].joined(separator: "  ")
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".hitsudan", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? line.write(to: dir.appendingPathComponent("hid-status.log"),
                            atomically: true, encoding: .utf8)
            self.bridge.publish(state: [
                "waitingFor": self.waitingLabel ?? "",
                "waitingKey": self.waitingKey,
                "proposalID": self.lastProposalID,
                "proposalOutcome": self.lastProposalOutcome,
                "tabletPresent": self.isPresent,
                "strokes": self.canvas.strokeCount,
                "hasBackground": self.canvas.backgroundImage != nil,
                "penSeized": self.hid.isSeizing,
                "mouseBarrier": self.barrier.summary,
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
            guard bridge.publish(png: png, note: "capture", bump: false) else {
                return ["ok": false, "error": "ボードの画像を保存できませんでした（~/.hitsudan に書き込めません）"]
            }
            showReading((args["label"] as? String) ?? waitingLabel ?? "Claude")
            return ["ok": true]

        case "clear":
            let owner = (args["key"] as? String) ?? ""
            let id = propose("セッションがボードの消去を求めています", onNewPage: false,
                             owner: owner, notify: !owner.isEmpty) { [weak self] in
                self?.canvas.clearAll()
            }
            return ["ok": true, "pending": true, "proposalID": id, "tabletPresent": isPresent]

        case "focus":
            // Only onto a tablet. Without one this would throw a full-screen
            // board over whatever the person is doing on the main display.
            if isPresent { comeForward() }
            return ["ok": true, "tabletPresent": isPresent]

        case "wait":
            let key = (args["key"] as? String) ?? ""
            let label = (args["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "セッション"
            // One request at a time. The same session re-posting (wait_for_board
            // is re-called about once a minute) refreshes its own; anyone else is
            // turned away instead of silently replacing it, so 送る can never go
            // to someone other than the session whose prompt is showing. Servers
            // without a key are told apart by label, as before.
            let again = waitingLabel != nil && waitingKey == key && (!key.isEmpty || waitingLabel == label)
            if let current = waitingLabel, !again {
                return ["ok": false, "busy": true,
                        "error": "ボードには \(current) の依頼が出ています。そちらが回収されるか期限が切れてから、もう一度依頼してください。"]
            }
            // A re-post may change what happens to the page, so it is applied
            // every time, as before.
            retention = Retention(rawValue: (args["retain"] as? String) ?? "") ?? .keep
            // A scratch page is reused only by the session it was made for, and
            // only while it is the page in front of the person; otherwise a send
            // could delete a page the answer was never drawn on. A re-post of
            // the request it was made for keeps it even if the page was turned.
            if !again, scratchPageID != nil, scratchOwner != key || scratchPageID != pages.currentID {
                forgetScratchPage()
            }
            if retention != .keep, scratchPageID == nil {
                // Answer on a page of its own, so a throwaway reply never lands
                // in the middle of whatever the notebook was being used for.
                savePage()
                returnToPage = pages.current
                pages.appendPage()
                openPage(pages.count - 1)
                scratchPageID = pages.currentID
                scratchOwner = key
            }
            waitingLabel = label
            waitingKey = key
            waitingPrompt = (args["prompt"] as? String) ?? ""
            // Each poll refreshes the lease, so a session that gives up quietly
            // stops being announced instead of waiting for ever.
            waitingUntil = Date().addingTimeInterval((args["lease"] as? Double) ?? 150)
            refreshNotice()
            applyPanelVisibility()
            // Brought forward once per request, not on every re-post — that
            // would steal focus once a minute. With no tablet the request just
            // waits; presence brings the board up when one is plugged in.
            if !again, isPresent { comeForward() }
            applySendState()
            return ["ok": true, "tabletPresent": isPresent]

        case "wait_end":
            // Only the session whose request is up may take it down: one
            // session collecting must never clear another's pending request.
            if waitingKey == ((args["key"] as? String) ?? "") { clearWaiting() }
            return ["ok": true]

        case "show":
            let owner = (args["key"] as? String) ?? ""
            // Every session proposal files its outcome, so the session can learn
            // it later (board_status) even if it did not wait for it.
            let notify = !owner.isEmpty
            let keepAs = Retention(rawValue: (args["retain"] as? String) ?? "")
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
                let id = propose(note ?? "セッションがテキストを送ってきました",
                                 owner: owner, notify: notify, retain: keepAs) { [weak self] in
                    guard let self else { return }
                    if clearInk { self.canvas.clearInkOnly() }
                    self.canvas.setBackgroundText(text)
                }
                return ["ok": true, "pending": true, "proposalID": id, "tabletPresent": isPresent]
            } else {
                return ["ok": false, "error": "svg / image_path / text のいずれかが必要です"]
            }
            guard let underlay else { return ["ok": false, "error": "描画に失敗しました"] }
            let clearInk = args["clear_ink"] as? Bool == true
            let note = args["notice"] as? String
            let id = propose(note ?? "セッションが下敷きを送ってきました", preview: underlay,
                             owner: owner, notify: notify, retain: keepAs) { [weak self] in
                guard let self else { return }
                if clearInk { self.canvas.clearInkOnly() }
                self.canvas.setBackground(underlay)
            }
            return ["ok": true, "pending": true, "proposalID": id, "tabletPresent": isPresent]

        case "set_pen":
            // Only while something has actually been asked of the person. The
            // pen belongs to whoever is drawing with it the rest of the time.
            guard waitingLabel != nil || proposal != nil else {
                return ["ok": false,
                        "error": "依頼中のときだけ変更できます。show_on_board か wait_for_board と一緒に呼んでください"]
            }
            if penLoan == nil {
                penLoan = (currentInkIndex(), widthDial.doubleValue, currentInkIndex(), widthDial.doubleValue)
            }
            if let name = (args["color"] as? String)?.lowercased() {
                let index: Int?
                switch name {
                case "black", "ink", "墨", "黒": index = 0
                case "red", "朱", "赤": index = 1
                case "blue", "青": index = 2
                case "green", "緑": index = 3
                case "laser", "レーザー": index = 4
                default: index = nil
                }
                guard let index, swatches.indices.contains(index) else {
                    return ["ok": false, "error": "色は black / red / blue / green / laser のいずれかです"]
                }
                pickColor(swatches[index])
            }
            if let width = args["width"] as? Double, width > 0 {
                widthDial.doubleValue = width
                applyWidth()
            }
            if let eraser = args["eraser"] as? Bool {
                canvas.eraserSelected = eraser
                modeControl?.selectedSegment = eraser ? 1 : 0
            }
            penLoan?.lentInk = currentInkIndex()
            penLoan?.lentWidth = widthDial.doubleValue
            return ["ok": true, "width": widthDial.doubleValue]

        case "status":
            return [
                "ok": true,
                "waitingFor": waitingLabel ?? "",
                "waitingKey": waitingKey,
                "proposalID": lastProposalID,
                "proposalOutcome": lastProposalOutcome,
                "pendingProposal": proposal != nil,
                "tabletPresent": isPresent,
                "strokes": canvas.strokeCount,
                "hasBackground": canvas.backgroundImage != nil,
                "penSeized": hid.isSeizing,
                "mouseBarrier": barrier.summary,
            ]

        default:
            return ["ok": false, "error": "unknown op: \(op)"]
        }
    }

    /// A session never overwrites the sheet on its own: it offers, and the
    /// person decides with a button big enough to hit with a pen.
    @discardableResult
    private func propose(_ summary: String, onNewPage: Bool = true, preview: CGImage? = nil,
                         owner: String = "", notify: Bool = false, retain: Retention? = nil,
                         applyTitle: String = "適用", discardTitle: String = "破棄",
                         _ apply: @escaping () -> Void) -> String {
        // Never replace a question silently. Whoever asked the old one hears it
        // was withdrawn, and an unanswered "残しますか？" leaves its page alone:
        // deleting a page takes an explicit 破棄 on that very question.
        if let old = proposal {
            if old.notify { bridge.publishOutcome(proposal: old.id, outcome: "superseded") }
            pendingScratchDrop = nil
        }
        let id = UUID().uuidString
        proposal = Proposal(id: id, summary: summary, applyTitle: applyTitle,
                            discardTitle: discardTitle, onNewPage: onNewPage, preview: preview,
                            owner: owner, notify: notify, retain: retain, apply: apply)
        applyButton.title = applyTitle
        discardButton.title = discardTitle
        lastProposalID = id
        lastProposalOutcome = "pending"
        proposalLabel.stringValue = summary
        for v in [proposalLabel, applyButton, discardButton] as [NSView] { v.isHidden = false }
        canvas.preview = preview
        refreshNotice()
        applyPanelVisibility()
        // As with requests: brought forward only where there is a tablet.
        if isPresent { comeForward() }
        return id
    }

    private func endProposal() {
        proposal = nil
        if waitingLabel == nil { returnBorrowedPen() }
        canvas.preview = nil
        for v in [proposalLabel, applyButton, discardButton] as [NSView] { v.isHidden = true }
        refreshNotice()
        applyPanelVisibility()
    }

    @objc private func applyProposal(_ sender: Any?) {
        guard let proposal else { return }
        canvas.preview = nil
        // What becomes of the new page. It becomes the pending answer's
        // retention only while this session's own request is up: another
        // session's request has its own, and with none up there is no answer
        // for it to govern — kept, it would only leak into a later proposal.
        let keepAs = proposal.retain ?? retention
        if waitingLabel != nil, waitingKey == proposal.owner { retention = keepAs }
        if proposal.onNewPage {
            savePage()
            let from = pages.current
            pages.appendPage()
            openPage(pages.count - 1)
            if keepAs != .keep, scratchPageID == nil { returnToPage = from }
        }
        proposal.apply()
        if proposal.onNewPage, keepAs != .keep, scratchPageID == nil {
            scratchPageID = pages.currentID
            scratchOwner = proposal.owner
        }
        lastProposalOutcome = "applied"
        let filed = !proposal.notify || bridge.publishOutcome(proposal: proposal.id, outcome: "applied")
        endProposal()
        statusLabel.stringValue = (proposal.onNewPage
            ? "新しいページ \(pages.current + 1) に適用しました" : "適用しました")
            + (filed ? "" : "（結果をセッションに伝えられませんでした）")
    }

    @objc private func discardProposal(_ sender: Any?) {
        guard let proposal else { return }
        lastProposalOutcome = "rejected"
        let filed = !proposal.notify || bridge.publishOutcome(proposal: proposal.id, outcome: "rejected")
        // Set only while the "残しますか？" question is the proposal on screen.
        let drop = pendingScratchDrop
        pendingScratchDrop = nil
        endProposal()
        if let drop {
            dropScratchPage(drop.id, returningTo: drop.back)
            if !filed { statusLabel.stringValue += "（結果をセッションに伝えられませんでした）" }
            return
        }
        statusLabel.stringValue = filed ? "破棄しました" : "破棄しました（結果をセッションに伝えられませんでした）"
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
    @objc func clearCanvas(_ sender: Any?) {
        let hadContent = !canvas.isEmpty
        canvas.clearAll()
        if hadContent { statusLabel.stringValue = "すべて消去しました（⌘Z で元に戻せます）" }
    }

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
        guard let recipient = waitingLabel else {
            statusLabel.stringValue = "待っているセッションがありません"
            return
        }
        guard !canvas.isEmpty else {
            statusLabel.stringValue = "キャンバスが空です"
            return
        }
        // Who it goes to is decided by what the person saw when they pressed
        // 送る. Commands are drained between here and the hop below, so the
        // waiting state may have changed by then (lease ran out, another
        // session's request went up).
        let key = waitingKey
        let howToKeep = retention
        let sentFrom = pages.currentID
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
                self.refreshNotice()
                return
            }
            // Addressed to that session and kept until it collects — a
            // read_board in between cannot overwrite it. Even if its lease ran
            // out during the hop, its collect_board looks for a reply first.
            guard self.bridge.publishReply(png: png, key: key, label: recipient) else {
                // Nothing reached the session, so the request, its page and
                // the button stay as they were for another try.
                self.sendState = .ready
                self.statusLabel.stringValue = "送信できませんでした（~/.hitsudan に書き込めません）"
                self.refreshNotice()
                return
            }
            if self.waitingLabel != nil, self.waitingKey == key { self.clearWaiting() }
            // Only the page the answer was drawn on is the request's to throw
            // away or ask about; a scratch page the person moved off is kept.
            var scratchKept = false
            if self.scratchPageID != nil, self.scratchPageID == sentFrom {
                scratchKept = !self.settleScratchPage(howToKeep)
            } else if self.scratchOwner == key {
                self.forgetScratchPage()
                self.retention = .keep
            }
            self.refreshNotice()
            // Also on the clipboard, for a session with no MCP server.
            let pb = NSPasteboard.general
            pb.clearContents()
            if let image = NSImage(data: png) { pb.writeObjects([image]) }

            // Hold the spinner long enough to be read as a state, not a flicker.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.sendState = .sent
                // The status line is overwritten here, so a page that could
                // not be thrown away has to be said again or it goes unnoticed.
                self.statusLabel.stringValue = "\(recipient) へ送信しました"
                    + (scratchKept ? "（一時ボードは削除できず残っています）" : "")
            }
        }
    }

    // MARK: - Absolute pen mapping

    private func rebuildDisplayChoices() {
        displayPopup.removeAllItems()
        screenChoices = []
        displayPopup.addItem(withTitle: "ペン割当: 自動")
        screenChoices.append(("auto", nil))
        for screen in NSScreen.screens {
            displayPopup.addItem(withTitle: "ペン割当: \(screen.localizedName)")
            screenChoices.append((Self.displayIdentity(screen), screen))
        }
        // A chosen display that is unplugged stays chosen, so the pen goes
        // back to it when it returns instead of to whatever took its place.
        if penDisplayChoice != "auto",
           !screenChoices.contains(where: { $0.id == penDisplayChoice }) {
            let name = UserDefaults.standard.string(forKey: "penDisplayName") ?? "ディスプレイ"
            displayPopup.addItem(withTitle: "ペン割当: \(name)（未接続）")
            screenChoices.append((penDisplayChoice, nil))
        }
        displayPopup.selectItem(at: screenChoices.firstIndex { $0.id == penDisplayChoice } ?? 0)
        resolvePenScreen()
    }

    /// Stable across replugging and rearranging: the display's UUID, or its
    /// name where the system has no UUID to give.
    private static func displayIdentity(_ screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
           let text = CFUUIDCreateString(nil, uuid) {
            return text as String
        }
        return "name:\(screen.localizedName)"
    }

    private func detectTabletScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            let name = screen.localizedName.lowercased()
            return name.contains("kamvas") || name.contains("huion") || name.contains("gs1333")
        }
    }

    private func resolvePenScreen() {
        switch penDisplayChoice {
        case "auto":
            penScreen = detectTabletScreen()
            displayPopup.item(at: 0)?.title = penScreen.map { "ペン割当: 自動（\($0.localizedName)）" }
                ?? "ペン割当: 自動（未検出）"
        default:
            penScreen = screenChoices.first { $0.id == penDisplayChoice }?.screen
        }
        if penScreen == nil {
            if penScreenLostAt == nil { penScreenLostAt = ProcessInfo.processInfo.systemUptime }
            lastPenPoint = nil
            if canvas.ignoresMouse {
                canvas.ignoresMouse = false
                canvas.finishStroke()
                penIsDown = false
            }
            // drivePen no longer runs without a display; nothing else would
            // ever release a control pressed when it went.
            releaseControlPress()
        } else {
            penScreenLostAt = nil
        }
        updatePenOwnership()
    }

    @objc private func displayChoiceChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard screenChoices.indices.contains(index) else { return }
        penDisplayChoice = screenChoices[index].id
        UserDefaults.standard.set(penDisplayChoice, forKey: "penDisplay")
        if let screen = screenChoices[index].screen {
            UserDefaults.standard.set(screen.localizedName, forKey: "penDisplayName")
        }
        // A deliberate choice is worth another try at the seize.
        seizeRefused = false
        resolvePenScreen()
    }

    @objc private func shapeSnapToggled(_ sender: NSButton) {
        canvas.snapsShapes = sender.state == .on
        UserDefaults.standard.set(canvas.snapsShapes, forKey: "shapeSnap")
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
        // Strokes come from the raw feed, never from mouse events: macOS
        // coalesces dragged events, so a 200 Hz pen would arrive as a few
        // dozen scattered points. Drawing from the samples keeps every one.
        guard let screen = penScreen, let window = self.window else { return }
        let frame = screen.frame
        let screenPoint = CGPoint(x: frame.minX + s.x * frame.width,
                                  y: frame.maxY - s.y * frame.height)
        // Out of range there is nowhere the pen points; a right-click from a
        // key must not land wherever the pen happened to leave.
        lastPenPoint = s.inRange ? screenPoint : nil

        if let press = controlPress {
            if s.tip {
                controlPress = (press.window, screenPoint)
                postMouse(.leftMouseDragged, at: screenPoint, to: press.window)
            } else {
                releaseControlPress()
                penIsDown = false
            }
            return
        }

        // The samples arrive whether or not the board can be seen. A hidden
        // board, or one under a sheet or an alert, must not take ink — the pen
        // is busy with something else, and the stroke would be saved and sent.
        let boardIsUsable = window.isVisible && window.attachedSheet == nil && NSApp.modalWindow == nil
        guard boardIsUsable else {
            if penIsDown { canvas.finishStroke() }
            // The sheet or alert in front is ours too, and only the pen can
            // reach it on this display.
            let pressed = s.tip && !penIsDown
            // A press still held when the board comes back belongs to whatever
            // it started on; it must not turn into a stroke halfway through.
            penIsDown = s.tip
            if pressed { pressControl(at: screenPoint) }
            return
        }
        canvas.ignoresMouse = true
        let viewPoint = canvas.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        let width = canvas.width(forPressure: CGFloat(s.pressure))
        switch (s.tip, penIsDown) {
        case (true, false):
            // Down either way, so a press that lands elsewhere stays elsewhere
            // even if it is dragged onto the board.
            penIsDown = true
            // Only a stroke that starts where the board is the frontmost window
            // — not on another app's window lying over it, or on another Space.
            guard NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
                    == window.windowNumber else {
                pressControl(at: screenPoint)
                return
            }
            if isOnPaper(viewPoint, in: window) {
                canvas.beginStroke(at: viewPoint, width: width, eraser: s.eraser)
            } else {
                pressControl(at: screenPoint)
            }
        case (true, true):
            canvas.extendStroke(to: viewPoint, width: width)
        case (false, true):
            canvas.finishStroke()
            penIsDown = false
        case (false, false):
            break
        }
    }

    /// The sheet takes ink everywhere except under the canvas's own control
    /// (the + button), which sits over its corner. Anything else lying over the
    /// paper (the page-turn animation) is not a control and does not stop ink.
    private func isOnPaper(_ viewPoint: CGPoint, in window: NSWindow) -> Bool {
        guard canvas.paperRect.contains(viewPoint) else { return false }
        guard let content = window.contentView else { return true }
        let inWindow = canvas.convert(viewPoint, to: nil)
        let hit = content.hitTest(content.superview?.convert(inWindow, from: nil) ?? inWindow)
        if let hit, hit !== canvas, hit.isDescendant(of: canvas) { return false }
        return true
    }

    /// A tap that is not ink goes to the control under the nib as an ordinary
    /// click — posted to our own window, so the system cursor never moves and
    /// nothing outside this app ever receives it.
    ///
    /// Posted to the queue, not handed to `sendEvent`: a button runs its own
    /// tracking loop on mouse-down and waits there for the drag and the
    /// mouse-up, which it only ever takes from the queue. The HID keeps
    /// reporting inside that loop (common modes), so they get there.
    private func pressControl(at screenPoint: CGPoint) {
        // Unseized, macOS turns this same press into a real click already;
        // another one here would press every button twice.
        guard hid.isSeizing else { return }
        let number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        // Someone else's window on the pen display is not ours to click.
        guard let target = NSApp.window(withWindowNumber: number), target.isVisible else { return }
        // Only what is in front takes a click: the modal itself, or the sheet
        // rather than the board it hangs from.
        if let modal = NSApp.modalWindow, target !== modal { return }
        if target.attachedSheet != nil { return }
        // A real click activates the app on its way in; a posted one does not,
        // and an inactive window spends its first click becoming key.
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if target.canBecomeKey, !target.isKeyWindow { target.makeKey() }
        controlPressNumber += 1
        controlPress = (target, screenPoint)
        postMouse(.leftMouseDown, at: screenPoint, to: target)
    }

    private func postMouse(_ type: NSEvent.EventType, at screenPoint: CGPoint, to target: NSWindow) {
        let pressed = type != .leftMouseUp && type != .rightMouseUp && type != .otherMouseUp
        guard let event = NSEvent.mouseEvent(
            with: type, location: target.convertPoint(fromScreen: screenPoint),
            modifierFlags: NSEvent.modifierFlags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: target.windowNumber, context: nil, eventNumber: controlPressNumber,
            clickCount: 1, pressure: pressed ? 1 : 0) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// Every posted mouse-down gets its mouse-up, even when the pen never
    /// lifts properly: the feed stops, the display goes, the tablet is pulled.
    /// A button left tracking would hold the app in its loop.
    private func releaseControlPress() {
        guard let press = controlPress else { return }
        controlPress = nil
        postMouse(.leftMouseUp, at: press.at, to: press.window)
    }

    /// The pen's other buttons, assigned to a right or middle click. With the
    /// device seized they click the board where the pen is, like the tip does;
    /// the system cursor is elsewhere and not the pen's. Unseized, the cursor
    /// is the pen's, and the click goes where it is, as it always did.
    private func penClick(_ button: CGMouseButton) {
        guard hid.isSeizing else { inputs.click(button); return }
        guard let point = lastPenPoint else { return }
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard let target = NSApp.window(withWindowNumber: number), target.isVisible,
              NSApp.modalWindow == nil || NSApp.modalWindow === target,
              target.attachedSheet == nil else { return }
        let types: [NSEvent.EventType] = button == .right ? [.rightMouseDown, .rightMouseUp]
                                                          : [.otherMouseDown, .otherMouseUp]
        controlPressNumber += 1
        for type in types { postMouse(type, at: point, to: target) }
    }

    /// A key let go: exactly one key-up for a key we posted, whatever the
    /// seize is now, and the release of a held action.
    private func keyReleased(_ usage: UInt8, modifiers: UInt8) {
        if postedKeys.remove(usage) != nil {
            inputs.passThrough(usage: usage, modifiers: modifiers, down: false)
        }
        let action = inputs.action(for: String(format: "key.%02x", usage))
        if action.isMomentary { run(action, down: false) }
    }

    /// The device can go away mid-press, and nothing will ever report those
    /// keys and buttons released: a passed-through key would stay down in the
    /// system, a held eraser would never let go, and the same key's first
    /// press after reconnecting would be swallowed as already down.
    private func releaseHeldInputs() {
        for usage in pressedKeys { keyReleased(usage, modifiers: 0) }
        pressedKeys = []
        postedKeys = []
        let held = previousPenButtons
        previousPenButtons = (false, false, false)
        if held.0 { penButton(1, "pen.button1", down: false) }
        if held.1 { penButton(2, "pen.button2", down: false) }
        if held.2 { penButton(3, "pen.button3", down: false) }
        if previousStripButton {
            previousStripButton = false
            run(inputs.action(for: "slider.button"), down: false)
        }
    }

    // MARK: - Menu bar access

    func releaseTablet() {
        releaseControlPress()
        hid.setSeizing(false)
    }
}
