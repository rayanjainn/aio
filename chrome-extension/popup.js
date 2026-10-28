// Popup script — probes the WebSocket server and shows connection status.

const WS_URL = "ws://localhost:27182";

const dot      = document.getElementById("dot");
const status   = document.getElementById("status");
const wsState  = document.getElementById("ws-state");
const tabCount = document.getElementById("tab-count");

// Probe the WS server with a short-lived connection
const probe = new WebSocket(WS_URL);
probe.addEventListener("open", () => {
  dot.classList.remove("disconnected");
  status.textContent   = "connected";
  status.className     = "";
  wsState.textContent  = "open";
  probe.close();
});
probe.addEventListener("error", () => {
  dot.classList.add("disconnected");
  status.textContent  = "offline";
  status.className    = "off";
  wsState.textContent = "closed";
});

// Count open non-internal tabs
chrome.tabs.query({}, (tabs) => {
  const real = tabs.filter(t => t.url && !t.url.startsWith("chrome://") && !t.url.startsWith("about:"));
  tabCount.textContent = real.length;
});
