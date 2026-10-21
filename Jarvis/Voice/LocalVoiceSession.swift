import Foundation
import AVFoundation
import Speech

/// Ses istemcisi arabirimi: Realtime (OpenAI) ve yerel hat aynı olay sözlüklerini üretir,
/// AppState ikisini de aynı kodla sürer.
protocol VoiceClient: AnyObject {
    var onEvent: ([String: Any]) -> Void { get set }
    var onClose: (String) -> Void { get set }
    var isOpen: Bool { get }
    func connect(apiKey: String, model: String, sessionConfig: [String: Any])
    func disconnect()
    /// 24 kHz PCM16 (Realtime bunu kullanır).
    func appendAudio(_ pcm16: Data)
    /// Aygıt formatında mono tampon (yerel hat bunu kullanır).
    func feed(_ buffer: AVAudioPCMBuffer)
    func sendText(_ text: String)
    func createResponse(instructions: String)
    func sendFunctionResult(callId: String, output: Any)
    func deleteItem(_ id: String)
    func cancelResponse()
}

/// Ucuz ses hattı: Apple konuşma tanıma (Türkçe) → küçük metin modeli (araç çağrılı) → Apple Türkçe sesi.
/// Realtime'ın olaylarını taklit eder; küre, yarım çift yönlü mod, araçlar ve uyku mantığı aynen çalışır.
/// Maliyet: yalnız metin modeli (tur başına kuruşun altı); ses tanıma ve sesli okuma ücretsiz.
/// Bedeli: cevap gecikmesi 1–3 sn, lafı kesmek yok, ses robotik (Yelda).
final class LocalVoiceSession: NSObject, VoiceClient {
    var onEvent: ([String: Any]) -> Void = { _ in }
    var onClose: (String) -> Void = { _ in }
    private(set) var isOpen = false
    var log: (String) -> Void = { _ in }

    static let textModel = "gpt-4o-mini"

    private var apiKey = ""
    private var instructions = ""
    private var tools: [[String: Any]] = []
    private var messages: [[String: Any]] = []

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastPartial = ""
    private var lastPartialAt = Date()
    private var speaking = false          // kullanıcı konuşuyor (kısmi sonuç akıyor)
    private var endTimer: Timer?
    private var paused = false            // Jarvis konuşurken ve cevap üretilirken dinleme duraklar
    private var itemCounter = 0

    private let synth = AVSpeechSynthesizer()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!

    // MARK: - Bağlantı

    func connect(apiKey: String, model: String, sessionConfig: [String: Any]) {
        self.apiKey = apiKey
        instructions = sessionConfig["instructions"] as? String ?? ""
        tools = (sessionConfig["tools"] as? [[String: Any]] ?? []).map { t in
            ["type": "function", "function": ["name": t["name"] ?? "", "description": t["description"] ?? "", "parameters": t["parameters"] ?? [:]]]
        }
        messages = [["role": "system", "content": instructions]]
        isOpen = true
        startListening()
        DispatchQueue.main.async { self.onEvent(["type": "session.updated"]) }
    }

    func disconnect() {
        isOpen = false
        stopListening()
        synth.stopSpeaking(at: .immediate)
    }

    // MARK: - Dinleme (Apple konuşma tanıma)

    private func startListening() {
        stopListening()
        guard let recognizer, recognizer.isAvailable else { log("yerel: Türkçe tanıyıcı hazır değil"); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = false
        req.taskHint = .dictation
        request = req
        lastPartial = ""
        speaking = false
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty && text != self.lastPartial {
                    self.lastPartial = text
                    self.lastPartialAt = Date()
                    if !self.speaking {
                        self.speaking = true
                        DispatchQueue.main.async { self.onEvent(["type": "input_audio_buffer.speech_started"]) }
                    }
                    self.scheduleEnd()
                }
                if result.isFinal { self.finishUtterance() }
            }
            if let error, self.isOpen, !self.paused {
                let code = (error as NSError).code
                if code != 216 && code != 301 && code != 1110 { self.log("yerel: tanıma hatası \(code)") }
                // Tanıma süresi dolunca (≈1 dk) ya da sessizlikte tazele.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.isOpen, !self.paused, self.task == nil else { return }
                    self.startListening()
                }
            }
        }
    }

    private func stopListening() {
        endTimer?.invalidate()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard isOpen, !paused else { return }
        request?.append(buffer)
    }

    func appendAudio(_ pcm16: Data) { /* yerel hat 24k parçaları kullanmaz */ }

    /// Kısmi metin 1 sn değişmeyince cümle bitmiş sayılır.
    private func scheduleEnd() {
        DispatchQueue.main.async {
            self.endTimer?.invalidate()
            self.endTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                self?.finishUtterance()
            }
        }
    }

    private func finishUtterance() {
        DispatchQueue.main.async {
            guard self.speaking else { return }
            self.speaking = false
            self.endTimer?.invalidate()
            let text = self.lastPartial.trimmingCharacters(in: .whitespacesAndNewlines)
            self.lastPartial = ""
            // Tanıyıcıyı durdur (cevap üretilirken ve Jarvis konuşurken dinlemeyiz), sonra tazele.
            self.paused = true
            self.stopListening()
            self.onEvent(["type": "input_audio_buffer.speech_stopped"])
            self.itemCounter += 1
            let itemId = "local_\(self.itemCounter)"
            self.onEvent(["type": "conversation.item.added", "item": ["id": itemId, "role": "user", "type": "message"]])
            guard !text.isEmpty else { self.resumeListening(); return }
            self.onEvent(["type": "conversation.item.input_audio_transcription.completed", "transcript": text])
            self.messages.append(["role": "user", "content": text, "_id": itemId])
            self.respond()
        }
    }

    private func resumeListening() {
        paused = false
        if isOpen { startListening() }
    }

    // MARK: - Konuşma: metin modeli (araç çağrılı)

    func sendText(_ text: String) {
        messages.append(["role": "user", "content": text])
        respond()
    }

    func createResponse(instructions: String) {
        messages.append(["role": "system", "content": instructions])
        respond()
    }

    func sendFunctionResult(callId: String, output: Any) {
        let json = (try? JSONSerialization.data(withJSONObject: output)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        messages.append(["role": "tool", "tool_call_id": callId, "content": json])
        respond()
    }

    func deleteItem(_ id: String) {
        messages.removeAll { ($0["_id"] as? String) == id }
    }

    func cancelResponse() {
        synth.stopSpeaking(at: .immediate)
    }

    private func respond() {
        paused = true
        stopListening()
        onEvent(["type": "response.created"])
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Dahili "_id" alanını API'ye gönderme.
        let clean = messages.map { m -> [String: Any] in var c = m; c["_id"] = nil; return c }
        var body: [String: Any] = ["model": Self.textModel, "messages": clean, "temperature": 0.4]
        if !tools.isEmpty { body["tools"] = tools }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choice = (obj["choices"] as? [[String: Any]])?.first,
                      let msg = choice["message"] as? [String: Any] else {
                    let why = err?.localizedDescription ?? String(data: data ?? Data(), encoding: .utf8)?.prefix(200).description ?? "boş cevap"
                    self.onEvent(["type": "error", "error": ["message": "Metin modeli: \(why)"]])
                    self.onEvent(["type": "response.done"])
                    self.resumeListening()
                    return
                }
                if let calls = msg["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                    // Araç çağrısı: mesajı geçmişe ekle, AppState'e Realtime biçiminde bildir; sonuç gelince devam.
                    self.messages.append(["role": "assistant", "content": msg["content"] as? String ?? "", "tool_calls": calls])
                    for c in calls {
                        let fn = c["function"] as? [String: Any] ?? [:]
                        self.onEvent(["type": "response.output_item.done",
                                      "item": ["type": "function_call", "name": fn["name"] ?? "", "call_id": c["id"] ?? "", "arguments": fn["arguments"] ?? "{}"]])
                    }
                    self.onEvent(["type": "response.done"])
                    return
                }
                let text = (msg["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                self.messages.append(["role": "assistant", "content": text])
                self.speak(text)
            }
        }.resume()
    }

    // MARK: - Sesli okuma (Apple Türkçe sesi → 24 kHz PCM16 → Realtime olayı gibi)

    private func speak(_ text: String) {
        guard !text.isEmpty else { onEvent(["type": "response.done"]); resumeListening(); return }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "tr-TR")
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        var converter: AVAudioConverter?
        var delivered = 0
        synth.write(u) { [weak self] buffer in
            guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                // Son tampon: okuma bitti.
                DispatchQueue.main.async {
                    self.onEvent(["type": "response.output_audio_transcript.done", "transcript": text])
                    self.onEvent(["type": "response.done"])
                    self.log("yerel: \(delivered) ses parçası okundu")
                    // Hoparlörde çalma bitince AppState onPlaybackIdle ile dinlemeye döner; biz 0,5 sn sonra tanıyıcıyı tazeleriz.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.resumeListening() }
                }
                return
            }
            if converter == nil { converter = AVAudioConverter(from: pcm.format, to: self.outFormat) }
            guard let conv = converter,
                  let out = AVAudioPCMBuffer(pcmFormat: self.outFormat, frameCapacity: AVAudioFrameCount(Double(pcm.frameLength) * 24_000 / pcm.format.sampleRate) + 16) else { return }
            var consumed = false
            var error: NSError?
            conv.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return pcm
            }
            guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
            let data = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
            delivered += 1
            DispatchQueue.main.async {
                self.onEvent(["type": "response.output_audio.delta", "delta": data.base64EncodedString()])
                self.onEvent(["type": "response.output_audio_transcript.delta", "delta": delivered == 1 ? text : ""])
            }
        }
    }
}
