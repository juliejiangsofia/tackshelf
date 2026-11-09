import AppKit

// Named pasteboards, a unique defaults suite and temporary files only.
// Nothing here reads/writes NSPasteboard.general or app preferences.
private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(description: message) }
}

@MainActor
private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FeltboardContentChecks-\(UUID().uuidString)", isDirectory: true)
    let suite = "local.feltboard.content-checks.\(UUID().uuidString)"
    let pasteboard = NSPasteboard(name: .init("local.feltboard.content-checks.\(UUID().uuidString)"))
    let defaults: UserDefaults
    let line: Line

    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        line = Line(defaults: defaults)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func close() {
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func record(_ content: ClipboardContent, named: String = UUID().uuidString) throws -> URL {
        let url = root.appendingPathComponent(named).appendingPathExtension(ClipboardContent.extensionName)
        try JSONEncoder().encode(content).write(to: url)
        return url
    }

    func photo(named: String = UUID().uuidString, width: Int = 11, height: Int = 7) throws -> URL {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: width * 3, bitsPerPixel: 24),
              let bytes = bitmap.bitmapData else { throw CheckFailure(description: "Cannot create image") }
        memset(bytes, 140, width * height * 3)
        let url = root.appendingPathComponent(named).appendingPathExtension("png")
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CheckFailure(description: "Cannot encode image")
        }
        try data.write(to: url)
        return url
    }

    func source(_ name: String, data: Data = Data("original file bytes".utf8)) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func hang(_ url: URL) throws -> UUID {
        guard let id = line.hang(url, quietly: true) else { throw CheckFailure(description: "Entry could not be hung") }
        return id
    }
}

@MainActor
private func runChecks() -> Int32 {
    var count = 0
    var failures = 0
    func check(_ name: String, _ body: (Fixture) throws -> Void) {
        count += 1
        do {
            let f = try Fixture()
            defer { f.close() }
            try body(f)
            print("PASS \(name)")
        } catch {
            failures += 1
            fputs("FAIL \(name): \(error)\n", stderr)
        }
    }

    check("text copies its full original content and rich representations after restore") { f in
        let text = "  第一行\r\n第二行 👩🏽‍💻\t\n" + String(repeating: "long text ", count: 300)
        let rtf = Data("{\\rtf1 rich original}".utf8)
        let html = Data("<p><b>HTML original</b></p>".utf8)
        let content = ClipboardContent(kind: .text, text: text, rtf: rtf, html: html)
        let url = try f.record(content)
        _ = try f.hang(url)
        let restored = Line(defaults: f.defaults)
        try require(restored.liveCount == 1, "Text history did not restore")
        guard let item = restored.items.first else { throw CheckFailure(description: "Restored item missing") }
        try require(item.content == content, "Persisted text representations changed")
        restored.copy(item.id, to: f.pasteboard)
        try require(f.pasteboard.string(forType: .string) == text, "Copy truncated text or changed whitespace")
        try require(f.pasteboard.data(forType: .rtf) == rtf, "Copy lost RTF bytes")
        try require(f.pasteboard.data(forType: .html) == html, "Copy lost HTML bytes")
        try require(f.pasteboard.string(forType: .fileURL) == nil, "Private metadata path leaked into copied content")
        try require(f.pasteboard.types?.contains(.init("local.feltboard.clipboard-owner")) == true,
                    "Own-copy marker missing")
    }

    check("web link copies both its original text and actual destination") { f in
        let destination = URL(string: "https://example.com/path?q=reference#part")!
        let rtf = Data("{\\rtf1 formatted link}".utf8)
        let html = Data("<a href=\"https://example.com/path?q=reference#part\">Example reference</a>".utf8)
        let record = try f.record(.init(kind: .link, text: "Example reference", urls: [destination], rtf: rtf, html: html))
        let id = try f.hang(record)
        f.line.copy(id, to: f.pasteboard)
        try require(f.pasteboard.string(forType: .string) == "Example reference", "Link text changed")
        try require(f.pasteboard.string(forType: .URL) == destination.absoluteString, "Link destination was lost")
        try require(f.pasteboard.data(forType: .rtf) == rtf && f.pasteboard.data(forType: .html) == html,
                    "Link classification dropped its original rich representations")
        try require(f.pasteboard.string(forType: .fileURL) == nil, "Link copied its metadata instead of URL")
    }

    check("file card copies every source file in order without altering originals") { f in
        let first = try f.source("first.pdf")
        let second = try f.source("audio.m4a")
        let folder = f.root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sources = [first, second, folder]
        let id = try f.hang(f.record(.init(kind: .files, urls: sources)))
        f.line.copy(id, to: f.pasteboard)
        let items = f.pasteboard.pasteboardItems ?? []
        try require(items.count == sources.count, "File batch was reduced to one file")
        try require(items.compactMap { $0.string(forType: .fileURL) } == sources.map(\.absoluteString),
                    "Copied file URLs changed or reordered")
        try require(items.allSatisfy { $0.types.contains(.init("local.feltboard.clipboard-owner")) },
                    "One file in the copied batch lacks the own-copy marker")
        f.line.discard(id, quietly: true)
        try require(try Data(contentsOf: first) == Data("original file bytes".utf8), "Discard changed the first original")
        try require(try Data(contentsOf: second) == Data("original file bytes".utf8), "Discard changed the second original")
        try require(FileManager.default.fileExists(atPath: folder.path), "Discard removed the source folder")
    }

    check("photo copy retains its image bytes") { f in
        let url = try f.photo()
        let original = try Data(contentsOf: url)
        let id = try f.hang(url)
        f.line.copy(id, to: f.pasteboard)
        try require(f.pasteboard.data(forType: .png) == original, "Photo copy changed PNG bytes")
        try require(f.pasteboard.string(forType: .fileURL) == url.absoluteString, "Photo file representation missing")
    }

    check("mixed history evicts oldest entries at ten and restores the same order") { f in
        var records: [URL] = []
        let original = try f.source("source-document.pdf")
        for index in 0..<12 {
            let url: URL
            switch index % 4 {
            case 0: url = try f.photo(named: "photo-\(index)")
            case 1: url = try f.record(.init(kind: .text, text: "text \(index)"), named: "text-\(index)")
            case 2:
                let target = URL(string: "https://example.com/\(index)")!
                url = try f.record(.init(kind: .link, text: target.absoluteString, urls: [target]), named: "link-\(index)")
            default: url = try f.record(.init(kind: .files, urls: [original]), named: "files-\(index)")
            }
            records.append(url)
            _ = try f.hang(url)
            try require(f.line.liveCount <= 10, "History exceeded the ten-item limit")
        }
        let expected = Array(records.suffix(10))
        try require(f.line.items.filter { !$0.falling }.map(\.url) == expected, "History did not keep the latest ten in order")
        try require(f.defaults.stringArray(forKey: "pegged") == expected.map(\.path), "Saved history includes an evicted entry")
        let restored = Line(defaults: f.defaults)
        try require(restored.liveCount == 10 && restored.items.map(\.url) == expected, "Restart changed the ten retained entries")
        try require(try Data(contentsOf: original) == Data("original file bytes".utf8), "Eviction changed an external source")
        try require(records.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "Eviction deleted an external fixture")
    }

    check("startup trims oversized history and skips malformed metadata") { f in
        var records: [URL] = []
        for index in 0..<15 { records.append(try f.record(.init(kind: .text, text: "history \(index)"))) }
        let malformed = try f.source("broken.feltclip", data: Data("not JSON".utf8))
        let missing = f.root.appendingPathComponent("missing.feltclip")
        f.defaults.set(records.map(\.path) + [malformed.path, missing.path], forKey: "pegged")
        let restored = Line(defaults: f.defaults)
        try require(restored.items.filter { !$0.falling }.map(\.url) == Array(records.suffix(10)),
                    "Restore kept invalid or more than ten entries")
        try require(f.defaults.stringArray(forKey: "pegged") == records.suffix(10).map(\.path),
                    "Trimmed startup history was not persisted")
    }

    check("drag exports original text rather than the private history file") { f in
        let content = ClipboardContent(kind: .text, text: "拖动这段完整文字\nSecond line")
        let id = try f.hang(f.record(content))
        guard let item = f.line.items.first(where: { $0.id == id }) else { throw CheckFailure(description: "Item missing") }
        let exported = item.pasteboardItems()
        try require(exported.count == 1 && exported[0].string(forType: .string) == content.text,
                    "Drag content differs from original text")
        try require(exported[0].string(forType: .fileURL) == nil, "Drag exported private metadata file")
    }

    check("compact panel keeps its proportions and fits available screen bounds") { _ in
        for available in [CGSize(width: 1440, height: 900), CGSize(width: 800, height: 500),
                          CGSize(width: 600, height: 400), CGSize(width: 480, height: 320)] {
            let size = Layout.panelSize(available: available)
            try require(size.width > 0 && size.height > 0, "Panel has no usable area")
            try require(size.width <= available.width && size.height <= available.height,
                        "Panel extends beyond the available screen")
            try require(size.width <= 840 && size.height <= 560, "Panel grows back into a full-screen strip")
            try require(abs(size.width / size.height - 1.5) < 0.01, "Panel loses its compact proportions")
            let viewport = Layout.cardViewport(for: size)
            try require(viewport.minX > 0 && viewport.maxX < size.width && viewport.minY >= 30,
                        "Cards have no frame inset or room above their pins")
            try require(viewport.height > 0 && viewport.maxY < size.height, "Card viewport leaves panel bounds")
            let camera = Layout.cameraFrame(for: size)
            try require(CGRect(origin: .zero, size: size).contains(camera),
                        "Bottom-right camera leaves the board")
            try require(viewport.maxY > camera.minY + camera.height / 2,
                        "An empty footer still hides cards beside the camera")
        }
    }

    check("cloth height follows visible text while long previews stay bounded") { f in
        let scale = Layout.size.scale
        let samples = [
            "felt pin board",
            "First line\nSecond line\nThird line",
            "A longer note should wrap naturally across several lines on the cloth.",
            String(repeating: "A long note with many lines.\n", count: 40),
            "中文布片 👩🏽‍💻\n第二行文字 🌿\n\n最后一行",
            ""
        ]
        let sizes = samples.map { MaterialCard.size(for: .init(kind: .text, text: $0)) }
        try require(sizes[0].height < 90 * scale, "A one-line note still leaves a tall empty cloth")
        try require(sizes[1].height > sizes[0].height && sizes[2].height > sizes[0].height,
                    "Explicit newlines or wrapped text do not grow the cloth")
        try require(abs(sizes[3].height - 156 * scale) < 0.01,
                    "Long text does not stop at the maximum card height")
        try require(sizes.allSatisfy { $0.height >= 58 * scale && $0.height <= 156 * scale },
                    "Empty, multilingual or multiline text escapes the cloth height bounds")
        try require(sizes.allSatisfy { $0.width == sizes[0].width }, "Text length changes the cloth width")
        for text in samples { _ = try f.hang(f.record(.init(kind: .text, text: text))) }
        let frames = Layout.frames(items: f.line.items, width: 840)
        for (index, item) in f.line.items.enumerated() {
            try require(PeggedView.cardSize(for: item) == sizes[index] && frames[item.id]?.size == sizes[index],
                        "Board layout still reserves the old fixed height for a text card")
        }
    }

    check("different card widths keep a constant edge gap in newest-first reading order") { f in
        _ = try f.hang(f.photo(width: 10, height: 40))
        _ = try f.hang(f.photo(width: 40, height: 10))
        _ = try f.hang(f.record(.init(kind: .text, text: "布料")))
        _ = try f.hang(f.record(.init(kind: .link, text: "https://example.com", urls: [URL(string: "https://example.com")!])))
        let items = f.line.items
        let size = CGSize(width: 2000, height: 560)
        let widths = items.map { PeggedView.cardSize(for: $0).width }
        try require(abs(widths[0] - widths[1]) > 20, "Fixture images do not exercise different card widths")
        let frames = Layout.frames(items: items, width: size.width)
        let ordered = items.reversed().compactMap { frames[$0.id] }
        try require(ordered.count == items.count, "One or more cards have no frame")
        for index in 1..<ordered.count {
            let gap = ordered[index].minX - ordered[index - 1].maxX
            try require(abs(gap - 20) < 0.01, "Card edge gap varies with image width")
            try require(abs(ordered[index].minY - ordered[0].minY) < 0.01, "A fitting row wraps or reverses its order")
        }
        let viewport = Layout.cardViewport(for: size)
        try require(abs(ordered[0].minX - viewport.minX) < 0.01, "Newest card does not begin at the reading edge")
        try require(ordered.allSatisfy { viewport.contains($0) }, "A fitting card overlaps the frame")
        try require(Layout.maximumScroll(items: items, width: size.width, height: size.height) == 0,
                    "Fitting cards unexpectedly scroll")
    }

    check("ten mixed cards wrap into rows without overlaps or clipped horizontal edges") { f in
        for index in 0..<10 {
            let url: URL
            if index % 3 == 0 { url = try f.photo(width: 10, height: 40) }
            else if index % 3 == 1 { url = try f.photo(width: 40, height: 10) }
            else { url = try f.record(.init(kind: .text, text: "text \(index)")) }
            _ = try f.hang(url)
        }
        let items = f.line.items
        let size = CGSize(width: 840, height: 560)
        let viewport = Layout.cardViewport(for: size)
        let frames = Layout.frames(items: items, width: size.width)
        let ordered = items.reversed().compactMap { frames[$0.id] }
        try require(ordered.count == 10, "Layout omitted retained cards")
        try require(ordered.last!.minY > ordered.first!.minY, "Cards remain in one long horizontal strip")
        for (index, frame) in ordered.enumerated() {
            try require(frame.minX >= viewport.minX && frame.maxX <= viewport.maxX,
                        "A card extends through the side of the board")
            try require(frame.minY >= viewport.minY, "A card starts above the card viewport")
            for other in ordered.prefix(index) {
                try require(!frame.intersects(other), "Cards overlap")
            }
            guard index > 0 else { continue }
            let previous = ordered[index - 1]
            if abs(frame.minY - previous.minY) < 0.01 {
                try require(abs(frame.minX - previous.maxX - 20) < 0.01, "Row edge spacing changed")
            } else {
                try require(frame.minY > previous.minY && abs(frame.minX - viewport.minX) < 0.01,
                            "Wrapped row does not follow newest-first reading order")
                let precedingRows = ordered.prefix(index).filter { $0.minY < frame.minY }
                let previousBottom = precedingRows.map(\.maxY).max()!
                try require(frame.minY - previousBottom >= 30, "Rows collide with paper or pin shadows")
            }
        }
    }

    check("vertical scrolling reaches all ten cards and clamps at newest and oldest ends") { f in
        let longText = String(repeating: "Long content on the cloth.\n", count: 12)
        for index in 0..<10 { _ = try f.hang(f.record(.init(kind: .text, text: "text \(index)\n" + longText))) }
        f.line.viewportWidth = 840
        f.line.viewportHeight = 560
        let items = f.line.items
        let size = CGSize(width: f.line.viewportWidth, height: f.line.viewportHeight)
        let viewport = Layout.cardViewport(for: size)
        guard let newest = Layout.frame(for: items.last!.id, items: items, width: size.width,
                                       height: size.height, scroll: 0) else {
            throw CheckFailure(description: "Newest card has no frame")
        }
        try require(viewport.contains(newest), "Newest card is not fully visible at default scroll")
        try require(newest.minY - PeggedView.cardOffsetBelowTop >= viewport.minY,
                    "First-row pin is clipped at the top of the card viewport")
        f.line.scroll(by: 100_000)
        try require(f.line.scroll == f.line.maximumScroll && f.line.maximumScroll > 0, "Scrolling past the old end did not clamp")
        guard let oldest = Layout.frame(for: items[0].id, items: items, width: size.width,
                                       height: size.height, scroll: f.line.scroll) else {
            throw CheckFailure(description: "Oldest card has no frame")
        }
        try require(viewport.contains(oldest), "Oldest card cannot be fully reached")
        let unscrolled = Layout.frames(items: items, width: size.width)
        for item in items {
            guard let initial = unscrolled[item.id] else { throw CheckFailure(description: "Card omitted from layout") }
            let offset = min(f.line.maximumScroll,
                             max(0, initial.minY - PeggedView.cardOffsetBelowTop - viewport.minY))
            guard let visible = Layout.frame(for: item.id, items: items, width: size.width,
                                             height: size.height, scroll: offset) else {
                throw CheckFailure(description: "Scrolled card has no frame")
            }
            try require(viewport.contains(visible), "A retained card can never be fully viewed")
            try require(visible.minY - PeggedView.cardOffsetBelowTop >= viewport.minY,
                        "A retained card cannot show its pin together with its full paper")
            try require(!visible.insetBy(dx: 0, dy: -Layout.shadowInset)
                .intersects(Layout.cameraFrame(for: size)),
                        "A retained card can never be scrolled clear of the camera")
        }
        f.line.scroll(by: -100_000)
        try require(f.line.scroll == 0, "Scrolling past the new end did not clamp")
    }

    check("floating camera only adds scroll travel for cards in its column") { f in
        let size = CGSize(width: 660, height: 440)
        let longText = String(repeating: "Long content on the cloth.\n", count: 12)
        for index in 0..<5 { _ = try f.hang(f.record(.init(kind: .text, text: "text \(index)\n" + longText))) }
        let viewport = Layout.cardViewport(for: size)
        let camera = Layout.cameraFrame(for: size)
        let withoutOverlap = Layout.frames(items: f.line.items, width: size.width)
        let bottom = withoutOverlap.values.map(\.maxY).max()!
        let naturalEnd = max(0, bottom + Layout.shadowInset - viewport.maxY)
        try require(Layout.maximumScroll(items: f.line.items, width: size.width, height: size.height) == naturalEnd,
                    "Left-hand cards unnecessarily reserve a camera footer")
        try require(withoutOverlap.values.contains { $0.minX < camera.minX && $0.maxY > camera.minY },
                    "Fixture does not exercise cards beside the camera")

        _ = try f.hang(f.record(.init(kind: .text, text: "text 5\n" + longText)))
        let maximum = Layout.maximumScroll(items: f.line.items, width: size.width, height: size.height)
        try require(maximum > naturalEnd, "An obscured right-hand card gets no extra scroll travel")
        let frames = Layout.frames(items: f.line.items, width: size.width)
        for item in f.line.items {
            let original = frames[item.id]!
            let offset = min(maximum, max(0, original.minY - PeggedView.cardOffsetBelowTop - viewport.minY))
            let visible = Layout.frame(for: item.id, items: f.line.items, width: size.width,
                                       height: size.height, scroll: offset)!
            try require(viewport.contains(visible) && !visible.intersects(camera),
                        "A card cannot be fully viewed clear of the floating camera")
        }
    }

    check("removed cards leave no empty slot and empty history does not scroll") { f in
        for index in 0..<5 { _ = try f.hang(f.record(.init(kind: .text, text: "text \(index)"))) }
        let newest = f.line.items.last!.id
        f.line.drop(newest, quietly: true)
        let frames = Layout.frames(items: f.line.items, width: 840)
        try require(frames[newest] == nil && frames.count == 4, "Falling card still reserves a layout slot")
        let next = f.line.items[f.line.items.count - 2].id
        let viewport = Layout.cardViewport(for: CGSize(width: 840, height: 560))
        try require(frames[next]?.minX == viewport.minX, "Removing newest leaves an empty leading slot")
        try require(Layout.maximumScroll(items: [], width: 840, height: 560) == 0, "Empty board can scroll")
    }

    print("\(count - failures)/\(count) board content checks passed; isolated pasteboards and defaults only.")
    return failures == 0 ? 0 : 1
}

exit(MainActor.assumeIsolated { runChecks() })
