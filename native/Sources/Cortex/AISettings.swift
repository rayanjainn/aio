import SwiftUI

/// Where the palette's AI answers come from: your local Ollama (default), Ollama Cloud, or any
/// OpenAI-compatible server (OpenAI, OpenRouter, Groq, LM Studio, a company gateway…).
struct AISettings: Codable, Equatable {
    var provider = "ollama"            // "ollama" | "openai"
    var baseURL = "https://api.openai.com/v1"
    var model = "gpt-4o-mini"
    var apiKey = ""

    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/ai.json")
    }

    static func load() -> AISettings {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(AISettings.self, from: d) else { return AISettings() }
        return s
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = try? JSONEncoder().encode(self) else { return }
        try? d.write(to: Self.url, options: .atomic)
        // The key lives in this file: keep it readable by you only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
    }
}

struct AIPane: View {
    @State private var s = AISettings.load()

    var body: some View {
        Form {
            Section("Answers") {
                Picker("Provider", selection: $s.provider) {
                    Text("Ollama (on this Mac)").tag("ollama")
                    Text("OpenAI-compatible server").tag("openai")
                }
                if s.provider == "openai" {
                    TextField("Base URL", text: $s.baseURL)
                    TextField("Model", text: $s.model)
                    SecureField("API key", text: $s.apiKey)
                    Text("Works with OpenAI, OpenRouter, Groq, LM Studio or any server that speaks the OpenAI chat API. The key is stored in ~/.cortex/native/ai.json, readable only by you. Your prompt (and any clipboard text you send with an AI command) goes to that server.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Uses Ollama running on this Mac (ollama.com). Nothing leaves your computer.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("In ⌘K: type  ? your question  or  ai  for clipboard commands.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .onChange(of: s) { _, new in new.save() }
    }
}
