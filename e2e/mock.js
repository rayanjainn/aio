// Injected before the app loads: fakes the Tauri IPC bridge with sample data
// so every window (palette, widgets, dock, island) runs in a plain browser.
// window.__MOCK__ (set by a test before load) overrides handlers/fixtures.
(() => {
  const h = location.hash;
  const label = h.startsWith('#/dock') ? 'dock' : h.startsWith('#/island') ? 'island' : h.startsWith('#/widget/') ? 'widget-' + h.split('/')[2] : 'main';
  let cbId = 0; const cbs = {}; const listeners = {};
  // Tests fire backend events with window.__emit(name, payload).
  window.__emit = (event, payload) => (listeners[event] || []).forEach(id => cbs[id] && cbs[id]({ event, payload, id }));
  const now = Date.now();
  const res = (pid, title, sub, extra = {}) => ({ id: pid + ':' + title, pluginId: pid, title, subtitle: sub, score: 0.9, action: 'open', metadata: {}, ...extra });
  const widgets = window.__MOCK_WIDGETS__ || [];
  const handlers = {
    get_onboarding_complete: () => true,
    get_config: () => ({ retentionDays: 30, blockedApps: ['Zoom'], rawStorage: false, compressRaw: false, githubToken: '', enabledPlugins: {}, fileRoots: [], quotaBytes: 5e9, terminal: 'Terminal', ui: {} }),
    get_daemon_status: () => ({ recording: true, indexedItems: 48213, storageBytes: 312e6, pluginCounts: { files: 40000, browser: 6000, git: 2213 }, activePlugins: ['apps', 'files', 'browser', 'git'], lastSync: new Date().toISOString() }),
    check_ollama_health: () => ({ available: true, missingModels: [] }),
    get_suggestions: () => ({ results: [res('apps', 'Safari', '/Applications/Safari.app', { path: '/Applications/Safari.app' }), res('apps', 'Visual Studio Code', '/Applications/Visual Studio Code.app', { path: '/x' }), res('files', 'roadmap-q4.md', '~/Documents/roadmap-q4.md', { path: '/Users/r/Documents/roadmap-q4.md', timestamp: new Date(now - 3.6e6).toISOString() })], sessions: [], totalMs: 4, sourceCounts: {}, mode: 'retrieval' }),
    get_running_apps: () => [{ name: 'Safari', path: '/Applications/Safari.app' }, { name: 'Slack', path: '/Applications/Slack.app' }, { name: 'Terminal', path: '/System/Applications/Utilities/Terminal.app' }],
    search: (a) => ({ results: [res('browser', 'Tauri 2 window effects — docs', 'https://v2.tauri.app', { url: 'https://v2.tauri.app', timestamp: new Date(now - 7.2e6).toISOString() }), res('git', 'feat: liquid glass dock', 'aio · 3f2a91c', { timestamp: new Date(now - 8.6e7).toISOString() }), res('clipboard', 'npm run tauri dev', 'from Terminal')], sessions: [], totalMs: 12, sourceCounts: {}, mode: 'retrieval' }),
    spotlight_search: () => [{ name: 'widgets.rs', path: '/Users/r/code/aio/src-tauri/src/desktop/widgets.rs' }],
    get_app_icon: () => null,
    set_autohide: () => null,
    detect_terminals: () => ['Terminal', 'iTerm'],
    check_google_auth: () => ({ connected: false, email: null, expired: false }),
    check_github_token: () => ({ connected: true, username: 'rayanjainn', error: null }),
    set_ui_value: () => null, set_config: () => null,
    'plugin:event|listen': (a) => { (listeners[a.event] = listeners[a.event] || []).push(a.handler); return a.handler; },
    'plugin:event|unlisten': () => null,
    'plugin:event|emit': () => null,
    dock_resize: () => null, dock_set_config: (a) => a.cfg, macos_dock_set: () => handlers.macos_dock_get(),
    surface_ready: () => null,
    sys_volume: () => [40, false],
    set_glass_material: () => null,
    open_privacy_pane: () => null,
    automation_status: () => 'ok',
    media_seek: () => null,
    glass_info: () => ({ native: window.__MOCK_NATIVE__ !== false, liquid: true, material: 'liquid' }),
    app_status: () => ({ running: true, cpu: 4 + Math.random() * 6, memBytes: 812e6, processes: 9 }),
    get_open_tabs: () => [{ browser: 'Brave Browser', title: 'Liquid Glass — Apple Developer', url: 'https://developer.apple.com/design/' }, { browser: 'Brave Browser', title: 'rayanjainn/aio: Cortex', url: 'https://github.com/rayanjainn/aio' }, { browser: 'Safari', title: 'Tauri 2 — Window customization', url: 'https://v2.tauri.app/learn/window-customization/' }, { browser: 'Safari', title: 'Open-Meteo API', url: 'https://open-meteo.com/' }],
    recent_files: () => [{ name: 'Q4 roadmap.pdf', path: '/Users/r/Downloads/Q4 roadmap.pdf', modified: Date.now()/1000 - 600, size: 2.4e6, isDir: false }, { name: 'IMG_2041.HEIC', path: '/x', modified: Date.now()/1000 - 3600, size: 3.1e6, isDir: false }, { name: 'cortex-design', path: '/y', modified: Date.now()/1000 - 86400, size: 0, isDir: true }, { name: 'invoice-oct.xlsx', path: '/z', modified: Date.now()/1000 - 172800, size: 48e3, isDir: false }],
    editor_recent: () => [{ name: 'aio', path: '/Users/r/code/aio', editor: 'Cursor' }, { name: 'portfolio', path: '/Users/r/code/portfolio', editor: 'Visual Studio Code' }, { name: 'ml-notebooks', path: '/Users/r/code/ml', editor: 'Visual Studio Code' }, { name: 'dotfiles', path: '/Users/r/dotfiles', editor: 'Cursor' }],
    system_dock_set_hidden: () => null,
    widgets_list: () => widgets, widgets_visible: () => true, widgets_edit_mode: () => null,
    widget_add: (a) => { const w = { id: 'w' + widgets.length, kind: a.kind, x: 0, y: 0, w: a.w, h: a.h, layer: 'desktop', locked: false, config: a.config || {} }; widgets.push(w); return w; },
    widget_update: () => null, github_activity: () => ({ repos: 24, commits7d: 31, days: Array.from({ length: 140 }, (_, i) => (i * 7919) % 6) }), photo_pick: () => null,
    widget_catalog: () => window.__MOCK_CATALOG__ || [],
    widget_get: (a) => widgets.find(w => w.id === a.id) || widgets[0],
    sys_stats: () => ({ cpu: 23 + Math.random() * 20, cores: [12, 40, 22, 65, 8, 30, 18, 50], memUsed: 11.2e9, memTotal: 16e9, diskUsed: 342e9, diskTotal: 494e9, netRx: 1.2e6, netTx: 2.1e5, battery: { percent: 82, charging: false, minutesLeft: 312 }, uptime: 386000, load: [2.1, 1.8, 1.6] }),
    now_playing: () => ({ app: 'Spotify', state: 'playing', title: 'Midnight City', artist: 'M83', album: "Hurry Up, We're Dreaming", position: 92, duration: 244, artwork: null, trackId: 'com.spotify.client:1', permission: 'ok', deniedApp: '' }),
    weather_get: () => ({ location: 'Mumbai', tempC: 29.4, feelsC: 33, code: 2, isDay: true, humidity: 71, windKph: 14, high: 31, low: 26, hourly: Array.from({ length: 12 }, (_, i) => ({ t: now / 1000 + i * 3600, tempC: 27 + Math.sin(i / 2) * 3, code: i % 4 ? 2 : 61 })), daily: Array.from({ length: 5 }, (_, i) => ({ t: now / 1000 + i * 86400, high: 31 - i, low: 25, code: [0, 2, 3, 61, 95][i] })) }),
    calendar_upcoming: () => [{ title: 'Design review', start: now / 1000 + 1800, end: now / 1000 + 5400, location: 'Zoom', calendar: 'Work' }, { title: 'Ship v0.2', start: now / 1000 + 90000, end: now / 1000 + 93600, location: null, calendar: 'Personal' }],
    git_repo_status: () => [{ name: 'aio', path: '~/code/aio', branch: 'feature/dock', ahead: 2, behind: 0, changed: 5, lastCommit: 'Add liquid dock', lastCommitTs: now / 1000 - 900 }],
    docker_containers: () => [{ name: 'postgres', image: 'postgres:16', state: 'running', status: 'Up 3 hours' }, { name: 'redis', image: 'redis:7', state: 'exited', status: 'Exited (0)' }],
    get_clipboard_history: () => [{ id: '1', preview: 'npm run tauri dev', content: 'npm run tauri dev', sourceApp: 'Terminal', ts: now / 1000 - 60 }, { id: '2', preview: 'https://open-meteo.com', content: 'https://open-meteo.com', sourceApp: 'Safari', ts: now / 1000 - 600 }],
    get_github_stats: () => ({ login: 'rayanjainn', repos: 24, followers: 120, contributions: 812, streak: 14, weeks: Array.from({ length: 20 }, () => Array.from({ length: 7 }, () => Math.floor(Math.random() * 5))) }),
    dock_get_config: () => window.__MOCK_DOCK__,
    macos_dock_get: () => ({ supported: true, autohide: false, tilesize: 48, magnification: true, largesize: 80, orientation: 'bottom', mineffect: 'genie', showRecents: true, autohideDelay: 0.5, autohideTimeModifier: 0.5, staticOnly: false, launchanim: true, minimizeToApplication: false, showProcessIndicators: true, scrollToOpen: false, apps: [{ label: 'Safari', path: '/Applications/Safari.app', kind: 'app' }, { label: '', path: '', kind: 'spacer' }, { label: 'Notes', path: '/System/Applications/Notes.app', kind: 'app' }], hasBackup: false }),
    list_installed_apps: () => [{ name: 'Safari', path: '/Applications/Safari.app' }, { name: 'Notes', path: '/System/Applications/Notes.app' }, { name: 'Slack', path: '/Applications/Slack.app' }],
    notes_get: () => ({ text: 'Ship dock widgets\n- magnification\n- autohide' }),
    todos_get: () => [{ id: 'a', text: 'Review PR', done: false }, { id: 'b', text: 'Write release notes', done: true }],
    coding_usage: () => ({ claude: { installed: true, todayTokens: 1843200, todayMessages: 212, week: [0.4e6, 1.1e6, 0.9e6, 0, 2.2e6, 1.4e6, 1.84e6], blockTokens: 612000, blockEndsAt: Date.now() / 1000 + 2 * 3600, lastActive: Date.now() / 1000 - 20, active: true, model: 'Sonnet 4.5', project: 'aio' }, codex: { installed: true, todayTokens: 420000, todayMessages: 31, week: [0, 0, 0, 0, 0, 0, 420000], blockTokens: 0, blockEndsAt: null, lastActive: Date.now() / 1000 - 4000, active: false, model: 'gpt-5-codex', project: '' } }),
    island_get_config: () => ({ enabled: true, style: 'notch', music: true, coding: true, calendar: true, battery: true, timer: true, toasts: true, hoverExpand: true }),
    island_geometry: () => ({ hasNotch: true, notchWidth: 186, menuBarHeight: 32, windowWidth: 760 }),
    island_pill: () => null, island_set_config: (a) => a.cfg, island_toast: () => null,
    shortcuts_get: () => (window.__SHORTCUTS__ || (window.__SHORTCUTS__ = [
      { id: 'palette', label: 'Open Cortex', group: 'General', accel: 'CommandOrControl+K', default: 'CommandOrControl+K', error: null },
      { id: 'pause', label: 'Pause / resume screen memory', group: 'General', accel: 'CommandOrControl+Shift+P', default: 'CommandOrControl+Shift+P', error: null },
      { id: 'island', label: 'Expand the Island', group: 'General', accel: 'Control+Alt+Space', default: 'Control+Alt+Space', error: null },
      { id: 'window.left', label: 'Left Half', group: 'Windows', accel: 'Control+Alt+ArrowLeft', default: 'Control+Alt+ArrowLeft', error: null },
      { id: 'window.right', label: 'Right Half', group: 'Windows', accel: 'Control+Alt+ArrowRight', default: 'Control+Alt+ArrowRight', error: null },
      { id: 'window.max', label: 'Maximize', group: 'Windows', accel: 'Control+Alt+Enter', default: 'Control+Alt+Enter', error: 'In use by another app' }])),
    shortcut_set: (a) => { const s = handlers.shortcuts_get(); const other = s.find(x => x.id !== a.id && a.accel && x.accel === a.accel); if (other) throw 'Already used for “' + other.label + '”'; const e = s.find(x => x.id === a.id); e.accel = a.accel; e.error = null; window.__LAST_SHORTCUT__ = a; return s; },
    shortcuts_suspend: () => null, shortcut_reset_all: () => handlers.shortcuts_get(),
    window_snap: (a) => { window.__LAST_SNAP__ = a.action; return 'Left Half'; },
    accessibility_status: () => true,
    update_check: () => ({ current: '0.2.0', available: null, ready: null, notes: null, error: null }), update_restart: () => null,
  };
  Object.assign(handlers, (window.__MOCK__ || {}).handlers || {});
  window.__CALLS__ = [];
  window.__TAURI_INTERNALS__ = {
    metadata: { currentWindow: { label }, currentWebview: { windowLabel: label, label } },
    transformCallback: (cb) => { const id = ++cbId; cbs[id] = cb; return id; },
    unregisterCallback: () => {},
    convertFileSrc: (p) => p,
    invoke: async (cmd, args) => {
      window.__CALLS__.push([cmd, args]);
      const h = handlers[cmd];
      if (!h) { if (cmd.startsWith('plugin:window|') || cmd.startsWith('plugin:')) return null; console.warn('[mock] unhandled', cmd); return null; }
      return h(args || {});
    },
  };
  window.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener: () => {} };
})();
