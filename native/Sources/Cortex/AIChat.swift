import Foundation

/// A streamed answer from Ollama (local, or Ollama Cloud when an api_key is in ~/.cortex/config.toml).
enum AIChat {
    struct Config { var host: String; var apiKey: String?; var model: String }

    static func config() -> Config {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/config.toml")
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        func field(_ key: String) -> String? {
            guard let section = raw.components(separatedBy: "[ollama]").dropFirst().first else { return nil }
            let body = section.components(separatedBy: "\n[").first ?? section
            guard let regex = try? NSRegularExpression(pattern: "(?m)^\\s*\(key)\\s*=\\s*\"([^\"]+)\""),
                  let m = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                  let r = Range(m.range(at: 1), in: body) else { return nil }
            return String(body[r])
        }
        let key = field("api_key").flatMap { $0.isEmpty ? nil : $0 }
        let host = (field("host") ?? "http://localhost:11434").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return Config(host: key != nil && field("host") == nil ? "https://ollama.com" : host, apiKey: key, model: field("chat_model") ?? "")
    }

    static func request(_ cfg: Config, path: String, body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: cfg.host + path)!)
        r.timeoutInterval = 120
        if let key = cfg.apiKey { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpMethod = "POST"; r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    static func pickModel(_ cfg: Config) async throws -> String {
        if !cfg.model.isEmpty { return cfg.model }
        var r = request(cfg, path: "/api/tags")
        r.timeoutInterval = 4
        let (data, _) = try await URLSession.shared.data(for: r)
        let names = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
            .flatMap { $0["models"] as? [[String: Any]] }?.compactMap { $0["name"] as? String } ?? []
        for preferred in ["llama3.1:8b", "qwen2.5:7b", "llama3.2:3b", "phi3:mini"] {
            if let hit = names.first(where: { $0.hasPrefix(preferred) }) { return hit }
        }
        guard let first = names.first else { throw EngineError(message: "Ollama has no models installed. Run: ollama pull llama3.2:3b") }
        return first
    }

    static func stream(_ prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let cfg = config()
                    let model: String
                    do { model = try await pickModel(cfg) }
                    catch let e as EngineError { throw e }
                    catch { throw EngineError(message: "Ollama isn't running. Start it (ollama.com) or add an api_key to ~/.cortex/config.toml.") }
                    let payload: [String: Any] = [
                        "model": model, "stream": true,
                        "messages": [
                            ["role": "system", "content": "You are Cortex, a concise assistant inside a Mac launcher. Answer directly in a few sentences unless asked for more."],
                            ["role": "user", "content": prompt],
                        ],
                    ]
                    let body = try JSONSerialization.data(withJSONObject: payload)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request(cfg, path: "/api/chat", body: body))
                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        throw EngineError(message: "The model server answered \(http.statusCode).")
                    }
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                        if let msg = (obj["message"] as? [String: Any])?["content"] as? String, !msg.isEmpty { continuation.yield(msg) }
                        if (obj["done"] as? Bool) == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
