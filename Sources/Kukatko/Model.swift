import AppKit
import ApplicationServices
import Security

enum Content {
    case text(String)
    case image(NSImage)

    var isImage: Bool { if case .image = self { return true } else { return false } }
    var text: String? { if case .text(let t) = self { return t } else { return nil } }
    var image: NSImage? { if case .image(let i) = self { return i } else { return nil } }
}

/// What the user marked, plus where it came from.
struct Captured {
    var content: Content
    var app: NSRunningApplication?
    /// Screen rect of the selection in Cocoa coordinates (bottom-left origin), if known.
    var anchor: NSRect?
    /// A bit of surrounding text, to disambiguate short selections.
    var context: String?
}

enum ResultMode: String, CaseIterable, Identifiable {
    case short, long, images
    var id: String { rawValue }
    var title: String {
        switch self {
        case .short: return "Krátce"
        case .long: return "Dlouze"
        case .images: return "Obrázky"
        }
    }
    var symbol: String {
        switch self {
        case .short: return "text.bubble"
        case .long: return "doc.text.magnifyingglass"
        case .images: return "photo.on.rectangle.angled"
        }
    }
}

enum AIModel: String, CaseIterable, Identifiable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .opus: return "Claude Opus 5.5 (nejchytřejší)"
        case .sonnet: return "Claude Sonnet 5.5 (vyvážený)"
        case .haiku: return "Claude Haiku 5.5 (nejrychlejší)"
        }
    }
}

enum Backend: String, CaseIterable, Identifiable {
    case gemini, cli, api
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gemini: return "Google Gemini (cloud, zdarma)"
        case .cli: return "Claude Code (předplatné)"
        case .api: return "Claude API (platí se za použití)"
        }
    }
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    func registerDefaults() {
        d.register(defaults: [
            "pillOnSelection": true,
            "pillOnImageCopy": true,
            "model": AIModel.opus.rawValue,
            "backend": Backend.gemini.rawValue,
            "geminiModel": "gemini-3.8-flash",
            "language": "česky",
        ])
    }

    var pillOnSelection: Bool {
        get { d.bool(forKey: "pillOnSelection") }
        set { d.set(newValue, forKey: "pillOnSelection") }
    }
    var pillOnImageCopy: Bool {
        get { d.bool(forKey: "pillOnImageCopy") }
        set { d.set(newValue, forKey: "pillOnImageCopy") }
    }
    var model: AIModel {
        get { AIModel(rawValue: d.string(forKey: "model") ?? "") ?? .opus }
        set { d.set(newValue.rawValue, forKey: "model") }
    }
    var backend: Backend {
        get { Backend(rawValue: d.string(forKey: "backend") ?? "") ?? .gemini }
        set { d.set(newValue.rawValue, forKey: "backend") }
    }
    var language: String {
        get { d.string(forKey: "language") ?? "česky" }
        set { d.set(newValue, forKey: "language") }
    }
    var excludedApps: [String] {
        get { d.stringArray(forKey: "excludedApps") ?? [] }
        set { d.set(newValue, forKey: "excludedApps") }
    }

    var geminiModel: String {
        get { d.string(forKey: "geminiModel") ?? "gemini-3.8-flash" }
        set { d.set(newValue, forKey: "geminiModel") }
    }
    var geminiKey: String? {
        get { Keychain.read(account: "gemini-api-key") }
        set {
            if let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                Keychain.write(v, account: "gemini-api-key")
            } else {
                Keychain.delete(account: "gemini-api-key")
            }
        }
    }

    var apiKey: String? {
        get { Keychain.read(account: "anthropic-api-key") }
        set {
            if let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                Keychain.write(v, account: "anthropic-api-key")
            } else {
                Keychain.delete(account: "anthropic-api-key")
            }
        }
    }
}

enum Keychain {
    private static let service = "cz.filipskluzacek.kukatko"

    static func read(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        delete(account: account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}

enum KeyCode {
    static let c: UInt32 = 8
    static let e: UInt32 = 14
    static let r: UInt32 = 15
}

extension NSImage {
    /// JPEG/PNG data scaled so the long edge is at most `maxEdge` px – what the API accepts comfortably.
    func encodedForAI(maxEdge: CGFloat = 1568) -> (data: Data, mediaType: String)? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxEdge / max(w, h))
        let tw = max(1, Int(w * scale)), th = max(1, Int(h * scale))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: tw, height: th))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let scaled = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaled)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return (data, "image/jpeg")
    }
}
