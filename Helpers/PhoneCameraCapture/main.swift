// Adapted from ContinuityCapture (https://github.com/techjuicelab/continuity-capture)
// Upstream commit: bd20af2dbc825c1f354dcdcd60642c9d250df670.
// The menu trigger / NSTextView receiver was verified by the local macOS 15.1 lab.
// This worker saves one photograph and a result file. It never changes the clipboard.
//
// MIT License
//
// Copyright (c) 2026 TechJuiceLab
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

struct CaptureResult: Encodable {
    let version = 1
    let requestID: String
    let status: String
    var path: String?
    var message: String?
    var mode: String?
    var available: Bool?
}

struct CaptureConfiguration {
    var outputDirectory = ""
    var resultFile = ""
    var requestID = ""
    var deviceHint = "iPhone"
    var timeout: TimeInterval = 180
    var selfTest = false
    var validationError: String?

    static func parse() -> Self {
        var config = Self()
        let arguments = Array(CommandLine.arguments.dropFirst())
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--self-test" {
                config.selfTest = true
                index += 1
                continue
            }
            guard ["--output-directory", "--result-file", "--request-id", "--device-hint", "--timeout"].contains(argument),
                  index + 1 < arguments.count else {
                config.validationError = "拍照程序的启动参数不完整。"
                index += 1
                continue
            }
            let value = arguments[index + 1]
            switch argument {
            case "--output-directory": config.outputDirectory = value
            case "--result-file": config.resultFile = value
            case "--request-id": config.requestID = value
            case "--device-hint": config.deviceHint = value.trimmingCharacters(in: .whitespacesAndNewlines)
            case "--timeout":
                if let seconds = Double(value), seconds.isFinite, (10...600).contains(seconds) {
                    config.timeout = seconds
                } else {
                    config.validationError = "拍照等待时间须为 10 到 600 秒。"
                }
            default: break
            }
            index += 2
        }
        if !config.outputDirectory.hasPrefix("/") || !config.resultFile.hasPrefix("/") {
            config.validationError = "照片和结果文件需要使用完整的本地路径。"
        }
        if UUID(uuidString: config.requestID) == nil || config.deviceHint.isEmpty {
            config.validationError = "拍照请求或设备名称无效。"
        }
        if !config.outputDirectory.isEmpty {
            config.outputDirectory = URL(fileURLWithPath: config.outputDirectory).standardizedFileURL.path
        }
        if !config.resultFile.isEmpty {
            config.resultFile = URL(fileURLWithPath: config.resultFile).standardizedFileURL.path
        }
        return config
    }
}

enum CaptureFailure: Error {
    case invalidImage
    case imageTooLarge
    case imageConversionFailed
    case fileWriteFailed

    var message: String {
        switch self {
        case .invalidImage: return "手机回传的内容不是可读取的照片。"
        case .imageTooLarge: return "回传的照片过大，请重新拍摄。"
        case .imageConversionFailed: return "照片格式转换失败，请重新拍摄。"
        case .fileWriteFailed: return "照片未能保存到本地，请检查可用空间和文件夹权限。"
        }
    }
}

enum PrivateFiles {
    static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
    }

    // A private temporary file and rename make the final JSON / photograph atomic.
    // O_NOFOLLOW and O_EXCL avoid following an existing temporary-file link.
    static func write(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".capture-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw CaptureFailure.fileWriteFailed }
        var didClose = false
        defer {
            if !didClose { Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: temporary)
        }
        try data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, address.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CaptureFailure.fileWriteFailed }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw CaptureFailure.fileWriteFailed }
        let closeResult = Darwin.close(descriptor)
        didClose = true
        guard closeResult == 0, Darwin.rename(temporary.path, destination.path) == 0 else {
            throw CaptureFailure.fileWriteFailed
        }
    }
}

enum CapturedImage {
    static let maximumBytes = 64 * 1_024 * 1_024
    static let maximumPixels: UInt64 = 80_000_000
    static let maximumDimension = 16_384

    static func prepare(_ data: Data) throws -> (data: Data, fileExtension: String) {
        guard !data.isEmpty else { throw CaptureFailure.invalidImage }
        guard data.count <= maximumBytes else { throw CaptureFailure.imageTooLarge }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source) as String? else {
            throw CaptureFailure.invalidImage
        }
        let primaryIndex = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, primaryIndex, nil) as? [CFString: Any],
              let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw CaptureFailure.invalidImage
        }
        let width = widthNumber.intValue
        let height = heightNumber.intValue
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
              UInt64(width) * UInt64(height) <= maximumPixels else {
            throw CaptureFailure.imageTooLarge
        }
        let isJPEG = type == UTType.jpeg.identifier
        let isPNG = type == UTType.png.identifier
        let isHEIF = UTType(type)?.conforms(to: .heif) == true || type == UTType.heic.identifier
        guard isJPEG || isPNG || isHEIF else { throw CaptureFailure.invalidImage }

        // Decode a small preview even for original JPEG/PNG files, so a valid
        // header alone cannot turn an unreadable attachment into a success.
        let previewOptions = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                              kCGImageSourceCreateThumbnailWithTransform: true,
                              kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary
        guard CGImageSourceCreateThumbnailAtIndex(source, primaryIndex, previewOptions) != nil else {
            throw CaptureFailure.invalidImage
        }
        if isJPEG { return (data, "jpg") }
        if isPNG { return (data, "png") }

        // Transform applies the HEIC orientation before encoding. The output
        // pixels are upright, so no orientation is lost when dropped elsewhere.
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: max(width, height)] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, primaryIndex, options) else {
            throw CaptureFailure.imageConversionFailed
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CaptureFailure.imageConversionFailed
        }
        let destinationProperties = [kCGImageDestinationLossyCompressionQuality: 0.92,
                                     kCGImagePropertyOrientation: 1] as CFDictionary
        CGImageDestinationAddImage(destination, image, destinationProperties)
        guard CGImageDestinationFinalize(destination), output.length <= maximumBytes else {
            throw CaptureFailure.imageConversionFailed
        }
        return (output as Data, "jpg")
    }
}

final class CaptureTextView: NSTextView {
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let returnType,
           NSImage.imageTypes.contains(returnType.rawValue) || returnType.rawValue == "com.adobe.pdf" {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
}

// Continuity Camera needs the receiver in a key window's responder chain.
final class CaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class CaptureDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    let configuration: CaptureConfiguration
    private var receiverWindow: CaptureWindow!
    private var receiver: CaptureTextView!
    private var fileMenu: NSMenu!
    private var invoked = false
    private var finished = false
    private var extracting = false
    private var signalSources: [DispatchSourceSignal] = []
    private var cancellationCheck: DispatchWorkItem?
    private let actionTitles = ["Take Photo", "拍照", "照片拍摄", "拍攝照片", "拍攝相片", "拍攝", "사진 찍기"]

    init(configuration: CaptureConfiguration) {
        self.configuration = configuration
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // AppKit attaches the device submenu to this identifier during launch.
        // Installing it in didFinishLaunching is too late on macOS 15.1.
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "PhoneCameraCapture")
        let quit = NSMenuItem(title: "取消拍照", action: #selector(cancelCapture(_:)), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let fileItem = NSMenuItem()
        fileMenu = NSMenu(title: "File")
        let importItem = NSMenuItem(title: "Import from Device", action: nil, keyEquivalent: "")
        importItem.identifier = NSMenuItem.importFromDeviceIdentifier
        fileMenu.addItem(importItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let error = configuration.validationError {
            finish(status: "error", message: error)
            return
        }
        do {
            try PrivateFiles.createDirectory(URL(fileURLWithPath: configuration.outputDirectory, isDirectory: true))
            try PrivateFiles.createDirectory(URL(fileURLWithPath: configuration.resultFile).deletingLastPathComponent())
            // Check the output location before asking the user to take a photo.
            let probe = URL(fileURLWithPath: configuration.outputDirectory)
                .appendingPathComponent(".probe-\(configuration.requestID)")
            try PrivateFiles.write(Data(), to: probe)
            try FileManager.default.removeItem(at: probe)
        } catch {
            finish(status: "error", message: CaptureFailure.fileWriteFailed.message)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let returnTypes = NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
            + [NSPasteboard.PasteboardType("com.adobe.pdf")]
        NSApp.registerServicesMenuSendTypes([], returnTypes: returnTypes)

        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        receiverWindow = CaptureWindow(contentRect: NSRect(x: screen.midX - 150, y: screen.midY - 60,
                                                           width: 300, height: 120),
                                       styleMask: [.borderless], backing: .buffered, defer: false)
        receiverWindow.isOpaque = false
        receiverWindow.backgroundColor = .clear
        receiverWindow.alphaValue = 0.02
        receiverWindow.level = .floating
        receiver = CaptureTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        receiver.isRichText = true
        receiver.isEditable = true
        receiver.importsGraphics = true
        receiver.allowsImageEditing = false
        receiver.delegate = self
        receiverWindow.contentView = receiver
        receiverWindow.makeKeyAndOrderFront(nil)
        receiverWindow.makeFirstResponder(receiver)

        NotificationCenter.default.addObserver(self, selector: #selector(textStorageDidChange(_:)),
                                               name: NSTextStorage.didProcessEditingNotification,
                                               object: receiver.textStorage)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(popoverDidClose(_:)),
                                               name: NSPopover.didCloseNotification, object: nil)
        installSignalHandlers()
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.timeout) { [weak self] in
            self?.finish(status: "timeout", message: "等待手机拍照超时，请重新尝试。")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.probeAndTrigger(attempt: 1)
        }
    }

    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                self?.finish(status: "cancelled", message: "已取消拍照。")
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // The system submenu is expanded without showing a menu. Only the requested
    // device section is eligible: there is deliberately no fallback to an iPad.
    private func probeAndTrigger(attempt: Int) {
        guard !finished, !invoked else { return }
        receiverWindow.makeKeyAndOrderFront(nil)
        receiverWindow.makeFirstResponder(receiver)
        // Match the verified lab's Services path: use NSApplication's live
        // File menu and update only its already attached device submenu.
        if let liveFileMenu = NSApp.mainMenu?.item(at: 1)?.submenu,
           let submenu = liveFileMenu.items.first(where: { $0.submenu != nil })?.submenu {
            submenu.update()
            if let index = submenu.items.indices.first(where: {
                let item = submenu.items[$0]
                return !item.isSeparatorItem && item.isEnabled && actionTitles.contains(item.title)
                    && sectionMatchesDevice(owner: submenu, index: $0)
            }) {
                if configuration.selfTest {
                    finish(status: "ready", message: "已找到可用的 iPhone 拍照入口；自检没有启动相机。", available: true)
                } else {
                    invoked = true
                    submenu.performActionForItem(at: index)
                }
                return
            }
        }
        if attempt < 25 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.probeAndTrigger(attempt: attempt + 1)
            }
        } else {
            finish(status: "unavailable", message: "暂未找到这部 iPhone 的拍照入口，请确认手机在附近、两端 Wi-Fi 和蓝牙已开启，并登录同一 Apple 账户。", available: configuration.selfTest ? false : nil)
        }
    }

    private func sectionMatchesDevice(owner: NSMenu, index: Int) -> Bool {
        guard index > 0 else { return false }
        var preceding = index - 1
        while preceding >= 0 {
            let item = owner.items[preceding]
            if item.isSeparatorItem { return false }
            if item.title.localizedCaseInsensitiveContains(configuration.deviceHint) { return true }
            preceding -= 1
        }
        return false
    }

    @objc private func textStorageDidChange(_ notification: Notification) {
        guard invoked, !finished, !extracting else { return }
        // Do not read / change the text storage during its own editing pass.
        DispatchQueue.main.async { [weak self] in self?.extractPhotograph() }
    }

    private func extractPhotograph() {
        guard !finished, !extracting, let storage = receiver?.textStorage, storage.length > 0 else { return }
        var attachmentData: Data?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let attachment = value as? NSTextAttachment else { return }
            if let wrapper = attachment.fileWrapper, wrapper.isRegularFile {
                attachmentData = wrapper.regularFileContents
            } else {
                attachmentData = attachment.contents
            }
            if attachmentData != nil { stop.pointee = true }
        }
        guard let data = attachmentData else { return }
        extracting = true
        cancellationCheck?.cancel()
        do {
            let prepared = try CapturedImage.prepare(data)
            let file = URL(fileURLWithPath: configuration.outputDirectory, isDirectory: true)
                .appendingPathComponent("iPhone-\(configuration.requestID).\(prepared.fileExtension)")
            try PrivateFiles.write(prepared.data, to: file)
            finish(status: "success", path: file.path)
        } catch let error as CaptureFailure {
            finish(status: "error", message: error.message)
        } catch {
            finish(status: "error", message: CaptureFailure.fileWriteFailed.message)
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window !== receiverWindow else { return }
        scheduleCancellationCheck()
    }

    @objc private func popoverDidClose(_ notification: Notification) {
        scheduleCancellationCheck()
    }

    private func scheduleCancellationCheck() {
        guard invoked, !finished, !extracting else { return }
        cancellationCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self, !self.finished, !self.extracting else { return }
            // AppKit sometimes closes the waiting panel just before delivering
            // its attachment. Allow that delivery before deciding it was cancel.
            self.extractPhotograph()
            if !self.finished && !self.extracting {
                // A replacement system panel may appear during connection.
                // Its later close or the deadline will finish this request.
                guard !NSApp.windows.contains(where: { $0 !== self.receiverWindow && $0.isVisible }) else { return }
                self.finish(status: "cancelled", message: "已取消拍照。")
            }
        }
        cancellationCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: check)
    }

    @objc private func cancelCapture(_ sender: Any?) {
        finish(status: "cancelled", message: "已取消拍照。")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !finished { finish(status: "cancelled", message: "已取消拍照。", terminate: false) }
        return .terminateNow
    }

    private func finish(status: String, path: String? = nil, message: String? = nil,
                        available: Bool? = nil, terminate: Bool = true) {
        guard !finished else { return }
        finished = true
        cancellationCheck?.cancel()
        let result = CaptureResult(requestID: configuration.requestID, status: status,
                                   path: path, message: message,
                                   mode: configuration.selfTest ? "self-test" : nil, available: available)
        do {
            guard configuration.resultFile.hasPrefix("/") else { throw CaptureFailure.fileWriteFailed }
            let resultURL = URL(fileURLWithPath: configuration.resultFile)
            try PrivateFiles.createDirectory(resultURL.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try PrivateFiles.write(try encoder.encode(result), to: resultURL)
        } catch {
            let message = "PhoneCameraCapture: 无法写入拍照结果文件。\n"
            FileHandle.standardError.write(Data(message.utf8))
            // A missing result is a failure; callers must never treat exit 0 as
            // success. A nonzero exit also covers an unwritable result location.
            Darwin.exit(74)
        }
        if terminate { NSApp.terminate(nil) }
    }
}

let configuration = CaptureConfiguration.parse()
let application = NSApplication.shared
let delegate = CaptureDelegate(configuration: configuration)
application.delegate = delegate
application.run()
