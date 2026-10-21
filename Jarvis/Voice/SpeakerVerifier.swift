import Foundation
import AVFoundation

/// Konuşmacı doğrulama: sesten bir "parmak izi" (embedding) çıkarır, kullanıcının profiliyle karşılaştırır.
/// Tamamen yerel çalışır (sherpa-onnx + WeSpeaker ResNet34-LM modeli, 16 kHz).
///
/// Karar, sabit bir eşikle değil karşılaştırmayla verilir: ses, kullanıcının örneklerine mi yoksa
/// "yabancı" referans seslere (kohort) mi daha çok benziyor? Kohort, kayıt sırasında OpenAI'nin farklı
/// seslerine birkaç cümle söyletilerek üretilir; dışarıya kullanıcı sesi gitmez, yalnız metin gider.
/// Profil çok örneklidir ve Jarvis'in güvenle kabul ettiği uzun cümlelerle zamanla büyür.
final class SpeakerVerifier {
    static let shared = SpeakerVerifier()

    /// Kayıt sırasında okunacak cümleler. Farklı sesler, uzunluklar ve tonlar içersin diye seçildi.
    static let enrollmentSentences = [
        "Jarvis, bugün açık olan oturumları listele ve hangisinin beklediğini söyle.",
        "Yarın sabah dokuzda İstanbul'da toplantım var, hava nasıl olacak merak ediyorum.",
        "Web projesine sor, testler geçti mi, commit bekleyen dosya var mı?",
        "Annemi ara, akşam yemeğe geleceğimi söyle, biraz geç kalabilirim.",
        "Masaüstündeki sunum dosyasını bul ve en son ne zaman değiştiğini söyle.",
        "Üç, yedi, on iki, kırk beş; bu sayıları not al, sonra bana hatırlat.",
        "Bu hafta hangi faturalar ödenecek, takvimde toplantı çakışması var mı?",
        "Tamam, teşekkürler, şimdilik bu kadar; sonra tekrar konuşuruz.",
    ]

    /// Kohort için OpenAI'ye okutulacak cümleler ve sesler.
    static let cohortSentences = [
        "Bugün açık olan oturumları listele ve hangisinin beklediğini söyle.",
        "Yarın sabah toplantım var, hava nasıl olacak merak ediyorum.",
        "Masaüstündeki dosyayı bul ve ne zaman değiştiğini söyle.",
    ]
    static let cohortVoices = ["alloy", "ash", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer", "verse"]

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "speakerGate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "speakerGate") }
    }

    /// Karar sonucu.
    enum Verdict: String { case owner, unsure, stranger }

    struct Score {
        let own: Float          // kullanıcı örneklerine benzerlik (en iyi 3'ün ortalaması)
        let cohort: Float       // en yakın yabancıya benzerlik
        let speechMs: Int
        let verdict: Verdict
        var margin: Float { own - cohort }
    }

    private struct Profile: Codable {
        var version = 2
        var user: [[Float]] = []
        var cohort: [[Float]] = []
    }

    private var extractor: OpaquePointer?
    private var profile = Profile()
    private let queue = DispatchQueue(label: "jarvis.speaker", qos: .userInitiated)
    private let lock = NSLock()
    var log: (String) -> Void = { _ in }

    /// Profile eklenecek en fazla kullanıcı örneği; dolunca en eski öğrenilmiş düşer, kayıt cümleleri korunur.
    private static let maxUserSamples = 40
    private var enrolledCount = 0

    private static let profileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jarvis", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voice-profile-v2.json")
    }()

    private init() {
        if let d = try? Data(contentsOf: Self.profileURL), let p = try? JSONDecoder().decode(Profile.self, from: d) {
            profile = p
            enrolledCount = min(p.user.count, Self.enrollmentSentences.count)
        }
    }

    var hasProfile: Bool { lock.lock(); defer { lock.unlock() }; return !profile.user.isEmpty }
    var hasCohort: Bool { lock.lock(); defer { lock.unlock() }; return !profile.cohort.isEmpty }
    var sampleCount: Int { lock.lock(); defer { lock.unlock() }; return profile.user.count }
    var cohortCount: Int { lock.lock(); defer { lock.unlock() }; return profile.cohort.count }
    var isReady: Bool { extractor != nil }

    /// Modeli yükler (ilk çağrıda ~1 sn). Uygulama paketindeki speaker.onnx kullanılır.
    func load() {
        guard extractor == nil else { return }
        guard let path = Bundle.main.path(forResource: "speaker", ofType: "onnx") else {
            log("konuşmacı: model dosyası pakette yok (speaker.onnx)")
            return
        }
        path.withCString { cPath in
            "cpu".withCString { cProv in
                var cfg = SherpaOnnxSpeakerEmbeddingExtractorConfig(model: cPath, num_threads: 2, debug: 0, provider: cProv)
                extractor = SherpaOnnxCreateSpeakerEmbeddingExtractor(&cfg)
            }
        }
        if let extractor {
            log("konuşmacı: model yüklendi, boyut \(SherpaOnnxSpeakerEmbeddingExtractorDim(extractor)), profil \(sampleCount) örnek, kohort \(cohortCount)")
        } else {
            log("konuşmacı: model yüklenemedi")
        }
    }

    // MARK: - Embedding

    /// 16 kHz Float örneklerden embedding (normalize). En az 0,5 sn konuşma gerekir.
    private func embedding(samples16k: [Float]) -> [Float]? {
        guard let extractor, samples16k.count >= 8_000 else { return nil }
        guard let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor) else { return nil }
        defer { SherpaOnnxDestroyOnlineStream(stream) }
        samples16k.withUnsafeBufferPointer { buf in
            SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, buf.baseAddress, Int32(buf.count))
        }
        SherpaOnnxOnlineStreamInputFinished(stream)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) != 0,
              let v = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream) else { return nil }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(v) }
        let dim = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(extractor))
        return Self.normalized(Array(UnsafeBufferPointer(start: v, count: dim)))
    }

    /// 24 kHz PCM16 parçalardan (mikrofon yolu) embedding; sessizlik atılır. Konuşma süresini de döndürür.
    func embedding(fromPCM16 chunks: [Data]) -> (emb: [Float]?, speechMs: Int) {
        let samples = Self.trimSilence(Self.resampleTo16k(pcm16at24k: chunks))
        return (embedding(samples16k: samples), samples.count / 16)
    }

    // MARK: - Karar

    /// Puanlar: kullanıcı örneklerinin en iyi 3'ünün ortalaması ve en yakın yabancı.
    func score(_ chunks: [Data]) -> Score? {
        let (e, ms) = embedding(fromPCM16: chunks)
        guard let e else { return nil }
        lock.lock(); let p = profile; lock.unlock()
        guard !p.user.isEmpty else { return nil }
        let ownSims = p.user.map { Self.cos(e, $0) }.sorted(by: >)
        let own = ownSims.prefix(3).reduce(0, +) / Float(min(3, ownSims.count))
        let cohort = p.cohort.map { Self.cos(e, $0) }.max() ?? -1
        return Score(own: own, cohort: cohort, speechMs: ms, verdict: Self.verdict(own: own, cohort: cohort, hasCohort: !p.cohort.isEmpty))
    }

    /// Karar kuralı. Kohort varsa karşılaştırmalı: kullanıcıya benzerlik en yakın yabancıdan belirgin
    /// yüksekse sahibi, yabancı kadar ya da daha az benziyorsa yabancı, arası belirsiz.
    /// Kohort yoksa (çevrimdışı kayıt) sabit aralıklar kullanılır.
    private static func verdict(own: Float, cohort: Float, hasCohort: Bool) -> Verdict {
        if hasCohort {
            let margin = own - cohort
            if own >= 0.55 || margin >= 0.12 { return .owner }
            if margin <= 0.0 || own < 0.20 { return .stranger }
            return .unsure
        } else {
            if own >= 0.55 { return .owner }
            if own < 0.30 { return .stranger }
            return .unsure
        }
    }

    /// Arka planda puanlar; geri çağrı ana iş parçacığında. Profil/model yoksa nil (karar yok).
    func verify(_ chunks: [Data], name: String = "kesit", completion: @escaping (Score?) -> Void) {
        queue.async {
            Self.dumpWAV(chunks, name: name)
            let s = self.score(chunks)
            DispatchQueue.main.async { completion(s) }
        }
    }

    /// Jarvis'in güvenle kabul ettiği uzun cümleyi profile ekler: kullandıkça daha iyi tanır.
    func learn(from chunks: [Data]) {
        queue.async {
            let (e, ms) = self.embedding(fromPCM16: chunks)
            guard let e, ms >= 1500 else { return }
            self.lock.lock()
            self.profile.user.append(e)
            if self.profile.user.count > Self.maxUserSamples {
                // Kayıt cümlelerini koru, en eski öğrenilmişi at.
                self.profile.user.remove(at: self.enrolledCount)
            }
            let p = self.profile
            self.lock.unlock()
            self.save(p)
            self.log("konuşmacı: profile örnek eklendi (\(p.user.count))")
        }
    }

    // MARK: - Kayıt

    struct EnrollResult {
        let sentenceScores: [Float]   // her cümlenin diğerlerine benzerliği (tutarlılık)
        let cohortMax: Float          // kayıt cümlelerinin en yakın yabancıya benzerliği (ayrışma)
        let strength: String          // "güçlü" / "orta" / "zayıf"
    }

    /// Kayıt: cümlelerin embedding'leri profil olur (ortalama değil, hepsi ayrı; koşul çeşitliliği korunur).
    func enroll(samplesPerSentence: [[Data]]) -> EnrollResult? {
        let embs = samplesPerSentence.compactMap { embedding(fromPCM16: $0).emb }
        guard embs.count >= 2 else { return nil }
        lock.lock()
        profile.user = embs
        enrolledCount = embs.count
        let p = profile
        lock.unlock()
        save(p)
        var scores: [Float] = []
        for (i, e) in embs.enumerated() {
            let others = embs.enumerated().filter { $0.offset != i }.map(\.element)
            scores.append(others.map { Self.cos(e, $0) }.max() ?? 0)
        }
        let cohortMax = embs.flatMap { e in p.cohort.map { Self.cos(e, $0) } }.max() ?? -1
        let minSelf = scores.min() ?? 0
        let strength = p.cohort.isEmpty ? "kohort yok" : (minSelf - cohortMax >= 0.2 ? "güçlü" : (minSelf - cohortMax >= 0.1 ? "orta" : "zayıf"))
        log(String(format: "konuşmacı: profil kaydedildi (%d cümle), tutarlılık %@, yabancıya en yakın %.2f, ayrışma %@",
                   embs.count, scores.map { String(format: "%.2f", $0) }.joined(separator: " "), cohortMax, strength))
        return EnrollResult(sentenceScores: scores, cohortMax: cohortMax, strength: strength)
    }

    func clearProfile() {
        lock.lock(); profile.user = []; enrolledCount = 0; let p = profile; lock.unlock()
        save(p)
    }

    /// Yabancı referans sesleri (kohort) OpenAI TTS ile üretir ve embedding'lerini saklar.
    /// Kullanıcının sesi gönderilmez; yalnız metin gider. Bir kez yapılır, profil silinse de kalır.
    func buildCohort(apiKey: String, progress: @escaping (String) -> Void, completion: @escaping (Int) -> Void) {
        queue.async {
            var embs: [[Float]] = []
            for voice in Self.cohortVoices {
                for (i, text) in Self.cohortSentences.enumerated() {
                    DispatchQueue.main.async { progress("Yabancı ses \(voice) \(i + 1)/\(Self.cohortSentences.count)") }
                    guard let pcm = Self.tts(apiKey: apiKey, voice: voice, text: text) else { continue }
                    // TTS 24 kHz PCM16 verir; mikrofon yoluyla aynı işlemden geçsin.
                    if let e = self.embedding(fromPCM16: [pcm]).emb { embs.append(e) }
                }
            }
            self.lock.lock(); self.profile.cohort = embs; let p = self.profile; self.lock.unlock()
            self.save(p)
            self.log("konuşmacı: kohort hazır (\(embs.count) örnek)")
            DispatchQueue.main.async { completion(embs.count) }
        }
    }

    /// OpenAI TTS: 24 kHz mono PCM16 döner.
    private static func tts(apiKey: String, voice: String, text: String) -> Data? {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "gpt-4o-mini-tts", "voice": voice, "input": text, "response_format": "pcm",
        ])
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 { out = data }
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }

    private func save(_ p: Profile) {
        if let d = try? JSONEncoder().encode(p) { try? d.write(to: Self.profileURL) }
    }

    // MARK: - Yardımcılar

    private static func cos(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private static func normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }

    /// Hata ayıklama: ölçülen kesiti ~/Library/Logs/jarvis-<ad>.wav olarak yazar (24 kHz mono PCM16).
    static func dumpWAV(_ chunks: [Data], name: String) {
        let pcm = chunks.reduce(into: Data()) { $0.append($1) }
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count)); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(24000); u32(48000); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(pcm.count)); d.append(pcm)
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/jarvis-\(name).wav")
        try? d.write(to: url)
    }

    /// Enerjiye göre sessiz kareleri atar (20 ms kareler, en gür karenin %12'sinin altı sessiz sayılır),
    /// konuşma karelerinin iki yanına 60 ms pay bırakır. Yankı önlemeli mikrofon sesi kısık verir;
    /// mutlak taban düşük tutulur.
    private static func trimSilence(_ x: [Float]) -> [Float] {
        let frame = 320                                   // 20 ms @ 16 kHz
        let n = x.count / frame
        guard n > 0 else { return x }
        var rms = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var s: Float = 0
            for j in 0..<frame { let v = x[i * frame + j]; s += v * v }
            rms[i] = sqrt(s / Float(frame))
        }
        let peak = rms.max() ?? 0
        let gate = max(peak * 0.12, 0.0008)
        var keep = rms.map { $0 >= gate }
        let pad = 3
        let orig = keep
        for i in 0..<n where orig[i] {
            for k in max(0, i - pad)...min(n - 1, i + pad) { keep[k] = true }
        }
        var out: [Float] = []
        out.reserveCapacity(x.count)
        for i in 0..<n where keep[i] { out.append(contentsOf: x[(i * frame)..<((i + 1) * frame)]) }
        return out
    }

    /// 24 kHz Int16 → 16 kHz Float. Oran 3:2; doğrusal ara değer, embedding için yeterli.
    private static func resampleTo16k(pcm16at24k chunks: [Data]) -> [Float] {
        var src: [Float] = []
        src.reserveCapacity(chunks.reduce(0) { $0 + $1.count / 2 })
        for d in chunks {
            d.withUnsafeBytes { raw in
                for s in raw.bindMemory(to: Int16.self) { src.append(Float(s) / 32768) }
            }
        }
        let outCount = src.count * 2 / 3
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let pos = Float(i) * 1.5
            let j = Int(pos)
            let frac = pos - Float(j)
            let a = src[j], b = j + 1 < src.count ? src[j + 1] : a
            out[i] = a + (b - a) * frac
        }
        return out
    }
}
