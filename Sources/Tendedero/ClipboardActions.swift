import AppKit

extension Pegged {
    /// Export the original content, never the app's private record file.
    @MainActor
    func pasteboardItems() -> [NSPasteboardItem] {
        let owner = NSPasteboard.PasteboardType("local.feltboard.clipboard-owner")
        func entry() -> NSPasteboardItem {
            let item = NSPasteboardItem()
            item.setString("1", forType: owner)
            return item
        }
        guard let content else {
            let item = entry()
            if !isRecording {
                if url.pathExtension.lowercased() == "png", let data = try? Data(contentsOf: url) {
                    item.setData(data, forType: .png)
                } else if let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiff),
                          let data = bitmap.representation(using: .png, properties: [:]) {
                    item.setData(data, forType: .png)
                }
            }
            item.setString(url.absoluteString, forType: .fileURL)
            return [item]
        }
        switch content.kind {
        case .text:
            let item = entry()
            item.setString(content.text, forType: .string)
            if let rtf = content.rtf { item.setData(rtf, forType: .rtf) }
            if let html = content.html { item.setData(html, forType: .html) }
            return [item]
        case .link:
            let item = entry()
            item.setString(content.text, forType: .string)
            if let url = content.urls.first { item.setString(url.absoluteString, forType: .URL) }
            if let rtf = content.rtf { item.setData(rtf, forType: .rtf) }
            if let html = content.html { item.setData(html, forType: .html) }
            return [item]
        case .files:
            return content.urls.map { url in
                let item = entry()
                item.setString(url.absoluteString, forType: .fileURL)
                return item
            }
        }
    }
}

extension ClipboardContent {
    @MainActor
    func boardThumbnail() -> NSImage {
        if kind == .files, let url = urls.first {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        // A small drag preview; the visible board is drawn with SwiftUI.
        let image = NSImage(size: NSSize(width: 180, height: 150))
        image.lockFocus()
        NSColor(calibratedRed: 0.93, green: 0.89, blue: 0.79, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 180, height: 150)).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let title = kind == .link ? (urls.first?.host ?? text) : String(text.prefix(180))
        (title as NSString).draw(in: NSRect(x: 14, y: 14, width: 152, height: 122), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.darkGray,
            .paragraphStyle: paragraph,
        ])
        image.unlockFocus()
        return image
    }
}

/// Full text remains readable even when the small fabric card is truncated.
@MainActor
final class ContentPreview {
    static let shared = ContentPreview()
    private var window: NSWindow?

    func show(_ text: String) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "布贴板 · 内容"
            window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            let view = NSTextView(frame: scroll.bounds)
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.isVerticallyResizable = true
            view.autoresizingMask = [.width]
            view.textContainer?.widthTracksTextView = true
            view.textContainerInset = NSSize(width: 20, height: 20)
            view.font = .systemFont(ofSize: 15)
            scroll.documentView = view
            window.contentView = scroll
            self.window = window
        }
        guard let window, let scroll = window.contentView as? NSScrollView,
              let view = scroll.documentView as? NSTextView else { return }
        view.string = text
        view.scrollToBeginningOfDocument(nil)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
