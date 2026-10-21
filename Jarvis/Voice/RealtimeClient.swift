import Foundation

/// OpenAI Realtime API'ye WebSocket bağlantısı. Ses gönderir, ses ve olay alır.
/// Olaylar ham sözlük olarak dışarı verilir; yorumlama AppState'te.
final class RealtimeClient: NSObject, URLSessionWebSocketDelegate {
    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    var onEvent: ([String: Any]) -> Void = { _ in }
    var onClose: (String) -> Void = { _ in }
    private(set) var isOpen = false

    func connect(apiKey: String, model: String, sessionConfig: [String: Any]) {
        var req = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let t = session.webSocketTask(with: req)
        task = t
        t.resume()
        receiveLoop()
        send(["type": "session.update", "session": sessionConfig])
    }

    func disconnect() {
        isOpen = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    // MARK: - Gönderim

    func send(_ event: [String: Any]) {
        guard let task, let d = try? JSONSerialization.data(withJSONObject: event), let s = String(data: d, encoding: .utf8) else { return }
        task.send(.string(s)) { [weak self] err in
            if let err { self?.onClose("gönderim hatası: \(err.localizedDescription)") }
        }
    }

    func appendAudio(_ pcm16: Data) {
        send(["type": "input_audio_buffer.append", "audio": pcm16.base64EncodedString()])
    }

    /// Konuşmaya metin olarak bir kullanıcı mesajı sokar ve cevap ister (sistem bildirimleri için).
    func sendText(_ text: String) {
        send(["type": "conversation.item.create",
              "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]])
        send(["type": "response.create"])
    }

    /// Modelden, verilen yönergeyle hemen bir cevap ister (uyanış cümlesi gibi).
    func createResponse(instructions: String) {
        send(["type": "response.create", "response": ["instructions": instructions]])
    }

    /// Konuşmadan bir öğeyi siler (yabancı sesin söylediğini modele hiç işletmemek için).
    func deleteItem(_ id: String) {
        send(["type": "conversation.item.delete", "item_id": id])
    }

    /// Üretilmekte olan cevabı iptal eder.
    func cancelResponse() {
        send(["type": "response.cancel"])
    }

    func sendFunctionResult(callId: String, output: Any) {
        let json = (try? JSONSerialization.data(withJSONObject: output)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        send(["type": "conversation.item.create",
              "item": ["type": "function_call_output", "call_id": callId, "output": json]])
        send(["type": "response.create"])
    }

    // MARK: - Alım

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.isOpen = false
                self.onClose(err.localizedDescription)
            case .success(let msg):
                if case .string(let s) = msg,
                   let d = s.data(using: .utf8),
                   let ev = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    self.onEvent(ev)
                }
                self.receiveLoop()
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        isOpen = true
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isOpen = false
        let why = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "kod \(closeCode.rawValue)"
        onClose(why)
    }
}
