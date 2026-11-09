import AppKit
import Combine
import ImageIO

/// Runs the native camera importer in its own AppKit process. The nonactivating
/// shelf keeps its focus behavior; only a confirmed, newly received photo is
/// moved from this request's private staging folder into the shelf's storage.
@MainActor
final class PhoneCameraCapture: ObservableObject {
    static func isLaunchURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "feltboard-preview"
            && url.host?.lowercased() == "camera"
            && (url.path.isEmpty || url.path == "/")
            && url.user == nil && url.password == nil && url.port == nil
            && url.query == nil && url.fragment == nil
    }

    @Published private(set) var isCapturing = false
    @Published private(set) var statusText: String?
    @Published private(set) var recoveryFolder: URL?
    var onPhoto: ((URL) -> Void)?

    struct Reply: Decodable {
        let version: Int
        let requestID: String
        let status: String
        let path: String?
        let message: String?
    }

    private struct Request {
        let id: UUID
        let directory: URL
        let staging: URL
        let result: URL
        let started: Date
    }

    private let outputFolder: URL
    private let helperURL: URL
    private let pasteboard: NSPasteboard
    private var request: Request?
    private var runningHelper: NSRunningApplication?
    private var launching = false
    private var pollTimer: Timer?
    private var messageID = UUID()

    init(outputFolder: URL = Inbox.folder, helperURL: URL? = nil, pasteboard: NSPasteboard = .general) {
        self.outputFolder = outputFolder
        self.pasteboard = pasteboard
        self.helperURL = helperURL ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/PhoneCameraCapture.app", isDirectory: true)
    }

    func takePhoto() {
        guard !isCapturing else { return }
        guard FileManager.default.fileExists(atPath: helperURL.appendingPathComponent("Contents/MacOS/PhoneCameraCapture").path) else {
            showMessage("拍照组件未安装，请重新构建布贴板")
            return
        }

        let id = UUID()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FeltboardPreview/CameraRequests", isDirectory: true)
        let directory = base.appendingPathComponent(id.uuidString, isDirectory: true)
        let staging = directory.appendingPathComponent("Photo", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            showMessage("无法准备照片保存位置，请稍后重试")
            return
        }

        let job = Request(id: id, directory: directory, staging: staging,
                          result: directory.appendingPathComponent("result.json"), started: Date())
        request = job
        launching = true
        isCapturing = true
        statusText = "请在 iPhone 拍照，再点“使用照片”"
        messageID = UUID()

        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        launch(job)
    }

    private func launch(_ job: Request) {
        guard request?.id == job.id else { return }
        let id = job.id
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: "local.feltboard.preview.phonecamera")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = [
            "--output-directory", job.staging.path,
            "--result-file", job.result.path,
            "--request-id", id.uuidString,
            "--device-hint", "iPhone", "--timeout", "180",
        ]
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.async {
                guard let self else { app?.terminate(); return }
                guard self.request?.id == id else { app?.terminate(); return }
                self.launching = false
                if error != nil || app == nil {
                    self.finish(message: "无法启动 iPhone 拍照，请重试")
                } else {
                    self.runningHelper = app
                    if let app {
                        NSApp.yieldActivation(to: app)
                        app.activate(options: [])
                    }
                    self.poll()
                }
            }
        }

    }

    func cancelCapture() {
        guard isCapturing else { return }
        // A confirmation that has already arrived wins over a nearly
        // simultaneous click on Cancel, so a received photo is not lost.
        if receiveResultIfReady() { return }
        finish(message: "已取消拍照")
    }

    func revealRecoveredPhoto() {
        if let recoveryFolder { NSWorkspace.shared.open(recoveryFolder) }
    }

    private func poll() {
        guard let job = request else { return }
        if receiveResultIfReady() { return }
        if Date().timeIntervalSince(job.started) > 190 {
            finish(message: "等待拍照超时，请点击相机重试")
        } else if !launching, runningHelper?.isTerminated == true {
            // Atomic result publication happens before the helper exits.
            finish(message: "拍照已结束，没有收到照片")
        }
    }

    @discardableResult
    private func receiveResultIfReady() -> Bool {
        guard let job = request, FileManager.default.fileExists(atPath: job.result.path) else { return false }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: job.result.path)
            guard let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 16_384 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let reply = try JSONDecoder().decode(Reply.self, from: Data(contentsOf: job.result))
            guard reply.version == 1, reply.requestID == job.id.uuidString else {
                throw CocoaError(.fileReadCorruptFile)
            }
            switch reply.status {
            case "success":
                guard let path = reply.path else { throw CocoaError(.fileReadCorruptFile) }
                let saved = try Self.importPhoto(from: URL(fileURLWithPath: path),
                                                 staging: job.staging, destination: outputFolder,
                                                 requestID: job.id)
                let copied = Self.copyPhoto(saved, to: pasteboard)
                finish(message: copied ? "照片已复制，可 ⌘V 粘贴" : "照片已贴上，但未能复制到剪贴板",
                       photo: saved)
            case "cancelled": finish(message: "已取消拍照")
            case "unavailable": finish(message: "未找到可用 iPhone，请检查附近设备的 Wi‑Fi 和蓝牙")
            case "timeout": finish(message: "等待拍照超时，请点击相机重试")
            default: finish(message: "拍照未完成，请点击相机重试")
            }
        } catch {
            finish(message: "照片接收失败，请点击相机重试")
        }
        return true
    }

    /// Validate the process boundary and keep the final photo in the same
    /// owned directory as other captures, so ten-item retention still applies.
    static func importPhoto(from source: URL, staging: URL, destination: URL, requestID: UUID) throws -> URL {
        let fm = FileManager.default
        let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
        let canonicalStaging = staging.resolvingSymlinksInPath().standardizedFileURL
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              canonicalSource.deletingLastPathComponent() == canonicalStaging,
              let bytes = values.fileSize, bytes > 0, bytes <= 64 * 1024 * 1024,
              let image = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetStatus(image) == .statusComplete,
              let metadata = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = metadata[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = metadata[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 80_000_000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let ext = source.pathExtension.lowercased()
        guard ["jpg", "jpeg", "png", "heic"].contains(ext) else { throw CocoaError(.fileReadUnknownStringEncoding) }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let name = "Phone \(requestID.uuidString).\(ext)"
        let target = destination.appendingPathComponent(name)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        try fm.moveItem(at: source, to: target)
        return target
    }

    /// Publish actual image bytes for image editors and web-based composers.
    /// Bake in camera orientation, and prepare every representation before
    /// replacing the clipboard. The owner marker prevents a second shelf card.
    static func copyPhoto(_ url: URL, to pasteboard: NSPasteboard) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0,
              width.doubleValue * height.doubleValue <= 80_000_000 else { return false }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: max(width.intValue, height.intValue)] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return false }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]),
              let tiff = bitmap.representation(using: .tiff, properties: [:]) else { return false }
        let item = NSPasteboardItem()
        guard item.setData(png, forType: .png), item.setData(tiff, forType: .tiff),
              item.setString("1", forType: .init("local.feltboard.clipboard-owner")) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    private func finish(message: String, photo: URL? = nil) {
        guard let job = request else { return }
        request = nil
        pollTimer?.invalidate()
        pollTimer = nil
        launching = false
        let helper = runningHelper
        runningHelper = nil
        if let helper, !helper.isTerminated {
            helper.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if !helper.isTerminated { helper.forceTerminate() }
            }
        }
        isCapturing = false
        let retained = photo == nil && Self.hasReceivedPhoto(in: job.staging)
        if retained {
            recoveryFolder = job.staging
            showMessage("照片已收到但未能贴上，可点“查看照片”")
        } else {
            showMessage(message)
        }
        if let photo { onPhoto?(photo) }
        // Give a terminating helper time to stop before removing only its
        // private request directory, including any unconfirmed staging file.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            // A photo confirmed on the phone must survive a failed move or
            // result publication, including one delivered while cancelling.
            if Self.hasReceivedPhoto(in: job.staging) {
                self?.recoveryFolder = job.staging
                if self?.isCapturing == false {
                    self?.showMessage("已收到的照片已保留，可点“查看照片”")
                }
            } else {
                try? FileManager.default.removeItem(at: job.directory)
            }
        }
    }

    private static func hasReceivedPhoto(in directory: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: .skipsHiddenFiles)) ?? []
        return files.contains { file in
            guard ["jpg", "jpeg", "png", "heic"].contains(file.pathExtension.lowercased()),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? 0) > 0
        }
    }

    private func showMessage(_ message: String) {
        let token = UUID()
        messageID = token
        statusText = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.messageID == token, !self.isCapturing else { return }
            self.statusText = nil
        }
    }
}
