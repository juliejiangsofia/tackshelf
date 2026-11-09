import AppKit
import QuartzCore

/// Draws the approved broad-fold discard effect above the board. The source
/// is the real rendered card, so photos, cloth, tags and envelopes keep their
/// appearance while they gather into a paper ball.
@MainActor
final class CrumpleDiscard {
    static let duration: CFTimeInterval = 1.05
    static let cleanupDelay: TimeInterval = duration + 0.10

    private static var active: [CrumpleDiscard] = []

    private let window: NSPanel
    private let view: CrumpleView
    private var timer: Timer?
    private var startedAt: CFTimeInterval = 0

    static func play(paper: CGImage, card: CGRect, tilt: CGFloat,
                     buttonColourIndex: Int, on screen: NSScreen) {
        let effect = CrumpleDiscard(paper: paper, card: card, tilt: tilt,
                                    buttonColourIndex: buttonColourIndex, screen: screen)
        active.append(effect)
        effect.start()
    }

    private init(paper: CGImage, card: CGRect, tilt: CGFloat,
                 buttonColourIndex: Int, screen: NSScreen) {
        window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let localCard = CGRect(x: card.minX - screen.frame.minX,
                               y: screen.frame.maxY - card.maxY,
                               width: card.width, height: card.height)
        view = CrumpleView(frame: CGRect(origin: .zero, size: screen.frame.size),
                           paper: paper, card: localCard, tilt: tilt,
                           button: ButtonArtwork.image(at: buttonColourIndex),
                           reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        window.contentView = view
    }

    private func start() {
        window.orderFrontRegardless()
        startedAt = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let actualDuration = view.reduceMotion ? 0.20 : Self.duration
        let progress = min(1, (CACurrentMediaTime() - startedAt) / actualDuration)
        view.progress = CGFloat(progress)
        view.needsDisplay = true
        guard progress >= 1 else { return }
        timer?.invalidate()
        timer = nil
        window.orderOut(nil)
        Self.active.removeAll { $0 === self }
    }
}

/// Internal so the visual-check harness can render individual animation
/// frames without deleting anything from the user's real history.
final class CrumpleView: NSView {
    struct Vector3 {
        var x: CGFloat
        var y: CGFloat
        var z: CGFloat

        static func - (lhs: Vector3, rhs: Vector3) -> Vector3 {
            Vector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
        }

        static func *= (lhs: inout Vector3, rhs: CGFloat) {
            lhs.x *= rhs; lhs.y *= rhs; lhs.z *= rhs
        }

        static func /= (lhs: inout Vector3, rhs: CGFloat) {
            lhs.x /= rhs; lhs.y /= rhs; lhs.z /= rhs
        }
    }

    struct Vertex {
        let source: CGPoint
        let flat: CGPoint
        let ball: Vector3
        let crease: CGFloat
    }

    struct Projected {
        let point: CGPoint
        let local: Vector3
    }

    let reduceMotion: Bool
    var progress: CGFloat = 0

    private let paper: CGImage
    private let paperSize: CGSize
    private let centre: CGPoint
    private let tilt: CGFloat
    private let button: CGImage?
    private let vertices: [Vertex]
    private let faces: [(Int, Int, Int)]

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(frame: CGRect, paper: CGImage, card: CGRect, tilt: CGFloat,
         button: CGImage?, reduceMotion: Bool) {
        self.paper = paper
        paperSize = card.size
        centre = CGPoint(x: card.midX, y: card.midY)
        self.tilt = tilt * .pi / 180
        self.button = button
        self.reduceMotion = reduceMotion

        let columns = 6
        let rows = 4
        let radius = min(26, max(17, min(card.width, card.height) * 0.20))
        var madeVertices: [Vertex] = []
        for row in 0...rows {
            for column in 0...columns {
                let rawU = CGFloat(column) / CGFloat(columns)
                let rawV = CGFloat(row) / CGFloat(rows)
                let u = rawU + ((column > 0 && column < columns)
                    ? (Self.noise(column, row) - 0.5) * 0.26 / CGFloat(columns) : 0)
                let v = rawV + ((row > 0 && row < rows)
                    ? (Self.noise(row, column + 20) - 0.5) * 0.26 / CGFloat(rows) : 0)
                let longitude = (u - 0.5) * .pi * 2
                let latitude = (v - 0.5) * .pi
                let variedRadius = radius * (0.94 + Self.noise(column + 18, row + 33) * 0.12)
                let source = CGPoint(x: u * card.width, y: v * card.height)
                let flat = CGPoint(x: (u - 0.5) * card.width, y: (v - 0.5) * card.height)
                let ballX = variedRadius * cos(latitude) * sin(longitude)
                let ballY = variedRadius * sin(latitude)
                let ballZ = variedRadius * cos(latitude) * cos(longitude)
                let ball = Vector3(x: ballX, y: ballY, z: ballZ)
                let crease = (Self.noise(column + 50, row + 60) - 0.5) * 10
                madeVertices.append(Vertex(source: source, flat: flat, ball: ball, crease: crease))
            }
        }
        vertices = madeVertices

        var madeFaces: [(Int, Int, Int)] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let a = row * (columns + 1) + column
                let b = a + 1
                let c = a + columns + 1
                let d = c + 1
                if (column + row).isMultiple(of: 2) {
                    madeFaces.append((a, b, d)); madeFaces.append((a, d, c))
                } else {
                    madeFaces.append((a, b, c)); madeFaces.append((b, d, c))
                }
            }
        }
        faces = madeFaces
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext, progress < 1 else { return }
        if reduceMotion {
            drawFlat(in: context, alpha: 1 - progress)
            drawButton(in: context, progress: progress)
            return
        }

        let fold = Self.smooth(0.06, 0.72, progress)
        let drop = Self.smooth(0.78, 1, progress)
        let fade = 1 - Self.smooth(0.87, 1, progress)
        if fold < 0.001 {
            drawFlat(in: context, alpha: fade)
        } else {
            drawFolded(in: context, fold: fold, drop: drop, alpha: fade)
        }
        drawButton(in: context, progress: progress)
    }

    private func drawFlat(in context: CGContext, alpha: CGFloat) {
        context.saveGState()
        context.setAlpha(alpha)
        context.translateBy(x: centre.x, y: centre.y)
        context.rotate(by: tilt)
        context.setShadow(offset: CGSize(width: 3, height: 6), blur: 7,
                          color: NSColor.black.withAlphaComponent(0.25).cgColor)
        drawImage(paper, size: paperSize, in: context,
                  origin: CGPoint(x: -paperSize.width / 2, y: -paperSize.height / 2))
        context.restoreGState()
    }

    private func drawFolded(in context: CGContext, fold: CGFloat, drop: CGFloat, alpha: CGFloat) {
        let bend = sin(fold * .pi)
        let rotationY = fold * 0.65
        let perspective = max(paperSize.width, paperSize.height) * 2.2
        let spin = tilt + fold * 0.32 + drop * 0.18
        let scale = 1 - drop * 0.65
        let wobble = bend * 1.5 * sin(progress * 17)
        let cosSpin = cos(spin), sinSpin = sin(spin)

        let projected = vertices.map { vertex -> Projected in
            var x = Self.mix(vertex.flat.x, vertex.ball.x, fold)
            var y = Self.mix(vertex.flat.y, vertex.ball.y, fold)
            var z = vertex.ball.z * fold + vertex.crease * bend
            x += sin((vertex.source.y / paperSize.height) * 8
                     + (vertex.source.x / paperSize.width) * 5) * bend * 4
            y += cos((vertex.source.x / paperSize.width) * 7
                     - (vertex.source.y / paperSize.height) * 5) * bend * 4
            let rotatedX = x * cos(rotationY) + z * sin(rotationY)
            z = z * cos(rotationY) - x * sin(rotationY)
            let depth = perspective / max(1, perspective - z)
            let screenX = rotatedX * depth * scale
            let screenY = y * depth * scale
            let finalX = screenX * cosSpin - screenY * sinSpin
            let finalY = screenX * sinSpin + screenY * cosSpin
            return Projected(point: CGPoint(x: centre.x + wobble + finalX,
                                            y: centre.y + drop * 38 + finalY),
                             local: Vector3(x: rotatedX, y: y, z: z))
        }

        context.saveGState()
        context.setAlpha(alpha)
        let shadowWidth = Self.mix(paperSize.width * 0.46, 22, fold) * scale
        let shadowHeight = Self.mix(paperSize.height * 0.40, 14, fold) * scale
        context.setShadow(offset: .zero, blur: 5,
                          color: NSColor(red: 0.22, green: 0.16, blue: 0.09, alpha: 0.27).cgColor)
        context.setFillColor(NSColor(red: 0.22, green: 0.16, blue: 0.09, alpha: 0.18).cgColor)
        context.fillEllipse(in: CGRect(x: centre.x + wobble - shadowWidth + 4,
                                       y: centre.y + drop * 38 - shadowHeight + 7,
                                       width: shadowWidth * 2, height: shadowHeight * 2))
        context.setShadow(offset: .zero, blur: 0, color: nil)

        let ordered = faces.sorted { faceDepth($0, projected) < faceDepth($1, projected) }
        for face in ordered {
            draw(face: face, projected: projected, fold: fold, in: context)
        }
        context.restoreGState()
    }

    private func draw(face: (Int, Int, Int), projected: [Projected], fold: CGFloat,
                      in context: CGContext) {
        let indices = [face.0, face.1, face.2]
        let source = indices.map { vertices[$0].source }
        let destination = indices.map { projected[$0].point }
        guard let transform = Self.affine(from: source, to: destination) else { return }

        let centre = CGPoint(x: destination.map(\.x).reduce(0, +) / 3,
                             y: destination.map(\.y).reduce(0, +) / 3)
        let expanded = destination.map { point -> CGPoint in
            let delta = CGVector(dx: point.x - centre.x, dy: point.y - centre.y)
            let length = max(0.001, hypot(delta.dx, delta.dy))
            return CGPoint(x: point.x + delta.dx / length * 0.28,
                           y: point.y + delta.dy / length * 0.28)
        }

        context.saveGState()
        let path = CGMutablePath()
        path.move(to: expanded[0]); path.addLine(to: expanded[1]); path.addLine(to: expanded[2])
        path.closeSubpath()
        context.addPath(path)
        context.clip()
        context.concatenate(transform)
        drawImage(paper, size: paperSize, in: context, origin: .zero)
        context.restoreGState()

        let a = projected[face.0].local
        let b = projected[face.1].local
        let c = projected[face.2].local
        var normal = Self.cross(b - a, c - a)
        let normalLength = max(0.001, sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z))
        normal /= normalLength
        if normal.z < 0 { normal *= -1 }
        let light = max(0, -normal.x * 0.4 - normal.y * 0.55 + normal.z * 0.73)
        let darkness = (1 - light) * 0.30 * Self.smooth(0, 0.4, fold)
        guard darkness > 0.002 else { return }
        context.saveGState()
        context.addPath(path); context.clip()
        context.setFillColor(NSColor(calibratedWhite: 0.17, alpha: darkness).cgColor)
        context.fill(bounds)
        context.restoreGState()
    }

    private func drawButton(in context: CGContext, progress: CGFloat) {
        guard let button else { return }
        let phase = Self.smooth(0, 0.15, progress)
        guard phase < 1 else { return }
        let top = CGPoint(x: centre.x + sin(tilt) * paperSize.height / 2,
                          y: centre.y - cos(tilt) * paperSize.height / 2 - phase * 13)
        let size = ButtonArtwork.diameter + 2 * ButtonArtwork.shadowPadding
        context.saveGState()
        context.setAlpha(1 - phase)
        drawImage(button, size: CGSize(width: size, height: size), in: context,
                  origin: CGPoint(x: top.x - size / 2, y: top.y - size / 2))
        context.restoreGState()
    }

    private func drawImage(_ image: CGImage, size: CGSize, in context: CGContext, origin: CGPoint) {
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y + size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        context.restoreGState()
    }

    private func faceDepth(_ face: (Int, Int, Int), _ points: [Projected]) -> CGFloat {
        (points[face.0].local.z + points[face.1].local.z + points[face.2].local.z) / 3
    }

    private static func affine(from source: [CGPoint], to destination: [CGPoint]) -> CGAffineTransform? {
        let a = source[0], b = source[1], c = source[2]
        let x = destination[0], y = destination[1], z = destination[2]
        let determinant = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
        guard abs(determinant) > 0.0001 else { return nil }
        let m11 = ((y.x - x.x) * (c.y - a.y) - (z.x - x.x) * (b.y - a.y)) / determinant
        let m21 = ((z.x - x.x) * (b.x - a.x) - (y.x - x.x) * (c.x - a.x)) / determinant
        let m12 = ((y.y - x.y) * (c.y - a.y) - (z.y - x.y) * (b.y - a.y)) / determinant
        let m22 = ((z.y - x.y) * (b.x - a.x) - (y.y - x.y) * (c.x - a.x)) / determinant
        return CGAffineTransform(a: m11, b: m12, c: m21, d: m22,
                                 tx: x.x - m11 * a.x - m21 * a.y,
                                 ty: x.y - m12 * a.x - m22 * a.y)
    }

    private static func smooth(_ start: CGFloat, _ end: CGFloat, _ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, (value - start) / (end - start)))
        return t * t * (3 - 2 * t)
    }

    private static func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    private static func noise(_ x: Int, _ y: Int) -> CGFloat {
        let value = sin(Double(x) * 127.1 + Double(y) * 311.7) * 43_758.5453
        return CGFloat(value - floor(value))
    }

    private static func cross(_ a: Vector3, _ b: Vector3) -> Vector3 {
        Vector3(x: a.y * b.z - a.z * b.y,
                y: a.z * b.x - a.x * b.z,
                z: a.x * b.y - a.y * b.x)
    }
}
