import SwiftUI

/// A small camera resting on the felt, in its own space beside the cards.
@MainActor
struct PhoneCameraButton: View {
    @ObservedObject var camera: PhoneCameraCapture

    private let ink = Color(red: 0.36, green: 0.30, blue: 0.23)

    var body: some View {
        ZStack {
            Button(action: camera.takePhoto) {
                CameraArtwork()
                    .contentShape(Rectangle())
            }
            .buttonStyle(CameraPressStyle())
            .disabled(camera.isCapturing)
            .accessibilityLabel(camera.isCapturing ? "正在等待手机拍照" : "用 iPhone 拍照")

            if camera.isCapturing {
                ProgressView()
                    .controlSize(.mini)
                    .tint(ink)
                    .padding(5)
                    .background(Color(red: 0.98, green: 0.96, blue: 0.90), in: Circle())
                    .offset(x: -32, y: 23)
                    .accessibilityLabel("等待照片")

                Button(action: camera.cancelCapture) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 21, height: 21)
                        .background(Color(red: 0.98, green: 0.96, blue: 0.90), in: Circle())
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .help("取消手机拍照")
                .accessibilityLabel("取消手机拍照")
                .offset(x: 35, y: -24)
            } else if camera.recoveryFolder != nil {
                Button(action: camera.revealRecoveredPhoto) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .frame(width: 23, height: 23)
                        .background(Color(red: 0.98, green: 0.96, blue: 0.90), in: Circle())
                }
                .buttonStyle(.plain)
                .help("查看已收到的照片")
                .accessibilityLabel("查看已收到的照片")
                .offset(x: 35, y: -24)
            } else if let status = camera.statusText, !status.isEmpty {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 15))
                    .background(Color(red: 0.98, green: 0.96, blue: 0.90), in: Circle())
                    .help(status)
                    .accessibilityLabel(status)
                    .offset(x: 35, y: -24)
            }
        }
        .foregroundStyle(ink)
        .frame(width: 94, height: 74)
        .help(camera.statusText ?? "用 iPhone 拍照，确认后贴到板上并复制，可用 ⌘V 粘贴")
        .animation(.easeInOut(duration: 0.18), value: camera.isCapturing)
    }
}

private struct CameraPressStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let lifted = hovering && isEnabled && !configuration.isPressed
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : (lifted ? 1.06 : 1))
            .offset(y: configuration.isPressed ? 1 : (lifted ? -3 : 0))
            .shadow(color: Color(red: 0.23, green: 0.17, blue: 0.11).opacity(lifted ? 0.36 : 0.22),
                    radius: configuration.isPressed ? 1.5 : (lifted ? 6 : 2.5),
                    x: lifted ? 2 : 1, y: configuration.isPressed ? 1 : (lifted ? 7 : 3))
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.23, dampingFraction: 0.75), value: configuration.isPressed)
            .animation(.spring(response: 0.25, dampingFraction: 0.76), value: lifted)
    }
}

/// The user's instant camera, cut out with alpha and bundled with the app.
private struct CameraArtwork: View {
    private static let image = Bundle.main.url(forResource: "InstantCamera", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(CameraSilhouette())
            } else {
                Image(systemName: "camera.fill")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 86, height: 72)
        .accessibilityHidden(true)
    }
}

/// A clean display outline for the bundled cutout. The source PNG stays
/// unchanged; this prevents tiny matte remnants from catching the hover shadow.
private struct CameraSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 170, y: 100))
        p.addLine(to: CGPoint(x: 1170, y: 100))
        p.addQuadCurve(to: CGPoint(x: 1235, y: 170), control: CGPoint(x: 1235, y: 100))
        p.addLine(to: CGPoint(x: 1235, y: 716))
        p.addQuadCurve(to: CGPoint(x: 1255, y: 738), control: CGPoint(x: 1235, y: 734))
        p.addQuadCurve(to: CGPoint(x: 1270, y: 763), control: CGPoint(x: 1270, y: 740))
        p.addLine(to: CGPoint(x: 1270, y: 1060))
        p.addQuadCurve(to: CGPoint(x: 1220, y: 1100), control: CGPoint(x: 1270, y: 1100))
        p.addLine(to: CGPoint(x: 115, y: 1100))
        p.addQuadCurve(to: CGPoint(x: 70, y: 1060), control: CGPoint(x: 70, y: 1100))
        p.addLine(to: CGPoint(x: 70, y: 763))
        p.addQuadCurve(to: CGPoint(x: 88, y: 738), control: CGPoint(x: 70, y: 740))
        p.addQuadCurve(to: CGPoint(x: 103, y: 716), control: CGPoint(x: 103, y: 734))
        p.addLine(to: CGPoint(x: 103, y: 170))
        p.addQuadCurve(to: CGPoint(x: 170, y: 100), control: CGPoint(x: 103, y: 100))
        p.closeSubpath()
        return p.applying(CGAffineTransform(scaleX: rect.width / 1341, y: rect.height / 1173))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
