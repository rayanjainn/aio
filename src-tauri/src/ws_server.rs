/// WebSocket server for the Chrome / Firefox browser extension.
///
/// Listens on `127.0.0.1:27182` (localhost only — not exposed to network).
/// Accepts any number of concurrent extension connections.
/// Each connection sends JSON `TabEvent` messages; the server forwards them to
/// `BrowserPlugin::handle_tab_event`.
///
/// Message format (from extension):
/// ```json
/// { "event": "updated", "tab_id": 42, "url": "https://…", "title": "…", "favicon_url": "…" }
/// { "event": "removed", "tab_id": 42 }
/// ```

use futures_util::{SinkExt, StreamExt};
use std::{net::SocketAddr, sync::Arc};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::{accept_async, tungstenite::Message};

use crate::plugins::browser::{BrowserPlugin, TabEvent};

const WS_ADDR: &str = "127.0.0.1:27182";

/// Start the WebSocket server.  Runs forever; should be `tokio::spawn`-ed.
pub async fn start(browser: Arc<BrowserPlugin>) {
    let listener = match TcpListener::bind(WS_ADDR).await {
        Ok(l) => {
            tracing::info!("WS server listening on {WS_ADDR}");
            l
        }
        Err(e) => {
            tracing::error!("WS server bind {WS_ADDR}: {e}");
            return;
        }
    };

    loop {
        match listener.accept().await {
            Ok((stream, addr)) => {
                let b = browser.clone();
                tokio::spawn(handle_connection(stream, addr, b));
            }
            Err(e) => {
                tracing::warn!("WS accept: {e}");
            }
        }
    }
}

async fn handle_connection(
    stream: TcpStream,
    addr: SocketAddr,
    browser: Arc<BrowserPlugin>,
) {
    let ws = match accept_async(stream).await {
        Ok(ws) => ws,
        Err(e) => {
            tracing::debug!("WS handshake {addr}: {e}");
            return;
        }
    };
    tracing::debug!("WS extension connected from {addr}");

    let (mut tx, mut rx) = ws.split();

    while let Some(msg) = rx.next().await {
        match msg {
            Ok(Message::Text(text)) => {
                match serde_json::from_str::<TabEvent>(&text) {
                    Ok(event) => {
                        browser.handle_tab_event(event).await;
                    }
                    Err(e) => {
                        tracing::debug!("WS bad TabEvent from {addr}: {e} — {text}");
                    }
                }
            }
            Ok(Message::Ping(p)) => {
                // tungstenite doesn't auto-pong in server mode; do it ourselves
                let _ = tx.send(Message::Pong(p)).await;
            }
            Ok(Message::Close(_)) | Err(_) => break,
            _ => {} // Binary / Pong / Frame — ignore
        }
    }

    tracing::debug!("WS extension disconnected from {addr}");
}
