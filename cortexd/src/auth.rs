//! Google OAuth2 + GitHub token check.

use anyhow::{Context, Result};
use chrono::Utc;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::time::Duration;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    sync::oneshot,
};
use url::form_urlencoded;

const TOKEN_FILE:    &str = ".cortex/tokens/google.json";
const CREDS_FILE:    &str = ".cortex/google_credentials.json";
const OAUTH_PORT:    u16  = 27183;
const GMAIL_SCOPES:  &str = "https://www.googleapis.com/auth/gmail.readonly \
                              https://www.googleapis.com/auth/calendar.readonly \
                              https://www.googleapis.com/auth/userinfo.email";

/* ─── Disk types ─────────────────────────────────────────── */

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GoogleToken {
    pub access_token:  String,
    pub refresh_token: Option<String>,
    pub token_type:    String,
    pub expires_at:    Option<i64>,
    pub email:         Option<String>,
}

#[derive(Debug, Deserialize)]
struct GoogleCreds { installed: CredsInner }

#[derive(Debug, Deserialize)]
struct CredsInner {
    client_id:     String,
    client_secret: String,
    auth_uri:      String,
    token_uri:     String,
}

/* ─── Frontend-facing status types ──────────────────────── */

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GoogleAuthStatus {
    pub connected: bool,
    pub email:     Option<String>,
    pub expired:   bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GithubAuthStatus {
    pub connected: bool,
    pub username:  Option<String>,
    pub error:     Option<String>,
}

/* ─── check_google_auth ──────────────────────────────────── */

pub fn check_google_auth_sync() -> GoogleAuthStatus {
    let path = dirs::home_dir().unwrap_or_default().join(TOKEN_FILE);

    let raw = match std::fs::read_to_string(&path) {
        Ok(r) => r,
        Err(_) => return GoogleAuthStatus { connected: false, email: None, expired: false },
    };
    let token: GoogleToken = match serde_json::from_str(&raw) {
        Ok(t) => t,
        Err(_) => return GoogleAuthStatus { connected: false, email: None, expired: false },
    };

    let expired = token.expires_at
        .map(|e| e < Utc::now().timestamp())
        .unwrap_or(false);

    GoogleAuthStatus { connected: true, email: token.email, expired }
}

/* ─── get_valid_access_token — shared by Gmail + Calendar plugins ── */

/// Returns a non-expired Google access token, refreshing via the saved
/// refresh_token + google_credentials.json if needed. Single source of truth —
/// both the Gmail and Calendar plugins call this instead of re-doing OAuth.
/// Errors if the user has not connected Google yet.
pub async fn get_valid_access_token() -> Result<String> {
    let home  = dirs::home_dir().unwrap_or_default();
    let tpath = home.join(TOKEN_FILE);
    let raw   = std::fs::read_to_string(&tpath)
        .context("Google not connected — open Settings → Connect Google")?;
    let mut token: GoogleToken = serde_json::from_str(&raw).context("parse google.json")?;

    // Still valid (>60s headroom)?
    let now = Utc::now().timestamp();
    if token.expires_at.map(|e| e > now + 60).unwrap_or(false) {
        return Ok(token.access_token);
    }

    // Refresh.
    let refresh = token.refresh_token.clone()
        .context("no refresh token — reconnect Google in Settings")?;
    let creds_raw = std::fs::read_to_string(home.join(CREDS_FILE))
        .context("missing google_credentials.json")?;
    let creds: GoogleCreds = serde_json::from_str(&creds_raw).context("invalid google_credentials.json")?;

    let http = Client::builder().timeout(Duration::from_secs(30)).build()?;
    let tres: serde_json::Value = http
        .post(&creds.installed.token_uri)
        .form(&[
            ("client_id",     creds.installed.client_id.as_str()),
            ("client_secret", creds.installed.client_secret.as_str()),
            ("refresh_token", refresh.as_str()),
            ("grant_type",    "refresh_token"),
        ])
        .send().await.context("token refresh")?
        .json().await.context("refresh JSON")?;

    if let Some(err) = tres["error"].as_str() {
        anyhow::bail!("refresh failed: {err} — reconnect Google in Settings");
    }
    let access = tres["access_token"].as_str().context("no access_token in refresh")?.to_string();
    token.access_token = access.clone();
    token.expires_at   = Some(now + tres["expires_in"].as_i64().unwrap_or(3600));
    // Google omits refresh_token on refresh — keep the old one.
    let _ = std::fs::write(&tpath, serde_json::to_string_pretty(&token)?);
    Ok(access)
}

/* ─── connect_google — full browser OAuth2 flow ─────────── */

const SUCCESS_HTML: &str = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n\
    <html><body style='font-family:system-ui;text-align:center;padding:60px;\
    background:#000;color:#fff'>\
    <h2 style='color:#4ade80;margin-bottom:8px'>&#x2713; Connected to Cortex</h2>\
    <p style='opacity:.5;font-size:14px'>Gmail is connected. Close this tab.</p>\
    </body></html>";

const FAIL_HTML: &str =
    "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";

pub async fn connect_google_oauth() -> Result<GoogleAuthStatus> {
    let home = dirs::home_dir().unwrap_or_default();

    // 1. Load credentials
    let creds_path = home.join(CREDS_FILE);
    if !creds_path.exists() {
        anyhow::bail!(
            "Add credentials at ~/.cortex/google_credentials.json first"
        );
    }
    let raw: String   = std::fs::read_to_string(&creds_path)?;
    let creds: GoogleCreds = serde_json::from_str(&raw)
        .context("invalid google_credentials.json")?;

    // 2. Build authorization URL
    let redirect = format!("http://localhost:{}/oauth/callback", OAUTH_PORT);
    let mut auth_url = url::Url::parse(&creds.installed.auth_uri)?;
    auth_url.query_pairs_mut()
        .append_pair("client_id",     &creds.installed.client_id)
        .append_pair("redirect_uri",  &redirect)
        .append_pair("response_type", "code")
        .append_pair("scope",         GMAIL_SCOPES)
        .append_pair("access_type",   "offline")
        .append_pair("prompt",        "consent");

    // 3. Bind callback listener
    let listener = TcpListener::bind(format!("127.0.0.1:{}", OAUTH_PORT))
        .await
        .with_context(|| format!("port {OAUTH_PORT} already in use"))?;

    let (code_tx, code_rx) = oneshot::channel::<String>();

    tokio::spawn(async move {
        let mut tx = Some(code_tx);
        loop {
            let Ok((mut stream, _)) = listener.accept().await else { break };
            let mut buf = vec![0u8; 8192];
            let n = stream.read(&mut buf).await.unwrap_or(0);
            let req = String::from_utf8_lossy(&buf[..n]);

            // Extract path from "GET /path?q HTTP/1.1"
            let path = req.split_whitespace().nth(1).unwrap_or("/");
            let query = path.splitn(2, '?').nth(1).unwrap_or("");
            let code  = form_urlencoded::parse(query.as_bytes())
                .find(|(k, _)| k == "code")
                .map(|(_, v)| v.into_owned());

            let html = if code.is_some() { SUCCESS_HTML } else { FAIL_HTML };
            let _ = stream.write_all(html.as_bytes()).await;

            if let Some(code) = code {
                if let Some(t) = tx.take() { let _ = t.send(code); }
                break;
            }
        }
    });

    // 4. Open browser
    opener::open(auth_url.as_str()).context("open browser")?;

    // 5. Wait for auth code (2-minute timeout)
    let code = tokio::time::timeout(Duration::from_secs(120), code_rx)
        .await
        .context("OAuth timed out — no callback received")?
        .context("callback channel closed")?;

    // 6. Exchange code for tokens
    let http = Client::builder().timeout(Duration::from_secs(30)).build()?;
    let tres: serde_json::Value = http
        .post(&creds.installed.token_uri)
        .form(&[
            ("code",          code.as_str()),
            ("client_id",     creds.installed.client_id.as_str()),
            ("client_secret", creds.installed.client_secret.as_str()),
            ("redirect_uri",  redirect.as_str()),
            ("grant_type",    "authorization_code"),
        ])
        .send().await.context("token exchange")?
        .json().await.context("token JSON")?;

    if let Some(err) = tres["error"].as_str() {
        anyhow::bail!("{err}: {}", tres["error_description"].as_str().unwrap_or(""));
    }

    let access   = tres["access_token"].as_str().context("no access_token")?.to_string();
    let refresh  = tres["refresh_token"].as_str().map(String::from);
    let expires_at = Utc::now().timestamp() + tres["expires_in"].as_i64().unwrap_or(3600);

    // 7. Fetch email via userinfo
    let email = match http
        .get("https://www.googleapis.com/oauth2/v2/userinfo")
        .bearer_auth(&access)
        .send().await
    {
        Ok(r) => r.json::<serde_json::Value>().await.ok()
            .and_then(|v| v["email"].as_str().map(String::from)),
        Err(_) => None,
    };

    // 8. Persist token
    let token = GoogleToken {
        access_token:  access,
        refresh_token: refresh,
        token_type:    "Bearer".into(),
        expires_at:    Some(expires_at),
        email:         email.clone(),
    };
    let dir = home.join(".cortex/tokens");
    std::fs::create_dir_all(&dir)?;
    std::fs::write(dir.join("google.json"), serde_json::to_string_pretty(&token)?)?;

    Ok(GoogleAuthStatus { connected: true, email, expired: false })
}

/* ─── check_github_token ─────────────────────────────────── */

/// The GitHub token, from the first source that has one:
/// `GITHUB_TOKEN` env → token pasted in Settings → `~/.cortex/config.toml`
/// `[github] token` → the GitHub CLI's login (`gh auth token`).
pub fn github_token() -> Option<String> {
    std::env::var("GITHUB_TOKEN").ok().filter(|t| !t.trim().is_empty())
        .or_else(|| Some(crate::config_ipc::load_config().github_token).filter(|t| !t.trim().is_empty()))
        .or_else(read_github_token)
        .or_else(gh_cli_token)
        .map(|t| t.trim().to_string())
}

/// GUI apps get a minimal PATH, so look for `gh` where Homebrew puts it too.
fn gh_cli_token() -> Option<String> {
    for gh in ["gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh"] {
        if let Ok(o) = std::process::Command::new(gh).args(["auth", "token"]).output() {
            let t = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if o.status.success() && !t.is_empty() { return Some(t); }
        }
    }
    None
}

fn read_github_token() -> Option<String> {
    let path    = dirs::home_dir()?.join(".cortex/config.toml");
    let raw     = std::fs::read_to_string(path).ok()?;
    let section = raw.split("[github]").nth(1)?;
    let section = section.split("\n[").next().unwrap_or(section);
    regex::Regex::new(r#"token\s*=\s*"([^"]+)""#).ok()?
        .captures(section)
        .map(|c| c[1].to_string())
}

pub async fn check_github_token() -> GithubAuthStatus {
    let Some(token) = tokio::task::spawn_blocking(github_token).await.ok().flatten() else {
        return GithubAuthStatus {
            connected: false,
            username:  None,
            error:     Some("No token — paste one below or run `gh auth login`".into()),
        };
    };

    let http = match Client::builder().timeout(Duration::from_secs(10)).build() {
        Ok(c)  => c,
        Err(e) => return GithubAuthStatus {
            connected: false, username: None, error: Some(e.to_string()),
        },
    };

    match http
        .get("https://api.github.com/user")
        .header("Authorization", format!("Bearer {token}"))
        .header("User-Agent", "Cortex/0.1.0")
        .send().await
    {
        Err(e) => GithubAuthStatus {
            connected: false, username: None, error: Some(e.to_string()),
        },
        Ok(r) if r.status() == reqwest::StatusCode::UNAUTHORIZED => GithubAuthStatus {
            connected: false, username: None,
            error: Some("Token expired or revoked — paste a new one".into()),
        },
        Ok(r) if !r.status().is_success() => GithubAuthStatus {
            connected: false, username: None,
            error: Some(format!("HTTP {}", r.status())),
        },
        Ok(r) => match r.json::<serde_json::Value>().await {
            Err(e) => GithubAuthStatus {
                connected: false, username: None, error: Some(e.to_string()),
            },
            Ok(v) => GithubAuthStatus {
                connected: true,
                username:  v["login"].as_str().map(String::from),
                error:     None,
            },
        },
    }
}
