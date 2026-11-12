import AppKit
import UniformTypeIdentifiers

/// Notices when an image lands on the clipboard (Copy Image, ⌃⇧⌘4 screenshot…) and offers the pill.
final class ClipboardWatcher {
    var onImage: ((NSImage) -> Void)?

    static var suppressed = false
    private static var lastSeen = NSPasteboard.general.changeCount
    private var timer: Timer?

    static func acknowledge(_ count: Int) { lastSeen = count }

    func start() {
        Self.lastSeen = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let pb = NSPasteboard.general
        guard !Self.suppressed, pb.changeCount != Self.lastSeen else { return }
        Self.lastSeen = pb.changeCount
        // Our own copies (from the result panel) mark themselves.
        if pb.types?.contains(.kukatkoOwn) == true { return }
        guard let content = Self.content(of: pb), case .image(let img) = content else { return }
        onImage?(img)
    }

    static func currentContent() -> Content? { content(of: .general) }

    static func content(of pb: NSPasteboard) -> Content? {
        let types = pb.types ?? []
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) { return nil }

        // Image files copied in Finder.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first,
           let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let img = NSImage(contentsOf: url) {
            return .image(img)
        }

        let hasString = types.contains(.string)
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]
        let hasImage = types.contains(where: { imageTypes.contains($0) })

        if hasImage && !hasString, let img = NSImage(pasteboard: pb), img.isValid {
            return .image(img)
        }
        if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return .text(String(s.prefix(12000)))
        }
        if hasImage, let img = NSImage(pasteboard: pb), img.isValid {
            return .image(img)
        }
        return nil
    }
}

extension NSPasteboard.PasteboardType {
    static let kukatkoOwn = NSPasteboard.PasteboardType("cz.filipskluzacek.kukatko.own")
}
