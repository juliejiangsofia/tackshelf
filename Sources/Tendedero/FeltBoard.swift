import SwiftUI

/// A shallow, linen-covered pinboard. All fibres and grain are derived from
/// fixed indices so copying or scrolling never changes the material pattern.
@MainActor
struct FeltBoard: View {
    private let frameWidth: CGFloat = 5.5

    var body: some View {
        ZStack {
            // A visible lower edge gives the board a little physical depth.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(red: 0.40, green: 0.28, blue: 0.16))
                .offset(y: 3)

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color(red: 0.75, green: 0.57, blue: 0.35), location: 0),
                            .init(color: Color(red: 0.60, green: 0.42, blue: 0.23), location: 0.48),
                            .init(color: Color(red: 0.78, green: 0.60, blue: 0.37), location: 1),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            woodGrain
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            linen
                .overlay {
                    Rectangle()
                        .strokeBorder(Color(red: 0.28, green: 0.22, blue: 0.15).opacity(0.38), lineWidth: 0.7)
                }
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(LinearGradient(colors: [.black.opacity(0.17), .clear],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(height: 4)
                }
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(LinearGradient(colors: [.black.opacity(0.10), .clear],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: 3)
                }
                .padding(frameWidth)

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.46), .black.opacity(0.16)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
        }
        .shadow(color: Color(red: 0.18, green: 0.12, blue: 0.07).opacity(0.25), radius: 7, x: 1, y: 7)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var linen: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [
                    Color(red: 0.82, green: 0.78, blue: 0.69),
                    Color(red: 0.79, green: 0.74, blue: 0.65),
                    Color(red: 0.83, green: 0.79, blue: 0.70),
                ]),
                startPoint: .zero, endPoint: CGPoint(x: size.width * 0.7, y: size.height)))

            // Warp yarn: a bright crest with a narrow shaded neighbour.
            // The small drift and thickness differences keep it from reading
            // like a perfectly regular digital grid at Retina resolution.
            let warpCount = max(0, Int(size.width / 1.65))
            for i in 0...warpCount {
                let n = Self.noise(i + 17)
                let x = CGFloat(i) * 1.65 + CGFloat(n) * 0.5
                var light = Path()
                var shade = Path()
                for j in 0...5 {
                    let y = size.height * CGFloat(j) / 5
                    let drift = CGFloat(sin(Double(i) * 0.71 + Double(j) * 1.39)) * 0.23
                    let p = CGPoint(x: x + drift, y: y)
                    let q = CGPoint(x: x + drift + 0.55, y: y)
                    if j == 0 { light.move(to: p); shade.move(to: q) }
                    else { light.addLine(to: p); shade.addLine(to: q) }
                }
                context.stroke(light, with: .color(.white.opacity(0.12 + n * 0.12)),
                               lineWidth: 0.46 + CGFloat(n) * 0.25)
                context.stroke(shade, with: .color(Color(red: 0.34, green: 0.28, blue: 0.20).opacity(0.08)),
                               lineWidth: 0.36)
            }

            // Weft yarn sits across the warp with slightly softer contrast.
            let weftCount = max(0, Int(size.height / 1.85))
            for i in 0...weftCount {
                let n = Self.noise(i + 2401)
                let y = CGFloat(i) * 1.85 + CGFloat(n) * 0.6
                var light = Path()
                var shade = Path()
                for j in 0...12 {
                    let x = size.width * CGFloat(j) / 12
                    let drift = CGFloat(sin(Double(i) * 0.51 + Double(j) * 1.87)) * 0.28
                    let p = CGPoint(x: x, y: y + drift)
                    let q = CGPoint(x: x, y: y + drift + 0.65)
                    if j == 0 { light.move(to: p); shade.move(to: q) }
                    else { light.addLine(to: p); shade.addLine(to: q) }
                }
                context.stroke(light, with: .color(.white.opacity(0.10 + n * 0.12)),
                               lineWidth: 0.48 + CGFloat(n) * 0.20)
                context.stroke(shade, with: .color(Color(red: 0.30, green: 0.24, blue: 0.17).opacity(0.08)),
                               lineWidth: 0.38)
            }

            // A few thicker linen fibres and tiny slubs add natural variation.
            // They are intentionally sparse, in the same quiet beige palette.
            let fibreCount = max(0, Int(size.width * size.height / 210))
            for i in 0..<fibreCount {
                let x = CGFloat(Self.noise(i * 5 + 111)) * size.width
                let y = CGFloat(Self.noise(i * 5 + 112)) * size.height
                let length = 1.2 + CGFloat(Self.noise(i * 5 + 113)) * 4.2
                var fibre = Path()
                fibre.move(to: CGPoint(x: x, y: y))
                fibre.addLine(to: CGPoint(x: x + 0.20, y: min(size.height, y + length)))
                let isLight = Self.noise(i * 5 + 114) > 0.48
                context.stroke(fibre, with: .color(isLight ? .white.opacity(0.16) : Color(red: 0.35, green: 0.27, blue: 0.18).opacity(0.12)),
                               lineWidth: 0.5)
            }
        }
    }

    private var woodGrain: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            for i in 0..<10 {
                let n = Self.noise(i + 780)
                let inset = 0.45 + CGFloat(i) * 0.54
                var grain = Path()
                for j in 0...16 {
                    let x = size.width * CGFloat(j) / 16
                    let drift = CGFloat(sin(Double(j) * 0.8 + Double(i))) * 0.24
                    let p = CGPoint(x: x, y: inset + drift)
                    if j == 0 { grain.move(to: p) } else { grain.addLine(to: p) }
                }
                for j in 0...16 {
                    let x = size.width * CGFloat(j) / 16
                    let drift = CGFloat(sin(Double(j) * 0.8 + Double(i))) * 0.24
                    let p = CGPoint(x: x, y: size.height - inset + drift)
                    if j == 0 { grain.move(to: p) } else { grain.addLine(to: p) }
                }
                grain.move(to: CGPoint(x: inset, y: 0))
                grain.addLine(to: CGPoint(x: inset + 0.3, y: size.height))
                grain.move(to: CGPoint(x: size.width - inset, y: 0))
                grain.addLine(to: CGPoint(x: size.width - inset - 0.3, y: size.height))
                context.stroke(grain, with: .color(n > 0.5 ? .white.opacity(0.15) : .black.opacity(0.12)), lineWidth: 0.4)
            }

            // Mitred corners on the thin wooden surround.
            var joints = Path()
            let corners = [
                (CGPoint.zero, CGPoint(x: 5.5, y: 5.5)),
                (CGPoint(x: size.width, y: 0), CGPoint(x: size.width - 5.5, y: 5.5)),
                (CGPoint(x: 0, y: size.height), CGPoint(x: 5.5, y: size.height - 5.5)),
                (CGPoint(x: size.width, y: size.height), CGPoint(x: size.width - 5.5, y: size.height - 5.5)),
            ]
            for (outer, inner) in corners { joints.move(to: outer); joints.addLine(to: inner) }
            context.stroke(joints, with: .color(.black.opacity(0.18)), lineWidth: 0.55)
        }
    }

    /// A fixed integer hash, rather than live randomness in a draw callback.
    private nonisolated static func noise(_ index: Int) -> Double {
        var value = UInt64(truncatingIfNeeded: index) &+ 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Double(value & 0xFFFF) / Double(0xFFFF)
    }
}
