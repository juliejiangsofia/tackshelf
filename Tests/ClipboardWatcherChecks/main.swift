import AppKit
import ImageIO

// These checks use an isolated named pasteboard and temporary output folders.
// They never access NSPasteboard.general, change preferences, or start the app.
private let remoteType = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
private let jpegType = NSPasteboard.PasteboardType("public.jpeg")

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(description: message) }
}

@MainActor
private func spin(for interval: TimeInterval) {
    let deadline = Date().addingTimeInterval(interval)
    while Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
    }
}

@MainActor
private func waitFor(_ description: String, timeout: TimeInterval = 2,
                     _ predicate: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline { spin(for: 0.01) }
    try require(predicate(), "Timed out: \(description)")
}

private func image(_ color: (UInt8, UInt8, UInt8), format: NSBitmapImageRep.FileType = .png) throws -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 11, pixelsHigh: 7,
                                     bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 33, bitsPerPixel: 24),
          let bytes = rep.bitmapData else {
        throw CheckFailure(description: "Could not create test image")
    }
    for pixel in 0..<(11 * 7) {
        bytes[pixel * 3] = color.0
        bytes[pixel * 3 + 1] = color.1
        bytes[pixel * 3 + 2] = color.2
    }
    guard let data = rep.representation(using: format, properties: [:]) else {
        throw CheckFailure(description: "Could not encode test image")
    }
    return data
}

private func rotatedJPEG() throws -> Data {
    let jpeg = try image((90, 170, 40), format: .jpeg)
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else {
        throw CheckFailure(description: "Could not read orientation fixture")
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
        throw CheckFailure(description: "Could not create orientation fixture")
    }
    CGImageDestinationAddImageFromSource(destination, source, 0,
                                        [kCGImagePropertyOrientation: 6] as CFDictionary)
    try require(CGImageDestinationFinalize(destination), "Could not finish orientation fixture")
    return output as Data
}

// An 81-megapixel one-bit PNG is valid but takes only ~10 MiB to build.
// This catches decompression-size regressions independently of the byte limit.
private func imageBeyondPixelLimit() throws -> Data {
    let width = 9000
    let height = 9000
    let rowBytes = (width + 7) / 8
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                     bitsPerSample: 1, samplesPerPixel: 1, hasAlpha: false,
                                     isPlanar: false, colorSpaceName: .deviceWhite,
                                     bytesPerRow: rowBytes, bitsPerPixel: 1),
          let bytes = rep.bitmapData else {
        throw CheckFailure(description: "Could not create pixel-limit fixture")
    }
    memset(bytes, 0, rowBytes * height)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw CheckFailure(description: "Could not encode pixel-limit fixture")
    }
    return png
}

@MainActor
private final class Fixture {
    final class Received {
        var events: [ImportedContent] = []
        var urls: [URL] { events.map(\.url) }
    }
    let pasteboard = NSPasteboard(name: .init("local.feltboard.clipboard-checks.\(UUID().uuidString)"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FeltboardClipboardChecks-\(UUID().uuidString)", isDirectory: true)
    let received = Received()
    let watcher: ClipboardWatcher
    var output: URL { root.appendingPathComponent("output", isDirectory: true) }

    init() throws {
        let output = root.appendingPathComponent("output", isDirectory: true)
        watcher = ClipboardWatcher(pasteboard: pasteboard, outputFolder: output,
                                   retryDelays: [0.04, 0.06, 0.1, 0.14], onContent: { [received] in
            received.events.append($0)
        })
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func close() {
        watcher.stop()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func copy(data: [NSPasteboard.PasteboardType: Data] = [:],
              strings: [NSPasteboard.PasteboardType: String] = [:]) throws -> Int {
        let item = NSPasteboardItem()
        for (type, value) in data { try require(item.setData(value, forType: type), "Failed to set \(type.rawValue)") }
        for (type, value) in strings { try require(item.setString(value, forType: type), "Failed to set \(type.rawValue)") }
        pasteboard.clearContents()
        try require(pasteboard.writeObjects([item]), "Could not write isolated pasteboard")
        return pasteboard.changeCount
    }

    @discardableResult
    func copyFile(_ url: URL, remote: Bool, extraData: [NSPasteboard.PasteboardType: Data] = [:]) throws -> Int {
        var strings: [NSPasteboard.PasteboardType: String] = [.fileURL: url.absoluteString]
        if remote { strings[remoteType] = "1" }
        return try copy(data: extraData, strings: strings)
    }

    @discardableResult
    func copyFiles(_ urls: [URL], remote: Bool = false,
                   preview: Data? = nil) throws -> Int {
        let items = try urls.enumerated().map { index, url in
            let item = NSPasteboardItem()
            try require(item.setString(url.absoluteString, forType: .fileURL), "Could not set file URL")
            if remote { try require(item.setString("1", forType: remoteType), "Could not set remote marker") }
            if index == 0, let preview {
                try require(item.setData(preview, forType: .png), "Could not set file preview")
            }
            return item
        }
        pasteboard.clearContents()
        try require(pasteboard.writeObjects(items), "Could not write isolated file batch")
        return pasteboard.changeCount
    }

    func savedFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: output.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
    }

    func requireNoImport(_ reason: String) throws {
        spin(for: 0.6)
        try require(received.urls.isEmpty, reason)
        try require(try savedFiles().isEmpty, "Rejected clipboard left an output file")
    }

    func requirePNG(_ url: URL, dimensions: (Int, Int) = (11, 7)) throws {
        let data = try Data(contentsOf: url)
        try require(data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), "Saved file is not PNG")
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw CheckFailure(description: "Saved image cannot be read")
        }
        try require(properties[kCGImagePropertyPixelWidth] as? Int == dimensions.0, "Wrong saved width")
        try require(properties[kCGImagePropertyPixelHeight] as? Int == dimensions.1, "Wrong saved height")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        try require(mode?.intValue == 0o600, "Saved clipboard image is not private (0600)")
    }

    func requireContent(_ url: URL, kind: ClipboardContent.Kind) throws -> ClipboardContent {
        guard let content = ClipboardContent.load(from: url) else {
            throw CheckFailure(description: "Saved entry cannot be decoded as clipboard content")
        }
        try require(content.kind == kind, "Expected \(kind), got \(content.kind)")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        try require(mode?.intValue == 0o600, "Saved clipboard metadata is not private (0600)")
        return content
    }
}

@MainActor
private func runChecks() -> Int32 {
    var failures = 0
    var count = 0
    func check(_ name: String, _ body: (Fixture) throws -> Void) {
        count += 1
        do {
            let fixture = try Fixture()
            defer { fixture.close() }
            try body(fixture)
            print("PASS \(name)")
        } catch {
            failures += 1
            fputs("FAIL \(name): \(error)\n", stderr)
        }
    }

    check("PNG is saved once with private permissions") { f in
        let png = try image((30, 120, 210))
        try f.copy(data: [.png: png])
        f.watcher.requestImport()
        try waitFor("PNG import") { f.received.urls.count == 1 }
        try f.requirePNG(f.received.urls[0])
        try require(try Data(contentsOf: f.received.urls[0]) == png, "PNG bytes were changed")
        try require(try f.savedFiles().count == 1, "Unexpected additional output files")
        try require(!f.received.events[0].isRemoteImage, "Local PNG was marked as remote")
        try require(!f.received.events[0].shouldAutomaticallyReveal, "Local PNG would open the board")
    }

    check("remote PNG is delivered with automatic reveal eligibility") { f in
        try f.copy(data: [.png: image((40, 110, 190))], strings: [remoteType: "1"])
        f.watcher.requestImport()
        try waitFor("remote PNG") { f.received.events.count == 1 }
        try f.requirePNG(f.received.events[0].url)
        try require(f.received.events[0].isRemoteImage, "Remote PNG was marked local")
        try require(f.received.events[0].allowsAutomaticReveal, "Live import unexpectedly disabled reveal")
        try require(f.received.events[0].shouldAutomaticallyReveal, "Remote PNG would stay hidden")
    }

    check("startup catch-up can import a remote image without revealing") { f in
        try f.copy(data: [.png: image((40, 160, 120))], strings: [remoteType: "1"])
        f.watcher.requestImport(allowAutomaticReveal: false)
        try waitFor("silent catch-up PNG") { f.received.events.count == 1 }
        try require(f.received.events[0].isRemoteImage, "Silent import erased the remote origin")
        try require(!f.received.events[0].allowsAutomaticReveal, "Silent import lost its reveal policy")
        try require(!f.received.events[0].shouldAutomaticallyReveal, "Startup catch-up would open the board")
        f.watcher.start()
        try f.copy(data: [.png: image((90, 120, 210))], strings: [remoteType: "1"])
        f.watcher.poll()
        try waitFor("next remote PNG") { f.received.events.count == 2 }
        try require(f.received.events[1].shouldAutomaticallyReveal, "Startup suppression leaked into the next copy")
    }

    check("delayed remote image retains a per-request silent reveal policy") { f in
        let file = f.root.appendingPathComponent("silent-late.png")
        try f.copyFile(file, remote: true)
        f.watcher.requestImport(allowAutomaticReveal: false)
        spin(for: 0.07)
        try image((140, 60, 80)).write(to: file)
        try waitFor("silent delayed image") { f.received.events.count == 1 }
        try require(f.received.events[0].isRemoteImage, "Retry lost remote image origin")
        try require(!f.received.events[0].shouldAutomaticallyReveal, "Retry lost the per-request silent policy")
    }

    check("remote text with an image preview stays silent") { f in
        try f.copy(data: [.png: image((30, 80, 140))],
                   strings: [.string: "Remote text contents", remoteType: "1"])
        f.watcher.requestImport()
        try waitFor("remote text") { f.received.events.count == 1 }
        _ = try f.requireContent(f.received.events[0].url, kind: .text)
        try require(!f.received.events[0].isRemoteImage, "Remote text preview became a remote image event")
        try require(!f.received.events[0].shouldAutomaticallyReveal, "Remote text would open the board")
    }

    check("remote web link stays silent") { f in
        let url = "https://example.com/remote-link"
        try f.copy(strings: [.URL: url, .string: url, remoteType: "1"])
        f.watcher.requestImport()
        try waitFor("remote URL") { f.received.events.count == 1 }
        _ = try f.requireContent(f.received.events[0].url, kind: .link)
        try require(!f.received.events[0].isRemoteImage, "Remote link became a remote image event")
        try require(!f.received.events[0].shouldAutomaticallyReveal, "Remote link would open the board")
    }

    check("legacy onImage callback still receives the imported file") { f in
        var legacyURLs: [URL] = []
        let legacyWatcher = ClipboardWatcher(pasteboard: f.pasteboard, outputFolder: f.output,
                                             retryDelays: [], onImage: { legacyURLs.append($0) })
        defer { legacyWatcher.stop() }
        try f.copy(data: [.png: image((100, 50, 170))])
        legacyWatcher.requestImport()
        try waitFor("legacy callback") { legacyURLs.count == 1 }
        try f.requirePNG(legacyURLs[0])
        try require(f.received.events.isEmpty, "Idle watcher unexpectedly received the legacy import")
    }

    check("JPEG is accepted and normalized to PNG") { f in
        try f.copy(data: [jpegType: image((90, 170, 40), format: .jpeg)])
        f.watcher.requestImport()
        try waitFor("JPEG import") { f.received.urls.count == 1 }
        try f.requirePNG(f.received.urls[0])
    }

    check("EXIF orientation 6 is applied while normalizing JPEG") { f in
        let jpeg = try rotatedJPEG()
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw CheckFailure(description: "Cannot inspect orientation fixture")
        }
        try require(properties[kCGImagePropertyOrientation] as? Int == 6, "Fixture lost EXIF orientation")
        try require(properties[kCGImagePropertyPixelWidth] as? Int == 11, "Fixture pixels were already rotated")
        try f.copy(data: [jpegType: jpeg])
        f.watcher.requestImport()
        try waitFor("oriented JPEG import") { f.received.urls.count == 1 }
        try f.requirePNG(f.received.urls[0], dimensions: (7, 11))
    }

    check("malformed preferred PNG falls back to valid JPEG") { f in
        let incompletePNG = Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 0])
        try f.copy(data: [.png: incompletePNG, jpegType: image((70, 120, 190), format: .jpeg)])
        f.watcher.requestImport()
        try waitFor("fallback JPEG import") { f.received.urls.count == 1 }
        try f.requirePNG(f.received.urls[0])
        try require(try f.savedFiles().count == 1, "Fallback wrote extra output files")
    }

    check("same changeCount retries a remote image whose file arrives late") { f in
        let png = try image((180, 90, 50))
        let remoteFile = f.root.appendingPathComponent("arrives-late.png")
        f.watcher.start()
        let count = try f.copyFile(remoteFile, remote: true)
        f.watcher.poll()
        spin(for: 0.07)
        try require(f.received.urls.isEmpty, "Missing file imported before it existed")
        try png.write(to: remoteFile)
        try waitFor("late remote file") { f.received.urls.count == 1 }
        try require(f.pasteboard.changeCount == count, "Test unexpectedly changed the clipboard between retries")
        try require(try Data(contentsOf: f.received.urls[0]) == png, "Late image bytes differ")
        try require(f.received.events[0].isRemoteImage, "Retry lost the remote image origin")
        try require(f.received.events[0].shouldAutomaticallyReveal, "Completed remote photo would stay hidden")
    }

    check("remote-only file URL imports a real photo") { f in
        let file = f.root.appendingPathComponent("phone.jpeg")
        try image((60, 80, 170), format: .jpeg).write(to: file)
        try f.copyFile(file, remote: true)
        f.watcher.requestImport()
        try waitFor("remote URL photo") { f.received.urls.count == 1 }
        try f.requirePNG(f.received.urls[0])
        try require(f.received.events[0].isRemoteImage, "Remote file photo lost its origin")
        try require(f.received.events[0].shouldAutomaticallyReveal, "Remote file photo would stay hidden")
    }

    check("ordinary Finder file URL takes priority over its PNG preview") { f in
        let png = try image((40, 150, 80))
        let file = f.root.appendingPathComponent("finder.png")
        try png.write(to: file)
        try f.copyFile(file, remote: false, extraData: [.png: png])
        f.watcher.requestImport()
        try waitFor("Finder file entry") { f.received.urls.count == 1 }
        let content = try f.requireContent(f.received.urls[0], kind: .files)
        try require(content.urls == [file], "Finder source URL was changed")
        try require(content.ownedAttachmentDirectory == nil, "Local file was unnecessarily duplicated")
        try require(try Data(contentsOf: file) == png, "Original Finder file was changed")
    }

    check("remote non-image file is preserved in private app storage") { f in
        let file = f.root.appendingPathComponent("not-a-photo.png")
        let data = Data("This is text, despite its extension.".utf8)
        try data.write(to: file)
        try f.copyFile(file, remote: true)
        f.watcher.requestImport()
        try waitFor("remote attachment") { f.received.urls.count == 1 }
        let content = try f.requireContent(f.received.urls[0], kind: .files)
        try require(content.urls.count == 1, "Remote attachment missing")
        try require(content.urls[0] != file, "Transient remote URL was retained")
        try require(content.ownedAttachmentDirectory != nil, "Remote ownership was not recorded")
        try require(content.urls[0].lastPathComponent == file.lastPathComponent, "Remote file name changed")
        try require(try Data(contentsOf: content.urls[0]) == data, "Remote file bytes changed")
        try require(try Data(contentsOf: file) == data, "Remote source was changed")
        try require(!f.received.events[0].isRemoteImage, "Remote attachment was marked as an image")
        try require(!f.received.events[0].shouldAutomaticallyReveal, "Remote attachment would open the board")
    }

    check("remote directory retains its nested files") { f in
        let folder = f.root.appendingPathComponent("Remote Folder", isDirectory: true)
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let data = Data("nested attachment".utf8)
        try data.write(to: nested.appendingPathComponent("readme.txt"))
        try f.copyFile(folder, remote: true)
        f.watcher.requestImport()
        try waitFor("remote folder") { f.received.urls.count == 1 }
        let content = try f.requireContent(f.received.urls[0], kind: .files)
        try require(content.urls.count == 1, "Remote folder missing")
        try require(content.urls[0] != folder, "Transient folder URL was retained")
        try require(try Data(contentsOf: content.urls[0].appendingPathComponent("nested/readme.txt")) == data,
                    "Nested remote attachment was not preserved")
    }

    check("reused remote file URL with changed bytes is captured as new content") { f in
        let file = f.root.appendingPathComponent("remote-document.pdf")
        let first = Data("first revision".utf8)
        let second = Data("other revision".utf8)
        try require(first.count == second.count, "Revision fixture must keep the same length")
        try first.write(to: file)
        let initialDate = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]
        try f.copyFile(file, remote: true)
        f.watcher.requestImport()
        try waitFor("first remote revision") { f.received.urls.count == 1 }
        let oldContent = try f.requireContent(f.received.urls[0], kind: .files)
        f.watcher.requestImport()
        spin(for: 0.4)
        try require(f.received.urls.count == 1, "Retrying the same copy duplicated a remote attachment")
        try require(try f.savedFiles().count == 2, "Retrying the same copy left extra attachment files")
        try second.write(to: file)
        if let initialDate { try FileManager.default.setAttributes([.modificationDate: initialDate], ofItemAtPath: file.path) }
        try f.copyFile(file, remote: true)
        f.watcher.requestImport()
        try waitFor("changed remote revision") { f.received.urls.count == 2 }
        let newContent = try f.requireContent(f.received.urls[1], kind: .files)
        try require(try Data(contentsOf: oldContent.urls[0]) == first, "New revision changed retained old attachment")
        try require(try Data(contentsOf: newContent.urls[0]) == second, "Changed remote source was deduplicated or captured incorrectly")
    }

    check("new copy replaces a pending remote photo without saving the old photo") { f in
        let oldPNG = try image((210, 40, 40))
        let newPNG = try image((40, 80, 210))
        let oldFile = f.root.appendingPathComponent("stale-photo.png")
        try f.copyFile(oldFile, remote: true)
        f.watcher.requestImport()
        spin(for: 0.025)
        try f.copy(data: [.png: newPNG])
        f.watcher.requestImport()
        try oldPNG.write(to: oldFile)
        try waitFor("replacement photo") { f.received.urls.count == 1 }
        spin(for: 0.5)
        try require(f.received.urls.count == 1, "Stale photo callback was delivered")
        try require(try f.savedFiles().count == 1, "Stale photo was written to disk")
        try require(try Data(contentsOf: f.received.urls[0]) == newPNG, "The replaced photo was saved instead of the newest copy")
        try require(!f.received.events[0].isRemoteImage, "Cancelled remote request contaminated the local replacement")
        try require(!f.received.events[0].shouldAutomaticallyReveal, "Cancelled remote request would reveal a local replacement")
    }

    check("new text copy cancels a pending photo even before the next poll") { f in
        let file = f.root.appendingPathComponent("cancelled.png")
        try f.copyFile(file, remote: true)
        f.watcher.requestImport()
        spin(for: 0.025)
        try f.copy(strings: [.string: "a newer copy"])
        try image((120, 30, 160)).write(to: file)
        try f.requireNoImport("An obsolete photo was imported after the clipboard changed")
    }

    check("text takes priority over its image preview") { f in
        try f.copy(data: [.png: image((30, 80, 140))], strings: [.string: "document contents"])
        f.watcher.requestImport()
        try waitFor("text plus image representation") { f.received.urls.count == 1 }
        let content = try f.requireContent(f.received.urls[0], kind: .text)
        try require(content.text == "document contents", "Copied text changed")
        try require(try f.savedFiles().count == 1, "Text preview was saved as an extra image")
    }

    check("plain text preserves Unicode, leading spaces and line endings") { f in
        let original = "  布贴板 👨‍👩‍👧‍👦\r\n第二行\tlet value = 1\n\n"
        try f.copy(strings: [.string: original])
        f.watcher.requestImport()
        try waitFor("Unicode text") { f.received.urls.count == 1 }
        let content = try f.requireContent(f.received.urls[0], kind: .text)
        try require(content.text == original, "Text was trimmed or line endings were changed")
        try require(content.urls.isEmpty, "Plain text unexpectedly contains a URL attachment")
    }

    check("a whole web URL is classified as a link and retains original text") { f in
        let original = "  https://example.com/a?q=hello%20world#section\n"
        try f.copy(strings: [.string: original])
        f.watcher.requestImport()
        try waitFor("plain URL") { f.received.urls.count == 1 }
        let content = try f.requireContent(f.received.urls[0], kind: .link)
        try require(content.text == original, "Link import lost the originally copied text")
        try require(content.urls == [URL(string: original.trimmingCharacters(in: .whitespacesAndNewlines))!],
                    "Link destination changed")
    }

    check("explicit URL representation supplies the destination") { f in
        let url = URL(string: "https://example.com/reference?view=full")!
        try f.copy(strings: [.URL: url.absoluteString, .string: "Example reference"])
        f.watcher.requestImport()
        try waitFor("explicit URL") { f.received.urls.count == 1 }
        let content = try f.requireContent(f.received.urls[0], kind: .link)
        try require(content.urls == [url], "Explicit URL destination changed")
        try require(content.text == "Example reference", "Explicit URL lost its plain representation")
    }

    check("a sentence containing a URL stays text") { f in
        let original = "请打开 https://example.com 查看参考。"
        try f.copy(strings: [.string: original])
        f.watcher.requestImport()
        try waitFor("sentence with URL") { f.received.urls.count == 1 }
        let content = try f.requireContent(f.received.urls[0], kind: .text)
        try require(content.text == original, "Sentence text changed")
    }

    check("rich text retains both RTF and HTML alongside the plain text") { f in
        let original = "加粗文字和链接\n第二行"
        let attributed = NSAttributedString(string: original, attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let html = Data("<p><b>加粗文字和链接</b><br>第二行</p>".utf8)
        try f.copy(data: [.rtf: rtf, .html: html], strings: [.string: original])
        f.watcher.requestImport()
        try waitFor("rich text") { f.received.urls.count == 1 }
        let content = try f.requireContent(f.received.urls[0], kind: .text)
        try require(content.text == original, "Rich text changed its plain representation")
        try require(content.rtf == rtf, "RTF formatting bytes were not preserved")
        try require(content.html == html, "HTML formatting bytes were not preserved")
    }

    check("RTF-only clipboard produces readable text and keeps formatting") { f in
        let original = "只有富文本\nStill readable"
        let attributed = NSAttributedString(string: original, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try f.copy(data: [.rtf: rtf])
        f.watcher.requestImport()
        try waitFor("RTF-only import") { f.received.urls.count == 1 }
        let content = try f.requireContent(f.received.urls[0], kind: .text)
        try require(content.text == original, "RTF plain text was not decoded")
        try require(content.rtf == rtf, "RTF-only source was changed")
    }

    check("HTML-only content preserves markup and derives a readable preview") { f in
        let html = Data("<html><head><title>hidden title</title></head><body><script>doNotShow()</script><p>布料 &amp; paper</p><p>第二行</p></body></html>".utf8)
        try f.copy(data: [.html: html])
        f.watcher.requestImport()
        try waitFor("HTML-only import") { f.received.urls.count == 1 }
        let content = try f.requireContent(f.received.urls[0], kind: .text)
        try require(content.html == html, "Original HTML was modified")
        try require(content.text.contains("布料 & paper") && content.text.contains("第二行"),
                    "HTML visible text was not extracted")
        try require(!content.text.contains("hidden title") && !content.text.contains("doNotShow"),
                    "HTML non-content leaked into the preview")
    }

    check("raw PDF document takes priority over an image preview") { f in
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 72, height: 72)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
            throw CheckFailure(description: "Could not create PDF fixture")
        }
        context.beginPDFPage(nil)
        context.setFillColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
        context.fill(bounds)
        context.endPDFPage()
        context.closePDF()
        let pdf = data as Data
        try f.copy(data: [.pdf: pdf, .png: image((20, 50, 70))])
        f.watcher.requestImport()
        try waitFor("PDF document") { f.received.urls.count == 1 }
        let content = try f.requireContent(f.received.urls[0], kind: .files)
        try require(content.urls.count == 1 && content.urls[0].pathExtension == "pdf", "PDF attachment missing")
        try require(try Data(contentsOf: content.urls[0]) == pdf, "PDF document was reduced to its preview")
    }

    check("Finder file batches and folders are one entry with every source URL") { f in
        let first = f.root.appendingPathComponent("first.pdf")
        let second = f.root.appendingPathComponent("second.mp4")
        let folder = f.root.appendingPathComponent("Folder", isDirectory: true)
        try Data("PDF fixture".utf8).write(to: first)
        try Data("video fixture".utf8).write(to: second)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = [first, second, folder]
        try f.copyFiles(urls, preview: image((90, 20, 70)))
        f.watcher.requestImport()
        try waitFor("file batch") { f.received.urls.count == 1 }
        let content = try f.requireContent(f.received.urls[0], kind: .files)
        try require(content.urls == urls, "File batch lost an item or changed its order")
        try require(content.ownedAttachmentDirectory == nil, "Local files were copied into owned storage")
        try require(try f.savedFiles().count == 1, "One file batch became multiple history entries")
    }

    check("a newer text entry replaces a pending remote photo without remnants") { f in
        let file = f.root.appendingPathComponent("superseded.png")
        try f.copyFile(file, remote: true)
        f.watcher.requestImport()
        spin(for: 0.025)
        try f.copy(strings: [.string: "latest text"])
        f.watcher.requestImport()
        try image((10, 20, 30)).write(to: file)
        try waitFor("replacement text") { f.received.urls.count == 1 }
        spin(for: 0.5)
        let content = try f.requireContent(f.received.urls[0], kind: .text)
        try require(content.text == "latest text", "Wrong text delivered after cancellation")
        try require(f.received.urls.count == 1, "Cancelled photo delivered a late callback")
        try require(try f.savedFiles().count == 1, "Cancelled photo left a saved file")
    }

    for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"] {
        check("private/temporary marker is rejected: \(marker)") { f in
            try f.copy(data: [.png: image((20, 50, 70)), .init(marker): Data()])
            f.watcher.requestImport()
            try f.requireNoImport("Protected clipboard content was imported")
        }
        check("protected text is excluded: \(marker)") { f in
            try f.copy(data: [.init(marker): Data()], strings: [.string: "protected text"])
            f.watcher.requestImport()
            try f.requireNoImport("Protected text was imported")
        }
    }

    check("copying our own content does not collect it again") { f in
        try f.copy(data: [.png: image((20, 50, 70)), .init("local.feltboard.clipboard-owner"): Data("1".utf8)],
                   strings: [.string: "own copied text"])
        f.watcher.requestImport()
        try f.requireNoImport("Own clipboard write created another history entry")
    }

    check("duplicate text is suppressed and reimported after its record is removed") { f in
        let original = "重复复制的文本"
        try f.copy(strings: [.string: original])
        f.watcher.requestImport()
        try waitFor("first text") { f.received.urls.count == 1 }
        try f.copy(strings: [.string: original])
        f.watcher.requestImport()
        spin(for: 0.4)
        try require(f.received.urls.count == 1, "Duplicate text callback was delivered")
        try require(try f.savedFiles().count == 1, "Duplicate text was written")
        try FileManager.default.removeItem(at: f.received.urls[0])
        try f.copy(strings: [.string: original])
        f.watcher.requestImport()
        try waitFor("restored text") { f.received.urls.count == 2 }
        let content = try f.requireContent(f.received.urls[1], kind: .text)
        try require(content.text == original, "Reimported text changed")
    }

    check("cancelled undelivered metadata does not suppress the next identical text") { f in
        let original = "new copy after cancelled delivery"
        try f.copy(strings: [.string: original])
        f.watcher.requestImport()
        let deadline = Date().addingTimeInterval(2)
        while try f.savedFiles().isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        try require(try f.savedFiles().count == 1, "Background text save did not complete")
        Thread.sleep(forTimeInterval: 0.03)
        try require(f.received.urls.isEmpty, "First text callback ran before cancellation")
        try f.copy(strings: [.string: original])
        f.watcher.requestImport()
        try waitFor("same text after cancelled delivery") { f.received.urls.count == 1 }
        try waitFor("cancelled metadata cleanup") { (try? f.savedFiles().count) == 1 }
        let content = try f.requireContent(f.received.urls[0], kind: .text)
        try require(content.text == original, "Replacement text changed")
    }

    check("cancelling an undelivered remote attachment removes its cached directory") { f in
        let source = f.root.appendingPathComponent("transient-document.pdf")
        try Data("temporary remote attachment".utf8).write(to: source)
        try f.copyFile(source, remote: true)
        f.watcher.requestImport()
        let deadline = Date().addingTimeInterval(2)
        while try f.savedFiles().filter({ $0.pathExtension == ClipboardContent.extensionName }).isEmpty,
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        try require(try f.savedFiles().contains { $0.pathExtension == ClipboardContent.extensionName },
                    "Remote attachment metadata was not saved before cancellation")
        Thread.sleep(forTimeInterval: 0.03)
        try require(f.received.urls.isEmpty, "Remote callback ran before cancellation")
        try f.copy(strings: [.string: "replacement after remote attachment"])
        f.watcher.requestImport()
        try waitFor("replacement after remote attachment") { f.received.urls.count == 1 }
        try waitFor("remote attachment cleanup") { (try? f.savedFiles().count) == 1 }
        let content = try f.requireContent(f.received.urls[0], kind: .text)
        try require(content.text == "replacement after remote attachment", "Wrong replacement content")
        try require(FileManager.default.fileExists(atPath: source.path), "Cancellation removed original remote source")
    }

    check("duplicate PNG is suppressed, and can be restored after removal") { f in
        let png = try image((140, 120, 40))
        try f.copy(data: [.png: png])
        f.watcher.requestImport()
        try waitFor("first import") { f.received.urls.count == 1 }
        try f.copy(data: [.png: png])
        f.watcher.requestImport()
        spin(for: 0.4)
        try require(f.received.urls.count == 1, "Duplicate callback was delivered")
        try require(try f.savedFiles().count == 1, "Duplicate was written to disk")
        try FileManager.default.removeItem(at: f.received.urls[0])
        try f.copy(data: [.png: png])
        f.watcher.requestImport()
        try waitFor("restore removed photo") { f.received.urls.count == 2 }
        try f.requirePNG(f.received.urls[1])
    }

    check("cancelled undelivered save does not suppress a new copy of the same image") { f in
        let png = try image((180, 100, 60))
        try f.copy(data: [.png: png])
        f.watcher.requestImport()
        // Keep the main queue occupied until the serial reader saves the file.
        // Its callback cannot run yet, so the next request cancels that token.
        let deadline = Date().addingTimeInterval(2)
        while try f.savedFiles().isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        try require(try f.savedFiles().count == 1, "Background save did not complete before cancellation")
        Thread.sleep(forTimeInterval: 0.03)
        try require(f.received.urls.isEmpty, "First callback unexpectedly ran before cancellation")
        try f.copy(data: [.png: png])
        f.watcher.requestImport()
        try waitFor("same image after cancelled delivery") { f.received.urls.count == 1 }
        try waitFor("cancelled output cleanup") { (try? f.savedFiles().count) == 1 }
        try f.requirePNG(f.received.urls[0])
        try require(try Data(contentsOf: f.received.urls[0]) == png, "Replacement image bytes changed")
    }

    check("remote photo larger than 64 MiB is rejected") { f in
        let file = f.root.appendingPathComponent("oversized.png")
        try image((100, 140, 180)).write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 64 * 1024 * 1024 + 1)
        try handle.close()
        try f.copyFile(file, remote: true)
        f.watcher.requestImport()
        try f.requireNoImport("Image beyond the byte limit was imported")
    }

    check("valid image beyond 80 million pixels is rejected") { f in
        let png = try imageBeyondPixelLimit()
        try require(png.count < 64 * 1024 * 1024, "Pixel fixture also exceeds byte limit")
        try f.copy(data: [.png: png])
        f.watcher.requestImport()
        try f.requireNoImport("Image beyond the decoded-pixel limit was imported")
    }

    check("stop cancels a pending remote photo") { f in
        let file = f.root.appendingPathComponent("stopped.png")
        try f.copyFile(file, remote: true)
        f.watcher.requestImport()
        spin(for: 0.025)
        f.watcher.stop()
        try image((90, 40, 20)).write(to: file)
        try f.requireNoImport("Stopped watcher delivered a pending import")
    }

    print("\(count - failures)/\(count) clipboard checks passed; isolated pasteboards only.")
    return failures == 0 ? 0 : 1
}

exit(MainActor.assumeIsolated { runChecks() })
