import SwiftUI

/// A warm-white photograph pinned to the fabric board. Its original aspect
/// ratio is preserved, with an even paper margin on all four sides.
@MainActor
struct PeggedView: View {
    let item: Pegged
    @ObservedObject var line: Line

    @State private var arrived = false
    @State private var hovering = false
    @State private var pressingPaper = false

    private var copied: Bool { line.copiedID == item.id }
    private var dragging: Bool { line.draggingID == item.id }
    private var pressed: Bool { line.pressedID == item.id }

    var body: some View {
        VStack(spacing: -Self.cardOffsetBelowTop) {
            PastelButton(colourIndex: ButtonPalette.index(for: item.url))
                .zIndex(1)
            card
        }
        .rotationEffect(.degrees(item.tilt), anchor: .top)
        .scaleEffect(arrived ? 1 : 0.975, anchor: .top)
        .offset(y: arrived ? 0 : 7)
        // The fall itself is drawn over the whole screen by CaptureFlight, so
        // the card here just steps aside at once.
        .opacity(item.falling || item.flying ? 0 : (arrived ? 1 : 0))
        .transaction { t in if item.falling { t.animation = nil } }
        .animation(.easeOut(duration: 0.16), value: item.flying)
        .onAppear(perform: arrive)
        .onChange(of: item.flying) { was, now in if was && !now { pressPaper() } }
        .onChange(of: copied) { _, isCopied in if isCopied { pressPaper() } }
    }

    /// The photo fits inside the card area keeping its proportions, so the
    /// white border hugs it whether the screenshot is wide or tall.
    nonisolated static func photoSize(for size: CGSize) -> CGSize {
        let maxW = Layout.cardWidth - Frame.inset * 2, maxH = Layout.photoMaxHeight
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxW, height: maxH) }
        let scale = min(maxW / size.width, maxH / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// Kept in sync with the SwiftUI paper and the capture-flight layer.
    nonisolated static func cardSize(for size: CGSize) -> CGSize {
        let p = photoSize(for: size)
        return CGSize(width: p.width + Frame.inset * 2,
                      height: p.height + Frame.inset + Frame.bottomInset)
    }

    /// Material cards and photos share the same layout and hit-area calculation.
    nonisolated static func cardSize(for item: Pegged) -> CGSize {
        if let content = item.content { return MaterialCard.size(for: content) }
        return cardSize(for: item.thumb.size)
    }

    /// The discard overlay needs the actual paper, cloth, tag or envelope—not
    /// the simplified drag thumbnail—before the live card leaves the layout.
    static func paperImage(for item: Pegged, scale: CGFloat) -> CGImage? {
        let size = cardSize(for: item)
        let renderer = ImageRenderer(
            content: PaperCard(item: item).frame(width: size.width, height: size.height)
        )
        renderer.scale = scale
        return renderer.cgImage
    }

    /// The pin's centre meets the top edge of the paper.
    nonisolated static let cardOffsetBelowTop: CGFloat = ButtonArtwork.diameter / 2

    private var card: some View {
        PaperCard(item: item)
            .shadow(color: Color(red: 0.27, green: 0.20, blue: 0.13).opacity(0.15), radius: 0.6, x: 0.5, y: 1.1)
            .shadow(color: Color(red: 0.25, green: 0.19, blue: 0.13).opacity(pressed ? 0.13 : 0.22),
                    radius: hovering && !pressed ? 5 : 3, x: hovering && !pressed ? 4 : 2.5,
                    y: hovering && !pressed ? 7 : 4)
            .scaleEffect(pressed || pressingPaper ? 0.985 : (hovering ? 1.012 : 1), anchor: .top)
            .animation(pressed ? .easeInOut(duration: 0.35) : .spring(response: 0.27, dampingFraction: 0.78), value: pressed)
            .opacity(dragging ? 0.45 : 1)
            .overlay(alignment: .topLeading) {
                // Drawn here, clicked through GrabView, which sits on top. A
                // cross sends a file in Tendedero's folder to the Trash; for a
                // file anywhere else it only hides it from the line.
                Image(systemName: line.isInInbox(item.id) ? "xmark" : "eye.slash")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(red: 0.36, green: 0.30, blue: 0.23))
                    .frame(width: 20, height: 20)
                    .background(Color(red: 0.99, green: 0.98, blue: 0.94), in: Circle())
                    .shadow(color: .black.opacity(0.13), radius: 2, x: 1, y: 1)
                    .padding(3)
                    .opacity(hovering && !dragging ? 1 : 0)
                    .scaleEffect(hovering ? 1 : 0.6)
                    .allowsHitTesting(false)
            }
            .overlay(GrabArea(item: item, line: line))
            .overlay(alignment: .bottom) {
                if copied {
                    Label(L("Copied"), systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0.36, green: 0.30, blue: 0.23))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(red: 0.99, green: 0.98, blue: 0.94), in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 3, x: 1, y: 2)
                        .offset(y: 16)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.easeOut(duration: 0.2), value: copied)
            .onHover { hovering = $0 }
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: HitRectsKey.self,
                                           value: item.falling ? [:] : [item.id: g.frame(in: .global)])
                }
            )
    }

    private func arrive() {
        // A capture that flew in is already in place; the flight did the arriving.
        if item.flying {
            arrived = true
            return
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.84)) { arrived = true }
    }

    /// A brief press reads as sticking the photograph onto the board.
    private func pressPaper() {
        withAnimation(.easeOut(duration: 0.09)) { pressingPaper = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.8)) { pressingPaper = false }
        }
    }
}

@MainActor
private struct PaperCard: View {
    let item: Pegged

    private var photoSize: CGSize { PeggedView.photoSize(for: item.thumb.size) }

    var body: some View {
        Group {
            if let content = item.content {
                MaterialCard(content: content)
            } else {
                Image(nsImage: item.thumb)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: photoSize.width, height: photoSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 0.35)
                            .strokeBorder(Color(red: 0.34, green: 0.30, blue: 0.24).opacity(0.17), lineWidth: 0.5)
                    )
                    .overlay {
                        if item.isRecording {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color(red: 0.35, green: 0.30, blue: 0.23))
                                .frame(width: 28, height: 28)
                                .background(Color(white: 0.99).opacity(0.94), in: Circle())
                                .shadow(color: .black.opacity(0.14), radius: 3, x: 1, y: 2)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, Frame.inset)
                    .padding(.top, Frame.inset)
                    .padding(.bottom, Frame.bottomInset)
                    .background(PaperSurface())
                    .overlay(
                        RoundedRectangle(cornerRadius: Frame.radius)
                            .strokeBorder(Color(red: 0.72, green: 0.68, blue: 0.59).opacity(0.32), lineWidth: 0.55)
                    )
            }
        }
    }
}
enum Frame {
    static let radius: CGFloat = 1.4
    static let inset: CGFloat = 9
    static let bottomInset: CGFloat = inset
}

private struct PaperSurface: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Frame.radius)
            .fill(LinearGradient(colors: [Color(red: 1, green: 0.997, blue: 0.978),
                                          Color(red: 0.975, green: 0.969, blue: 0.944)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Canvas { context, size in
                    // Small, fixed fibres keep the paper matte. Their positions
                    // are deterministic so a redraw never makes the texture move.
                    for index in 0..<360 {
                        let x = CGFloat((index * 73 + 19) % 997) / 997 * size.width
                        let y = CGFloat((index * 179 + 41) % 991) / 991 * size.height
                        var fibre = Path()
                        fibre.move(to: CGPoint(x: x, y: y))
                        fibre.addLine(to: CGPoint(x: x + 0.6, y: y + 0.18))
                        context.stroke(fibre, with: .color(Color(red: 0.55, green: 0.49, blue: 0.39).opacity(0.075)),
                                       lineWidth: 0.35)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Frame.radius))
                .allowsHitTesting(false)
            }
    }
}

extension View {
    /// A crisp glass: the system's blurred material with a thin specular
    /// edge, lit from above. No refraction, so the background stays sharp
    /// around the frame instead of bending like gel.
    func glassFrame(cornerRadius: CGFloat = 0, circle: Bool = false, capsule: Bool = false) -> some View {
        let shape: AnyShape = circle ? AnyShape(Circle())
            : capsule ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        return background(.ultraThinMaterial, in: shape)
            .overlay(
                shape.stroke(
                    LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
            )
            .overlay(shape.stroke(Color.black.opacity(0.10), lineWidth: 0.5).padding(-0.5))
    }
}
