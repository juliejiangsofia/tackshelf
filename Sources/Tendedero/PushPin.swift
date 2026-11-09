import SwiftUI

/// A restrained pastel library. The URL hash makes the choice feel random
/// across cards while keeping every card's colour stable after relaunch.
struct ButtonColour: Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var base: Color { Color(red: red, green: green, blue: blue) }
    var light: Color {
        Color(red: min(1, red + 0.13), green: min(1, green + 0.13), blue: min(1, blue + 0.13))
    }
    var shade: Color {
        Color(red: red * 0.70, green: green * 0.70, blue: blue * 0.70)
    }
}

enum ButtonPalette {
    nonisolated static let colours: [ButtonColour] = [
        .init(red: 0.58, green: 0.72, blue: 0.82), // powder blue
        .init(red: 0.84, green: 0.65, blue: 0.70), // blush pink
        .init(red: 0.88, green: 0.79, blue: 0.56), // butter yellow
        .init(red: 0.65, green: 0.78, blue: 0.69), // soft mint
        .init(red: 0.73, green: 0.68, blue: 0.82), // pale lavender
        .init(red: 0.86, green: 0.70, blue: 0.59)  // muted peach
    ]

    /// FNV-1a is deterministic, unlike Swift's per-process `hashValue`.
    nonisolated static func index(for url: URL) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in url.standardizedFileURL.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(colours.count))
    }

    nonisolated static func colour(at index: Int) -> ButtonColour {
        colours[((index % colours.count) + colours.count) % colours.count]
    }
}

/// Shared dimensions and cached artwork keep the button unchanged as a photo lands.
@MainActor
enum ButtonArtwork {
    nonisolated static let diameter: CGFloat = 18
    nonisolated static let shadowPadding: CGFloat = 10
    private static var images: [Int: CGImage] = [:]

    static func image(at colourIndex: Int) -> CGImage? {
        if let image = images[colourIndex] { return image }
        let renderer = ImageRenderer(
            content: PastelButton(colourIndex: colourIndex).padding(shadowPadding)
        )
        renderer.scale = 3
        let image = renderer.cgImage
        images[colourIndex] = image
        return image
    }
}

/// A small four-hole button with a raised rim and a stitched inner ring.
struct PastelButton: View {
    let colourIndex: Int

    private var colour: ButtonColour { ButtonPalette.colour(at: colourIndex) }

    var body: some View {
        ZStack {
            Circle()
                .fill(colour.shade)
                .frame(width: 17.4, height: 17.4)
                .offset(x: 0.45, y: 1.25)

            Circle()
                .fill(RadialGradient(stops: [
                    .init(color: colour.light, location: 0),
                    .init(color: colour.base, location: 0.52),
                    .init(color: colour.shade, location: 1)
                ], center: UnitPoint(x: 0.30, y: 0.24), startRadius: 0, endRadius: 13))
                .frame(width: 17.4, height: 17.4)
                .overlay {
                    Circle()
                        .strokeBorder(
                            LinearGradient(colors: [Color.white.opacity(0.50),
                                                    colour.shade.opacity(0.76)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 0.75
                        )
                }
                .overlay {
                    Circle()
                        .strokeBorder(colour.shade.opacity(0.48), lineWidth: 0.65)
                        .padding(2.15)
                }

            // A soft thread shadow gives the separate perimeter stitches a
            // little depth without reading as another printed circle.
            Circle()
                .stroke(Color.black.opacity(0.16),
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round,
                                           dash: [1.45, 1.00]))
                .padding(3.0)
                .offset(x: 0.35, y: 0.48)

            Circle()
                .stroke(Color(red: 0.95, green: 0.93, blue: 0.87),
                        style: StrokeStyle(lineWidth: 1.05, lineCap: .round,
                                           dash: [1.45, 1.00]))
                .padding(3.0)
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.40),
                                style: StrokeStyle(lineWidth: 0.30, lineCap: .round,
                                                   dash: [1.45, 1.00]))
                        .padding(3.0)
                        .offset(x: -0.15, y: -0.18)
                }

            ForEach(0..<4, id: \.self) { index in
                let angle = CGFloat(index) * .pi / 2
                let x = cos(angle) * 3.15
                let y = sin(angle) * 3.15
                Circle()
                    .fill(Color(red: 0.96, green: 0.94, blue: 0.88))
                    .frame(width: 3.05, height: 3.05)
                    .overlay(Circle().strokeBorder(colour.shade.opacity(0.56), lineWidth: 0.45))
                    .shadow(color: colour.shade.opacity(0.42), radius: 0.45, x: 0.35, y: 0.45)
                    .offset(x: x, y: y)
            }
        }
        .frame(width: ButtonArtwork.diameter, height: ButtonArtwork.diameter)
        .compositingGroup()
        .shadow(color: .black.opacity(0.16), radius: 0.65, x: 0.5, y: 1.1)
        .shadow(color: Color(red: 0.20, green: 0.16, blue: 0.11).opacity(0.22),
                radius: 2.2, x: 2, y: 2.8)
        .fixedSize()
        .allowsHitTesting(false)
    }
}
