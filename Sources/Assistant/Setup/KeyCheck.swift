import Foundation

/// Asks each service whether a key is any good, before it is saved.
/// Every check returns nil when the key works, or a sentence saying why not.
enum KeyCheck {
    /// The live voice needs this exact model, so that is what is asked for.
    static func openAI(_ key: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models/gpt-live-1")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12
        do {
            let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: return nil
            case 401: return "OpenAI did not accept that key."
            case 403, 404: return "That key is real, but it is not allowed to use the live voice model."
            case 429: return "OpenAI says this key is out of quota or sending too much."
            case let status: return "OpenAI answered with \(status). Try again in a moment."
            }
        } catch {
            return "Could not reach OpenAI. Check the connection and try again."
        }
    }

    /// Rime says "ready" as soon as a connection with a good key is open.
    static func rime(_ key: String) async -> String? {
        var request = URLRequest(url: URL(string: "wss://coda.api.rime.ai/ws")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
        task.resume()
        let timeout = Task {
            try? await Task.sleep(for: .seconds(8))
            task.cancel(with: .goingAway, reason: nil)
        }
        defer {
            timeout.cancel()
            task.cancel(with: .normalClosure, reason: nil)
        }
        do {
            if case .string(let text) = try await task.receive(), text.contains("\"ready\"") { return nil }
            return "Rime did not accept that key."
        } catch {
            return "Rime did not accept that key, or could not be reached."
        }
    }
}
