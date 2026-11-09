import AppKit
import ImageIO

// Exercise the actual helper-to-shelf file boundary with generated images in
// a temporary directory. No camera, general pasteboard, or real history.
private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(description: message) }
}

@MainActor
private func runChecks() -> Int32 {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("PhoneCameraChecks-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    var count = 0
    var failures = 0
    func check(_ name: String, _ body: (URL, URL, URL) throws -> Void) {
        count += 1
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stage = folder.appendingPathComponent("stage", isDirectory: true)
        let dest = folder.appendingPathComponent("shelf", isDirectory: true)
        do {
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            try body(folder, stage, dest)
            print("PASS \(name)")
        } catch {
            failures += 1
            fputs("FAIL \(name): \(error)\n", stderr)
        }
    }
    func image(at url: URL) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6,
                                            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 24, bitsPerPixel: 24),
              let bytes = bitmap.bitmapData else { throw Failure(description: "No bitmap") }
        memset(bytes, 150, 8 * 6 * 3)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(description: "No PNG")
        }
        try data.write(to: url)
        return data
    }

    check("received photo moves into shelf storage with its bytes and private permissions") { _, stage, dest in
        let source = stage.appendingPathComponent("photo.png")
        let original = try image(at: source)
        let target = try PhoneCameraCapture.importPhoto(from: source, staging: stage, destination: dest, requestID: UUID())
        try require(target.deletingLastPathComponent() == dest, "Photo stored outside shelf")
        try require(!fm.fileExists(atPath: source.path), "Staging photo remained")
        try require(try Data(contentsOf: target) == original, "Photo data changed")
        let attributes = try fm.attributesOfItem(atPath: target.path)
        try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Permissions are not 0600")
    }

    check("a helper path outside its request is rejected and preserved") { folder, stage, dest in
        let source = folder.appendingPathComponent("external.png")
        let original = try image(at: source)
        do {
            _ = try PhoneCameraCapture.importPhoto(from: source, staging: stage, destination: dest, requestID: UUID())
            throw Failure(description: "Accepted an external file")
        } catch is CocoaError { }
        try require(try Data(contentsOf: source) == original, "External file was changed")
    }

    check("a staging symlink cannot pull an external photo into the shelf") { folder, stage, dest in
        let original = folder.appendingPathComponent("external.png")
        _ = try image(at: original)
        let link = stage.appendingPathComponent("photo.png")
        try fm.createSymbolicLink(at: link, withDestinationURL: original)
        do {
            _ = try PhoneCameraCapture.importPhoto(from: link, staging: stage, destination: dest, requestID: UUID())
            throw Failure(description: "Accepted a symlink")
        } catch is CocoaError { }
        try require(fm.fileExists(atPath: original.path), "External photo was moved")
    }

    check("invalid image data never becomes a shelf photo") { _, stage, dest in
        let source = stage.appendingPathComponent("photo.png")
        try Data("not a photo".utf8).write(to: source)
        do {
            _ = try PhoneCameraCapture.importPhoto(from: source, staging: stage, destination: dest, requestID: UUID())
            throw Failure(description: "Accepted invalid image bytes")
        } catch is CocoaError { }
        try require(fm.fileExists(atPath: source.path), "Rejected file was moved")
    }

    check("repeated result cannot overwrite an already imported photo") { _, stage, dest in
        let id = UUID()
        let first = stage.appendingPathComponent("first.png")
        let original = try image(at: first)
        let target = try PhoneCameraCapture.importPhoto(from: first, staging: stage, destination: dest, requestID: id)
        let second = stage.appendingPathComponent("second.png")
        _ = try image(at: second)
        do {
            _ = try PhoneCameraCapture.importPhoto(from: second, staging: stage, destination: dest, requestID: id)
            throw Failure(description: "Overwrote prior capture")
        } catch is CocoaError { }
        try require(try Data(contentsOf: target) == original, "Prior photo changed")
        try require(fm.fileExists(atPath: second.path), "Duplicate source was consumed")
    }

    check("camera JPEG pastes as an upright image without a file URL") { folder, stage, dest in
        let png = stage.appendingPathComponent("source.png")
        let original = try image(at: png)
        guard let source = CGImageSourceCreateWithData(original as CFData, nil) else {
            throw Failure(description: "Cannot create camera fixture")
        }
        let bytes = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil) else {
            throw Failure(description: "Cannot encode camera JPEG")
        }
        CGImageDestinationAddImageFromSource(encoder, source, 0,
                                            [kCGImagePropertyOrientation: 6] as CFDictionary)
        try require(CGImageDestinationFinalize(encoder), "Camera fixture encoding failed")
        let jpeg = stage.appendingPathComponent("photo.jpg")
        try (bytes as Data).write(to: jpeg)
        let saved = try PhoneCameraCapture.importPhoto(from: jpeg, staging: stage,
                                                       destination: dest, requestID: UUID())
        let pb = NSPasteboard(name: .init("local.feltboard.phone-checks.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        try require(PhoneCameraCapture.copyPhoto(saved, to: pb), "Photo was not copied")
        try require(pb.pasteboardItems?.count == 1, "Copy created multiple attachments")
        try require(pb.string(forType: .fileURL) == nil, "Copy offers a file URL instead of an image")
        try require(pb.string(forType: .init("local.feltboard.clipboard-owner")) == "1", "Missing collection-loop marker")
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pb.data(forType: type), let bitmap = NSBitmapImageRep(data: data) else {
                throw Failure(description: "Missing readable \(type.rawValue)")
            }
            try require(bitmap.pixelsWide == 6 && bitmap.pixelsHigh == 8, "Camera orientation was lost")
        }
        try require(NSImage(pasteboard: pb) != nil, "A native image consumer cannot paste the photo")
        try require(try Data(contentsOf: saved) == bytes as Data, "Copy changed the saved photo")
    }

    check("a failed photo copy preserves the previous clipboard") { folder, _, _ in
        let broken = folder.appendingPathComponent("broken.jpg")
        try Data("invalid camera data".utf8).write(to: broken)
        let pb = NSPasteboard(name: .init("local.feltboard.phone-checks.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("previous copy", forType: .string)
        let count = pb.changeCount
        try require(!PhoneCameraCapture.copyPhoto(broken, to: pb), "Copied an invalid image")
        try require(pb.changeCount == count && pb.string(forType: .string) == "previous copy",
                    "Failed copy replaced the previous clipboard")
    }

    check("camera shortcut only accepts its fixed local command") { _, _, _ in
        for address in ["feltboard-preview://camera", "FELTBOARD-PREVIEW://CAMERA/"] {
            try require(PhoneCameraCapture.isLaunchURL(URL(string: address)!), "Shortcut was rejected")
        }
        for address in ["https://camera", "feltboard-preview://other", "feltboard-preview://camera/other",
                        "feltboard-preview://camera?file=/tmp/photo.jpg", "feltboard-preview://camera#data",
                        "feltboard-preview://user@camera", "feltboard-preview://camera:80"] {
            try require(!PhoneCameraCapture.isLaunchURL(URL(string: address)!), "Unexpected camera command accepted")
        }
    }

    print("\(count - failures)/\(count) phone camera checks passed")
    return failures == 0 ? 0 : 1
}

let result = MainActor.assumeIsolated { runChecks() }
exit(result)
