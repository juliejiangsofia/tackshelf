import Foundation

/// Non-image clipboard entries are small, private metadata files alongside
/// collected PNGs. Local file URLs refer to the original files; only remote
/// attachments explicitly identified below belong to the clipboard history.
struct ClipboardContent: Codable, Equatable {
    enum Kind: String, Codable {
        case text, link, files
    }

    static let extensionName = "feltclip"

    let kind: Kind
    let text: String
    let urls: [URL]
    let rtf: Data?
    let html: Data?
    let ownedAttachmentDirectory: URL?

    init(kind: Kind, text: String = "", urls: [URL] = [], rtf: Data? = nil,
         html: Data? = nil, ownedAttachmentDirectory: URL? = nil) {
        self.kind = kind
        self.text = text
        self.urls = urls
        self.rtf = rtf
        self.html = html
        self.ownedAttachmentDirectory = ownedAttachmentDirectory
    }

    static func load(from url: URL) -> ClipboardContent? {
        guard url.pathExtension == extensionName,
              let data = try? Data(contentsOf: url),
              let content = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        return content
    }
}
