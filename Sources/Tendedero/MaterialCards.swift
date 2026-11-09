import AppKit
import SwiftUI

/// Small physical objects on the board: a stitched cloth, a luggage tag, and
/// a string-tie envelope. Text stays native so it is crisp at every card size.
@MainActor
struct MaterialCard: View {
    let content: ClipboardContent

    nonisolated static func size(for content: ClipboardContent) -> CGSize {
        let scale = Layout.size.scale
        let base: CGSize
        switch content.kind {
        case .text:
            return ClothText.size(for: content.text, scale: scale)
        case .link: base = CGSize(width: 106, height: 172)
        case .files: base = CGSize(width: 134, height: 174)
        }
        return CGSize(width: base.width * scale, height: base.height * scale)
    }

    private var scale: CGFloat { Layout.size.scale }
    private var size: CGSize { Self.size(for: content) }
    private var ink: Color { Color(red: 0.24, green: 0.22, blue: 0.18) }

    var body: some View {
        Group {
            switch content.kind {
            case .text: cloth
            case .link: tag
            case .files: envelope
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var cloth: some View {
        Text(ClothText.preview(content.text))
            .font(Font(ClothText.font(scale: scale)))
            .foregroundStyle(ink)
            .lineSpacing(ClothText.lineSpacing * scale)
            .lineLimit(7)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, ClothText.horizontalPadding * scale)
            .padding(.vertical, ClothText.verticalPadding * scale)
            .background(ClothSurface())
            .help(String(content.text.prefix(1000)))
    }

    private var link: URL? { content.urls.first }
    private var domain: String {
        guard let link else { return content.text }
        return link.host?.replacingOccurrences(of: "www.", with: "") ?? link.scheme ?? "链接"
    }
    private var linkDetail: String {
        guard let link else { return "" }
        let path = link.path.removingPercentEncoding ?? link.path
        let query = link.query.map { "?" + $0 } ?? ""
        let fragment = link.fragment.map { "#" + $0 } ?? ""
        let detail = path + query + fragment
        return detail == "/" ? "" : detail
    }

    private var tag: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            Text(domain)
                .font(.system(size: 11.5 * scale, weight: .medium, design: .serif))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle()
                .fill(ink.opacity(0.23))
                .frame(width: 20 * scale, height: 0.5)
            Text(String(linkDetail.prefix(300)))
                .font(.system(size: 9 * scale))
                .foregroundStyle(ink.opacity(0.70))
                .lineLimit(4)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            HStack(spacing: 4 * scale) {
                Image(systemName: "link")
                Text("网页")
            }
            .font(.system(size: 8 * scale, weight: .medium))
            .foregroundStyle(ink.opacity(0.65))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 13 * scale)
        .padding(.top, 49 * scale)
        .padding(.bottom, 12 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TagSurface())
        .help(String((link?.absoluteString ?? content.text).prefix(2000)))
    }

    private var firstFile: URL? { content.urls.first }
    private var fileName: String { firstFile?.lastPathComponent ?? "文件" }
    private var fileType: String {
        guard let file = firstFile else { return "文件" }
        if file.hasDirectoryPath { return "文件夹" }
        return file.pathExtension.isEmpty ? "文件" : file.pathExtension.uppercased()
    }
    private var envelope: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(fileType)
                    .font(.system(size: 8 * scale, weight: .medium))
                    .tracking(1 * scale)
                    .foregroundStyle(ink.opacity(0.50))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.top, 17 * scale)
            .padding(.horizontal, 12 * scale)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 3 * scale) {
                Text(fileName)
                    .font(.system(size: 10.5 * scale, weight: .medium))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if content.urls.count > 1 {
                    Text("另有 \(content.urls.count - 1) 个文件")
                        .font(.system(size: 8 * scale))
                        .foregroundStyle(ink.opacity(0.62))
                }
            }
            .foregroundStyle(ink)
            .padding(8 * scale)
            .frame(maxWidth: .infinity, minHeight: 44 * scale, alignment: .leading)
            .background(Color(red: 0.985, green: 0.977, blue: 0.945))
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 0.5, x: 0.3, y: 0.8)
            .padding(.leading, 10 * scale)
            .padding(.trailing, 15 * scale)
            .padding(.bottom, 13 * scale)
        }
        .background(EnvelopeSurface())
        .help(content.urls.map(\.lastPathComponent).joined(separator: "\n"))
    }
}

/// Measure the same font and wrapping width used by the visible cloth label.
/// Only the preview is bounded; clipboard and full-text viewing retain the source.
private enum ClothText {
    static let horizontalPadding: CGFloat = 19
    static let verticalPadding: CGFloat = 22
    static let lineSpacing: CGFloat = 3

    static func preview(_ text: String) -> String { String(text.prefix(600)) }

    static func font(scale: CGFloat) -> NSFont {
        let system = NSFont.systemFont(ofSize: 11.5 * scale)
        guard let descriptor = system.fontDescriptor.withDesign(.serif) else { return system }
        return NSFont(descriptor: descriptor, size: 11.5 * scale) ?? system
    }

    static func size(for text: String, scale: CGFloat) -> CGSize {
        let width = 176 * scale
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing * scale
        paragraph.lineBreakMode = .byWordWrapping
        let label = NSAttributedString(string: preview(text), attributes: [
            .font: font(scale: scale), .paragraphStyle: paragraph
        ])
        let measured = label.boundingRect(
            with: CGSize(width: width - horizontalPadding * 2 * scale,
                         height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        // A small rounding allowance protects fallback glyphs and fractional
        // baselines. The cap retains the original card's maximum footprint.
        let height = ceil(measured.height) + (verticalPadding * 2 + 2) * scale
        return CGSize(width: width, height: min(156 * scale, max(58 * scale, height)))
    }
}

/// Paper grain uses fixed coordinates, so it never shimmers when a card moves.
private func paperGrain(_ context: inout GraphicsContext, size: CGSize, tint: Color, count: Int = 650) {
    for i in 0..<count {
        let x = CGFloat((i * 73 + 19) % 997) / 997 * size.width
        let y = CGFloat((i * 179 + 41) % 991) / 991 * size.height
        var fibre = Path()
        fibre.move(to: CGPoint(x: x, y: y))
        fibre.addLine(to: CGPoint(x: x + (i.isMultiple(of: 3) ? 1.6 : 0.65), y: y + 0.2))
        context.stroke(fibre, with: .color(tint.opacity(i.isMultiple(of: 2) ? 0.11 : 0.06)), lineWidth: 0.45)
    }
}

private struct ClothSurface: View {
    var body: some View {
        Canvas { context, size in
            let s = size.width / 176
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 2 * s, dy: 2 * s)
            let edge = raggedEdge(bounds, scale: s)
            let cream = Color(red: 0.93, green: 0.91, blue: 0.84)
            let thread = Color(red: 0.82, green: 0.77, blue: 0.65)
            context.fill(edge, with: .linearGradient(Gradient(colors: [Color(red: 0.98, green: 0.96, blue: 0.89), cream]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
            var fabric = context
            fabric.clip(to: edge)
            for i in 0...Int(size.width / (1.8 * s)) {
                let x = CGFloat(i) * 1.8 * s
                var warp = Path()
                warp.move(to: CGPoint(x: x, y: 0))
                warp.addLine(to: CGPoint(x: x + (i.isMultiple(of: 2) ? 0.4 : -0.3) * s, y: size.height))
                fabric.stroke(warp, with: .color(thread.opacity(i.isMultiple(of: 3) ? 0.23 : 0.12)), lineWidth: 0.65 * s)
            }
            for i in 0...Int(size.height / (1.6 * s)) {
                let y = CGFloat(i) * 1.6 * s
                var weft = Path()
                weft.move(to: CGPoint(x: 0, y: y))
                weft.addLine(to: CGPoint(x: size.width, y: y + (i.isMultiple(of: 3) ? 0.4 : -0.2) * s))
                fabric.stroke(weft, with: .color(i.isMultiple(of: 2) ? Color.white.opacity(0.29) : thread.opacity(0.12)), lineWidth: 0.6 * s)
            }
            paperGrain(&fabric, size: size, tint: Color(red: 0.53, green: 0.46, blue: 0.34), count: 400)
            // Loose fibres extend beyond an irregular, slightly thick cloth edge.
            for i in 0..<65 {
                let t = CGFloat(i) / 64
                let length = CGFloat(1 + (i * 7) % 4) * s
                let wobble = CGFloat((i * 3) % 5 - 2) * 0.38 * s
                var fray = Path()
                fray.move(to: CGPoint(x: 3 * s + t * (size.width - 6 * s), y: 3 * s))
                fray.addLine(to: CGPoint(x: 3 * s + t * (size.width - 6 * s) + wobble, y: 3 * s - length))
                fray.move(to: CGPoint(x: 3 * s + t * (size.width - 6 * s), y: size.height - 3 * s))
                fray.addLine(to: CGPoint(x: 3 * s + t * (size.width - 6 * s) + wobble, y: size.height - 3 * s + length))
                fray.move(to: CGPoint(x: 3 * s, y: 3 * s + t * (size.height - 6 * s)))
                fray.addLine(to: CGPoint(x: 3 * s - length, y: 3 * s + t * (size.height - 6 * s) + wobble))
                fray.move(to: CGPoint(x: size.width - 3 * s, y: 3 * s + t * (size.height - 6 * s)))
                fray.addLine(to: CGPoint(x: size.width - 3 * s + length, y: 3 * s + t * (size.height - 6 * s) + wobble))
                context.stroke(fray, with: .color(i.isMultiple(of: 3) ? thread.opacity(0.55) : Color(red: 0.97, green: 0.95, blue: 0.87)), lineWidth: 0.6 * s)
            }
            let stitchBounds = bounds.insetBy(dx: 9 * s, dy: 9 * s)
            stitches(&context, bounds: stitchBounds, scale: s)
        }
        .allowsHitTesting(false)
    }

    private func raggedEdge(_ rect: CGRect, scale: CGFloat) -> Path {
        var path = Path()
        let steps = 40
        for edge in 0..<4 {
            for i in 0..<steps {
                let t = CGFloat(i) / CGFloat(steps)
                let fuzz = CGFloat((i * 13 + edge * 7) % 11 - 5) * 0.14 * scale
                let point: CGPoint
                switch edge {
                case 0: point = CGPoint(x: rect.minX + t * rect.width, y: rect.minY + fuzz)
                case 1: point = CGPoint(x: rect.maxX + fuzz, y: rect.minY + t * rect.height)
                case 2: point = CGPoint(x: rect.maxX - t * rect.width, y: rect.maxY + fuzz)
                default: point = CGPoint(x: rect.minX + fuzz, y: rect.maxY - t * rect.height)
                }
                if edge == 0 && i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        path.closeSubpath()
        return path
    }

    private func stitches(_ context: inout GraphicsContext, bounds: CGRect, scale: CGFloat) {
        for edge in 0..<4 {
            let length = edge.isMultiple(of: 2) ? bounds.width : bounds.height
            let count = Int(length / (11 * scale))
            for i in 0..<count {
                let start = CGFloat(i) * length / CGFloat(count) + 1.5 * scale
                let end = CGFloat(i + 1) * length / CGFloat(count) - 2.5 * scale
                let a: CGPoint, b: CGPoint, control: CGPoint
                switch edge {
                case 0:
                    a = CGPoint(x: bounds.minX + start, y: bounds.minY)
                    b = CGPoint(x: bounds.minX + end, y: bounds.minY + 0.4 * scale)
                    control = CGPoint(x: (a.x + b.x) / 2, y: bounds.minY + 1.5 * scale)
                case 1:
                    a = CGPoint(x: bounds.maxX, y: bounds.minY + start)
                    b = CGPoint(x: bounds.maxX - 0.4 * scale, y: bounds.minY + end)
                    control = CGPoint(x: bounds.maxX - 1.5 * scale, y: (a.y + b.y) / 2)
                case 2:
                    a = CGPoint(x: bounds.maxX - start, y: bounds.maxY)
                    b = CGPoint(x: bounds.maxX - end, y: bounds.maxY - 0.4 * scale)
                    control = CGPoint(x: (a.x + b.x) / 2, y: bounds.maxY - 1.5 * scale)
                default:
                    a = CGPoint(x: bounds.minX, y: bounds.maxY - start)
                    b = CGPoint(x: bounds.minX + 0.4 * scale, y: bounds.maxY - end)
                    control = CGPoint(x: bounds.minX + 1.5 * scale, y: (a.y + b.y) / 2)
                }
                var stitch = Path()
                stitch.move(to: a)
                stitch.addQuadCurve(to: b, control: control)
                var shadow = context
                shadow.translateBy(x: 0.4 * scale, y: 1.1 * scale)
                shadow.stroke(stitch, with: .color(Color(red: 0.45, green: 0.37, blue: 0.27).opacity(0.30)), style: StrokeStyle(lineWidth: 1.8 * scale, lineCap: .round))
                context.stroke(stitch, with: .color(Color(red: 0.86, green: 0.81, blue: 0.69)), style: StrokeStyle(lineWidth: 1.7 * scale, lineCap: .round))
                var highlight = context
                highlight.translateBy(x: -0.25 * scale, y: -0.35 * scale)
                highlight.stroke(stitch, with: .color(Color(red: 0.99, green: 0.96, blue: 0.86).opacity(0.9)), style: StrokeStyle(lineWidth: 0.65 * scale, lineCap: .round))
            }
        }
    }
}

private struct TagSurface: View {
    var body: some View {
        Canvas { context, size in
            let s = size.width / 106
            let face = tagPath(size, scale: s)
            context.fill(face, with: .linearGradient(Gradient(colors: [Color(red: 0.90, green: 0.85, blue: 0.72), Color(red: 0.84, green: 0.78, blue: 0.65)]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)), style: FillStyle(eoFill: true))
            var grain = context
            grain.clip(to: face, style: FillStyle(eoFill: true))
            paperGrain(&grain, size: size, tint: Color(red: 0.39, green: 0.32, blue: 0.21), count: 1100)
            context.stroke(face, with: .color(Color(red: 0.60, green: 0.52, blue: 0.38).opacity(0.30)), lineWidth: 0.65 * s)
            let hole = CGRect(x: size.width / 2 - 4.3 * s, y: 29 * s, width: 8.6 * s, height: 8.6 * s)
            context.stroke(Path(ellipseIn: hole.insetBy(dx: -1.5 * s, dy: -1.5 * s)), with: .color(Color(red: 0.93, green: 0.89, blue: 0.78).opacity(0.8)), lineWidth: 2.2 * s)
            var cord = Path()
            cord.move(to: CGPoint(x: size.width / 2 - 2.7 * s, y: 0))
            cord.addQuadCurve(to: CGPoint(x: size.width / 2 - 1.3 * s, y: 33 * s), control: CGPoint(x: size.width / 2 - 4.2 * s, y: 24 * s))
            cord.addQuadCurve(to: CGPoint(x: size.width / 2 + 2 * s, y: 33 * s), control: CGPoint(x: size.width / 2 + 2 * s, y: 38 * s))
            cord.addQuadCurve(to: CGPoint(x: size.width / 2 + 2.4 * s, y: 0), control: CGPoint(x: size.width / 2 + 5 * s, y: 20 * s))
            drawCord(&context, path: cord, scale: s)
            var knot = Path()
            knot.move(to: CGPoint(x: size.width / 2 - 3 * s, y: 20 * s))
            knot.addQuadCurve(to: CGPoint(x: size.width / 2 + 3.5 * s, y: 23 * s), control: CGPoint(x: size.width / 2 + 6 * s, y: 17 * s))
            drawCord(&context, path: knot, scale: s * 0.85)
        }
        .allowsHitTesting(false)
    }

    private func tagPath(_ size: CGSize, scale: CGFloat) -> Path {
        let top = 19 * scale, corner = 18 * scale
        var path = Path()
        path.move(to: CGPoint(x: corner, y: top))
        path.addLine(to: CGPoint(x: size.width - corner, y: top))
        path.addLine(to: CGPoint(x: size.width - 1, y: top + corner))
        path.addLine(to: CGPoint(x: size.width - 1, y: size.height - 2))
        path.addQuadCurve(to: CGPoint(x: size.width - 3, y: size.height), control: CGPoint(x: size.width - 1, y: size.height))
        path.addLine(to: CGPoint(x: 3, y: size.height))
        path.addQuadCurve(to: CGPoint(x: 1, y: size.height - 2), control: CGPoint(x: 1, y: size.height))
        path.addLine(to: CGPoint(x: 1, y: top + corner))
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: size.width / 2 - 4.3 * scale, y: 29 * scale, width: 8.6 * scale, height: 8.6 * scale))
        return path
    }
}

private struct EnvelopeSurface: View {
    var body: some View {
        Canvas { context, size in
            let s = size.width / 134
            let base = Color(red: 0.64, green: 0.80, blue: 0.82)
            let light = Color(red: 0.76, green: 0.87, blue: 0.87)
            let edge = RoundedRectangle(cornerRadius: 1.2 * s).path(in: CGRect(origin: .zero, size: size))
            context.fill(edge, with: .linearGradient(Gradient(colors: [light, base]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
            context.stroke(edge, with: .color(Color.black.opacity(0.16)), lineWidth: 0.5 * s)
            var grain = context
            grain.clip(to: edge)
            paperGrain(&grain, size: size, tint: Color(red: 0.37, green: 0.40, blue: 0.35), count: 800)
            var flap = Path()
            flap.move(to: CGPoint(x: 1 * s, y: 0))
            flap.addLine(to: CGPoint(x: size.width - 3 * s, y: 0))
            flap.addLine(to: CGPoint(x: size.width - 4 * s, y: 34 * s))
            flap.addQuadCurve(to: CGPoint(x: size.width - 14 * s, y: 43 * s), control: CGPoint(x: size.width - 4 * s, y: 43 * s))
            flap.addLine(to: CGPoint(x: 1 * s, y: 43 * s))
            flap.closeSubpath()
            context.fill(flap, with: .color(light.opacity(0.24)))
            var seam = Path()
            seam.move(to: CGPoint(x: size.width - 3 * s, y: 1))
            seam.addLine(to: CGPoint(x: size.width - 4 * s, y: 34 * s))
            seam.addQuadCurve(to: CGPoint(x: size.width - 14 * s, y: 43 * s), control: CGPoint(x: size.width - 4 * s, y: 43 * s))
            seam.addLine(to: CGPoint(x: 1 * s, y: 43 * s))
            context.stroke(seam, with: .color(Color(red: 0.30, green: 0.35, blue: 0.32).opacity(0.32)), lineWidth: 0.7 * s)
            // Folded bottom corners and a narrow paper-thickness highlight.
            var folds = Path()
            folds.move(to: CGPoint(x: 1 * s, y: size.height - 10 * s))
            folds.addLine(to: CGPoint(x: size.width - 1 * s, y: size.height - 10 * s))
            folds.move(to: CGPoint(x: 1 * s, y: size.height - 1 * s))
            folds.addLine(to: CGPoint(x: 12 * s, y: size.height - 10 * s))
            folds.move(to: CGPoint(x: size.width - 1 * s, y: size.height - 1 * s))
            folds.addLine(to: CGPoint(x: size.width - 12 * s, y: size.height - 10 * s))
            context.stroke(folds, with: .color(Color.white.opacity(0.45)), lineWidth: 0.7 * s)
            let x = size.width * 0.75
            // The cotton string passes beneath two round fasteners.
            var cord = Path()
            cord.move(to: CGPoint(x: x - 2 * s, y: 28 * s))
            cord.addLine(to: CGPoint(x: x + 5 * s, y: 63 * s))
            cord.addQuadCurve(to: CGPoint(x: x - 5 * s, y: 63 * s), control: CGPoint(x: x, y: 74 * s))
            cord.addLine(to: CGPoint(x: x + 4 * s, y: 28 * s))
            cord.addLine(to: CGPoint(x: x - 4 * s, y: 63 * s))
            cord.addQuadCurve(to: CGPoint(x: x + 2 * s, y: 94 * s), control: CGPoint(x: x + 2 * s, y: 83 * s))
            drawCord(&context, path: cord, scale: s * 0.65)
            fastener(&context, at: CGPoint(x: x, y: 28 * s), scale: s)
            fastener(&context, at: CGPoint(x: x, y: 63 * s), scale: s)
        }
        .allowsHitTesting(false)
    }

    private func fastener(_ context: inout GraphicsContext, at point: CGPoint, scale: CGFloat) {
        let rect = CGRect(x: point.x - 7.5 * scale, y: point.y - 7.5 * scale, width: 15 * scale, height: 15 * scale)
        let disk = Path(ellipseIn: rect)
        var shadow = context
        shadow.translateBy(x: 0.7 * scale, y: 1.3 * scale)
        shadow.fill(disk, with: .color(Color.black.opacity(0.18)))
        let colors: [Color] = [Color(red: 0.99, green: 0.97, blue: 0.91), Color(red: 0.83, green: 0.83, blue: 0.77)]
        context.fill(disk, with: .linearGradient(Gradient(colors: colors), startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
        context.stroke(Path(ellipseIn: rect.insetBy(dx: 1.5 * scale, dy: 1.5 * scale)), with: .color(Color.white.opacity(0.8)), lineWidth: 0.5 * scale)
        let rivet = CGRect(x: point.x - 2.3 * scale, y: point.y - 2.3 * scale, width: 4.6 * scale, height: 4.6 * scale)
        context.fill(Path(ellipseIn: rivet), with: .linearGradient(Gradient(colors: [Color(white: 0.95), Color(white: 0.44)]), startPoint: rivet.origin, endPoint: CGPoint(x: rivet.maxX, y: rivet.maxY)))
        context.fill(Path(ellipseIn: rivet.insetBy(dx: 1.2 * scale, dy: 1.2 * scale)), with: .color(Color(white: 0.38)))
    }
}

private func drawCord(_ context: inout GraphicsContext, path: Path, scale: CGFloat) {
    var shadow = context
    shadow.translateBy(x: 1.2 * scale, y: 0.8 * scale)
    shadow.stroke(path, with: .color(Color(red: 0.38, green: 0.31, blue: 0.21).opacity(0.30)), style: StrokeStyle(lineWidth: 2.2 * scale, lineCap: .round, lineJoin: .round))
    context.stroke(path, with: .color(Color(red: 0.79, green: 0.72, blue: 0.57)), style: StrokeStyle(lineWidth: 2.1 * scale, lineCap: .round, lineJoin: .round))
    var highlight = context
    highlight.translateBy(x: -0.4 * scale, y: -0.4 * scale)
    highlight.stroke(path, with: .color(Color(red: 0.99, green: 0.96, blue: 0.85)), style: StrokeStyle(lineWidth: 0.9 * scale, lineCap: .round, lineJoin: .round))
}
