import SwiftUI

/// Menü çubuğunda düz bir menü, oturumlar ve konuşma dökümü için normal bir pencere.
///
/// Neden `.menu` stili: macOS 27'de MenuBarExtra'nın `.window` stilindeki SwiftUI içeriği, fare üstünde gezince
/// SwiftUI hit-test'inde (PointerBridge.mouseMoved → MainActor.assumeIsolated) SIGSEGV ile çöküyor. Ölçüldü, üç kez.
/// Düz NSMenu'de ve normal pencerede bu yol çalışmıyor.
@main
struct JarvisApp: App {
    @StateObject private var state = AppState()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        MenuBarExtra {
            Button(state.isOn ? "Durdur" : "Dinle") { state.toggle() }
            if state.phase == .standby {
                Button("Uyandır") { state.wakeUp() }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
            }
            Text(state.status)
            Divider()
            Toggle("Küre", isOn: Binding(get: { state.orbVisible }, set: { state.setOrb(visible: $0) }))
            Button("Pencereyi aç") { show { openWindow(id: "main") } }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Ayarlar…") { show { openSettings() } }
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Çıkış") { state.shutdown(); NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: icon)
        }
        .menuBarExtraStyle(.menu)

        Window("Jarvis", id: "main") {
            MenuView().environmentObject(state)
        }
        .defaultSize(width: 400, height: 560)

        Settings {
            SettingsView().environmentObject(state)
        }
    }

    /// Dock'ta olmayan uygulamanın penceresi arkada kalıyor; önce öne al, sonra aç.
    private func show(_ open: () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        open()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.activate(ignoringOtherApps: true) }
    }

    private var icon: String {
        switch state.phase {
        case .off: "waveform.circle"
        case .standby: "moon.circle"
        case .connecting: "waveform.circle.fill"
        case .listening: "waveform.badge.mic"
        case .thinking: "ellipsis.circle.fill"
        case .speaking: "speaker.wave.2.circle.fill"
        }
    }
}
