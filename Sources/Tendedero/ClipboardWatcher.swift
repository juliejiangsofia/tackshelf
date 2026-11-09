import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Universal Clipboard may advertise content before its data or files arrive.
/// Reads run off the UI thread and have a bounded retry schedule.
@MainActor
final class ClipboardWatcher {
    enum ImportResult {
        case imported, alreadyImported, noImage, unavailable, rejected
    }
    var onImportResult: ((ImportResult) -> Void)?
    private let onContent: (ImportedContent) -> Void
    private let pasteboard: NSPasteboard
    private let retryDelays: [TimeInterval]
    private let reader: Reader
    private let queue = DispatchQueue(label: "local.tackshelf.clipboard-reader", qos: .userInitiated)
    private var timer: Timer?
    private var lastCount: Int
    private var token: Cancellation?
    private var pendingRetry: DispatchWorkItem?
    private static let enabledKey = "clipboardEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Named pasteboards and temporary folders let checks avoid user content.
    init(pasteboard: NSPasteboard = .general, outputFolder: URL = Inbox.folder,
         retryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8, 12],
         onContent: @escaping (ImportedContent) -> Void) {
        self.pasteboard = pasteboard
        self.lastCount = pasteboard.changeCount
        self.retryDelays = retryDelays
        self.reader = Reader(pasteboardName: pasteboard.name, folder: outputFolder)
        self.onContent = onContent
    }

    /// Keep URL-only consumers compatible while the app uses source context.
    convenience init(pasteboard: NSPasteboard = .general, outputFolder: URL = Inbox.folder,
                     retryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8, 12],
                     onImage: @escaping (URL) -> Void) {
        self.init(pasteboard: pasteboard, outputFolder: outputFolder,
                  retryDelays: retryDelays, onContent: { onImage($0.url) })
    }

    func start() {
        guard timer == nil else { return }
        // Enabling collection does not import an old clipboard.
        lastCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancelPending()
    }

    /// Explicitly retry the current copy, even with automatic collection off.
    /// Startup recovery can collect it without reopening the board.
    func requestImport(allowAutomaticReveal: Bool = true) {
        lastCount = pasteboard.changeCount
        begin(count: lastCount, allowAutomaticReveal: allowAutomaticReveal)
    }

    func poll() {
        let count = pasteboard.changeCount
        guard count != lastCount else { return }
        lastCount = count
        begin(count: count)
    }

    private func cancelPending() {
        pendingRetry?.cancel()
        pendingRetry = nil
        token?.cancel()
        token = nil
    }

    private func begin(count: Int, allowAutomaticReveal: Bool = true) {
        cancelPending()
        let token = Cancellation(allowAutomaticReveal: allowAutomaticReveal)
        self.token = token
        attempt(count: count, number: 0, token: token)
    }

    private func attempt(count: Int, number: Int, token: Cancellation) {
        let reader = reader
        // A system data-provider call can wait for a remote transfer. One
        // background queue keeps that wait, decoding and disk I/O off the UI.
        // Cancellation cannot interrupt such a call, but suppresses its result.
        queue.async { [weak self] in
            let result = autoreleasepool { reader.read(count: count, token: token) }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.finish(result, count: count, number: number, token: token)
                }
            }
        }
    }

    private func finish(_ result: Reader.Result, count: Int, number: Int, token: Cancellation) {
        guard self.token === token, !token.isCancelled,
              pasteboard.changeCount == count else {
            token.cancel()
            if case .saved(let url, _) = result {
                let reader = reader
                queue.async { reader.removeOwnedEntry(at: url) }
            }
            return
        }
        switch result {
        case .saved(let url, let isRemoteImage):
            self.token = nil
            log.notice("Clipboard content imported (attempt \(number + 1, privacy: .public))")
            onContent(ImportedContent(url: url, isRemoteImage: isRemoteImage,
                                      allowsAutomaticReveal: token.allowAutomaticReveal))
            onImportResult?(.imported)
        case .duplicate:
            self.token = nil
            onImportResult?(.alreadyImported)
        case .retry:
            guard number < retryDelays.count else {
                self.token = nil
                log.notice("Clipboard content unavailable after bounded retries")
                onImportResult?(.unavailable)
                return
            }
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.token === token, !token.isCancelled else { return }
                    self.attempt(count: count, number: number + 1, token: token)
                }
            }
            pendingRetry = item
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelays[number], execute: item)
        case .noImage:
            self.token = nil
            onImportResult?(.noImage)
        case .rejected:
            self.token = nil
            log.debug("Clipboard copy excluded by collection policy")
            onImportResult?(.rejected)
        case .superseded:
            self.token = nil
        }
    }

    /// Shared by the main actor and serial reader queue.
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        let allowAutomaticReveal: Bool

        init(allowAutomaticReveal: Bool) {
            self.allowAutomaticReveal = allowAutomaticReveal
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    /// Confined to `queue`, including its potentially large duplicate buffer.
    private final class Reader {
        enum Result {
            case saved(URL, isRemoteImage: Bool), duplicate, retry, noImage, rejected, superseded
        }
        let pasteboardName: NSPasteboard.Name
        let folder: URL
        private var last: (fingerprint: Data, url: URL, token: Cancellation)?
        private static let maxTextBytes = 8 * 1024 * 1024
        private static let maxAttachmentEntries = 512
        private static let maxBytes = 64 * 1024 * 1024
        private static let maxPixels = 80_000_000
        private static let remoteType = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
        private static let privateTypes: Set<NSPasteboard.PasteboardType> = [
            .init("org.nspasteboard.ConcealedType"),
            .init("org.nspasteboard.TransientType"),
            .init("org.nspasteboard.AutoGeneratedType"),
            .init("local.tackshelf.clipboard-owner"),
        ]

        init(pasteboardName: NSPasteboard.Name, folder: URL) {
            self.pasteboardName = pasteboardName
            self.folder = folder
        }

        func read(count: Int, token: Cancellation) -> Result {
            let pb = NSPasteboard(name: pasteboardName)
            let current = { !token.isCancelled && pb.changeCount == count }
            guard current() else { return .superseded }
            guard let items = pb.pasteboardItems, !items.isEmpty else { return .noImage }
            let types = Set(items.flatMap(\.types)).union(pb.types ?? [])
            guard Self.privateTypes.isDisjoint(with: types) else { return .rejected }
            let isRemote = types.contains(Self.remoteType)
            let hasFile = types.contains(.fileURL) || types.contains(.init("NSFilenamesPboardType"))

            // A Finder copy often offers an icon or thumbnail too. The actual
            // file list wins over every preview representation.
            if hasFile {
                let urls = pb.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]
                guard current() else { return .superseded }
                guard let urls, !urls.isEmpty, urls.allSatisfy(Self.isLocalFile) else { return .retry }
                if isRemote && urls.count == 1 {
                    let url = urls[0]
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]) else { return .retry }
                    if values.isRegularFile == true {
                        guard let size = values.fileSize, size <= Self.maxBytes else { return .rejected }
                        guard let data = Self.boundedData(at: url, limit: Self.maxBytes), !data.isEmpty else { return .retry }
                        guard current() else { return .superseded }
                        if let source = CGImageSourceCreateWithData(data as CFData, nil),
                           let identifier = CGImageSourceGetType(source),
                           UTType(identifier as String)?.conforms(to: .image) == true {
                            guard let png = Self.png(from: data) else { return .retry }
                            return save(png, extensionName: "png", isRemoteImage: isRemote,
                                        token: token, stillCurrent: current)
                        }
                    }
                }
                let content = ClipboardContent(kind: .files, urls: urls)
                guard var fingerprint = Self.encode(content) else { return .rejected }
                if isRemote {
                    // The system may reuse a temporary URL for different
                    // remote files. Reuse a snapshot only when retrying this
                    // exact clipboard event; a new copy gets a fresh snapshot.
                    fingerprint.append(Data("\nremote-copy-event:\(count)".utf8))
                }
                if isDuplicate(fingerprint) { return .duplicate }
                if isRemote {
                    return saveRemoteFiles(urls, fingerprint: fingerprint, token: token, stillCurrent: current)
                }
                // Local originals stay where they are. Neither collection nor
                // eventual history eviction moves or deletes those originals.
                return saveContent(content, token: token, stillCurrent: current)
            }

            // Text and URLs likewise take priority over a raster preview.
            let urlType = NSPasteboard.PasteboardType("public.url")
            let hasText = types.contains(.string) || types.contains(.rtf) || types.contains(.html)
                || types.contains(urlType) || types.contains(.rtfd)
            if hasText {
                let rtf = types.contains(.rtf) ? pb.data(forType: .rtf) : nil
                let html = types.contains(.html) ? pb.data(forType: .html) : nil
                guard (rtf?.count ?? 0) <= Self.maxTextBytes,
                      (html?.count ?? 0) <= Self.maxTextBytes else { return .rejected }
                let explicitURL = pb.string(forType: urlType)
                var text = pb.string(forType: .string) ?? explicitURL
                if text == nil, let rtf {
                    text = (try? NSAttributedString(data: rtf,
                        options: [.documentType: NSAttributedString.DocumentType.rtf],
                        documentAttributes: nil))?.string
                }
                if text == nil, let html { text = Self.plainText(fromHTML: html) }
                if text == nil, types.contains(.rtfd), let rtfd = pb.data(forType: .rtfd) {
                    guard rtfd.count <= Self.maxTextBytes else { return .rejected }
                    text = NSAttributedString(rtfd: rtfd, documentAttributes: nil)?.string
                }
                guard current() else { return .superseded }
                guard let text, !text.isEmpty else { return .retry }
                guard text.utf8.count <= Self.maxTextBytes else { return .rejected }
                // Browser link copies may put the title in plain text and
                // the destination in public.url. Trust that explicit URL
                // representation, while preserving the original title text.
                let link = explicitURL.flatMap(Self.webURL) ?? Self.webURL(from: text)
                let content = ClipboardContent(kind: link == nil ? .text : .link,
                    text: text, urls: link.map { [$0] } ?? [], rtf: rtf, html: html)
                return saveContent(content, token: token, stillCurrent: current)
            }

            // A native PDF representation is a document, even if it comes with
            // a PNG/TIFF preview (for example a copied page in Preview).
            if types.contains(.pdf) {
                guard let data = pb.data(forType: .pdf), !data.isEmpty else { return .retry }
                guard current() else { return .superseded }
                guard data.count <= Self.maxBytes else { return .rejected }
                return saveDocumentData(data, filename: "Copied document.pdf", token: token, stillCurrent: current)
            }

            let preferred: [NSPasteboard.PasteboardType] = [
                .png, .tiff, .init("public.jpeg"), .init("public.heic"),
                .init("public.heif"), .init("com.compuserve.gif"), .init("com.microsoft.bmp"),
            ]
            let imageTypes = preferred.filter(types.contains) + types.filter { type in
                !preferred.contains(type) && UTType(type.rawValue)?.conforms(to: .image) == true
            }
            guard !imageTypes.isEmpty else { return isRemote ? .retry : .noImage }
            for type in imageTypes {
                guard current() else { return .superseded }
                guard let candidate = pb.data(forType: type), !candidate.isEmpty else { continue }
                guard candidate.count <= Self.maxBytes else { return .rejected }
                // A partial preferred representation must not hide a complete
                // fallback format that the system has already transferred.
                if let png = Self.png(from: candidate) {
                    guard current() else { return .superseded }
                    return save(png, extensionName: "png", isRemoteImage: isRemote,
                                token: token, stillCurrent: current)
                }
            }
            return current() ? .retry : .superseded
        }

        private static func isLocalFile(_ url: URL) -> Bool {
            url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
        }

        private static func boundedData(at url: URL, limit: Int) -> Data? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
            return data
        }

        private static func webURL(from text: String) -> URL? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  let components = URLComponents(string: trimmed),
                  let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = components.host, !host.isEmpty,
                  let url = components.url else { return nil }
            return url
        }

        /// Preview-only HTML extraction. Preserve the original HTML for paste,
        /// but never invoke WebKit or fetch embedded remote resources to display
        /// a clipboard card. Native plain text, when present, is preferred.
        private static func plainText(fromHTML data: Data) -> String? {
            guard var string = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .utf16) else { return nil }
            string = string.replacingOccurrences(of: "(?is)<(script|style|head)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
            string = string.replacingOccurrences(of: "(?i)<br\\s*/?>|</(?:p|div|li|h[1-6]|tr)\\s*>", with: "\n", options: .regularExpression)
            string = string.replacingOccurrences(of: "(?s)<[^>]+>", with: "", options: .regularExpression)
            let entities = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&amp;": "&"]
            if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
                let matches = regex.matches(in: string, range: NSRange(string.startIndex..., in: string))
                for match in matches.reversed() {
                    guard let range = Range(match.range(at: 1), in: string),
                          let full = Range(match.range, in: string) else { continue }
                    let number = String(string[range])
                    let scalar = number.first == "x" ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
                    if let scalar, let character = UnicodeScalar(scalar) { string.replaceSubrange(full, with: String(character)) }
                }
            }
            // Ampersand is deliberately last, so escaped entity text remains
            // literal instead of being decoded a second time.
            for key in ["&nbsp;", "&lt;", "&gt;", "&quot;", "&apos;", "&amp;"] {
                string = string.replacingOccurrences(of: key, with: entities[key]!)
            }
            return string.trimmingCharacters(in: .newlines)
        }

        private static func encode(_ content: ClipboardContent) -> Data? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try? encoder.encode(content)
        }

        private func isDuplicate(_ fingerprint: Data) -> Bool {
            guard let last, !last.token.isCancelled, last.fingerprint == fingerprint else { return false }
            return FileManager.default.fileExists(atPath: last.url.path)
        }

        private func saveContent(_ content: ClipboardContent, fingerprint: Data? = nil,
                                 token: Cancellation, stillCurrent: () -> Bool) -> Result {
            guard let data = Self.encode(content) else { return .rejected }
            return save(data, extensionName: ClipboardContent.extensionName,
                        fingerprint: fingerprint, token: token, stillCurrent: stillCurrent)
        }

        private enum AttachmentError: Error { case rejected, unavailable, superseded }

        private func saveRemoteFiles(_ urls: [URL], fingerprint: Data, token: Cancellation,
                                     stillCurrent: () -> Bool) -> Result {
            let fm = FileManager.default
            // The output directory cannot be copied into one of its own
            // ancestors; doing so would recursively consume its new output.
            let outputPath = folder.standardizedFileURL.path + "/"
            guard !urls.contains(where: {
                outputPath.hasPrefix($0.standardizedFileURL.path + "/")
            }) else { return .rejected }
            let directory = folder.appendingPathComponent("Attachments-\(UUID().uuidString)", isDirectory: true)
            var keep = false
            defer { if !keep { try? fm.removeItem(at: directory) } }
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                var bytes = 0
                var entries = 0
                var copied: [URL] = []
                for url in urls {
                    guard stillCurrent() else { throw AttachmentError.superseded }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let name = url.lastPathComponent.isEmpty ? "Attachment" : url.lastPathComponent
                    var destination = directory.appendingPathComponent(name)
                    var suffix = 2
                    while fm.fileExists(atPath: destination.path) {
                        destination = directory.appendingPathComponent("\(suffix)-\(name)")
                        suffix += 1
                    }
                    try copyAttachment(url, to: destination, bytes: &bytes, entries: &entries, stillCurrent: stillCurrent)
                    copied.append(destination)
                }
                let content = ClipboardContent(kind: .files, urls: copied, ownedAttachmentDirectory: directory)
                let result = saveContent(content, fingerprint: fingerprint, token: token, stillCurrent: stillCurrent)
                if case .saved = result { keep = true }
                return result
            } catch AttachmentError.superseded { return .superseded }
              catch AttachmentError.rejected { return .rejected }
              catch { return stillCurrent() ? .retry : .superseded }
        }

        private func copyAttachment(_ source: URL, to destination: URL, bytes: inout Int,
                                    entries: inout Int, stillCurrent: () -> Bool) throws {
            guard stillCurrent() else { throw AttachmentError.superseded }
            entries += 1
            guard entries <= Self.maxAttachmentEntries else { throw AttachmentError.rejected }
            let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isSymbolicLink != true else { throw AttachmentError.rejected }
            let fm = FileManager.default
            if values.isDirectory == true {
                try fm.createDirectory(at: destination, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
                let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                guard children.count <= Self.maxAttachmentEntries - entries else { throw AttachmentError.rejected }
                for child in children {
                    try copyAttachment(child, to: destination.appendingPathComponent(child.lastPathComponent),
                                       bytes: &bytes, entries: &entries, stillCurrent: stillCurrent)
                }
                return
            }
            guard values.isRegularFile == true else { throw AttachmentError.rejected }
            guard let size = values.fileSize, size <= Self.maxBytes - bytes else { throw AttachmentError.rejected }
            guard fm.createFile(atPath: destination.path, contents: nil,
                                attributes: [.posixPermissions: 0o600]) else { throw AttachmentError.unavailable }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            let startBytes = bytes
            while true {
                guard stillCurrent() else { throw AttachmentError.superseded }
                guard let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
                guard chunk.count <= Self.maxBytes - bytes else { throw AttachmentError.rejected }
                bytes += chunk.count
                try output.write(contentsOf: chunk)
            }
            // A remote file may still be growing after its URL is advertised.
            // Do not publish a snapshot if the provider changed it mid-read.
            let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard bytes - startBytes == size, after.fileSize == values.fileSize,
                  after.contentModificationDate == values.contentModificationDate else {
                throw AttachmentError.unavailable
            }
        }

        private func saveDocumentData(_ data: Data, filename: String, token: Cancellation,
                                      stillCurrent: () -> Bool) -> Result {
            var fingerprint = Data("document:pdf:".utf8)
            fingerprint.append(data)
            if isDuplicate(fingerprint) { return .duplicate }
            let fm = FileManager.default
            let directory = folder.appendingPathComponent("Attachments-\(UUID().uuidString)", isDirectory: true)
            var keep = false
            defer { if !keep { try? fm.removeItem(at: directory) } }
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                let attachment = directory.appendingPathComponent(filename)
                guard fm.createFile(atPath: attachment.path, contents: data,
                                    attributes: [.posixPermissions: 0o600]) else { return .retry }
                guard stillCurrent() else { return .superseded }
                let content = ClipboardContent(kind: .files, urls: [attachment], ownedAttachmentDirectory: directory)
                let result = saveContent(content, fingerprint: fingerprint, token: token, stillCurrent: stillCurrent)
                if case .saved = result { keep = true }
                return result
            } catch { return stillCurrent() ? .retry : .superseded }
        }

        /// Only metadata and attachments created under this reader's own
        /// output directory are eligible for cleanup after stale delivery.
        func removeOwnedEntry(at url: URL) {
            let fm = FileManager.default
            let root = folder.standardizedFileURL
            guard url.standardizedFileURL.deletingLastPathComponent() == root else { return }
            if let owned = ClipboardContent.load(from: url)?.ownedAttachmentDirectory?.standardizedFileURL,
               owned.deletingLastPathComponent() == root,
               owned.lastPathComponent.hasPrefix("Attachments-") {
                try? fm.removeItem(at: owned)
            }
            try? fm.removeItem(at: url)
        }

        /// Check metadata before decoding an arbitrarily large bitmap. Only
        /// actual image formats are accepted, never file icons or PDF previews.
        private static func png(from data: Data) -> Data? {
            guard let source = CGImageSourceCreateWithData(data as CFData,
                                                          [kCGImageSourceShouldCache: false] as CFDictionary),
                  let identifier = CGImageSourceGetType(source),
                  UTType(identifier as String)?.conforms(to: .image) == true,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0, width <= maxPixels / height else { return nil }
            if identifier as String == UTType.png.identifier {
                guard CGImageSourceCreateImageAtIndex(source, 0,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary) != nil else { return nil }
                return data
            }
            // Phone JPEG/HEIC files often store rotation in EXIF rather than
            // their pixels. Apply it at the original resolution before PNG
            // conversion, which otherwise loses that orientation metadata.
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCache: false,
            ] as CFDictionary) else { return nil }
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                  png.count <= maxBytes else { return nil }
            return png
        }

        private func save(_ data: Data, extensionName: String, fingerprint: Data? = nil,
                          isRemoteImage: Bool = false,
                          token: Cancellation, stillCurrent: () -> Bool) -> Result {
            guard stillCurrent() else { return .superseded }
            let fingerprint = fingerprint ?? data
            if isDuplicate(fingerprint) { return .duplicate }
            let fm = FileManager.default
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ".")
            let id = UUID().uuidString
            let url = folder.appendingPathComponent("Clipboard \(stamp) \(id.prefix(8)).\(extensionName)")
            let temporary = folder.appendingPathComponent(".clipboard-\(id).tmp")
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                guard fm.createFile(atPath: temporary.path, contents: nil,
                                    attributes: [.posixPermissions: 0o600]) else { return .retry }
                defer { try? fm.removeItem(at: temporary) }
                let handle = try FileHandle(forWritingTo: temporary)
                do {
                    try handle.write(contentsOf: data)
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
                guard stillCurrent() else { return .superseded }
                try fm.moveItem(at: temporary, to: url)
                guard stillCurrent() else {
                    try? fm.removeItem(at: url)
                    return .superseded
                }
                last = (fingerprint, url, token)
                return .saved(url, isRemoteImage: isRemoteImage)
            } catch {
                // Paths, image bytes and other clipboard content stay private.
                log.error("Could not save clipboard content")
                return .retry
            }
        }
    }
}
