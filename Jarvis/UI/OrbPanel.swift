import AppKit

/// Küreyi taşıyan çerçevesiz, her zaman üstte pencere. Odak çalmaz: kullanıcı başka uygulamada çalışırken köşede durur.
///
/// Fare olaylarını tamamen yok sayar (`ignoresMouseEvents`). Ölçüldü: macOS 27'de çerçevesiz paneldeki
/// NSHostingView, fare üstünden geçince SwiftUI hit-test'inde (PointerBridge.mouseMoved) SIGSEGV ile çöküyor.
/// Bedeli: pencere sürüklenemez; sağ alt köşede sabit durur.
@MainActor
final class OrbPanel {
    private var panel: NSPanel?

    func show(state: AppState) {
        if let panel { panel.orderFrontRegardless(); return }
        let size = NSSize(width: 300, height: 300)
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false

        let view = OrbView(frame: NSRect(origin: .zero, size: size))
        view.sample = { [weak state] in
            let (i, o) = state?.levels ?? (0, 0)
            return OrbView.Sample(phase: state?.phase ?? .off, inputLevel: i, outputLevel: o)
        }
        p.contentView = view

        // Sağ alt köşe, menü çubuğu ve Dock'a çarpmadan.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - size.width - 24, y: f.minY + 24))
        }
        p.orderFrontRegardless()
        panel = p
    }

    func hide() {
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }
}
