/**
 * Cortex Memory Bridge — Manifest V3 background service worker
 *
 * Maintains a persistent WebSocket connection to the local Cortex daemon
 * (ws://localhost:27182).  Sends tab lifecycle events so the daemon can
 * maintain a live-tabs table that surfaces currently-open pages in search.
 *
 * Reconnection: exponential back-off starting at 1 s, capped at 30 s.
 * Service workers can be suspended; `chrome.alarms` keeps the worker alive
 * and reconnects on resume.
 */

const WS_URL        = "ws://localhost:27182";
const ALARM_NAME    = "cortex-keepalive";
const ALARM_PERIOD  = 0.4;     // minutes — fires every ~24 s to prevent suspension
const MAX_BACKOFF   = 30_000;  // ms

let ws        = null;
let backoff   = 1_000;
let reconnect = null;

/* ─── WebSocket lifecycle ─────────────────────────────── */

function connect() {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
    return;
  }

  clearTimeout(reconnect);
  ws = new WebSocket(WS_URL);

  ws.addEventListener("open", () => {
    console.log("[Cortex] WS connected");
    backoff = 1_000; // reset back-off on successful connect
    // Send all currently open tabs immediately
    chrome.tabs.query({}, (tabs) => {
      for (const tab of tabs) {
        sendEvent("updated", tab);
      }
    });
  });

  ws.addEventListener("close", (ev) => {
    console.log(`[Cortex] WS closed (${ev.code}), reconnecting in ${backoff}ms`);
    scheduleReconnect();
  });

  ws.addEventListener("error", () => {
    // close event will fire after error; let that handler reconnect
    ws?.close();
  });
}

function scheduleReconnect() {
  clearTimeout(reconnect);
  reconnect = setTimeout(() => {
    connect();
    backoff = Math.min(backoff * 2, MAX_BACKOFF);
  }, backoff);
}

/* ─── Event helpers ───────────────────────────────────── */

function sendEvent(eventType, tab) {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  if (!tab?.url || tab.url.startsWith("chrome://") || tab.url.startsWith("about:")) return;

  const payload = {
    event:       eventType,
    tab_id:      tab.id,
    url:         tab.url        ?? null,
    title:       tab.title      ?? null,
    favicon_url: tab.favIconUrl ?? null,
  };

  try {
    ws.send(JSON.stringify(payload));
  } catch (e) {
    console.warn("[Cortex] send failed:", e);
  }
}

function sendRemove(tabId) {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  try {
    ws.send(JSON.stringify({ event: "removed", tab_id: tabId }));
  } catch (_) {}
}

/* ─── Chrome tab event listeners ─────────────────────── */

chrome.tabs.onCreated.addListener((tab) => {
  sendEvent("created", tab);
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  // Only fire when URL or title actually changes
  if (changeInfo.url || changeInfo.title || changeInfo.status === "complete") {
    sendEvent("updated", tab);
  }
});

chrome.tabs.onActivated.addListener(({ tabId }) => {
  chrome.tabs.get(tabId, (tab) => {
    if (!chrome.runtime.lastError) {
      sendEvent("activated", tab);
    }
  });
});

chrome.tabs.onRemoved.addListener((tabId) => {
  sendRemove(tabId);
});

chrome.tabs.onReplaced.addListener((addedTabId, removedTabId) => {
  sendRemove(removedTabId);
  chrome.tabs.get(addedTabId, (tab) => {
    if (!chrome.runtime.lastError) sendEvent("created", tab);
  });
});

/* ─── Keep-alive alarm (prevents service worker suspension) */

chrome.alarms.create(ALARM_NAME, { periodInMinutes: ALARM_PERIOD });

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name !== ALARM_NAME) return;
  // Re-connect if the WS dropped while the worker was suspended
  if (!ws || ws.readyState === WebSocket.CLOSED || ws.readyState === WebSocket.CLOSING) {
    connect();
  }
});

/* ─── Initial connection ──────────────────────────────── */

connect();
