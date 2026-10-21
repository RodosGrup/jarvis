import SwiftUI

/// Ana pencere: durum, aç/kapa, açık oturumlar ve konuşma dökümü.
struct MenuView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            sessionsSection
            Divider()
            transcript
            Divider()
            footer
        }
        .padding(14)
        .frame(minWidth: 380, minHeight: 480)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: state.toggle) {
                ZStack {
                    Circle().fill(orbColor.opacity(0.18)).frame(width: 44, height: 44)
                    Circle().fill(orbColor).frame(width: 14, height: 14)
                }
            }
            .buttonStyle(.plain)
            .help(state.isOn ? "Dinlemeyi durdur" : "Dinlemeye başla")
            VStack(alignment: .leading, spacing: 2) {
                Text("Jarvis").font(.headline)
                Text(state.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(state.isOn ? "Durdur" : "Dinle", action: state.toggle)
                .keyboardShortcut(.space, modifiers: [])
        }
    }

    private var orbColor: Color {
        switch state.phase {
        case .off: return .gray
        case .standby: return .blue.opacity(0.6)
        case .connecting: return .yellow
        case .listening: return .green
        case .thinking: return .orange
        case .speaking: return .blue
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Açık oturumlar").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            if state.sessions.isEmpty {
                Text("Açık Claude oturumu yok.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(state.sessions) { s in
                HStack(spacing: 8) {
                    Circle().fill(s.isIdle ? Color.gray : Color.blue).frame(width: 7, height: 7)
                    Text(s.name).font(.callout.weight(.medium))
                    Text(s.project).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(s.statusLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Konuşma").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(state.entries) { e in
                        HStack(alignment: .top, spacing: 8) {
                            Text(label(e.kind)).font(.caption2.weight(.semibold)).foregroundStyle(color(e.kind))
                                .frame(width: 52, alignment: .leading)
                            Text(e.text).font(e.kind == .tool ? .system(.caption, design: .monospaced) : .callout)
                                .foregroundStyle(e.kind == .tool || e.kind == .system ? .secondary : .primary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func label(_ k: AppState.Entry.Kind) -> String {
        switch k { case .you: "Sen"; case .jarvis: "Jarvis"; case .system: "Sistem"; case .tool: "Araç"; case .error: "Hata" }
    }

    private func color(_ k: AppState.Entry.Kind) -> Color {
        switch k { case .you: .green; case .jarvis: .blue; case .system: .orange; case .tool: .secondary; case .error: .red }
    }

    private var footer: some View {
        HStack {
            Toggle("Küre", isOn: Binding(get: { state.orbVisible }, set: { state.setOrb(visible: $0) }))
                .toggleStyle(.switch).controlSize(.small)
            Spacer()
            Button("Ayarlar…") { openSettings() }
        }
        .font(.callout)
    }
}
