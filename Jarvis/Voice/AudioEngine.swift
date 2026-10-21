import AVFoundation

/// Mikrofon ve hoparlör. Realtime API 24 kHz, tek kanal, 16 bit PCM ister; burada o formata çevrilir.
///
/// İKİ AYRI MOTOR: giriş motoru (yankı önlemeli, yalnız tap) ve çıkış motoru (oynatıcı). Ölçüldü (vptest):
/// aynı motora hem yankı önleme hem oynatıcı takılınca motor -10875 ile açılmıyor; iki motor sorunsuz.
/// Yankı önleme açılamazsa "yarım çift yönlü" moda düşülür: Jarvis konuşurken mikrofon dışarı gitmez
/// (`halfDuplex`), böylece model kendi sesini duymaz ve konuşmacı doğrulaması Jarvis'in sesini ölçmez.
final class AudioEngine {
    static let sampleRate: Double = 24_000

    private var inputEngine = AVAudioEngine()
    private var outputEngine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    /// Mikrofondan gelen 24 kHz PCM16 parçaları (yaklaşık 100 ms'lik).
    var onChunk: (Data) -> Void = { _ in }
    /// Aynı ses, tek kanal, aygıt örnekleme hızında (uyandırma kelimesi tanıyıcısı için).
    var onRawBuffer: (AVAudioPCMBuffer) -> Void = { _ in }
    /// Adım adım günlük (hata ayıklama).
    var log: (String) -> Void = { _ in }

    /// Küre animasyonu için anlık ses seviyeleri (0...1). Ana iş parçacığı dışından yazılır, okunması güvenli.
    private(set) var inputLevel: Float = 0
    private(set) var outputLevel: Float = 0

    /// Yankı önleme açık mı? (Gürültü bastırma için yararlı; ama ayrı motordan çalan sesi SİLMİYOR, ölçüldü:
    /// "Sizi dinliyorum." 760 ms'lik "cümle" olarak geri geldi.) Bu yüzden yarım çift yönlü mod hep açık.
    private(set) var voiceProcessing = false
    var halfDuplex: Bool { true }
    /// Çalma bittikten sonra bu kadar süre daha mikrofon yutulur (yankı kuyruğu).
    static let muteTail: TimeInterval = 0.4
    private var lastPlaybackEnd = Date.distantPast
    /// Şu an mikrofon yutulmalı mı?
    var shouldMuteMic: Bool { isSpeaking || Date().timeIntervalSince(lastPlaybackEnd) < Self.muteTail }
    /// Kullanılan mikrofonun adı (günlük ve arayüz için).
    private(set) var inputName = "sistem varsayılanı"

    /// Hoparlörde çalmayı bekleyen/çalan parça sayısı. Model sesi gerçek zamandan hızlı gönderir;
    /// "cevap bitti" olayı ses hâlâ çalarken gelir. Küre ve durum bu sayaca bakar, olaya değil.
    private let playLock = NSLock()
    private var pendingBuffers = 0
    var isSpeaking: Bool { playLock.lock(); defer { playLock.unlock() }; return pendingBuffers > 0 }
    /// Kuyruktaki son parça da çalındı.
    var onPlaybackIdle: () -> Void = {}

    private var observer: NSObjectProtocol?
    private var active = false
    private var restartWork: DispatchWorkItem?
    private var restartTimes: [Date] = []
    /// Dinle açılmadan önceki sistem mikrofonu; kapanınca geri yüklenir.
    private var previousDefaultInput: AudioDeviceID?

    // MARK: - Açma / kapama

    func start() throws {
        active = true
        watchConfigurationChanges()
        pinInputDevice()
        try startOutput()
        // Yankı önleme bazı aygıtlarda açılmıyor; o zaman onsuz başlat, yarım çift yönlü moda geç.
        do {
            try startInput(voiceProcessing: true)
        } catch {
            log("ses: yankı önlemeli giriş olmadı (\(error.localizedDescription)); onsuz deneniyor")
            teardownInput()
            try startInput(voiceProcessing: false)
        }
    }

    func stop() {
        active = false
        restartWork?.cancel()
        teardownInput()
        teardownOutput()
        restoreInputDevice()
        inputLevel = 0
        outputLevel = 0
    }

    func describe() -> String {
        let f = inputEngine.inputNode.outputFormat(forBus: 0)
        return "mikrofon \(inputName), yankı önleme \(voiceProcessing ? "açık" : "kapalı (yarım çift yönlü)"), giriş \(Int(f.sampleRate)) Hz \(f.channelCount) kanal, giriş motoru \(inputEngine.isRunning ? "çalışıyor" : "DURUYOR"), çıkış motoru \(outputEngine.isRunning ? "çalışıyor" : "DURUYOR")"
    }

    private func startInput(voiceProcessing vp: Bool) throws {
        let input = inputEngine.inputNode
        if vp { try input.setVoiceProcessingEnabled(true) }
        voiceProcessing = vp
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw JarvisError("mikrofon formatı okunamadı (giriş aygıtı yok mu?)")
        }
        // Yankı önlemeli mikrofon dizisi 5 kanal verebiliyor; ilk kanalı alıp mono yapıyoruz.
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: mono, to: wireFormat) else {
            throw JarvisError("ses dönüştürücü kurulamadı (\(inFormat))")
        }
        monoFormat = mono
        converter = conv
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inFormat.sampleRate / 10), format: inFormat) { [weak self] buf, _ in
            guard let self, let m = self.monoBuffer(from: buf) else { return }
            self.inputLevel = Self.level(of: m, previous: self.inputLevel)
            self.onRawBuffer(m)
            self.convertAndEmit(m)
        }
        log("ses: mikrofon \(inputName), yankı önleme=\(vp), giriş \(Int(inFormat.sampleRate)) Hz \(inFormat.channelCount) kanal")
        inputEngine.prepare()
        try inputEngine.start()
    }

    private func startOutput() throws {
        outputEngine.attach(player)
        outputEngine.connect(player, to: outputEngine.mainMixerNode, format: playFormat)
        // Hoparlöre gerçekten giden sesi ölçüyoruz; kuyruğa eklenen değil, o anda çalan.
        player.installTap(onBus: 0, bufferSize: 1024, format: playFormat) { [weak self] buf, _ in
            guard let self else { return }
            self.outputLevel = Self.level(of: buf, previous: self.outputLevel)
        }
        outputEngine.prepare()
        try outputEngine.start()
        player.play()
    }

    /// Giriş motorunu atıp yenisini kurar (aynı motora ikinci kez tap kurmak istisna fırlatıyor; ölçüldü).
    private func teardownInput() {
        inputEngine.inputNode.removeTap(onBus: 0)
        inputEngine.stop()
        inputEngine = AVAudioEngine()
        converter = nil
        monoFormat = nil
    }

    private func teardownOutput() {
        player.removeTap(onBus: 0)
        player.stop()
        outputEngine.stop()
        outputEngine = AVAudioEngine()
        player = AVAudioPlayerNode()
        playLock.lock(); pendingBuffers = 0; playLock.unlock()
    }

    // MARK: - Mikrofon seçimi

    /// Mikrofonu sabitle: tercih edilen (ya da dahili) aygıtı sistem varsayılanı yap. Sistem varsayılanı
    /// AirPods'a kayınca telefon profiline düşmesin, konuşmacı profili tutarlı kalsın.
    /// Ölçüldü: motorun giriş birimine aygıt atamak (kAudioOutputUnitProperty_CurrentDevice) -10875 veriyor.
    private func pinInputDevice() {
        guard let dev = InputDevices.preferred(uid: Prefs.inputDeviceUID.isEmpty ? nil : Prefs.inputDeviceUID) else {
            inputName = "sistem varsayılanı"; return
        }
        let current = InputDevices.systemDefaultInput()
        if current != dev.id {
            if previousDefaultInput == nil { previousDefaultInput = current }
            if InputDevices.setSystemDefaultInput(dev.id) {
                log("ses: sistem mikrofonu \(dev.name) yapıldı (önce: \(current.map(InputDevices.name) ?? "yok"))")
            } else {
                log("ses: sistem mikrofonu değiştirilemedi")
            }
        }
        inputName = dev.name
    }

    private func restoreInputDevice() {
        guard let prev = previousDefaultInput else { return }
        previousDefaultInput = nil
        if InputDevices.setSystemDefaultInput(prev) { log("ses: sistem mikrofonu geri yüklendi: \(InputDevices.name(of: prev))") }
    }

    /// Ses aygıtı değişince (kulaklık takılır/çıkar) macOS motoru durdurur; bildirimi dinleyip taze kurarız.
    /// Art arda gelen bildirimler 0,6 sn'de toplanır; motor hâlâ çalışıyorsa dokunulmaz (kısır döngü ölçüldü).
    private func watchConfigurationChanges() {
        if observer != nil { return }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.active else { return }
            self.restartWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.active else { return }
                if self.inputEngine.isRunning && self.outputEngine.isRunning {
                    self.log("ses: aygıt yapılandırması değişti ama motorlar çalışıyor, dokunulmadı")
                    return
                }
                let now = Date()
                self.restartTimes = self.restartTimes.filter { now.timeIntervalSince($0) < 60 }
                guard self.restartTimes.count < 5 else {
                    self.log("ses: bir dakikada 5 yeniden kurulum oldu, durduruldu; Dinle'yi kapatıp açın")
                    return
                }
                self.restartTimes.append(now)
                self.log("ses: aygıt yapılandırması değişti, motor durmuş, yeniden kuruluyor")
                self.teardownInput()
                self.teardownOutput()
                do {
                    try self.startOutput()
                    do { try self.startInput(voiceProcessing: true) } catch { self.teardownInput(); try self.startInput(voiceProcessing: false) }
                    self.log("ses: motor yeniden çalışıyor (\(self.describe()))")
                } catch {
                    self.log("ses: yeniden başlatılamadı: \(error.localizedDescription)")
                }
            }
            self.restartWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    // MARK: - Çalma

    /// Modelden gelen PCM16 sesi kuyruğa ekler.
    func enqueue(pcm16: Data) {
        let frames = pcm16.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        let out = buf.floatChannelData![0]
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(samples[i]) / 32768 }
        }
        playLock.lock(); pendingBuffers += 1; playLock.unlock()
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.playLock.lock()
            self.pendingBuffers = max(0, self.pendingBuffers - 1)
            let idle = self.pendingBuffers == 0
            self.playLock.unlock()
            if idle { self.lastPlaybackEnd = Date(); self.onPlaybackIdle() }
        }
        if !player.isPlaying { player.play() }
    }

    /// Kullanıcı lafa girdi: çalmakta olan cevabı anında kes.
    func flushPlayback() {
        playLock.lock(); pendingBuffers = 0; playLock.unlock()
        lastPlaybackEnd = Date()
        player.stop()
        player.play()
    }

    // MARK: - Yardımcılar

    /// Çok kanallı tamponun ilk kanalını mono tampona kopyalar.
    private func monoBuffer(from buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let monoFormat, let src = buf.floatChannelData?[0],
              let m = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buf.frameLength) else { return nil }
        m.frameLength = buf.frameLength
        m.floatChannelData![0].update(from: src, count: Int(buf.frameLength))
        return m
    }

    /// RMS seviyesi; konuşma aralığını 0...1'e sıkıştırır, düşerken yumuşatır ki küre titremesin.
    private static func level(of buf: AVAudioPCMBuffer, previous: Float) -> Float {
        guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return previous * 0.8 }
        var sum: Float = 0
        for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
        let rms = sqrt(sum / Float(buf.frameLength))
        let db = 20 * log10(max(rms, 1e-6))
        let norm = min(max((db + 50) / 40, 0), 1)   // -50 dB sessiz, -10 dB bağırıyor
        return norm > previous ? norm : previous * 0.85 + norm * 0.15
    }

    private func convertAndEmit(_ buf: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = wireFormat.sampleRate / buf.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buf
        }
        guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        onChunk(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
    }
}
