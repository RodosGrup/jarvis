import SwiftUI

/// Ayarlar penceresi: API anahtarı, model, ses, orkestratör argümanları.
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var apiKey = Prefs.apiKey
    @State private var model = Prefs.model
    @State private var voice = Prefs.voice
    @State private var wakeWord = Prefs.wakeWord
    @State private var inputUID = Prefs.inputDeviceUID
    private let inputs = InputDevices.list()
    @State private var claudeArgs = Prefs.claudeArgs
    @State private var claudePath = Prefs.claudePath
    @State private var saved = false
    @State private var speakerGate = SpeakerVerifier.enabled
    @State private var showEnroll = false
    @State private var profileTick = 0

    var body: some View {
        Form {
            Section("OpenAI") {
                SecureField("API anahtarı", text: $apiKey)
                Picker("Model", selection: $model) {
                    ForEach(Prefs.models, id: \.self) { Text($0) }
                }
                Picker("Ses", selection: $voice) {
                    ForEach(Prefs.voices, id: \.self) { Text($0) }
                }
                TextField("Uyandırma kelimesi", text: $wakeWord)
                Picker("Mikrofon", selection: $inputUID) {
                    Text("Dahili mikrofon (önerilen)").tag("")
                    ForEach(inputs) { d in Text(d.name).tag(d.uid) }
                }
                Text("AirPods mikrofonu kulaklığı telefon kalitesine düşürür ve ses profilini bozar; ses yine kulaklıktan çalar, mikrofon Mac'te kalsın. Değişiklik Dinle'yi kapatıp açınca geçerli olur.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Mini ucuz ve yeterli; tam model daha doğal konuşur ama 3 kat pahalı. Değişiklik bir sonraki bağlantıda geçerli olur.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ses tanıma") {
                Toggle("Sadece benim sesime tepki ver", isOn: $speakerGate)
                HStack {
                    Text(state.speaker.hasProfile
                         ? "Ses profili: \(state.speaker.sampleCount) örnek · yabancı referans: \(state.speaker.cohortCount)"
                         : "Ses profili yok.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Sesimi kaydet…") { showEnroll = true }
                    if state.speaker.hasProfile {
                        Button("Profili sil") { state.speaker.clearProfile(); profileTick += 1 }
                    }
                }
                Text("Jarvis sekiz cümle okutur, sesinizin parmak izini çıkarır ve yerelde saklar; sesiniz dışarı gitmez. Karar sabit bir eşikle değil karşılaştırmayla verilir: sesiniz size mi, yoksa yabancı referans seslere mi daha çok benziyor? Jarvis sizi dinledikçe profil büyür ve tanıma güçlenir.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude orkestratörü") {
                TextField("claude yolu", text: $claudePath)
                TextField("Ek argümanlar", text: $claudeArgs)
                Text("Orkestratör, görevleri diğer oturumlara SendMessage ile iletir. Onların mesajı onaysız kabul etmesi için izin modu onlarla aynı olmalı; varsayılan --permission-mode auto.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if saved { Text("Kaydedildi").font(.caption).foregroundStyle(.secondary) }
                Button("Kaydet") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.bottom, 8)
        .id(profileTick)
        .sheet(isPresented: $showEnroll) {
            EnrollView(onDone: {
                speakerGate = SpeakerVerifier.enabled
                profileTick += 1
            }).environmentObject(state)
        }
    }

    private func save() {
        Prefs.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Prefs.model = model
        SpeakerVerifier.enabled = speakerGate
        Prefs.voice = voice
        Prefs.inputDeviceUID = inputUID
        Prefs.wakeWord = wakeWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Jarvis" : wakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let argsChanged = claudeArgs != Prefs.claudeArgs || claudePath != Prefs.claudePath
        Prefs.claudeArgs = claudeArgs
        Prefs.claudePath = claudePath
        if argsChanged { state.restartOrchestrator() }
        saved = true
    }
}
