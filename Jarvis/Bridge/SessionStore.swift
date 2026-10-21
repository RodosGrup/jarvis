import Foundation

/// Açık bir Claude Code oturumu.
struct ClaudeSession: Identifiable, Equatable {
    let name: String
    let pid: Int32
    let sessionId: String
    let cwd: String
    let status: String      // "idle" | "busy"
    let startedAt: Date

    var id: String { sessionId }
    var project: String { (cwd as NSString).lastPathComponent }
    var isIdle: Bool { status == "idle" }
    var statusLabel: String { isIdle ? "boşta" : "çalışıyor" }
}

/// Açık Claude Code oturumlarını Claude'un kendi kayıt dosyalarından okur.
/// Hiçbir ayar değiştirilmez, hook kurulmaz; yalnızca okunur (Vardiya ile aynı yaklaşım).
///
///   ~/.claude/sessions/<pid>.json             canlı oturum kaydı (ad, klasör, durum)
///   ~/.claude/projects/<proje>/<id>.jsonl     oturum dökümü (son asistan mesajı buradan)
enum SessionStore {
    static let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")

    /// Açık oturumlar; kendi orkestratörümüz (jarvis-*) ve ölü süreçler elenir.
    static func list() -> [ClaudeSession] {
        let dir = claudeDir.appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [ClaudeSession] = []
        for f in files where f.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent(f).path),
                  let rec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = rec["pid"] as? Int32, isAlive(pid),
                  let sessionId = rec["sessionId"] as? String,
                  let cwd = rec["cwd"] as? String else { continue }
            let name = rec["name"] as? String ?? "pid-\(pid)"
            if name.lowercased().hasPrefix("jarvis") { continue }
            let startedMs = rec["startedAt"] as? Double ?? 0
            out.append(ClaudeSession(
                name: name, pid: pid, sessionId: sessionId, cwd: cwd,
                status: rec["status"] as? String ?? "unknown",
                startedAt: Date(timeIntervalSince1970: startedMs / 1000)))
        }
        return out.sorted { $0.startedAt > $1.startedAt }
    }

    /// Süreç hâlâ yaşıyor mu? Ölü oturumların kaydı bazen dosyada kalıyor.
    private static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// Kullanıcının ağzından çıkan adı gerçek oturuma çevirir: "web sitesi" -> web-sitesi-3a.
    /// Tam eşleşme > başlangıç > içerme > proje adı.
    static func resolve(_ spoken: String, in sessions: [ClaudeSession]) -> ClaudeSession? {
        func norm(_ s: String) -> String {
            s.lowercased()
                .replacingOccurrences(of: "[\\s_]+", with: "-", options: .regularExpression)
                .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
        }
        let q = norm(spoken)
        guard !q.isEmpty else { return nil }
        return sessions.first { norm($0.name) == q }
            ?? sessions.first { norm($0.name).hasPrefix(q) }
            ?? sessions.first { norm($0.name).contains(q) }
            ?? sessions.first { norm($0.project) == q || norm($0.project).contains(q) }
    }

    /// Oturum dökümündeki son asistan metni (sesle okunacak özet için).
    /// Dosya büyük olabilir; sondan 256 KB okunur, yeterli.
    static func lastAssistantText(of s: ClaudeSession) -> String {
        let projectDir = s.cwd.replacingOccurrences(of: "[/.]", with: "-", options: .regularExpression)
        let file = claudeDir.appendingPathComponent("projects/\(projectDir)/\(s.sessionId).jsonl")
        guard let fh = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let chunk = min(size, 256 * 1024)
        try? fh.seek(toOffset: size - chunk)
        guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else { return "" }
        for line in text.split(separator: "\n").reversed() where line.contains("\"type\":\"assistant\"") {
            guard let rec = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  rec["type"] as? String == "assistant",
                  (rec["isSidechain"] as? Bool) != true,
                  let msg = rec["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { continue }
            let t = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return ""
    }
}
