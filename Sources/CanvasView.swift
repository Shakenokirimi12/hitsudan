import AppKit

/// The paper. Position comes from the OS cursor (correct on a display tablet
/// whatever the screen mapping); pressure, tilt and pen buttons come from
/// `TabletHID` when it is listening, and fall back to NSEvent tablet data.
final class CanvasView: NSView {

    struct Point { var p: CGPoint; var w: CGFloat }
    struct Stroke { var color: NSColor; var erase: Bool; var points: [Point] }

    static let paperSize = CGSize(width: 1600, height: 1000)
    private let bitmapScale: CGFloat = 2

    var inkColor: NSColor = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.11, alpha: 1)
    var baseWidth: CGFloat = 7
    /// Gamma on pressure. A raw sensor is very non-linear at the light end —
    /// this is the curve the vendor driver used to apply for us.
    var pressureCurve: CGFloat = 0.65
    /// A hair-thin line is never what anyone wants, so pressure scales the
    /// width down to this fraction and no further.
    var minWidthFactor: CGFloat = 0.28
    var eraserSelected = false
    var pressureSource: (() -> (pressure: Double, eraser: Bool)?)?
    var onChange: (() -> Void)?
    /// Set while strokes are driven by absolute tablet coordinates, so the OS
    /// cursor does not draw a second, wrong stroke alongside the pen.
    var ignoresMouse = false
    /// Draw a shape, then hold still without lifting: the stroke snaps to the
    /// clean version of what you drew, and stays adjustable until you lift.
    var snapsShapes = true
    var onSnap: ((String) -> Void)?

    /// Laser mode: the pen leaves no ink, only a red spot with a short trail —
    /// for pointing at something on screen rather than marking it.
    var laserMode = false {
        didSet {
            if !laserMode { laserTrail.removeAll(); needsDisplay = true }
            else { startLaserFade() }
        }
    }
    private var laserTrail: [(point: CGPoint, at: Date)] = []
    private var laserTimer: Timer?

    /// A line from the session, shown across the top of the sheet.
    var notice: String? { didSet { needsDisplay = true } }
    /// Something a session wants to put on the sheet, shown faintly until the
    /// person accepts it. Never applied on its own.
    var preview: CGImage? { didSet { needsDisplay = true } }

    private(set) var strokes: [Stroke] = []
    private var redoStack: [Stroke] = []
    private var live: Stroke?
    private var burned = 0                    // points of `live` already in the bitmap

    private enum ShapeKind { case line, ellipse, rectangle }
    private var strokeStart: CGPoint?
    /// The corner (or end) the snapped shape is pinned to while it is adjusted.
    private var snapAnchor: CGPoint?
    private var lastMovement = Date()
    private var holdTimer: Timer?
    private var snapped: ShapeKind?

    private var ink: CGContext!
    private var inkImage: CGImage?
    private(set) var backgroundImage: CGImage?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) { super.init(frame: frame); commonInit() }
    required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }

    private func commonInit() {
        let w = Int(Self.paperSize.width * bitmapScale)
        let h = Int(Self.paperSize.height * bitmapScale)
        ink = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ink.scaleBy(x: bitmapScale, y: bitmapScale)
        ink.setLineCap(.round)
        ink.setLineJoin(.round)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    // MARK: - Geometry

    /// Where the sheet sits inside the view, aspect-preserved.
    var paperRect: NSRect {
        let avail = bounds.insetBy(dx: 18, dy: 18)
        guard avail.width > 0, avail.height > 0 else { return bounds }
        let ratio = Self.paperSize.width / Self.paperSize.height
        var w = avail.width, h = avail.width / ratio
        if h > avail.height { h = avail.height; w = h * ratio }
        return NSRect(x: (avail.midX - w / 2).rounded(), y: (avail.midY - h / 2).rounded(),
                      width: w.rounded(), height: h.rounded())
    }

    private var paperScale: CGFloat { paperRect.width / Self.paperSize.width }

    func paperPoint(from viewPoint: CGPoint) -> CGPoint { toPaper(viewPoint) }

    private func toPaper(_ viewPoint: CGPoint) -> CGPoint {
        let r = paperRect, k = paperScale
        return CGPoint(x: (viewPoint.x - r.minX) / k, y: (viewPoint.y - r.minY) / k)
    }

    private func toView(_ paperPoint: CGPoint) -> CGPoint {
        let r = paperRect, k = paperScale
        return CGPoint(x: r.minX + paperPoint.x * k, y: r.minY + paperPoint.y * k)
    }

    private func aspectFit(_ image: CGImage, in rect: CGRect) -> CGRect {
        let ratio = CGFloat(image.width) / CGFloat(image.height)
        var w = rect.width, h = rect.width / ratio
        if h > rect.height { h = rect.height; w = h * ratio }
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    // MARK: - Input

    private func shape(_ pressure: CGFloat) -> CGFloat {
        let p = pow(min(max(pressure, 0), 1), pressureCurve)
        return baseWidth * (minWidthFactor + (1 - minWidthFactor) * p)
    }

    private func widthFor(_ event: NSEvent) -> (CGFloat, Bool) {
        if let live = pressureSource?() {
            return (shape(CGFloat(live.pressure)), live.eraser)
        }
        // Without a vendor driver macOS can hand us tablet events whose pressure
        // is a flat zero. Drawing that honestly gives a hairline, so treat a
        // pressure-less source as no pressure information at all.
        if event.subtype == .tabletPoint, event.pressure > 0.004 {
            return (shape(CGFloat(event.pressure)), false)
        }
        return (baseWidth, false)
    }

    /// Width for a pressure reading; `nil` means the source has no pressure.
    func width(forPressure pressure: CGFloat?) -> CGFloat {
        guard let pressure else { return baseWidth }
        return shape(pressure)
    }

    /// Feed the pen's position while pointing. `nil` when the pen leaves.
    func updateLaser(paper point: CGPoint?) {
        guard laserMode else { return }
        if let point { laserTrail.append((point, Date())) }
        trimLaserTrail()
        needsDisplay = true
    }

    private func trimLaserTrail() {
        let cutoff = Date().addingTimeInterval(-0.45)
        laserTrail.removeAll { $0.at < cutoff }
        if laserTrail.count > 120 { laserTrail.removeFirst(laserTrail.count - 120) }
    }

    private func startLaserFade() {
        laserTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.laserMode else { self.laserTimer?.invalidate(); self.laserTimer = nil; return }
            guard !self.laserTrail.isEmpty else { return }
            self.trimLaserTrail()
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        laserTimer = timer
    }

    func beginStroke(at viewPoint: CGPoint, width w: CGFloat, eraser: Bool) {
        guard !laserMode else { return }
        // A pen stroke is only rasterised on release, so a second press arriving
        // before the matching release would throw the whole stroke away.
        if live != nil { finishStroke() }
        guard paperRect.contains(viewPoint) else { return }
        let start = toPaper(viewPoint)
        live = Stroke(color: inkColor, erase: eraserSelected || eraser, points: [Point(p: start, w: w)])
        burned = 0
        strokeStart = start
        snapAnchor = nil
        snapped = nil
        lastMovement = Date()
        startHoldWatch()
        if live!.erase { burnLive() }
        needsDisplay = true
    }

    func extendStroke(to viewPoint: CGPoint, width w: CGFloat) {
        guard !laserMode, live != nil else { return }
        let point = toPaper(viewPoint)

        // Once snapped, the gesture keeps steering the shape rather than adding
        // to it — the same way a snapped shape stays adjustable until you lift.
        if let kind = snapped, let anchor = snapAnchor {
            live!.points = idealShape(kind, from: anchor, to: point, width: averageWidth())
            needsDisplay = true
            return
        }

        let previous = live!.points.last!
        let next = Point(p: point, w: w)
        live!.points.append(next)
        if hypot(next.p.x - previous.p.x, next.p.y - previous.p.y) > 2.5 { lastMovement = Date() }
        if live!.erase { burnLive() }
        setNeedsDisplay(dirtyRect(previous, next))
    }

    func finishStroke() {
        holdTimer?.invalidate()
        holdTimer = nil
        strokeStart = nil
        snapAnchor = nil
        snapped = nil
        guard var stroke = live else { return }
        if !stroke.erase { burnLive() }
        live = nil
        if stroke.points.count == 1 { stroke.points.append(stroke.points[0]) }
        strokes.append(stroke)
        redoStack.removeAll()
        onChange?()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard !ignoresMouse else { return }
        window?.makeFirstResponder(self)
        let (w, penEraser) = widthFor(event)
        beginStroke(at: convert(event.locationInWindow, from: nil), width: w, eraser: penEraser)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !ignoresMouse else { return }
        let (w, _) = widthFor(event)
        extendStroke(to: convert(event.locationInWindow, from: nil), width: w)
    }

    override func mouseUp(with event: NSEvent) {
        guard !ignoresMouse else { return }
        finishStroke()
    }

    private func dirtyRect(_ a: Point, _ b: Point) -> NSRect {
        let k = paperScale
        let pad = max(a.w, b.w) * k / 2 + 4
        let p1 = toView(a.p), p2 = toView(b.p)
        return NSRect(x: min(p1.x, p2.x) - pad, y: min(p1.y, p2.y) - pad,
                      width: abs(p1.x - p2.x) + pad * 2, height: abs(p1.y - p2.y) + pad * 2)
    }

    // MARK: - Rasterising

    /// Draw the not-yet-burned part of the live stroke into the bitmap.
    private func burnLive() {
        guard let stroke = live else { return }
        render(stroke, from: burned, into: ink, origin: .zero, scale: 1)
        burned = max(stroke.points.count - 1, 0)
        inkImage = nil
    }

    private func render(_ stroke: Stroke, from start: Int, into ctx: CGContext, origin: CGPoint, scale k: CGFloat) {
        let pts = stroke.points
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if stroke.erase {
            ctx.setBlendMode(.clear)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
        } else {
            ctx.setBlendMode(.normal)
            ctx.setStrokeColor(stroke.color.cgColor)
            ctx.setFillColor(stroke.color.cgColor)
        }
        func place(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * k, y: origin.y + p.y * k) }

        if pts.count == 1 && start == 0 {
            let r = max(pts[0].w * k, 0.6) / 2
            let c = place(pts[0].p)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
        var i = max(start, 1)
        while i < pts.count {
            let a = pts[i - 1], b = pts[i]
            ctx.setLineWidth(max((a.w + b.w) / 2 * k, 0.6))
            ctx.beginPath()
            ctx.move(to: place(a.p))
            ctx.addLine(to: place(b.p))
            ctx.strokePath()
            i += 1
        }
        ctx.restoreGState()
    }

    private func rebuildBitmap() {
        ink.clear(CGRect(origin: .zero, size: CGSize(width: Self.paperSize.width * bitmapScale,
                                                     height: Self.paperSize.height * bitmapScale)))
        for stroke in strokes { render(stroke, from: 0, into: ink, origin: .zero, scale: 1) }
        inkImage = nil
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        let r = paperRect

        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -2), blur: 10,
                    color: NSColor.black.withAlphaComponent(0.22).cgColor)
        g.setFillColor(NSColor.white.cgColor)
        g.fill(r)
        g.restoreGState()

        // Ruling — a drafting grid that stays on screen and never reaches the export.
        g.saveGState()
        g.clip(to: r)
        g.setStrokeColor(NSColor(srgbRed: 0.42, green: 0.50, blue: 0.48, alpha: 0.11).cgColor)
        g.setLineWidth(1)
        let step: CGFloat = 50 * paperScale
        var x = r.minX + step
        while x < r.maxX { g.move(to: CGPoint(x: x, y: r.minY)); g.addLine(to: CGPoint(x: x, y: r.maxY)); x += step }
        var y = r.minY + step
        while y < r.maxY { g.move(to: CGPoint(x: r.minX, y: y)); g.addLine(to: CGPoint(x: r.maxX, y: y)); y += step }
        g.strokePath()
        g.restoreGState()

        if let bg = backgroundImage {
            g.saveGState(); g.clip(to: r); g.draw(bg, in: aspectFit(bg, in: r)); g.restoreGState()
        }

        if let preview {
            g.saveGState()
            g.clip(to: r)
            g.setAlpha(0.45)
            g.draw(preview, in: aspectFit(preview, in: r))
            g.restoreGState()
        }

        if inkImage == nil { inkImage = ink.makeImage() }
        if let img = inkImage { g.draw(img, in: r) }

        if let stroke = live, !stroke.erase {
            g.saveGState(); g.clip(to: r)
            render(stroke, from: 0, into: g, origin: r.origin, scale: paperScale)
            g.restoreGState()
        }

        g.setStrokeColor(NSColor.separatorColor.cgColor)
        g.setLineWidth(1)
        g.stroke(r.insetBy(dx: 0.5, dy: 0.5))

        if laserMode, !laserTrail.isEmpty {
            g.saveGState()
            g.clip(to: r)
            let now = Date()
            let red = NSColor(srgbRed: 0.94, green: 0.24, blue: 0.24, alpha: 1)   // Open Color red 7

            // The tail, oldest first so the newest sits on top.
            g.setLineCap(.round)
            g.setLineJoin(.round)
            for i in 1..<max(laserTrail.count, 1) {
                let age = now.timeIntervalSince(laserTrail[i].at)
                let life = max(0, 1 - age / 0.45)
                guard life > 0 else { continue }
                g.setStrokeColor(red.withAlphaComponent(CGFloat(life) * 0.5).cgColor)
                g.setLineWidth(2 + 7 * CGFloat(life))
                g.beginPath()
                g.move(to: toView(laserTrail[i - 1].point))
                g.addLine(to: toView(laserTrail[i].point))
                g.strokePath()
            }

            if let head = laserTrail.last?.point {
                let centre = toView(head)
                for (radius, alpha) in [(26.0, 0.10), (17.0, 0.18), (10.0, 0.45)] {
                    g.setFillColor(red.withAlphaComponent(CGFloat(alpha)).cgColor)
                    g.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                             width: radius * 2, height: radius * 2))
                }
                g.setFillColor(NSColor(srgbRed: 1, green: 0.86, blue: 0.86, alpha: 1).cgColor)
                g.fillEllipse(in: CGRect(x: centre.x - 4, y: centre.y - 4, width: 8, height: 8))
            }
            g.restoreGState()
        }

        if let notice, !notice.isEmpty {
            let band = NSRect(x: r.minX, y: r.maxY - 62, width: r.width, height: 62)
            g.setFillColor(NSColor(srgbRed: 0.04, green: 0.44, blue: 0.37, alpha: 0.94).cgColor)
            g.fill(band)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 19, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: style,
            ]
            (notice as NSString).draw(in: band.insetBy(dx: 20, dy: 18), withAttributes: attrs)
        }

        if strokes.isEmpty && live == nil && backgroundImage == nil && notice == nil && preview == nil {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let text = "ここにペンで書く\n⌘V でスクリーンショットを貼って、その上に赤で指示を描く"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: NSColor(srgbRed: 0.45, green: 0.50, blue: 0.49, alpha: 0.75),
                .paragraphStyle: style,
            ]
            let size = (text as NSString).boundingRect(with: NSSize(width: r.width - 80, height: 200),
                                                       options: [.usesLineFragmentOrigin], attributes: attrs).size
            (text as NSString).draw(in: NSRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2,
                                               width: size.width, height: size.height), withAttributes: attrs)
        }
    }

    // MARK: - Commands

    var canUndo: Bool { !strokes.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Drop a stroke still in progress without committing it. Anything that
    /// rewrites the bitmap has to do this first, or the half-finished stroke is
    /// rasterised afterwards on top of the new state.
    func cancelStroke() {
        holdTimer?.invalidate()
        holdTimer = nil
        live = nil
        burned = 0
        strokeStart = nil
        snapAnchor = nil
        snapped = nil
    }

    // MARK: - Shape snapping

    private func startHoldWatch() {
        holdTimer?.invalidate()
        guard snapsShapes else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.live != nil, self.snapped == nil else { return }
            guard Date().timeIntervalSince(self.lastMovement) > 0.55 else { return }
            self.trySnap()
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func averageWidth() -> CGFloat {
        guard let points = live?.points, !points.isEmpty else { return baseWidth }
        return points.reduce(0) { $0 + $1.w } / CGFloat(points.count)
    }

    /// Decide what was drawn, and if it is clean enough to be one of the shapes
    /// we know, replace it with the ideal version.
    private func trySnap() {
        guard let stroke = live, !stroke.erase, stroke.points.count >= 10,
              let start = strokeStart else { return }
        let points = stroke.points.map(\.p)

        var length: CGFloat = 0
        for i in 1..<points.count {
            length += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
        }
        guard length > 60 else { return }

        let first = points.first!, last = points.last!
        let chord = hypot(last.x - first.x, last.y - first.y)
        let closed = chord < length * 0.22

        let kind: ShapeKind?
        if closed {
            kind = closedShape(points)
        } else {
            kind = isLine(points, from: first, to: last, chord: chord) ? .line : nil
        }
        guard let kind else { return }

        // A closed shape's first and last points sit on top of each other, so
        // the ideal version has to come from the bounding box, not from the two
        // ends — otherwise it collapses to nothing.
        let anchor: CGPoint, moving: CGPoint
        if kind == .line {
            anchor = start
            moving = last
        } else {
            let xs = points.map(\.x), ys = points.map(\.y)
            let box = CGRect(x: xs.min()!, y: ys.min()!,
                             width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            // Pin the corner furthest from the pen, and let the pen keep hold of
            // the opposite one, so the shape stays adjustable the way a line is.
            let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                           CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            let far = corners.max { hypot($0.x - last.x, $0.y - last.y) < hypot($1.x - last.x, $1.y - last.y) }!
            anchor = far
            moving = CGPoint(x: far.x == box.minX ? box.maxX : box.minX,
                             y: far.y == box.minY ? box.maxY : box.minY)
        }

        snapped = kind
        snapAnchor = anchor
        live!.points = idealShape(kind, from: anchor, to: moving, width: averageWidth())
        needsDisplay = true
        onSnap?(kind == .line ? "直線に補正" : kind == .ellipse ? "円に補正" : "四角に補正")
    }

    private func isLine(_ points: [CGPoint], from a: CGPoint, to b: CGPoint, chord: CGFloat) -> Bool {
        guard chord > 40 else { return false }
        let dx = b.x - a.x, dy = b.y - a.y
        var worst: CGFloat = 0
        for p in points {
            // Distance from the chord, by the cross product over its length.
            let d = abs(dy * (p.x - a.x) - dx * (p.y - a.y)) / chord
            worst = max(worst, d)
        }
        return worst < max(chord * 0.06, 6)
    }

    private func closedShape(_ points: [CGPoint]) -> ShapeKind? {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        let rx = (maxX - minX) / 2, ry = (maxY - minY) / 2
        guard rx > 20, ry > 20 else { return nil }
        let cx = minX + rx, cy = minY + ry

        var onEllipse = 0, onBox = 0
        // A hand-drawn box bows on the edges and rounds at the corners, so the
        // band it has to stay inside is wider than it first seems.
        let tolerance = max(min(rx, ry) * 0.24, 12)
        for p in points {
            let radial = abs(pow((p.x - cx) / rx, 2) + pow((p.y - cy) / ry, 2) - 1)
            if radial < 0.38 { onEllipse += 1 }
            let edge = min(min(abs(p.x - minX), abs(p.x - maxX)), min(abs(p.y - minY), abs(p.y - maxY)))
            if edge < tolerance { onBox += 1 }
        }
        let total = CGFloat(points.count)
        // A rectangle hugs its bounding box nearly everywhere; an ellipse only
        // touches it at four points, so a loose threshold still separates them.
        if CGFloat(onBox) / total > 0.84 { return .rectangle }
        if CGFloat(onEllipse) / total > 0.75 { return .ellipse }
        return nil
    }

    private func idealShape(_ kind: ShapeKind, from a: CGPoint, to b: CGPoint, width w: CGFloat) -> [Point] {
        switch kind {
        case .line:
            return (0...48).map { i in
                let t = CGFloat(i) / 48
                return Point(p: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), w: w)
            }
        case .ellipse:
            let cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2
            let rx = abs(b.x - a.x) / 2, ry = abs(b.y - a.y) / 2
            return (0...96).map { i in
                let t = CGFloat(i) / 96 * 2 * .pi
                return Point(p: CGPoint(x: cx + cos(t) * rx, y: cy + sin(t) * ry), w: w)
            }
        case .rectangle:
            let corners = [CGPoint(x: a.x, y: a.y), CGPoint(x: b.x, y: a.y),
                           CGPoint(x: b.x, y: b.y), CGPoint(x: a.x, y: b.y), CGPoint(x: a.x, y: a.y)]
            var out: [Point] = []
            for i in 1..<corners.count {
                let from = corners[i - 1], to = corners[i]
                for step in 0...24 {
                    let t = CGFloat(step) / 24
                    out.append(Point(p: CGPoint(x: from.x + (to.x - from.x) * t,
                                                y: from.y + (to.y - from.y) * t), w: w))
                }
            }
            return out
        }
    }

    func undo() {
        cancelStroke()
        guard let last = strokes.popLast() else { return }
        redoStack.append(last)
        rebuildBitmap()
        onChange?()
    }

    func redo() {
        cancelStroke()
        guard let stroke = redoStack.popLast() else { return }
        strokes.append(stroke)
        rebuildBitmap()
        onChange?()
    }

    func clearAll() {
        cancelStroke()
        strokes.removeAll()
        redoStack.removeAll()
        backgroundImage = nil
        rebuildBitmap()
        onChange?()
    }

    func clearInkOnly() {
        cancelStroke()
        strokes.removeAll()
        redoStack.removeAll()
        rebuildBitmap()
        onChange?()
    }

    func setBackground(_ image: CGImage?) {
        backgroundImage = image
        needsDisplay = true
        onChange?()
    }

    var isEmpty: Bool { strokes.isEmpty && backgroundImage == nil }
    var strokeCount: Int { strokes.count }

    /// Hand the page's strokes out and take a page's strokes back, so a sheet
    /// can be put away and picked up again still editable.
    var storedStrokes: [StoredStroke] {
        strokes.map { stroke in
            let rgb = stroke.color.usingColorSpace(.sRGB) ?? .black
            return StoredStroke(
                r: Double(rgb.redComponent), g: Double(rgb.greenComponent),
                b: Double(rgb.blueComponent), a: Double(rgb.alphaComponent),
                erase: stroke.erase,
                points: stroke.points.map { StoredPoint(x: Double($0.p.x), y: Double($0.p.y), w: Double($0.w)) })
        }
    }

    func restore(strokes stored: [StoredStroke], background image: CGImage?) {
        cancelStroke()
        redoStack.removeAll()
        strokes = stored.map { s in
            Stroke(color: NSColor(srgbRed: CGFloat(s.r), green: CGFloat(s.g),
                                  blue: CGFloat(s.b), alpha: CGFloat(s.a)),
                   erase: s.erase,
                   points: s.points.map { Point(p: CGPoint(x: $0.x, y: $0.y), w: CGFloat($0.w)) })
        }
        backgroundImage = image
        notice = nil
        preview = nil
        rebuildBitmap()
    }

    /// Lay text down as the sheet's underlay, so the pen can annotate on top.
    /// This is how a session puts what it wrote in front of the person.
    func setBackgroundText(_ text: String) {
        let scale: CGFloat = 2
        let w = Int(Self.paperSize.width * scale), h = Int(Self.paperSize.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 8
        style.paragraphSpacing = 12
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 34, weight: .regular),
            .foregroundColor: NSColor(srgbRed: 0.10, green: 0.13, blue: 0.13, alpha: 1),
            .paragraphStyle: style,
        ]
        let inset: CGFloat = 64
        let box = NSRect(x: inset, y: inset,
                         width: Self.paperSize.width - inset * 2,
                         height: Self.paperSize.height - inset * 2)
        (text as NSString).draw(with: box, options: [.usesLineFragmentOrigin], attributes: attrs)
        NSGraphicsContext.current = previous

        setBackground(ctx.makeImage())
    }

    // MARK: - Export

    /// Flatten paper + background + ink into a PNG for Claude to read.
    func flattenedPNG() -> Data? {
        guard let flat = flattenedImage() else { return nil }
        return NSBitmapImageRep(cgImage: flat).representation(using: .png, properties: [:])
    }

    /// The sheet as one image — used for the page-turn animation as well.
    func flattenedImage() -> CGImage? {
        let w = Int(Self.paperSize.width * bitmapScale)
        let h = Int(Self.paperSize.height * bitmapScale)
        guard let out = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        out.scaleBy(x: bitmapScale, y: bitmapScale)
        let sheet = CGRect(origin: .zero, size: Self.paperSize)
        out.setFillColor(CGColor(gray: 1, alpha: 1))
        out.fill(sheet)
        if let bg = backgroundImage { out.draw(bg, in: aspectFit(bg, in: sheet)) }
        if inkImage == nil { inkImage = ink.makeImage() }
        if let img = inkImage { out.draw(img, in: sheet) }
        return out.makeImage()
    }

    // MARK: - Pasting & dropping images

    @objc func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let first = images.first {
            setBackground(first.cgImage(forProposedRect: nil, context: nil, hints: nil))
            return
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first, let image = NSImage(contentsOf: url) {
            setBackground(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first, let image = NSImage(contentsOf: url) {
            setBackground(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            return true
        }
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let first = images.first {
            setBackground(first.cgImage(forProposedRect: nil, context: nil, hints: nil))
            return true
        }
        return false
    }
}
