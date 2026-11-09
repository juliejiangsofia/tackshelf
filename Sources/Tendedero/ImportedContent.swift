import Foundation

/// Source information belongs to the completed clipboard read, not to whatever
/// happens to be on the clipboard when its asynchronous result is delivered.
struct ImportedContent: Sendable {
    let url: URL
    /// The system's remote marker identifies a cross-device image; it does not
    /// identify which kind of Apple device supplied it.
    let isRemoteImage: Bool
    let allowsAutomaticReveal: Bool

    var shouldAutomaticallyReveal: Bool {
        isRemoteImage && allowsAutomaticReveal
    }
}
