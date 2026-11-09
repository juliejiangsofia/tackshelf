import SwiftUI

enum Layout {
    /// Photo size from the menu bar. The wood frame and buttons keep their size;
    /// photos and the room they take grow or shrink together.
    enum Size: String, CaseIterable {
        case small, medium, large

        nonisolated var scale: CGFloat {
            switch self {
            case .small: 0.8
            case .medium: 1
            case .large: 1.35
            }
        }
    }

    nonisolated static var size: Size {
        get { Size(rawValue: UserDefaults.standard.string(forKey: "lineSize") ?? "") ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "lineSize") }
    }

    nonisolated static var photoMaxHeight: CGFloat { (136 * size.scale).rounded() }
    nonisolated static var cardWidth: CGFloat { (172 * size.scale).rounded() }
    nonisolated static let cardGap: CGFloat = 20
    nonisolated static let rowGap: CGFloat = 30
    nonisolated static let sideInset: CGFloat = 40
    nonisolated static let headerHeight: CGFloat = 40
    nonisolated static let bottomInset: CGFloat = 42
    nonisolated static let shadowInset: CGFloat = 12

    /// A compact, centred board. Smaller displays keep the same 3:2 shape.
    nonisolated static func panelSize(available: CGSize) -> CGSize {
        let width = min(840, max(0, available.width - 32), max(0, available.height - 20) * 1.5)
        return CGSize(width: width, height: width / 1.5)
    }

    /// Cards fill the board, including the space beside the floating camera.
    nonisolated static func cardViewport(for size: CGSize) -> CGRect {
        CGRect(x: sideInset, y: headerHeight,
               width: max(0, size.width - sideInset * 2),
               height: max(0, size.height - headerHeight - bottomInset))
    }

    nonisolated static func cameraFrame(for size: CGSize) -> CGRect {
        CGRect(x: size.width - 134, y: size.height - 100, width: 94, height: 74)
    }

    /// Paper frames use top-origin panel coordinates. Newer items read from
    /// left to right, then wrap naturally without stretching the gaps.
    @MainActor
    static func frames(items: [Pegged], width: CGFloat) -> [UUID: CGRect] {
        let availableWidth = max(0, width - sideInset * 2)
        var result: [UUID: CGRect] = [:]
        var x = sideInset
        var rowTop = headerHeight
        var rowHeight: CGFloat = 0
        for item in items.reversed() where !item.falling {
            let size = PeggedView.cardSize(for: item)
            if x > sideInset && x + size.width > sideInset + availableWidth {
                x = sideInset
                rowTop += rowHeight + rowGap
                rowHeight = 0
            }
            result[item.id] = CGRect(x: x, y: rowTop + PeggedView.cardOffsetBelowTop,
                                     width: size.width, height: size.height)
            x += size.width + cardGap
            rowHeight = max(rowHeight, size.height + PeggedView.cardOffsetBelowTop)
        }
        return result
    }

    @MainActor
    static func contentHeight(items: [Pegged], width: CGFloat) -> CGFloat {
        guard let bottom = frames(items: items, width: width).values.map(\.maxY).max() else { return 0 }
        return bottom - headerHeight + shadowInset
    }

    @MainActor
    static func maximumScroll(items: [Pegged], width: CGFloat, height: CGFloat) -> CGFloat {
        let size = CGSize(width: width, height: height)
        let viewport = cardViewport(for: size)
        let camera = cameraFrame(for: size)
        let papers = frames(items: items, width: width).values
        guard let bottom = papers.map(\.maxY).max() else { return 0 }
        let normalScroll = max(0, bottom + shadowInset - viewport.maxY)
        // Only cards in the camera's column need extra travel. This lets the
        // oldest paper scroll above the button without reserving a footer.
        let cameraScroll = papers
            .filter { $0.maxX > camera.minX && $0.minX < camera.maxX }
            .map { $0.maxY + shadowInset - camera.minY }
            .max() ?? 0
        return max(normalScroll, cameraScroll)
    }

    @MainActor
    static func frame(for id: UUID, items: [Pegged], width: CGFloat, height: CGFloat,
                      scroll: CGFloat) -> CGRect? {
        guard let frame = frames(items: items, width: width)[id] else { return nil }
        let offset = min(maximumScroll(items: items, width: width, height: height), max(0, scroll))
        return frame.offsetBy(dx: 0, dy: -offset)
    }
}

@MainActor
struct LineView: View {
    @ObservedObject var line: Line
    @ObservedObject var camera: PhoneCameraCapture

    private let ink = Color(red: 0.36, green: 0.31, blue: 0.24)

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let viewport = Layout.cardViewport(for: geo.size)
            let cameraFrame = Layout.cameraFrame(for: geo.size)
            // Small paint bleed keeps tilted paper edges and button shadows intact.
            let clipViewport = viewport.insetBy(dx: -8, dy: -8)
            let maximumScroll = Layout.maximumScroll(items: line.items, width: width, height: height)
            let scroll = min(maximumScroll, max(0, line.scroll))
            let frames = Layout.frames(items: line.items, width: width)
            ZStack(alignment: .topLeading) {
                FeltBoard()
                    .frame(width: max(0, width - 28), height: max(0, height - 23))
                    .offset(x: 14, y: 4)

                if line.liveCount == 0 {
                    Hint()
                        .frame(maxWidth: viewport.width)
                        .position(x: viewport.midX, y: viewport.midY)
                        .transition(.opacity)
                }

                ZStack(alignment: .topLeading) {
                    ForEach(line.items) { item in
                        if let paper = frames[item.id] {
                            let itemHeight = paper.height + PeggedView.cardOffsetBelowTop
                            PeggedView(item: item, line: line)
                                .frame(width: paper.width, height: itemHeight, alignment: .top)
                                .position(x: paper.midX - clipViewport.minX,
                                          y: paper.minY - clipViewport.minY - scroll
                                            - PeggedView.cardOffsetBelowTop + itemHeight / 2)
                        }
                    }
                }
                .frame(width: clipViewport.width, height: clipViewport.height, alignment: .topLeading)
                .clipped()
                .offset(x: clipViewport.minX, y: clipViewport.minY)

                PhoneCameraButton(camera: camera)
                    .frame(width: cameraFrame.width, height: cameraFrame.height)
                    .background {
                        GeometryReader { cameraGeo in
                            Color.clear.preference(key: CameraHitRectKey.self,
                                                   value: cameraGeo.frame(in: .global))
                        }
                    }
                    .offset(x: cameraFrame.minX, y: cameraFrame.minY)

                if maximumScroll > 0, viewport.height > 0 {
                    let thumbHeight = min(viewport.height,
                                          max(28, viewport.height * viewport.height / (viewport.height + maximumScroll)))
                    let thumbTop = (viewport.height - thumbHeight) * scroll / maximumScroll
                    Capsule()
                        .fill(ink.opacity(0.10))
                        .frame(width: 3, height: viewport.height)
                        .overlay(alignment: .top) {
                            Capsule()
                                .fill(ink.opacity(0.42))
                                .frame(width: 3, height: thumbHeight)
                                .offset(y: thumbTop)
                        }
                        .offset(x: width - 29, y: viewport.minY)
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: line.items.map(\.id))
            .animation(.easeInOut(duration: 0.3), value: line.liveCount == 0)
            // Tucked away, the whole board waits above the top edge and
            // slides out from under the menu bar like an auto-hiding Dock.
            .offset(y: line.revealed ? 0 : -(height + 12))
            .animation(line.revealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                     : .easeIn(duration: 0.22), value: line.revealed)
            .onPreferenceChange(HitRectsKey.self) { rects in
                let origin = geo.frame(in: .global).origin
                let bounds = clipViewport.offsetBy(dx: origin.x, dy: origin.y)
                line.hitRects = rects.reduce(into: [:]) { visible, entry in
                    let clipped = entry.value.intersection(bounds)
                    if !clipped.isNull && !clipped.isEmpty { visible[entry.key] = clipped }
                }
            }
        }
        .onPreferenceChange(CameraHitRectKey.self) { rect in
            line.cameraHitRect = rect
        }
    }
}

@MainActor
private struct Hint: View {
    var body: some View {
        Text("复制图片、文字、网址或文件，就会贴在这里")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color(red: 0.36, green: 0.31, blue: 0.24))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color(red: 0.96, green: 0.94, blue: 0.88).opacity(0.82),
                        in: RoundedRectangle(cornerRadius: 2))
            .shadow(color: .black.opacity(0.10), radius: 3, x: 1, y: 2)
    }
}

struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct CameraHitRectKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() { value = next }
    }
}
