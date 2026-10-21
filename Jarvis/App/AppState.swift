import Foundation
import AVFoundation

/// Uygulamanın beyni: ses, uyandırma kelimesi, Realtime bağlantısı, orkestratör ve izleyiciyi birbirine bağlar.
///
/// Akış: Dinle → bekleme (mikrofon açık, yalnızca cihaz içi uyandırma kelimesi dinlenir, dışarı ses gitmez)
///        → "Jarvis" → Realtime bağlantısı açılır, konuşma → cevap → 5 sn sessizlik → bağlantı kapanır, bekleme.
@MainActor
final class AppState: ObservableObject {
    enum Phase: String { case off, standby, connecting, listening, speaking, thinking }

    struct Entry: Identifiable {
        enum Kind { case you, jarvis, system, tool, error }
        let id = UUID()
        let kind: Kind
        var text: String
        let at = Date()
    }

    @Published var phase: Phase = .off
    @Published var status = "Kapalı"
    @Published var sessions: [ClaudeSession] = []
    @Published var entries: [Entry] = []
    @Published var orbVisible = false

    /// Cevap bittikten sonra kaç saniye sessizlikte uykuya dönülür.
    static let sleepAfter: TimeInterval = 5
    /// Uyandıktan sonra soru için tanınan süre (düşünme payı).
    static let sleepAfterWake: TimeInterval = 8

    private let orb = OrbPanel()

    /// Küre animasyonu için anlık mikrofon ve hoparlör seviyeleri (0...1).
    var levels: (Float, Float) { (audio.inputLevel, audio.outputLevel) }

    func setOrb(visible: Bool) {
        orbVisible = visible
        visible ? orb.show(state: self) : orb.hide()
    }

    private let audio = AudioEngine()
    /// Seçili ses hattı: Realtime (OpenAI) ya da yerel. Uyanışta Prefs.pipeline'a göre seçilir.
    private var realtime: VoiceClient = RealtimeClient()
    private let realtimeClient = RealtimeClient()
    private let localClient = LocalVoiceSession()
    private let wake = WakeWord()
    private let watcher = Watcher()
    private var orchestrator: Orchestrator
    /// Mac işçisi: yalnız osascript/open/shortcuts/mdfind çalıştırabilen headless Claude. İlk kullanımda açılır.
    private var macWorker: Orchestrator?
    private var liveJarvisLine: UUID?
    private var chunkCount = 0

    /// Uyanıkken bağlantı kurulana kadar biriken ses; "Jarvis, ... ?" tek nefeste söylenebilsin diye.
    private var pendingAudio: [Data] = []
    /// Beklemedeyken gelen bildirim; uyanınca okunur.
    private var pendingTexts: [String] = []
    private var sleepTimer: Timer?
    /// Çalışan araç sayısı (Mac görevi, oturum sorgusu). Sıfırdan büyükken uyunmaz.
    private var toolsInFlight = 0
    /// Son ~3 sn'lik mikrofon sesi (uyanışta konuşmacı doğrulaması için).
    private var recent: [Data] = []
    /// Uyanıkken süren cümle; bitince konuşmacı doğrulanır.
    private var utterance: [Data]?
    private var lastUserItemId: String?
    private var rejectPending = false
    /// Ses kaydı (Ayarlar › Sesimi kaydet) sürüyorsa parçalar burada birikir.
    private var enrollChunks: [Data]?
    let speaker = SpeakerVerifier.shared
    /// Uyanış cümlesinden sonra soru için uzun pay tanınır.
    private var justWoke = false
    /// Uyanıştan sonraki ilk cümle: konuşmacı doğrulamasının asıl kararı burada verilir.
    private var justWokeUtterance = false
    /// Bu uyanıklık döneminde en az bir cümle sahibi olarak doğrulandı; kısa cevaplar ("evet") sorgulanmaz.
    /// Ölçüldü: 600 ms'lik "evet" 0,21 puan alıp reddediliyordu.
    private var sessionTrusted = false

    init() {
        orchestrator = Orchestrator(
            claudePath: Prefs.claudePath,
            extraArgs: Prefs.claudeArgs.split(separator: " ").map(String.init))
        orchestrator.log = { [weak self] s in Task { @MainActor in self?.add(.system, s) } }
        orchestrator.start()

        watcher.onSessions = { [weak self] in self?.sessions = $0 }
        watcher.onEvent = { [weak self] in self?.handle($0) }
        watcher.start()

        for c in [realtimeClient as VoiceClient, localClient as VoiceClient] {
            c.onEvent = { [weak self] ev in Task { @MainActor in self?.handle(ev) } }
            c.onClose = { [weak self] why in Task { @MainActor in self?.connectionClosed(why) } }
        }
        localClient.log = { Self.logToFile("[system] \($0)") }
        realtime = realtimeClient

        audio.log = { Self.logToFile("[system] \($0)") }
        audio.onPlaybackIdle = { [weak self] in
            Task { @MainActor in
                guard let self, self.phase == .speaking else { return }
                self.phase = .listening; self.status = "Dinliyorum."
                self.scheduleSleep(after: self.justWoke ? Self.sleepAfterWake : Self.sleepAfter)
                self.justWoke = false
            }
        }
        audio.onRawBuffer = { [weak self] buf in
            guard let self else { return }
            self.wake.feed(buf)
            // Yerel hat ham tamponu kullanır; Jarvis konuşurken yutulur.
            if self.isAwake && !self.audio.shouldMuteMic { self.realtime.feed(buf) }
        }
        audio.onChunk = { [weak self] d in
            guard let self else { return }
            self.chunkCount += 1
            // Yankı önleme yoksa Jarvis konuşurken mikrofonu yut: model kendi sesini duymasın,
            // konuşmacı doğrulaması Jarvis'in sesini ölçmesin (ölçüldü: ilk cümle 0,16 puan alıyordu).
            if self.audio.shouldMuteMic { return }
            self.recent.append(d)
            if self.recent.count > 30 { self.recent.removeFirst() }
            self.utterance?.append(d)
            self.enrollChunks?.append(d)
            switch self.phase {
            case .connecting: self.pendingAudio.append(d)          // bağlantı kurulana kadar biriktir
            case .listening, .thinking, .speaking: self.realtime.appendAudio(d)
            default: break                                          // beklemede dışarı ses gitmez
            }
        }

        wake.log = { Self.logToFile("[system] \($0)") }

        // Sağlık günlüğü: 10 sn'de bir motor durumu ve gelen parça sayısı (ses kesilmesini görmek için).
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase != .off else { return }
                Self.logToFile("[audio] sağlık: \(self.chunkCount) parça, \(self.audio.describe())")
            }
        }
        wake.onWake = { [weak self] in Task { @MainActor in self?.wakeRequested() } }
        speaker.log = { Self.logToFile("[system] \($0)") }
        DispatchQueue.global(qos: .utility).async { [speaker] in speaker.load() }

        // Test parametresi: `-jarvisOrb YES` ile küre açılışta görünür (ses olmadan animasyonu incelemek için).
        if UserDefaults.standard.bool(forKey: "jarvisOrb") { setOrb(visible: true) }
    }

    // MARK: - Açma / kapama

    var isOn: Bool { phase != .off }
    var isAwake: Bool { phase == .connecting || phase == .listening || phase == .thinking || phase == .speaking }

    func toggle() { isOn ? stop(reason: "Kapalı") : start() }

    /// Dinlemeye başla: mikrofon açılır, bekleme moduna girilir.
    func start() {
        let key = Prefs.apiKey
        guard !key.isEmpty else { add(.error, "OpenAI API anahtarı yok. Ayarlar'dan girin."); return }
        phase = .standby
        status = "Hazırlanıyor…"
        setOrb(visible: true)
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
            // Ana kuyruğa dispatch ile dönüyoruz; Task { @MainActor } bu geri çağrıdan çalışmıyor (ölçüldü).
            DispatchQueue.main.async {
                guard let self else { return }
                guard ok else { self.stop(reason: "Mikrofon izni verilmedi."); return }
                WakeWord.requestPermission { granted in
                    guard granted else { self.stop(reason: "Konuşma tanıma izni verilmedi (uyandırma kelimesi için gerekli)."); return }
                    do {
                        try self.audio.start()
                        self.add(.system, "Ses motoru açıldı: \(self.audio.describe())")
                    } catch {
                        self.stop(reason: "Ses başlatılamadı: \(error.localizedDescription)")
                        return
                    }
                    self.wake.keyword = Prefs.wakeWord.lowercased()
                    self.wake.start()
                    self.enterStandby()
                }
            }
        }
    }

    func stop(reason: String) {
        sleepTimer?.invalidate()
        wake.stop()
        audio.stop()
        realtime.disconnect()
        pendingAudio = []
        phase = .off
        status = reason
        add(reason == "Kapalı" ? .system : .error, reason)
        setOrb(visible: false)
    }

    private func enterStandby() {
        sleepTimer?.invalidate()
        realtime.disconnect()
        pendingAudio = []
        phase = .standby
        status = "Beklemede. \"\(Prefs.wakeWord)\" deyince uyanır."
        add(.system, "Beklemede.")
    }

    /// Uyandırma kelimesi duyuldu: önce (açıksa) sesin sahibine bak, sonra uyan.
    private func wakeRequested() {
        guard phase == .standby, enrollChunks == nil else { return }
        guard speaker.hasProfile else { wakeUp(); return }
        let snapshot = recent                       // son 3 sn: tanıyıcı gecikmeli bildirir, kelime bu aralıkta
        speaker.verify(snapshot, name: "uyanis") { [weak self] score in
            guard let self else { return }
            // Ölçüm yapılamadıysa (konuşma çok kısa) karar verme, uyan; asıl karar ilk cümlede.
            guard let s = score else { self.add(.system, "Uyanış sesi ölçülemedi, ilk cümlede bakılacak."); self.wakeUp(); return }
            self.add(.system, String(format: "Uyanış: sahibine %.2f, yabancıya %.2f → %@", s.own, s.cohort, s.verdict.rawValue))
            // Tek kelimelik ses güvenilmez; yalnız açıkça yabancıysa uyanma.
            if s.verdict == .stranger && SpeakerVerifier.enabled { self.add(.system, "Yabancı ses, uyanmadı.") } else { self.wakeUp() }
        }
    }

    /// Realtime'a bağlan (uyanış).
    func wakeUp() {
        guard phase == .standby else { return }
        let key = Prefs.apiKey
        guard !key.isEmpty else { return }
        phase = .connecting
        status = "Uyanıyor…"
        pendingAudio = []
        justWokeUtterance = true
        sessionTrusted = false
        realtime = Prefs.pipeline == "local" ? localClient : realtimeClient
        add(.system, "Uyandı, bağlanıyor (\(Prefs.pipeline == "local" ? "yerel hat" : Prefs.model)).")
        realtime.connect(apiKey: key, model: Prefs.model, sessionConfig: Prompt.sessionConfig(voice: Prefs.voice))
    }

    /// Cevap bittikten sonra sessizlik sayacı: dolunca uykuya dön.
    private func scheduleSleep(after seconds: TimeInterval = AppState.sleepAfter) {
        sleepTimer?.invalidate()
        sleepTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .listening else { return }
                // Araç hâlâ çalışıyorsa (Mac görevi 30 sn sürebilir) bekle, sonra yeniden bak.
                if self.toolsInFlight > 0 { self.scheduleSleep(after: seconds); return }
                self.enterStandby()
            }
        }
    }

    private func connectionClosed(_ why: String) {
        guard isAwake else { return }
        add(.error, "Bağlantı koptu: \(why)")
        enterStandby()
    }

    func restartOrchestrator() {
        orchestrator.stop()
        orchestrator = Orchestrator(
            claudePath: Prefs.claudePath,
            extraArgs: Prefs.claudeArgs.split(separator: " ").map(String.init))
        orchestrator.log = { [weak self] s in Task { @MainActor in self?.add(.system, s) } }
        orchestrator.start()
    }

    func shutdown() {
        wake.stop()
        audio.stop()
        realtime.disconnect()
        watcher.stop()
        orchestrator.stop()
        macWorker?.stop()
    }

    // MARK: - Realtime olayları

    private func handle(_ ev: [String: Any]) {
        let type = ev["type"] as? String ?? "?"
        if !type.hasSuffix(".delta") { Self.logToFile("[event] \(type)") }
        switch type {
        case "session.updated":
            guard phase == .connecting else { return }
            phase = .listening; status = "Dinliyorum."
            // Uyanırken biriken sesi gönder: "Jarvis, hangi oturumlar açık?" kaybolmasın.
            for d in pendingAudio { realtime.appendAudio(d) }
            pendingAudio = []
            // Beklemedeyken biriken bildirimler varsa önce onları oku.
            for t in pendingTexts { realtime.sendText(t) }
            pendingTexts = []
            // Uyanış cümlesi: kullanıcı dinlendiğini duysun. Aynı nefeste soru sorduysa VAD onu ayrı tur olarak işler.
            justWoke = true
            realtime.createResponse(instructions: "Az önce uyandın. Tek kısa cümleyle dinlemeye başladığını söyle: \"Sizi dinliyorum.\", \"Buyurun.\" ya da \"Efendim?\" gibi. Başka hiçbir şey ekleme.")
            scheduleSleep(after: Self.sleepAfterWake)
        case "input_audio_buffer.speech_started":
            sleepTimer?.invalidate()
            justWoke = false
            utterance = Array(recent.suffix(5))   // VAD biraz geç tetiklenir; yarım saniye geriden al
            lastUserItemId = nil
            rejectPending = false
            // Kullanıcı lafa girdi: çalan cevabı kes.
            audio.flushPlayback()
            liveJarvisLine = nil
            phase = .listening; status = "Seni duyuyorum…"
        case "input_audio_buffer.speech_stopped":
            if let u = utterance, speaker.hasProfile {
                utterance = nil
                let firstAfterWake = justWokeUtterance
                justWokeUtterance = false
                speaker.verify(u, name: "cumle") { [weak self] score in
                    guard let self else { return }
                    guard let s = score else { Self.logToFile("[system] Cümle sesi ölçülemedi, geçildi."); return }
                    Self.logToFile(String(format: "[system] Cümle: sahibine %.2f, yabancıya %.2f, %d ms → %@", s.own, s.cohort, s.speechMs, s.verdict.rawValue))
                    if s.verdict == .owner {
                        self.sessionTrusted = true
                        // Güvenle kabul edilen uzun cümle profile eklenir: kullandıkça daha iyi tanır.
                        if s.speechMs >= 1500 && s.own >= 0.5 { self.speaker.learn(from: u) }
                        return
                    }
                    guard SpeakerVerifier.enabled else { return }
                    // Belirsiz: güvenilir oturumda ya da kısa cümlede geç; ilk uzun cümlede de geç ama güven verme.
                    if s.verdict == .unsure { Self.logToFile("[system] Belirsiz, geçildi."); return }
                    // Yabancı: güvenilir oturumda çok kısa sesler (gürültü, "hı") yok sayılmaz, reddedilmez.
                    if self.sessionTrusted && s.speechMs < 1000 { Self.logToFile("[system] Kısa ses, oturum güvenilir; geçildi."); return }
                    if firstAfterWake {
                        // Uyanış gevşek eşikle geçti; asıl karar burada: ilk cümle yabancıysa sessizce uyu.
                        self.add(.system, "Yabancı ses, uykuya dönüldü.")
                        self.enterStandby()
                    } else {
                        self.add(.system, "Yabancı ses, cümle yok sayıldı.")
                        if let id = self.lastUserItemId { self.rejectItem(id) } else { self.rejectPending = true }
                    }
                }
            }
        case "conversation.item.added":
            if let item = ev["item"] as? [String: Any], item["role"] as? String == "user", let id = item["id"] as? String {
                lastUserItemId = id
                if rejectPending { rejectPending = false; rejectItem(id) }
            }
        case "conversation.item.input_audio_transcription.completed":
            if let t = (ev["transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { add(.you, t) }
        case "response.created":
            sleepTimer?.invalidate()
            phase = .thinking; status = "Düşünüyor…"
        case "response.output_audio.delta":
            if let b64 = ev["delta"] as? String, let d = Data(base64Encoded: b64) { audio.enqueue(pcm16: d) }
            phase = .speaking; status = "Konuşuyor…"
        case "response.output_audio_transcript.delta":
            if let delta = ev["delta"] as? String { appendJarvis(delta) }
        case "response.output_audio_transcript.done":
            if let t = ev["transcript"] as? String { Self.logToFile("[jarvis] \(t)") }
            liveJarvisLine = nil
        case "response.output_item.done":
            if let item = ev["item"] as? [String: Any], item["type"] as? String == "function_call" {
                Task { await callTool(item) }
            }
        case "response.done":
            // Ses hâlâ çalıyorsa kırmızı kalsın; çalma bitince onPlaybackIdle dinlemeye döndürür ve uyku sayacını kurar.
            if isAwake && !audio.isSpeaking {
                phase = .listening; status = "Dinliyorum."
                scheduleSleep(after: justWoke ? Self.sleepAfterWake : Self.sleepAfter)
                justWoke = false
            }
        case "error":
            let msg = (ev["error"] as? [String: Any])?["message"] as? String ?? "\(ev)"
            add(.error, msg)
        default:
            break
        }
    }

    /// Yabancı sesin cümlesini konuşmadan sil ve varsa cevabı iptal et.
    private func rejectItem(_ id: String) {
        realtime.cancelResponse()
        realtime.deleteItem(id)
        audio.flushPlayback()
        liveJarvisLine = nil
        if isAwake { phase = .listening; status = "Dinliyorum."; scheduleSleep() }
    }

    // MARK: - Ses kaydı (konuşmacı profili)

    /// Bir cümlenin kaydını başlatır. Jarvis açık (beklemede) olmalı; kayıt sırasında uyanmaz.
    func beginEnrollRecording() { enrollChunks = [] }

    /// Kaydı bitirir, parçaları döndürür.
    func endEnrollRecording() -> [Data] {
        let c = enrollChunks ?? []
        enrollChunks = nil
        return c
    }

    private func appendJarvis(_ delta: String) {
        if let id = liveJarvisLine, let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].text += delta
        } else {
            let e = Entry(kind: .jarvis, text: delta)
            liveJarvisLine = e.id
            entries.insert(e, at: 0)
        }
    }

    // MARK: - Araçlar

    private func callTool(_ item: [String: Any]) async {
        let name = item["name"] as? String ?? ""
        let callId = item["call_id"] as? String ?? ""
        let args = (item["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        add(.tool, "\(name) \(args)")
        status = name.hasPrefix("mac") ? "Mac'te çalışıyor…" : "Oturumlarla konuşuyor…"
        toolsInFlight += 1
        sleepTimer?.invalidate()
        let result = await runTool(name, args)
        toolsInFlight -= 1
        guard isAwake else { add(.system, "Araç bitti ama Jarvis uyumuştu; sonuç: \(result)"); return }
        realtime.sendFunctionResult(callId: callId, output: result)
    }

    private func runTool(_ name: String, _ args: [String: Any]) async -> [String: Any] {
        let list = SessionStore.list()
        func describe(_ s: ClaudeSession, full: Bool) -> [String: Any] {
            let last = SessionStore.lastAssistantText(of: s)
            return [
                "name": s.name, "project": s.project, "status": s.statusLabel,
                "startedMinutesAgo": Int(Date().timeIntervalSince(s.startedAt) / 60),
                "lastMessage": full ? last : String(last.prefix(300)),
            ]
        }
        switch name {
        case "list_sessions":
            return ["sessions": list.map { describe($0, full: false) }]
        case "get_session_status":
            guard let s = SessionStore.resolve(args["session"] as? String ?? "", in: list) else {
                return ["error": "öyle bir oturum yok", "available": list.map(\.name)]
            }
            return describe(s, full: true)
        case "mac_task":
            return await macTask(args["task"] as? String ?? "")
        case "mac_confirm":
            return await macTask((args["approve"] as? Bool ?? false) ? "ONAYLANDI" : "İPTAL")
        case "send_task":
            guard let s = SessionStore.resolve(args["session"] as? String ?? "", in: list) else {
                return ["error": "öyle bir oturum yok", "available": list.map(\.name)]
            }
            let message = (args["message"] as? String ?? "") +
                "\n\n(Bu mesaj kullanıcıdan, Jarvis sesli asistanı üzerinden geldi. İş bitince kısa bir özet yaz.)"
            do {
                try await orchestrator.send(to: s.name, message: message)
                watcher.track(s.name)
                add(.system, "\(s.name) oturumuna iletildi.")
                return ["ok": true, "session": s.name, "note": "İletildi. Bitince bildirim gelecek."]
            } catch {
                return ["error": "İletilemedi: \(error.localizedDescription)"]
            }
        default:
            return ["error": "bilinmeyen araç \(name)"]
        }
    }

    // MARK: - Mac işleri

    private func macTask(_ text: String) async -> [String: Any] {
        if macWorker == nil {
            let w = Orchestrator(
                claudePath: Prefs.claudePath,
                extraArgs: Prefs.claudeArgs.split(separator: " ").map(String.init),
                name: "jarvis-mac", systemPrompt: Prompt.macWorkerPrompt,
                allowedTools: "Bash(osascript:*) Bash(open:*) Bash(shortcuts:*) Bash(mdfind:*) Read", restricted: false)
            w.log = { [weak self] s in Task { @MainActor in self?.add(.system, s) } }
            w.start()
            macWorker = w
        }
        guard let macWorker else { return ["status": "error", "text": "Mac yardımcısı açılamadı"] }
        add(.system, "Mac görevi: \(text)")
        do {
            let reply = try await macWorker.ask(text)
            add(.system, "Mac cevabı: \(reply)")
            // İşçinin cevabı "ONAY:/TAMAM:/SORU:/HATA:" ile başlar; modele durum olarak aktar.
            let status: String
            if reply.hasPrefix("ONAY") { status = "confirm" }
            else if reply.hasPrefix("SORU") { status = "question" }
            else if reply.hasPrefix("HATA") { status = "error" }
            else if reply.hasPrefix("TAMAM") { status = "ok" }
            else {
                // Etiket yok: iş bitti sayılamaz. Jarvis "yapıldı" dememeli (ölçüldü: "gönderildi" diye uydurdu).
                return ["status": "unknown", "text": "Yardımcı net sonuç bildirmedi, iş TAMAMLANMAMIŞ olabilir. Kullanıcıya bunu söyle, yapıldı deme. Yardımcının son sözü: \(reply.prefix(200))"]
            }
            let body = reply.split(separator: ":", maxSplits: 1).dropFirst().joined().trimmingCharacters(in: .whitespaces)
            return ["status": status, "text": body.isEmpty ? reply : body]
        } catch {
            return ["status": "error", "text": "Mac yardımcısı cevap vermedi: \(error.localizedDescription)"]
        }
    }

    // MARK: - İzleyici bildirimleri

    private func handle(_ e: Watcher.Event) {
        let text: String
        switch e {
        case .finished(let s, let t): text = "[BİLDİRİM] \(s) oturumu işi bitirdi. Son mesajı: \(t.isEmpty ? "(boş)" : t)"
        case .stuck(let s): text = "[BİLDİRİM] \(s) oturumuna görev gönderildi ama başlamadı; terminalinde onay bekliyor olabilir."
        case .gone(let s): text = "[BİLDİRİM] \(s) oturumu kapandı."
        }
        add(.system, text)
        switch phase {
        case .listening, .thinking, .speaking:
            realtime.sendText(text)
        case .standby, .connecting:
            // Uyuyorsa uyandır; bağlantı kurulunca okunur.
            pendingTexts.append(text)
            wakeUp()
        case .off:
            break
        }
    }

    private func add(_ kind: Entry.Kind, _ text: String) {
        entries.insert(Entry(kind: kind, text: text), at: 0)
        if entries.count > 300 { entries.removeLast() }
        Self.logToFile("[\(kind)] \(text)")
    }

    /// ~/Library/Logs/Jarvis.log: menüde görünen her satır buraya da yazılır (hata ayıklama için).
    private static let logFile: FileHandle? = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Jarvis.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        try? h?.seekToEnd()
        return h
    }()

    private static func logToFile(_ s: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        logFile?.write(Data("\(stamp) \(s)\n".utf8))
    }
}
