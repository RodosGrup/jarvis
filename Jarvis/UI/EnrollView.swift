import SwiftUI

/// Ses profili kaydı: üç cümle okunur, her biri ayrı kaydedilir, ortalaması profil olur.
struct EnrollView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var onDone: () -> Void = {}

    @State private var index = 0
    @State private var recording = false
    @State private var takes: [[Data]] = []
    @State private var message = ""
    @State private var seconds = 0
    @State private var timer: Timer?

    private let sentences = SpeakerVerifier.enrollmentSentences

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sesimi kaydet").font(.title3.weight(.semibold))
            if !state.isOn {
                Text("Önce menüden \"Dinle\" deyin; kayıt aynı mikrofonu kullanır.").foregroundStyle(.secondary)
            } else if !state.speaker.isReady {
                Text("Konuşmacı modeli yüklenemedi. Günlüğe bakın.").foregroundStyle(.red)
            } else if index < sentences.count {
                Text("Cümle \(index + 1) / \(sentences.count). Kaydı başlatın, normal sesinizle okuyun, bitirin.")
                    .foregroundStyle(.secondary)
                Text(sentences[index])
                    .font(.title3)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                HStack {
                    Button(recording ? "Bitir (\(seconds) sn)" : "Kaydı başlat") { recording ? stop() : start() }
                        .keyboardShortcut(.space, modifiers: [])
                        .tint(recording ? .red : .accentColor)
                        .buttonStyle(.borderedProminent)
                    if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
                }
            } else {
                Text(message).foregroundStyle(message.hasPrefix("Kaydedildi") ? .green : .red)
            }
            HStack {
                Spacer()
                Button(index < sentences.count ? "Vazgeç" : "Kapat") { cancel(); dismiss() }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func start() {
        state.beginEnrollRecording()
        recording = true
        seconds = 0
        message = ""
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in seconds += 1 }
    }

    private func stop() {
        timer?.invalidate()
        recording = false
        let chunks = state.endEnrollRecording()
        // 100 ms'lik parçalar: 15 parça = 1,5 sn. Daha kısası modele yetmez.
        guard chunks.count >= 15 else { message = "Çok kısa, tekrar okuyun."; return }
        takes.append(chunks)
        index += 1
        if index == sentences.count { finish() }
    }

    private func finish() {
        message = "Profil çıkarılıyor…"
        let t = takes
        let apiKey = Prefs.apiKey
        // Yabancı referans sesler yoksa önce onları üret (OpenAI TTS, yalnız metin gider), sonra profili çıkar.
        let enrollNow: () -> Void = {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = state.speaker.enroll(samplesPerSentence: t)
                DispatchQueue.main.async {
                    if let r = result {
                        let m = r.sentenceScores.map { String(format: "%.2f", $0) }.joined(separator: ", ")
                        message = String(format: "Kaydedildi. Cümle tutarlılığı: %@. Yabancıya en yakın: %.2f. Ayrışma: %@.", m, r.cohortMax, r.strength)
                        SpeakerVerifier.enabled = true
                        onDone()
                    } else {
                        message = "Profil çıkarılamadı; kayıtlar çok kısa ya da model hazır değil."
                    }
                }
            }
        }
        if state.speaker.hasCohort || apiKey.isEmpty {
            enrollNow()
        } else {
            state.speaker.buildCohort(apiKey: apiKey, progress: { message = "Yabancı sesler hazırlanıyor: \($0)" }) { n in
                message = n > 0 ? "Yabancı sesler hazır (\(n)). Profil çıkarılıyor…" : "Yabancı sesler üretilemedi; sabit aralıklarla devam."
                enrollNow()
            }
        }
    }

    private func cancel() {
        timer?.invalidate()
        if recording { _ = state.endEnrollRecording() }
    }
}
