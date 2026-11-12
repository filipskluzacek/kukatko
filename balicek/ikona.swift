import AppKit

// Renders the 1024 px app icon: a squircle of warm ink with a lens over lines of text.
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

// Soft drop shadow like Big Sur+ icons
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
NSColor.black.setFill(); squircle.fill()
ctx.restoreGState()

squircle.addClip()
let bg = NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.20, blue: 0.42, alpha: 1),
                             NSColor(srgbRed: 0.33, green: 0.25, blue: 0.62, alpha: 1)])!
bg.draw(in: rect, angle: -60)

// Lines of "text"
NSColor.white.withAlphaComponent(0.20).setFill()
let lineW: [CGFloat] = [560, 470, 600, 380, 520]
for (i, w) in lineW.enumerated() {
    let y = rect.maxY - 190 - CGFloat(i) * 112
    NSBezierPath(roundedRect: CGRect(x: rect.minX + 110, y: y, width: w, height: 46), xRadius: 23, yRadius: 23).fill()
}
// Highlighted word under the lens
NSColor(srgbRed: 1.0, green: 0.82, blue: 0.35, alpha: 1).setFill()
NSBezierPath(roundedRect: CGRect(x: rect.minX + 250, y: rect.maxY - 190 - 2 * 112 - 10, width: 260, height: 66), xRadius: 20, yRadius: 20).fill()

// Lens
let c = CGPoint(x: rect.minX + 390, y: rect.maxY - 190 - 2 * 112 + 23)
let r: CGFloat = 175
let glass = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
NSColor.white.withAlphaComponent(0.16).setFill(); glass.fill()
glass.lineWidth = 46
NSColor.white.setStroke(); glass.stroke()
// Handle
let h = NSBezierPath()
let a = CGFloat.pi * 1.75
h.move(to: CGPoint(x: c.x + cos(a) * (r + 18), y: c.y + sin(a) * (r + 18)))
h.line(to: CGPoint(x: c.x + cos(a) * (r + 230), y: c.y + sin(a) * (r + 230)))
h.lineWidth = 78; h.lineCapStyle = .round
h.stroke()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
