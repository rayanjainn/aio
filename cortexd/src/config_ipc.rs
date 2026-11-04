//! Settings shared with the app (`~/.cortex/config.json`). Same schema the desktop
//! app always wrote, so existing configs keep working.

use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;
use std::{collections::HashMap, path::PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppConfig {
    pub retention_days:   u32,
    pub blocked_apps:     Vec<String>,
    pub raw_storage:      bool,
    pub compress_raw:     bool,
    pub github_token:     String,
    pub enabled_plugins:  HashMap<String, bool>,
    pub file_roots:       Vec<String>,
    pub quota_bytes:      u64,
    pub terminal:         String,
    pub ui:               serde_json::Map<String, JsonValue>,
    pub shortcuts:        HashMap<String, String>,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            retention_days:  30,
            blocked_apps:    vec![],
            raw_storage:     false,
            compress_raw:    false,
            github_token:    String::new(),
            enabled_plugins: HashMap::new(),
            file_roots:      vec![],
            quota_bytes:     5 * 1024 * 1024 * 1024,
            terminal:        default_terminal(),
            ui:              serde_json::Map::new(),
            shortcuts:       HashMap::new(),
        }
    }
}

pub fn default_terminal() -> String {
    #[cfg(target_os = "macos")]   { "Terminal".into() }
    #[cfg(target_os = "windows")] { "PowerShell".into() }
    #[cfg(target_os = "linux")]   { "xterm".into() }
}

pub fn configured_terminal() -> String { load_config().terminal }

fn config_path() -> PathBuf {
    dirs::home_dir().unwrap_or_default().join(".cortex/config.json")
}

pub fn load_config() -> AppConfig {
    let Ok(raw) = std::fs::read_to_string(config_path()) else { return AppConfig::default() };
    serde_json::from_str(&raw).unwrap_or_default()
}

pub fn save_config(cfg: &AppConfig) -> Result<()> {
    let path = config_path();
    std::fs::create_dir_all(path.parent().unwrap_or(&path))?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_string_pretty(cfg)?)?;
    std::fs::rename(tmp, path)?;
    Ok(())
}
