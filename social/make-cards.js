// Generates every still the social plan needs from the website demo's screenshots (run capture-states.js first):
//   social/covers/*.png          Reel covers (1080x1920, text inside the centre 3:4 so the profile grid crops cleanly)
//   social/posts/<set>/NN.png    Instagram carousels (1080x1350)
//   record/edit/assets/*.png     hook cards, caption pills, end card, bezel and background for the Reel editor
//   record/edit/reels.conf       what the editor needs to know about each Reel
//   node social/make-cards.js
const { chromium } = require('playwright');
const fs = require('fs'), path = require('path');
const ROOT = path.resolve(__dirname, '..');
const SHOTS = path.join(ROOT, 'social/shots'), ASSETS = path.join(ROOT, 'record/edit/assets');
const COVERS = path.join(ROOT, 'social/covers'), POSTS = path.join(ROOT, 'social/posts');
for (const d of [ASSETS, COVERS, POSTS]) fs.mkdirSync(d, { recursive: true });
const icon = 'data:image/png;base64,' + fs.readFileSync(path.join(ROOT, 'marketing/aio-icon-256.png')).toString('base64');
const shotURL = n => 'data:image/png;base64,' + fs.readFileSync(path.join(SHOTS, n + '.png')).toString('base64');
const URL_TEXT = 'aio.raycode.tech';

const CSS = `
*{margin:0;padding:0;box-sizing:border-box}
html,body{font-family:Inter,"SF Pro Display",-apple-system,sans-serif;color:#1d1d1f;-webkit-font-smoothing:antialiased}
.bg{position:absolute;inset:0;background:radial-gradient(1400px 1000px at 50% 0%,#fff 0%,#f5f5f7 55%,#e6e8ee 100%)}
.h{font-weight:800;letter-spacing:-.045em;line-height:1.02}
.sub{font-weight:600;letter-spacing:-.01em;color:#6e6e73}
.pill{display:inline-flex;align-items:center;gap:16px;background:#1d1d1f;color:#fff;border-radius:999px;font-weight:700;letter-spacing:-.01em}
.card{position:relative;overflow:hidden;border-radius:30px;background:#fff;box-shadow:0 0 0 2px rgba(0,0,0,.08),0 50px 90px -40px rgba(0,0,0,.45)}
.card img{position:absolute;max-width:none}
.chip{font-family:ui-monospace,"SF Mono",Menlo,monospace;font-weight:600;background:#fff;border-radius:22px;box-shadow:0 0 0 2px rgba(0,0,0,.08),0 18px 40px -20px rgba(0,0,0,.35);padding:22px 36px;white-space:nowrap}
.brand{display:flex;align-items:center;gap:18px;font-weight:800;letter-spacing:-.03em}
.brand img{border-radius:22%;box-shadow:0 10px 24px -8px rgba(0,0,0,.35)}
.kbd{display:inline-block;background:#fff;border-radius:16px;box-shadow:0 0 0 2px rgba(0,0,0,.1),0 5px 0 rgba(0,0,0,.12);padding:6px 26px;font-weight:700}
`;
// a 16:10 crop of a 2880x1800 screenshot, centred on (fx, fy), zoomed by z
const crop = (name, w, fx, fy, z) => {
  const h = w * 0.625, iw = w * z, ih = iw * 0.625;
  const left = Math.min(0, Math.max(w - iw, w / 2 - fx * iw)), top = Math.min(0, Math.max(h - ih, h / 2 - fy * ih));
  return `<div class="card" style="width:${w}px;height:${h}px"><img src="${shotURL(name)}" style="width:${iw}px;left:${left}px;top:${top}px"></div>`;
};
const page = (w, h, body, bg = true) => `<html><head><style>${CSS}body{width:${w}px;height:${h}px;position:relative;overflow:hidden}</style></head><body>${bg ? '<div class="bg"></div>' : ''}${body}</body></html>`;

(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1080, height: 1920 }, deviceScaleFactor: 1 });
  const render = async (html, file, w, h, transparent = false) => {
    await p.setViewportSize({ width: w, height: h }); await p.setContent(html); await p.waitForTimeout(150);
    await p.screenshot({ path: file, omitBackground: transparent, clip: { x: 0, y: 0, width: w, height: h } });
  };

  // ---------------- Reels: story, captions, covers ----------------
  // scene = the recording that feeds it (record/scenes/<scene>.sh); crop = zoom on the screen recording: zoom, focus x, focus y
  const REELS = [
    { id: 'cmdk', scene: '01-cmdk', hook: 'One bar<br>for your<br>whole Mac.', cover: ['⌘K does it all.', 'Maths · units · currency · events · emoji'], shot: 'cmdk-event', c: [.5, .17, 2.0], crop: [1.7, .5, .3],
      caps: [['cap_press', 'Press ⌘K'], ['cap_maths', 'Maths. Instantly.'], ['cap_units', 'Any unit.'], ['cap_currency', 'Live currency.'], ['cap_event', 'Schedule it by typing it.'], ['cap_emoji', 'Emoji in one word.'], ['cap_apps', 'And every app on your Mac.']] },
    { id: 'snap', scene: '02-snap', hook: 'Snap windows<br>with your<br>keyboard.', cover: ['Snap windows.', 'Halves, quarters, thirds, maximize'], shot: 'snap-left', c: [.5, .5, 1], crop: [1, .5, .5],
      caps: [['cap_left', 'Left half'], ['cap_right', 'Right half'], ['cap_quarters', 'Quarters'], ['cap_max', 'Maximize'], ['cap_restore', 'Restore']] },
    { id: 'switch', scene: '03-switch', hook: 'Switch windows,<br>not just apps.', cover: ['⌥⇥ switches windows.', 'Every window, every Space'], shot: 'switcher', c: [.5, .5, 1.5], crop: [1.4, .5, .5],
      caps: [['cap_hold', 'Hold ⌥, press ⇥'], ['cap_every', 'Every window. Every Space.']] },
    { id: 'act', scene: '04-act', hook: 'Select text.<br>Act on it.', cover: ['Act on any text.', 'Translate · Summarise · Fix · Reply'], shot: 'act-translate', c: [.28, .55, 1.9], crop: [1.7, .3, .5],
      caps: [['cap_select', 'Select any text'], ['cap_act', 'Press ⌃⌥A'], ['cap_choose', 'Translate · Summarise · Fix · Reply']] },
    { id: 'notch', scene: '05-notch', hook: 'Your notch<br>finally does<br>something.', cover: ['Hover the notch.', 'Clipboard · Shelf · Tools · Volume'], shot: 'island-clip', c: [.5, .13, 2.1], crop: [2.0, .5, .13],
      caps: [['cap_hover', 'Hover the notch'], ['cap_clip', 'Clipboard history'], ['cap_shelf', 'File shelf + AirDrop'], ['cap_tools', 'Timer, mirror, tools'], ['cap_volume', 'A better volume HUD']] },
    { id: 'dock', scene: '06-dock', hook: 'A Dock with<br>live widgets.', cover: ['Truly your Dock.', 'Live widgets · presets · magnification'], shot: 'dock-ocean', c: [.5, .93, 1.8], crop: [1.8, .5, .92],
      caps: [['cap_magnify', 'Magnification'], ['cap_widgets', 'Music, clock, weather, battery'], ['cap_presets', 'Presets in one click']] },
    { id: 'launcher', scene: '07-launcher', hook: 'Launchpad,<br>but yours.', cover: ['Move your widgets.', 'Left, right, anywhere'], shot: 'launcher-moved', c: [.5, .5, 1], crop: [1, .5, .5],
      caps: [['cap_open', 'Every app, one keystroke'], ['cap_search', 'Instant search'], ['cap_drag', 'Drag widgets to either side']] },
    { id: 'music', scene: '08-music', hook: 'Your song.<br>Full screen.', cover: ['Full-screen music.', 'Five styles · synced lyrics'], shot: 'music', c: [.5, .5, 1], crop: [1, .5, .5],
      caps: [['cap_play', 'Press ⌃⌥P'], ['cap_styles', 'Five styles'], ['cap_keys', 'All keyboard']] },
  ];
  const slug = t => 'cap-' + t.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  const made = new Set();

  // background and device frame for the Reel editor
  await render(page(1080, 1920, ''), path.join(ASSETS, 'bg.png'), 1080, 1920);
  const PX = 40, PY = 600, PW = 1000, PH = 625;      // where the screen recording sits
  await render(page(1080, 1920, `
    <div style="position:absolute;left:${PX - 16}px;top:${PY - 16}px;width:${PW + 32}px;height:${PH + 32}px;border:16px solid #1d1d1f;border-radius:44px;box-shadow:0 60px 90px -50px rgba(0,0,0,.5)"></div>
    <div style="position:absolute;left:${PX - 70}px;top:${PY + PH + 14}px;width:${PW + 140}px;height:22px;border-radius:0 0 26px 26px;background:linear-gradient(#e3e3e6,#b4b4ba)"></div>
    <div class="brand" style="position:absolute;left:0;right:0;top:130px;justify-content:center;font-size:54px"><img src="${icon}" width="92" height="92">AIO</div>`, false), path.join(ASSETS, 'bezel.png'), 1080, 1920, true);

  let conf = '# Written by social/make-cards.js. One block per Reel; read by record/edit/make-reels.sh\nREELS="' + REELS.map(r => r.id).join(' ') + '"\n';
  for (const r of REELS) {
    // hook card (the first 2.5 s of every Reel): a statement, not a feature
    await render(page(1080, 1920, `
      <div class="brand" style="position:absolute;left:0;right:0;top:150px;justify-content:center;font-size:54px"><img src="${icon}" width="92" height="92">AIO</div>
      <div class="h" style="position:absolute;left:60px;right:60px;top:560px;text-align:center;font-size:150px">${r.hook}</div>`), path.join(ASSETS, `hook-${r.id}.png`), 1080, 1920);
    // captions: one pill each, transparent, placed under the screen
    for (const [, text] of r.caps) {
      const f = slug(text); if (made.has(f)) continue; made.add(f);
      await render(page(1080, 200, `<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center"><div class="pill" style="font-size:58px;padding:26px 56px;background:#fff;color:#1d1d1f;box-shadow:0 0 0 2px rgba(0,0,0,.07),0 24px 50px -20px rgba(0,0,0,.4)">${text}</div></div>`, false), path.join(ASSETS, f + '.png'), 1080, 200, true);
    }
    // cover (IG shows the middle 3:4 of a 9:16 cover on the profile grid)
    await render(page(1080, 1920, `
      <div class="brand" style="position:absolute;left:0;right:0;top:300px;justify-content:center;font-size:46px"><img src="${icon}" width="76" height="76">AIO</div>
      <div style="position:absolute;left:50px;right:50px;top:400px;height:430px;display:flex;flex-direction:column;justify-content:center;gap:28px;text-align:center">
        <div class="h" style="font-size:118px">${r.cover[0]}</div><div class="sub" style="font-size:44px">${r.cover[1]}</div></div>
      <div style="position:absolute;left:50px;top:880px">${crop(r.shot, 980, ...r.c)}</div>
      <div style="position:absolute;left:0;right:0;top:1560px;text-align:center"><span class="pill" style="font-size:44px;padding:20px 48px">${URL_TEXT}</span></div>`), path.join(COVERS, `${r.id}.png`), 1080, 1920);
    conf += `\nreel_${r.id}_scene="${r.scene}"\nreel_${r.id}_hook="hook-${r.id}.png"\nreel_${r.id}_crop="${r.crop.join(' ')}"\nreel_${r.id}_caps="${r.caps.map(([mark, text]) => `${mark}:${slug(text)}.png`).join(' ')}"\n`;
  }
  fs.writeFileSync(path.join(ROOT, 'record/edit/reels.conf'), conf);

  // end cards: the URL is the point
  await render(page(1080, 1920, `
    <img src="${icon}" width="220" height="220" style="position:absolute;left:430px;top:330px;border-radius:22%;box-shadow:0 30px 60px -20px rgba(0,0,0,.4)">
    <div class="h" style="position:absolute;left:0;right:0;top:600px;text-align:center;font-size:230px">AIO</div>
    <div class="sub" style="position:absolute;left:60px;right:60px;top:880px;text-align:center;font-size:52px;line-height:1.25">One bar for your whole Mac.<br>⌘K · Launcher · Dock · Notch · Music</div>
    <div style="position:absolute;left:0;right:0;top:1130px;text-align:center"><span class="pill" style="font-size:78px;padding:34px 76px">${URL_TEXT}</span></div>
    <div class="sub" style="position:absolute;left:0;right:0;top:1330px;text-align:center;font-size:44px">Free for macOS · Link in bio</div>
    <div class="sub" style="position:absolute;left:0;right:0;top:1440px;text-align:center;font-size:40px;color:#86868b">Follow for more Mac tricks</div>`), path.join(ASSETS, 'end.png'), 1080, 1920);
  await render(page(1920, 1080, `
    <img src="${icon}" width="170" height="170" style="position:absolute;left:875px;top:120px;border-radius:22%;box-shadow:0 30px 60px -20px rgba(0,0,0,.4)">
    <div class="h" style="position:absolute;left:0;right:0;top:300px;text-align:center;font-size:190px">AIO</div>
    <div class="sub" style="position:absolute;left:0;right:0;top:520px;text-align:center;font-size:46px">One bar for your whole Mac: ⌘K · Launcher · Dock · Notch · Music</div>
    <div style="position:absolute;left:0;right:0;top:640px;text-align:center"><span class="pill" style="font-size:72px;padding:30px 70px">${URL_TEXT}</span></div>
    <div class="sub" style="position:absolute;left:0;right:0;top:830px;text-align:center;font-size:40px">Free for macOS · Link in the description</div>`), path.join(ASSETS, 'end-wide.png'), 1920, 1080);
  await render(page(1920, 1080, `
    <img src="${icon}" width="150" height="150" style="position:absolute;left:885px;top:180px;border-radius:22%;box-shadow:0 30px 60px -20px rgba(0,0,0,.4)">
    <div class="h" style="position:absolute;left:0;right:0;top:380px;text-align:center;font-size:150px">One bar for<br>your whole Mac.</div>`), path.join(ASSETS, 'hook-wide.png'), 1920, 1080);

  // ---------------- Instagram carousels (1080x1350) ----------------
  const dots = (i, n) => `<div style="position:absolute;left:0;right:0;bottom:46px;display:flex;justify-content:center;gap:14px">${Array.from({ length: n }, (_, k) => `<i style="display:block;width:${k === i ? 38 : 14}px;height:14px;border-radius:7px;background:${k === i ? '#1d1d1f' : '#c7c7cc'}"></i>`).join('')}</div>`;
  const foot = (i, n) => `${dots(i, n)}<div class="sub" style="position:absolute;right:56px;bottom:36px;font-size:30px;color:#86868b">${URL_TEXT}</div>`;
  const slide = (n, i, title, sub, visual, extra = '') => page(1080, 1350, `
    <div class="brand" style="position:absolute;left:60px;top:54px;font-size:38px"><img src="${icon}" width="58" height="58">AIO</div>
    <div style="position:absolute;left:60px;right:60px;top:130px;height:480px;display:flex;flex-direction:column;justify-content:center;gap:30px">
      <div class="h" style="font-size:108px">${title}</div><div class="sub" style="font-size:44px;line-height:1.28">${sub}</div></div>
    <div style="position:absolute;left:60px;top:640px">${visual}</div>${foot(i, n)}`);
  const sets = {
    'aio-in-8-slides': [
      (n, i) => page(1080, 1350, `<div class="brand" style="position:absolute;left:0;right:0;top:120px;justify-content:center;font-size:56px"><img src="${icon}" width="96" height="96">AIO</div>
        <div class="h" style="position:absolute;left:60px;right:60px;top:330px;text-align:center;font-size:150px">Your Mac,<br>from one bar.</div>
        <div style="position:absolute;left:0;right:0;top:780px;text-align:center;font-size:56px" class="sub">Press <span class="kbd" style="font-size:72px;margin:0 12px">⌘ K</span></div>
        <div class="sub" style="position:absolute;left:0;right:0;top:1000px;text-align:center;font-size:40px">Swipe →  8 things AIO does</div>${foot(i, n)}`),
      (n, i) => slide(n, i, '⌘K does it all.', 'Maths, units, live currency, quick-add events, emoji, files and every app.', crop('cmdk-calc', 960, .5, .17, 2)),
      (n, i) => slide(n, i, 'Snap & switch.', 'Windows into halves, quarters and thirds. ⌥⇥ jumps to any window.', crop('snap-left', 960, .5, .5, 1)),
      (n, i) => slide(n, i, 'Act on any text.', 'Select it, press ⌃⌥A: translate, summarise, fix, reply.', crop('act-translate', 960, .28, .55, 1.9)),
      (n, i) => slide(n, i, 'Your Launcher.', 'Every app, instant search, and widgets you can put on either side.', crop('launcher-moved', 960, .5, .5, 1)),
      (n, i) => slide(n, i, 'A Dock with widgets.', 'Music, clock, weather, battery. Presets in one click.', crop('dock-ocean', 960, .5, .93, 1.8)),
      (n, i) => slide(n, i, 'Hover the notch.', 'Clipboard history, file shelf, timer, mirror and a better volume HUD.', crop('island-clip', 960, .5, .13, 2.1)),
      (n, i) => page(1080, 1350, `<img src="${icon}" width="200" height="200" style="position:absolute;left:440px;top:150px;border-radius:22%;box-shadow:0 30px 60px -20px rgba(0,0,0,.4)">
        <div class="h" style="position:absolute;left:60px;right:60px;top:410px;text-align:center;font-size:150px">Free for Mac.</div>
        <div style="position:absolute;left:0;right:0;top:700px;text-align:center"><span class="pill" style="font-size:70px;padding:30px 66px">${URL_TEXT}</span></div>
        <div class="sub" style="position:absolute;left:60px;right:60px;top:900px;text-align:center;font-size:42px;line-height:1.3">Link in bio · Try the demo in your browser<br>Save this post · Share it with a Mac friend</div>${foot(i, n)}`),
    ],
    'cmdk-7-things': [
      (n, i) => page(1080, 1350, `<div class="brand" style="position:absolute;left:0;right:0;top:120px;justify-content:center;font-size:56px"><img src="${icon}" width="96" height="96">AIO</div>
        <div class="h" style="position:absolute;left:60px;right:60px;top:330px;text-align:center;font-size:140px">7 things you can type into <span style="color:#0071e3">⌘K</span></div>
        <div class="sub" style="position:absolute;left:0;right:0;top:1020px;text-align:center;font-size:40px">Swipe →</div>${foot(i, n)}`),
      ...[['1', '12*(3+4)', 'Maths, instantly.', 'cmdk-calc'], ['2', '10 km to mi', 'Any unit.', 'cmdk-convert'], ['3', '100 usd to eur', 'Live currency.', 'cmdk-currency'],
          ['4', 'event lunch tomorrow 1pm', 'Adds it to Calendar.', 'cmdk-event'], ['5', 'remind call mom at 6pm', 'Adds a Reminder.', 'cmdk-remind'],
          ['6', 'heart', 'Emoji, one word.', 'cmdk-emoji'], ['7', 'mus', 'Every app on your Mac.', 'cmdk-apps']].map(([k, q, t, s]) => (n, i) => page(1080, 1350, `
        <div class="brand" style="position:absolute;left:60px;top:54px;font-size:38px"><img src="${icon}" width="58" height="58">AIO</div>
        <div style="position:absolute;left:60px;right:60px;top:130px;height:480px;display:flex;flex-direction:column;justify-content:center;gap:26px;align-items:flex-start">
          <div class="sub" style="font-size:46px;color:#0071e3">#${k}</div><div class="h" style="font-size:108px">${t}</div><span class="chip" style="font-size:46px">${q}</span></div>
        <div style="position:absolute;left:60px;top:640px">${crop(s, 960, .5, .17, 2)}</div>${foot(i, n)}`)),
      (n, i) => page(1080, 1350, `<img src="${icon}" width="200" height="200" style="position:absolute;left:440px;top:170px;border-radius:22%;box-shadow:0 30px 60px -20px rgba(0,0,0,.4)">
        <div class="h" style="position:absolute;left:60px;right:60px;top:430px;text-align:center;font-size:130px">Press ⌘K.<br>Try it free.</div>
        <div style="position:absolute;left:0;right:0;top:810px;text-align:center"><span class="pill" style="font-size:66px;padding:28px 62px">${URL_TEXT}</span></div>
        <div class="sub" style="position:absolute;left:60px;right:60px;top:1000px;text-align:center;font-size:40px">Link in bio · Save this for later</div>${foot(i, n)}`),
    ],
    'install-in-60s': (() => {
      const step = (k, t, s, extra = '') => (n, i) => page(1080, 1350, `
        <div class="brand" style="position:absolute;left:60px;top:54px;font-size:38px"><img src="${icon}" width="58" height="58">AIO</div>
        <div class="h" style="position:absolute;left:60px;top:200px;font-size:300px;color:#d2d2d7">${k}</div>
        <div class="h" style="position:absolute;left:60px;right:60px;top:560px;font-size:100px">${t}</div>
        <div class="sub" style="position:absolute;left:60px;right:60px;top:820px;font-size:46px;line-height:1.3">${s}</div>${extra}${foot(i, n)}`);
      return [
        (n, i) => page(1080, 1350, `<div class="brand" style="position:absolute;left:0;right:0;top:120px;justify-content:center;font-size:56px"><img src="${icon}" width="96" height="96">AIO</div>
          <div class="h" style="position:absolute;left:60px;right:60px;top:340px;text-align:center;font-size:140px">Install AIO<br>in 60 seconds</div>
          <div class="sub" style="position:absolute;left:60px;right:60px;top:800px;text-align:center;font-size:44px;line-height:1.3">Plus the one-time macOS warning, explained.<br>Swipe →</div>${foot(i, n)}`),
        step('1', 'Download.', `Get <b>AIO.dmg</b> from <b>${URL_TEXT}</b> (macOS 14 or later).`),
        step('2', 'Drag to Applications.', 'Open the disk image and drag AIO onto the Applications folder.'),
        step('3', 'Open it.', 'macOS may say “Apple could not verify AIO is free of malware”. That is expected: the app isn’t notarized yet.'),
        step('4', 'Allow it once.', 'In Terminal run:', `<div style="position:absolute;left:60px;top:960px"><span class="chip" style="font-size:40px">xattr -cr /Applications/AIO.app</span></div><div class="sub" style="position:absolute;left:60px;right:60px;top:1110px;font-size:40px;line-height:1.3">or System Settings → Privacy &amp; Security → <b>Open Anyway</b>.</div>`),
        step('5', 'Grant permissions.', 'Settings → Privacy &amp; Permissions → <b>Grant everything</b>. Accessibility and Screen Recording you switch on yourself.'),
        step('6', 'Press ⌘K.', 'That’s it. Updates install themselves and keep their permissions.'),
        (n, i) => page(1080, 1350, `<img src="${icon}" width="200" height="200" style="position:absolute;left:440px;top:170px;border-radius:22%;box-shadow:0 30px 60px -20px rgba(0,0,0,.4)">
          <div class="h" style="position:absolute;left:60px;right:60px;top:430px;text-align:center;font-size:140px">Free for Mac.</div>
          <div style="position:absolute;left:0;right:0;top:700px;text-align:center"><span class="pill" style="font-size:66px;padding:28px 62px">${URL_TEXT}</span></div>
          <div class="sub" style="position:absolute;left:60px;right:60px;top:900px;text-align:center;font-size:40px">Link in bio · Save this post</div>${foot(i, n)}`),
      ];
    })(),
  };
  for (const [name, list] of Object.entries(sets)) {
    fs.mkdirSync(path.join(POSTS, name), { recursive: true });
    for (let i = 0; i < list.length; i++) await render(list[i](list.length, i), path.join(POSTS, name, String(i + 1).padStart(2, '0') + '.png'), 1080, 1350);
    console.log(name, list.length, 'slides');
  }
  console.log('reels', REELS.length, 'captions', made.size);
  await b.close();
})();
