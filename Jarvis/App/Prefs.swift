import Foundation
import Security

/// Kullanıcı ayarları. API anahtarı Keychain'de, gerisi UserDefaults'ta.
enum Prefs {
    static let models = ["gpt-realtime-mini", "gpt-realtime"]
    static let voices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]

    static var model: String {
        get { UserDefaults.standard.string(forKey: "model") ?? "gpt-realtime-mini" }
        set { UserDefaults.standard.set(newValue, forKey: "model") }
    }
    /// Uyandırma kelimesi; cihaz içi tanıma İngilizce olduğundan İngilizce okunuşu olan bir kelime iyi çalışır.
    static var wakeWord: String {
        get { UserDefaults.standard.string(forKey: "wakeWord") ?? "Jarvis" }
        set { UserDefaults.standard.set(newValue, forKey: "wakeWord") }
    }
    /// Seçili mikrofonun UID'si; boşsa dahili mikrofon, o da yoksa sistem varsayılanı.
    static var inputDeviceUID: String {
        get { UserDefaults.standard.string(forKey: "inputDeviceUID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "inputDeviceUID") }
    }
    static var voice: String {
        get { UserDefaults.standard.string(forKey: "voice") ?? "marin" }
        set { UserDefaults.standard.set(newValue, forKey: "voice") }
    }
    /// Orkestratör Claude oturumuna geçilecek ek argümanlar. Diğer oturumların mesajı onaysız
    /// kabul etmesi için izin sınıfı onlarla aynı olmalı; varsayılan ayar "auto".
    static var claudeArgs: String {
        get { UserDefaults.standard.string(forKey: "claudeArgs") ?? "--permission-mode auto" }
        set { UserDefaults.standard.set(newValue, forKey: "claudeArgs") }
    }
    static var claudePath: String {
        get {
            if let p = UserDefaults.standard.string(forKey: "claudePath"), !p.isEmpty { return p }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            for c in ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            where FileManager.default.isExecutableFile(atPath: c) { return c }
            return "\(home)/.local/bin/claude"
        }
        set { UserDefaults.standard.set(newValue, forKey: "claudePath") }
    }

    // MARK: - Keychain

    private static let service = "com.batuhanhaymana.jarvis"
    private static let account = "openai-api-key"

    static var apiKey: String {
        get {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
            ]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
            return String(data: d, encoding: .utf8) ?? ""
        }
        set {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(q as CFDictionary)
            guard !newValue.isEmpty else { return }
            var add = q
            add[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
