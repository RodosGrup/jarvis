import Foundation
import Speech
import AVFoundation

/// Uyandırma kelimesi dedektörü. Mac'in cihaz içi konuşma tanımasıyla (internet yok) mikrofonu dinler,
/// "Jarvis" geçince haber verir. Beklemedeyken hiçbir ses dışarı gitmez.
///
/// Cihaz içi tanıma tek istekte yaklaşık bir dakika sürüyor; o yüzden istek her 50 sn'de ve her yakalamadan
/// sonra tazelenir.
final class WakeWord {
    var keyword = "jarvis"
    var onWake: () -> Void = {}
    var log: (String) -> Void = { _ in }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private var active = false
    private var lastWake = Date.distantPast
    private var warnedDisabled = false
    private var lastHeard = ""

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { done(status == .authorized) }
        }
    }

    func start() {
        active = true
        beginRequest()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
            self?.beginRequest()
        }
    }

    func stop() {
        active = false
        restartTimer?.invalidate()
        restartTimer = nil
        endRequest()
    }

    /// Mikrofon tap'inden gelen ham tampon (dönüştürülmemiş, aygıt formatında).
    func feed(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    /// Metinde kelime geçiyor mu? Birebir değil, yakın yazım da sayılır (ölçüldü: "Mikail" → "mikhail", "michal").
    /// Kural: aynı ya da düzenleme uzaklığı en fazla kelime uzunluğunun üçte biri (5 harfte 1, 6–8 harfte 2).
    static func matches(_ text: String, keyword: String) -> Bool {
        let kw = fold(keyword)
        guard !kw.isEmpty else { return false }
        if fold(text).contains(kw) { return true }
        let allowed = max(1, kw.count / 3)
        for word in text.split(whereSeparator: { !$0.isLetter }) {
            let w = fold(String(word))
            if abs(w.count - kw.count) <= allowed, levenshtein(w, kw) <= allowed { return true }
        }
        return false
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased().filter { $0.isLetter }
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    private func beginRequest() {
        endRequest()
        guard active, let recognizer, recognizer.isAvailable else {
            log("uyandırma: tanıyıcı hazır değil")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        // Kelimeyi ipucu olarak ver: tanıyıcı İngilizce; "Mikail" gibi adları yoksa "mikhail/michal" yazıyor.
        req.contextualStrings = [keyword, keyword.capitalized]
        req.taskHint = .search
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString.lowercased()
                if text != self.lastHeard {
                    self.lastHeard = text
                    self.log("uyandırma duydu: \"\(text.suffix(60))\"")
                }
                if Self.matches(text, keyword: self.keyword), Date().timeIntervalSince(self.lastWake) > 2 {
                    self.lastWake = Date()
                    self.log("uyandırma: \"\(text)\"")
                    self.onWake()
                    // Aynı cümleyi tekrar yakalamasın diye isteği tazele.
                    DispatchQueue.main.async { self.beginRequest() }
                }
            }
            if let error, self.active {
                // Tanıma süresi dolunca ya da sessizlikte hata döner; sessizce tazele.
                // 201: Siri ve Dikte kapalı (Sistem Ayarları'ndan açılmalı); 10 sn'de bir dene, bir kez uyar.
                let code = (error as NSError).code
                let fatal = code == 201
                if code != 216 && code != 301 && code != 1110 && !(fatal && self.warnedDisabled) {
                    self.log("uyandırma: tanıma hatası \(code): \(error.localizedDescription)" +
                             (fatal ? " → Sistem Ayarları › Klavye › Dikte'yi açın." : ""))
                    if fatal { self.warnedDisabled = true }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (fatal ? 10 : 0.5)) { [weak self] in
                    guard let self, self.active, self.task == nil else { return }
                    self.beginRequest()
                }
            }
        }
    }

    private func endRequest() {
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }
}
