import AppKit

/// Writes a string to the system pasteboard. Injected so tests never touch the real
/// clipboard (which would clobber whatever the user had copied).
@MainActor
public protocol PasteboardWriting: Sendable {
    func copy(_ string: String)
}

/// The production writer: the general pasteboard, as plain text.
public struct NSPasteboardWriter: PasteboardWriting {
    public init() {}

    public func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
