import Foundation

/// Görev verilen oturumları izler: çalışıp boşa düşünce "bitti" der ve son mesajını getirir.
/// Orkestratör cevap alamadığı için bitiş tespiti tamamen Claude'un kayıt dosyalarına dayanır.
@MainActor
final class Watcher {
    enum Event {
        case finished(session: String, text: String)
        case stuck(session: String)
        case gone(session: String)
    }

    private struct Tracked {
        let since: Date
        var sawBusy = false
        var warned = false
    }

    private var tracked: [String: Tracked] = [:]
    private var lastStatus: [String: String] = [:]
    private var timer: Timer?
    var onEvent: (Event) -> Void = { _ in }
    var onSessions: ([ClaudeSession]) -> Void = { _ in }

    func start(interval: TimeInterval = 1.5) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func stop() { timer?.invalidate() }

    /// Bu oturuma görev verildi; boşa düşünce haber ver.
    func track(_ name: String) { tracked[name] = Tracked(since: Date()) }

    private func tick() {
        let sessions = SessionStore.list()
        onSessions(sessions)
        var seen = Set<String>()
        for s in sessions {
            seen.insert(s.name)
            let prev = lastStatus[s.name]
            lastStatus[s.name] = s.status
            guard var t = tracked[s.name] else { continue }
            if !s.isIdle { t.sawBusy = true }
            if t.sawBusy, prev != "idle", s.isIdle {
                // Görev verildi, çalıştı, şimdi boşta: bitti demektir.
                tracked[s.name] = nil
                onEvent(.finished(session: s.name, text: SessionStore.lastAssistantText(of: s)))
            } else if !t.sawBusy, !t.warned, Date().timeIntervalSince(t.since) > 20 {
                // 20 sn geçti, hiç çalışmaya başlamadı: muhtemelen terminalinde onay bekliyor.
                t.warned = true
                tracked[s.name] = t
                onEvent(.stuck(session: s.name))
            } else {
                tracked[s.name] = t
            }
        }
        for name in tracked.keys where !seen.contains(name) {
            tracked[name] = nil
            onEvent(.gone(session: name))
        }
    }
}
