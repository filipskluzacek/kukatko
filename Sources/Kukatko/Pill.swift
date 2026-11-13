import AppKit
import SwiftUI

/// Small floating bar that appears next to a selection: Krátce · Dlouze · Proč · Obrázek.
@MainActor
final class PillController {
    private var panel: PillPanel?
    private var captured: Captured?
    private var hideWork: DispatchWorkItem?

    func show(for c: Captured, force: Bool = false) {
        // Don't pop over our own open result panel for the same thing.
        if !force, AppDelegate.shared.result.isVisible, AppDelegate.shared.result.isPinned { return }
        captured = c
        let view = PillView(isImage: c.content.isImage,
                            onPick: { [weak self] mode in self?.pick(mode) },
                            onHover: { [weak self] inside in self?.hovering(inside) })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize

        let p = panel ?? PillPanel()
        panel = p
        p.contentView = host
        let frame = Self.frame(for: size, anchor: c.anchor ?? NSRect(origin: NSEvent.mouseLocation, size: .zero))
        p.setFrame(frame, display: true)

        p.alphaValue = 0
        p.orderFrontRegardless()
        let target = frame
        p.setFrame(target.offsetBy(dx: 0, dy: -4), display: false)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            p.animator().alphaValue = 1
            p.animator().setFrame(target, display: true)
        }
        scheduleHide(after: force ? 12 : 7)
    }

    func hide() {
        hideWork?.cancel()
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }

    private func pick(_ mode: ResultMode) {
        guard let c = captured else { return }
        hideWork?.cancel()
        panel?.orderOut(nil)
        AppDelegate.shared.result.open(c, mode: mode)
    }

    private func hovering(_ inside: Bool) {
        if inside { hideWork?.cancel() } else { scheduleHide(after: 4) }
    }

    private func scheduleHide(after s: Double) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    private static func frame(for size: NSSize, anchor: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main!
        let vis = screen.visibleFrame
        let gap: CGFloat = anchor.height > 0 ? 8 : 16
        var x = anchor.midX - size.width / 2
        if anchor.width > 600 { x = anchor.minX } // long multi-line selection: hug the start
        var y = anchor.maxY + gap
        if y + size.height > vis.maxY { y = anchor.minY - gap - size.height }
        x = min(max(x, vis.minX + 6), vis.maxX - size.width - 6)
        y = min(max(y, vis.minY + 6), vis.maxY - size.height - 6)
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
}

final class PillPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct PillView: View {
    let isImage: Bool
    let onPick: (ResultMode) -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 2) {
                PillButton(title: "Krátce", symbol: "text.bubble") { onPick(.short) }
                PillButton(title: "Dlouze", symbol: "text.alignleft") { onPick(.long) }
                PillButton(title: "Proč", symbol: "questionmark.bubble") { onPick(.why) }
                PillButton(title: isImage ? "Podobné" : "Obrázek", symbol: "photo") { onPick(.images) }
            }
            .padding(4)
            .fixedSize()
            .glassEffect(.regular, in: Capsule())
        }
        .padding(10) // room for the glass shadow
        .onHover(perform: onHover)
    }
}

private struct PillButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
                Text(title).font(.system(size: 12.5, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(hover ? 0.10 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}
