//! Ollama / cloud-LLM settings (read from ~/.cortex/config.toml).

/// Ollama connection settings from ~/.cortex/config.toml `[ollama]`.
/// When `api_key` is present, chat runs on Ollama Cloud (host=https://ollama.com);
/// otherwise it falls back to a local daemon. Embeddings always stay local.
pub struct OllamaCfg { pub host: String, pub api_key: Option<String>, pub model: String }

pub fn ollama_cfg() -> OllamaCfg {
    fn field(raw: &str, key: &str) -> Option<String> {
        let section = raw.split("[ollama]").nth(1)?;
        let section = section.split("\n[").next().unwrap_or(section);
        regex::Regex::new(&format!(r#"(?m)^\s*{key}\s*=\s*"([^"]+)""#)).ok()?
            .captures(section).map(|c| c[1].to_string())
    }
    let raw = dirs::home_dir().map(|h| h.join(".cortex/config.toml"))
        .and_then(|p| std::fs::read_to_string(p).ok()).unwrap_or_default();
    let api_key = field(&raw, "api_key").filter(|s| !s.is_empty());
    let host = field(&raw, "host").filter(|s| !s.is_empty())
        .unwrap_or_else(|| "http://localhost:11434".into())
        .trim_end_matches('/').to_string();
    let model = field(&raw, "chat_model").filter(|s| !s.is_empty()).unwrap_or_default();
    OllamaCfg { host, api_key, model }
}

