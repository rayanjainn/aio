"""Builds the AIO launch film as a Hyperframes composition, using the live Mac demo from the website.

    node film/snapshot.js http://localhost:8765/ film/snapshot.json   # once, with marketing/ served on :8765
    python3 film/build.py landscape film/landscape
    python3 film/build.py portrait  film/portrait
    (cd film/landscape && npx hyperframes render -q delivery -o ../aio-film.mp4)

Everything on screen is a pure function of time (render(t)), so every frame is deterministic.
"""
import json, os, shutil, subprocess, sys

MODE, OUT = sys.argv[1], sys.argv[2]
V = MODE == "portrait"
W, H = (1080, 1920) if V else (1920, 1080)
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SNAP = json.load(open(os.path.join(HERE, "snapshot.json")))

# Beat grid of "Digital Clouds" (Mixkit), 129 BPM; the cut puts the drop on beat 6.
B, T0 = 0.46511, 0.2
SRC_START = 26.971
BEATS = 53
def b(n): return round(T0 + n * B, 3)
TOTAL = b(BEATS)

K0 = 0.75 if V else 1.2          # screen scale at zoom 1: fills the frame width (portrait) or height (landscape)

# ---------- Camera: [time, focus x, focus y, zoom, tilt°, y offset px, ease] ----------
if not V:
    CAM = [
        [0,      720, 450, .50, 26, 420, "out"],
        [1.3,    720, 450, .50, 26, 300, "out"],
        [b(5.5), 720, 450, .50, 26, 300, "inout"],
        [b(6.6), 720, 450, 1.0, 0, 0, "expo"],
        [b(7),   720, 450, 1.0, 0, 0, "inout"],
        [b(8.4), 720, 175, 2.1, 0, 0, "inout"],
        [b(12.8), 720, 175, 2.1, 0, 0, "inout"],
        [b(14),  720, 450, 1.0, 0, 0, "inout"],
        [b(14.4), 720, 450, 1.0, 0, 0, "inout"],
        [b(15.3), 420, 770, 1.75, 0, 0, "inout"],
        [b(18.4), 900, 770, 1.75, 0, 0, "inout"],
        [b(19.2), 940, 770, 1.75, 0, 0, "inout"],
        [b(20.5), 720, 450, 1.0, 0, 0, "inout"],
        [b(21),  720, 450, 1.0, 0, 0, "inout"],
        [b(27.5), 760, 430, 1.1, 0, 0, "inout"],
        [b(28),  760, 430, 1.1, 0, 0, "inout"],
        [b(29.2), 720, 330, 1.55, 0, 0, "inout"],
        [b(35.4), 720, 330, 1.55, 0, 0, "inout"],
        [b(36.5), 720, 450, 1.0, 0, 0, "inout"],
        [b(37.2), 560, 430, 1.15, 0, 0, "inout"],
        [b(44),  900, 410, 1.2, 0, 0, "inout"],
        [b(45.6), 720, 450, .5, 16, 250, "expo"],
        [TOTAL,  720, 450, .48, 16, 250, "out"],
    ]
else:
    CAM = [
        [0,      720, 450, .9, 24, 640, "out"],
        [1.3,    720, 450, .9, 24, 520, "out"],
        [b(5.5), 720, 450, .9, 24, 520, "inout"],
        [b(6.6), 720, 450, 1.0, 0, 0, "expo"],
        [b(7),   720, 450, 1.0, 0, 0, "inout"],
        [b(8.4), 720, 140, 2.0, 0, 0, "inout"],
        [b(12.8), 720, 140, 2.0, 0, 0, "inout"],
        [b(14),  720, 450, 1.0, 0, 0, "inout"],
        [b(14.4), 720, 450, 1.0, 0, 0, "inout"],
        [b(15.3), 380, 770, 2.4, 0, 0, "inout"],
        [b(18.4), 900, 770, 2.4, 0, 0, "inout"],
        [b(19.2), 960, 770, 2.4, 0, 0, "inout"],
        [b(20.5), 720, 450, 1.0, 0, 0, "inout"],
        [b(21),  720, 450, 1.0, 0, 0, "inout"],
        [b(23),  540, 380, 1.55, 0, 0, "inout"],
        [b(27.5), 740, 360, 1.55, 0, 0, "inout"],
        [b(28),  740, 360, 1.5, 0, 0, "inout"],
        [b(29.2), 720, 330, 1.75, 0, 0, "inout"],
        [b(35.4), 720, 330, 1.75, 0, 0, "inout"],
        [b(36.5), 720, 450, 1.0, 0, 0, "inout"],
        [b(37.2), 380, 400, 1.7, 0, 0, "inout"],
        [b(44),  1080, 360, 1.7, 0, 0, "inout"],
        [b(45.6), 720, 450, .82, 14, 470, "expo"],
        [TOTAL,  720, 450, .8, 14, 470, "out"],
    ]

# ---------- Cursor (screen coordinates): [time, x, y, ease]; the Dock items are measured at runtime ----------
CURSOR = [
    [b(6.6), 1040, 640, "inout"], [b(6.9), 1040, 640, "inout"], [b(8), 720, 14, "inout"],
    [b(12.6), 720, 14, "inout"], [b(13.4), 900, 520, "inout"],
    [b(14.2), 900, 520, "inout"], [b(15.2), "D0+10", 858, "inout"], [b(15.4), "D0+10", 858, "inout"],
    [b(18.4), "D8", 862, "inout"], [b(18.6), "D8", 862, "inout"], [b(19.2), "NP", 855, "inout"],
    [b(19.6), "NP", 855, "inout"], [b(20.6), "D0", 860, "inout"],
    [b(22), "D0", 860, "inout"], [b(22.9), 720, 74, "inout"], [b(27.4), 720, 74, "inout"], [b(28.2), 1000, 600, "inout"],
    [b(35.8), 1000, 600, "inout"], [b(36.6), "NP", 855, "inout"],
]
CURSOR_ON = [b(6.6), b(37.4)]
CLICKS = [b(20.7), b(23), b(36.7)]
BOUNCES = [["Launcher", b(20.7)], ["Music", b(36.7)]]

ISLAND = [[b(8), 0, "out"], [b(8.7), 1, "back"], [b(12.8), 1, "inout"], [b(13.3), 0, "inout"]]
DOCKMAG = [b(14.2), b(20.6)]
LAUNCH = [[b(20.9), 0, "out"], [b(21.6), 1, "out"], [b(27.2), 1, "out"], [b(27.8), 0, "out"]]
LP_TYPE = [[b(23.3), b(24.3), b(27.8), "note"]]
PAL = [[b(28.2), 0, "out"], [b(28.7), 1, "back"], [b(35.5), 1, "out"], [b(35.9), 0, "out"]]
PAL_TYPE = [[b(29.3), b(30.5), b(32.3), "12*(3+4)"], [b(32.5), b(33.9), b(35.9), "10 km to mi"]]
KEYS = [[b(27.8), b(28.9), ["⌘", "K"]], [b(35.3), b(36.1), ["esc"]]]
PLAYER = b(36.9)
LYRICS = [b(38), b(40), b(42), b(44)]

# ---------- Captions: [in, out, text, where] ----------
CAPS = [
    [b(8.7), b(12.7), "Hello, notch.", "bottom"],
    [b(15.2), b(20.2), "Truly your Dock.", "bottom" if V else "top"],
    [b(21.7), b(27.2), "All your apps. Plus your day.", "bottom" if not V else "top"],
    [b(29.2), b(35.4), "Type it. It's done.", "bottom"],
    [b(37.4), b(43.8), "Your song. The whole screen.", "top" if V else "bottom"],
]

words = ["Launcher.", "Dock.", "Notch.", "Music."]

# ---------- Assets ----------
os.makedirs(f"{OUT}/assets/sfx", exist_ok=True)
old = os.path.join(ROOT, "brag-output-2026-11-08-132658/composition/assets")
shutil.copy(f"{old}/gsap.min.js", f"{OUT}/assets/gsap.min.js")
for s in ["click", "impact", "swish", "drop"]:
    shutil.copy(f"{old}/sfx/{s}.ogg", f"{OUT}/assets/sfx/{s}.ogg")
shutil.copy(os.path.join(ROOT, "marketing/aio-icon-256.png"), f"{OUT}/assets/aio-icon-256.png")
track = os.environ.get("FILM_TRACK", os.path.join(HERE, "digital-clouds.mp3"))
if not os.path.exists(f"{OUT}/assets/music.wav"):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", str(SRC_START), "-t", str(round(TOTAL + 1.5, 3)), "-i", track,
                    "-af", "afade=t=in:d=0.04,loudnorm=I=-14:TP=-1.2:LRA=9", "-ar", "48000", "-ac", "2", f"{OUT}/assets/music.wav"], check=True)

screen_html = SNAP["screen"].replace('src="aio-icon-256.png"', 'src="assets/aio-icon-256.png"')
import re
css = SNAP["css"].replace("url(aio-icon-256.png)", "url(assets/aio-icon-256.png)")
css = re.sub(r"(?<![-\w])(transition(-delay)?|animation)\s*:[^;}]*;?", "", css)   # the film drives every change itself

sfx = [("impact", b(6), .32), ("swish", b(6.1), .22)]
for i in range(4): sfx.append(("click", b(i), .2))
sfx.append(("impact", b(4), .26))
for t in [b(7), b(14.4), b(28), b(36.5)]: sfx.append(("swish", t, .16))
for t in CLICKS: sfx.append(("click", t, .32))
sfx.append(("click", b(27.9), .26)); sfx.append(("click", b(28.1), .26))
sfx.append(("drop", b(45.2), .3))
audio = f'<audio id="music" class="clip" src="assets/music.wav" data-start="0" data-duration="{TOTAL}" data-volume="0.8" data-fade-out="1.6" data-track-index="20"></audio>\n'
for k, (n, t, v) in enumerate(sfx):
    d = {"click": 0.01, "impact": 0.18, "swish": 0.06, "drop": 0.11}[n]
    audio += f'      <audio id="sfx{k}" class="clip" src="assets/sfx/{n}.ogg" data-start="{t}" data-duration="{d}" data-volume="{v}" data-track-index="{21 + k}"></audio>\n'

if V:
    hook_html = "".join(f'<div class="hw" id="hw{i}" style="top:{250 + i * 150}px">{w}</div>' for i, w in enumerate(words)) + '<div class="hw one" id="hw4" style="top:900px">All in one.</div>'
    out_html = """<img id="oicon" src="assets/aio-icon-256.png" style="top:300px;width:170px;height:170px;margin-left:-85px">
      <div class="ot" id="oname" style="top:500px;font-size:170px">AIO</div>
      <div class="ot sub" id="otag" style="top:700px;font-size:46px">All in one: Launcher · Dock<br>Notch · Music · ⌘K</div>
      <div class="ot cta" id="octa" style="top:880px;font-size:34px">Free for macOS · github.com/rayanjainn/aio</div>"""
else:
    hook_html = '<div class="hline" style="top:150px">' + " ".join(f'<span class="hw2" id="hw{i}">{w}</span>' for i, w in enumerate(words)) + '</div><div class="hw one" id="hw4" style="top:285px">All in one.</div>'
    out_html = """<img id="oicon" src="assets/aio-icon-256.png" style="top:70px;width:110px;height:110px;margin-left:-55px">
      <div class="ot" id="oname" style="top:180px;font-size:130px">AIO</div>
      <div class="ot sub" id="otag" style="top:330px;font-size:38px">All in one: Launcher · Dock · Notch · Music · ⌘K</div>
      <div class="ot cta" id="octa" style="top:410px;font-size:30px">Free for macOS · github.com/rayanjainn/aio</div>"""
caps_html = "".join(f'<div class="cap" id="cap{i}" style="{"top:" + str(220 if V else 70) + "px" if w == "top" else "top:" + str(1600 if V else 920) + "px"}">{t}</div>' for i, (_, _, t, w) in enumerate(CAPS))

DATA = dict(TOTAL=TOTAL, K0=K0, W=W, H=H, CAM=CAM, CURSOR=CURSOR, CURSOR_ON=CURSOR_ON, CLICKS=CLICKS, BOUNCES=BOUNCES,
            ISLAND=ISLAND, DOCKMAG=DOCKMAG, LAUNCH=LAUNCH, LP_TYPE=LP_TYPE, PAL=PAL, PAL_TYPE=PAL_TYPE, KEYS=KEYS,
            PLAYER=PLAYER, LYRICS=LYRICS, CAPS=[c[:2] for c in CAPS], ROWS=SNAP["rows"],
            HOOK=[b(0), b(1), b(2), b(3), b(4)], HOOK_OUT=b(5.6), OUTRO=[b(45), b(45.6), b(46.4), b(47.2)], V=V)

JS = r"""
const D = __DATA__;
const $ = s => document.querySelector(s), $$ = s => [...document.querySelectorAll(s)];
const clamp = (v, a = 0, z = 1) => Math.min(z, Math.max(a, v));
const E = {
  out: t => 1 - Math.pow(1 - t, 3),
  inout: t => t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2,
  expo: t => t === 0 ? 0 : t === 1 ? 1 : t < .5 ? Math.pow(2, 20 * t - 10) / 2 : (2 - Math.pow(2, -20 * t + 10)) / 2,
  back: t => { const c1 = 1.5, c3 = c1 + 1; return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2); },
  none: t => t
};
// keyframes: [[time, ...values, ease]] -> interpolated values at t
const kf = (t, list) => {
  if (t <= list[0][0]) return list[0].slice(1, -1);
  for (let i = 1; i < list.length; i++) {
    const a = list[i - 1], z = list[i];
    if (t <= z[0]) { const p = E[z[z.length - 1]]((t - a[0]) / (z[0] - a[0] || 1)); return a.slice(1, -1).map((v, k) => v + (z[k + 1] - v) * p); }
  }
  return list[list.length - 1].slice(1, -1);
};
const win = (t, a, z, fade = .3) => clamp(Math.min((t - a) / fade, (z - t) / fade));
const typed = (t, list) => { for (const [a, e, c, s] of list) if (t >= a && t < c) return s.slice(0, Math.max(0, Math.min(s.length, Math.floor((t - a) / (e - a) * s.length) + 1))); return ''; };

const screen = $('#screen'), cam = $('#cam'), island = $('#island'), lp = $('#lp'), pal = $('#pal'), player = $('#player');
const cursor = $('#cursor'); cursor.classList.remove('hide');
const pos = el => { let x = 0, y = 0, n = el; while (n && n !== screen) { x += n.offsetLeft; y += n.offsetTop; n = n.offsetParent; } return { x, y, w: el.offsetWidth, h: el.offsetHeight, cx: x + el.offsetWidth / 2, cy: y + el.offsetHeight / 2 }; };
const dis = $$('#mdock .di');
dis.forEach(d => d.style.width = d.style.height = '58px');
const base = dis.map(d => pos(d).cx), dockR = pos($('#mdock .dbar')), npX = pos($('.dw.np')).cx;
const cur = D.CURSOR.map(([t, x, y, e]) => {
  const rx = typeof x === 'number' ? x : x === 'NP' ? npX : (() => { const m = x.match(/^D(\d+)([+-]\d+)?$/); return base[+m[1]] + (+m[2] || 0); })();
  return [t, rx, y, e];
});
const lyr = $$('#lyr p'), pgs = $$('.pg'), plbar = $('#plbar');
const palq = $('#palq'), rows = $('#rows'), lpq = $('#lpq'), apps = $$('#apps .app');
const keys = $('#keys'), clk = cursor.querySelector('.clk');
let lastRows = null, lastLp = null, lastKeys = null;
$('#lyr').style.transition = 'none';

function render(t) {
  // camera
  const [px, py, z, rx, yo] = kf(t, D.CAM), k = D.K0 * z;
  const tx = -(px - 720) * k, ty = -(py - 450) * k + yo;
  cam.style.transform = `translate(${tx.toFixed(2)}px,${ty.toFixed(2)}px)` + (rx > .01 ? ` perspective(2600px) rotateX(${rx.toFixed(3)}deg)` : '') + ` scale(${k.toFixed(4)})`;
  cam.style.opacity = clamp(t / .5);

  // hook + outro text
  D.HOOK.forEach((h, i) => { const el = $('#hw' + i), p = E.out(clamp((t - h) / .35)), o = 1 - clamp((t - D.HOOK_OUT) / .35);
    el.style.opacity = (p * o).toFixed(3); el.style.transform = `translateY(${((1 - p) * 30 - (1 - o) * 50).toFixed(1)}px)`; el.style.filter = `blur(${((1 - p) * 10).toFixed(1)}px)`;
    if (i < 4) el.style.color = t > D.HOOK[4] ? '#c7c7cc' : '#1d1d1f'; });
  ['#oicon', '#oname', '#otag', '#octa'].forEach((s, i) => { const el = $(s), p = (i === 0 ? E.back : E.out)(clamp((t - D.OUTRO[i]) / .5));
    el.style.opacity = clamp((t - D.OUTRO[i]) / .3).toFixed(3); el.style.transform = `translateY(${((1 - p) * 40).toFixed(1)}px) scale(${(.9 + .1 * p).toFixed(3)})`; });
  D.CAPS.forEach(([a, z2], i) => { const el = $('#cap' + i), o = win(t, a, z2, .3), p = E.back(clamp((t - a) / .45));
    el.style.opacity = o.toFixed(3); el.style.transform = `translateX(-50%) translateY(${((1 - p) * 26).toFixed(1)}px) scale(${(.94 + .06 * p).toFixed(3)})`; });

  // cursor
  const [cx, cy] = kf(t, cur);
  cursor.style.transform = `translate(${(cx - 5).toFixed(1)}px,${(cy - 3).toFixed(1)}px)`;
  cursor.style.opacity = win(t, D.CURSOR_ON[0], D.CURSOR_ON[1], .25);
  let rip = 0; for (const c of D.CLICKS) if (t >= c && t < c + .45) rip = (t - c) / .45;
  clk.style.opacity = rip ? (1 - rip).toFixed(3) : 0; clk.style.transform = `scale(${(.2 + 1.2 * rip).toFixed(3)})`;

  // island
  const o = clamp(kf(t, D.ISLAND)[0], 0, 1.08);
  island.style.width = (196 + 494 * o).toFixed(1) + 'px'; island.style.height = (32 + 190 * o).toFixed(1) + 'px';
  island.style.borderRadius = `0 0 ${(14 + 24 * Math.min(o, 1)).toFixed(1)}px ${(14 + 24 * Math.min(o, 1)).toFixed(1)}px`;
  island.style.boxShadow = o > .05 ? `0 30px 60px -20px rgba(0,0,0,${(.45 * Math.min(o, 1)).toFixed(2)})` : 'none';
  const inn = island.querySelector('.in'), io = clamp((o - .45) / .55);
  inn.style.opacity = io.toFixed(3); inn.style.transform = `scale(${(.94 + .06 * io).toFixed(3)}) translateY(${(-8 * (1 - io)).toFixed(1)}px)`;
  island.querySelector('.dots').style.opacity = io.toFixed(3);

  // dock magnification + bounce
  const magOn = t > D.DOCKMAG[0] && t < D.DOCKMAG[1];
  const inside = magOn && cy > dockR.y - 40 && cx > dockR.x - 30 && cx < dockR.x + dockR.w + 30;
  let near = -1, nd = 31;
  dis.forEach((d, i) => {
    const dist = inside ? Math.abs(cx - base[i]) : 999;
    const m = 1 + 0.62 * Math.max(0, Math.cos(Math.min(dist / 190, 1) * Math.PI / 2)) ** 1.6;
    d.style.width = d.style.height = (58 * m).toFixed(2) + 'px';
    if (dist < nd) { nd = dist; near = i; }
    let by = 0; for (const [n, bt] of D.BOUNCES) if (d.dataset.name === n && t >= bt && t < bt + .9) { const q = (t - bt) / .9; by = -Math.abs(Math.sin(q * Math.PI * 2)) * (q < .5 ? 26 : 10); }
    d.querySelector('.ico').style.transform = `translateY(${by.toFixed(1)}px)`;
  });
  dis.forEach((d, i) => d.classList.toggle('tipon', i === near));

  // launcher
  const l = clamp(kf(t, D.LAUNCH)[0]);
  lp.style.opacity = l.toFixed(3); lp.querySelector('.inner').style.transform = `scale(${(1.06 - .06 * l).toFixed(4)})`;
  $('#mdock').style.transform = `translateY(${(130 * l).toFixed(1)}%)`; $('#mdock').style.opacity = (1 - l).toFixed(3);
  const lq = typed(t, D.LP_TYPE);
  if (lq !== lastLp) { lastLp = lq; lpq.value = lq; apps.forEach(a => a.classList.toggle('gone', !!lq && !a.dataset.name.toLowerCase().includes(lq))); }

  // command bar
  const p = clamp(kf(t, D.PAL)[0], 0, 1.05);
  pal.style.opacity = clamp(p).toFixed(3); pal.style.transform = `translateX(-50%) scale(${(.96 + .04 * p).toFixed(4)})`;
  const q = typed(t, D.PAL_TYPE);
  if (q !== lastRows) { lastRows = q; palq.value = q; rows.innerHTML = D.ROWS[q] ?? D.ROWS['']; }
  let kk = null; for (const [a, z2, ks] of D.KEYS) if (t >= a && t < z2) kk = ks;
  const ko = kk ? 1 : 0; if (kk && kk.join() !== lastKeys) { lastKeys = kk.join(); keys.innerHTML = kk.map(x => `<span>${x}</span>`).join(''); }
  keys.style.opacity = ko; keys.style.transform = 'translateX(-50%)';

  // music player
  const pt = t - D.PLAYER, po = clamp(pt / .28);
  player.style.opacity = po.toFixed(3);
  const s = E.out(clamp(pt / .9)), sv = E.out(clamp((pt - .35) / 1));
  const sl = player.querySelector('.sleeve'); sl.style.opacity = s.toFixed(3); sl.style.transform = `translateX(${(-60 * (1 - s)).toFixed(1)}px)`;
  const vin = player.querySelector('.sleeve .vinyl'); vin.style.left = (10 + 180 * sv).toFixed(1) + 'px'; vin.style.transform = `rotate(${(Math.max(0, pt) * 90).toFixed(2)}deg)`;
  player.querySelector('.bg').style.transform = `translate(${(t * .3).toFixed(2)}%,${(-t * .2).toFixed(2)}%) scale(1.04)`;
  $('#lp .vinyl').style.transform = `rotate(${(t * 90).toFixed(2)}deg)`;
  let li = 0; D.LYRICS.forEach((lt, i) => { if (t >= lt) li = i; });
  lyr.forEach((el, i) => { el.classList.toggle('on', i === li); el.classList.toggle('past', i < li);
    if (i === li) el.style.setProperty('--p', (clamp((t - D.LYRICS[li]) / ((D.LYRICS[li + 1] || D.LYRICS[li] + 2) - D.LYRICS[li] - .2)) * 100).toFixed(1) + '%'); });
  const pct = ((52 + t) % 214) / 214 * 100; pgs.forEach(e => e.style.width = pct + '%'); plbar.style.width = pct + '%';

  // clock widgets: 9:41, the second hand moves with the film
  const sec = 12 + t, mins = 41 + sec / 60, hrs = 9 + mins / 60;
  const a = $('#aclock'); a.querySelector('.h').style.transform = `rotate(${hrs * 30}deg)`; a.querySelector('.mi').style.transform = `rotate(${mins * 6}deg)`; a.querySelector('.s').style.transform = `rotate(${sec * 6}deg)`;
  const dc = $('#dclock'); dc.querySelector('.h').style.transform = `rotate(${hrs * 30}deg)`; dc.querySelector('.mi').style.transform = `rotate(${mins * 6}deg)`;
}
const clock = { _t: 0, get t() { return this._t; }, set t(v) { this._t = v; render(v); } };
const tl = gsap.timeline({ paused: true });
tl.fromTo(clock, { t: 0 }, { t: D.TOTAL, duration: D.TOTAL, ease: 'none' }, 0);
window.__timelines = window.__timelines || {};
window.__timelines['main'] = tl;
render(0);
"""

FILM_CSS = f"""
#root * {{ transition: none !important; animation: none !important; }}
html, body {{ width:{W}px; height:{H}px; overflow:hidden; background:#f5f5f7; margin:0; }}
#root {{ position:relative; width:{W}px; height:{H}px; overflow:hidden; font-family: Inter, sans-serif;
  background: radial-gradient({W}px {H}px at 50% 0%, #ffffff 0%, #f5f5f7 55%, #e8eaef 100%); }}
#root #screen {{ font-family: Inter, sans-serif; }}
#cam {{ position:absolute; left:{W / 2 - 731}px; top:{H / 2 - 461}px; width:1462px; transform-origin:731px 461px; }}
#cam .viewport {{ width:1440px; height:900px; aspect-ratio:auto; }}
#cam .base {{ margin:0 -50px; }}
.hline {{ position:absolute; left:0; right:0; text-align:center; font-size:96px; font-weight:800; letter-spacing:-.045em; color:#1d1d1f; }}
.hw2 {{ display:inline-block; }}
.hw {{ position:absolute; left:0; right:0; text-align:center; font-size:{136 if V else 120}px; font-weight:800; letter-spacing:-.045em; color:#1d1d1f; line-height:1; }}
.hw.one {{ color:#1d1d1f; }}
#oicon {{ position:absolute; left:50%; border-radius:24%; box-shadow:0 20px 40px -12px rgba(0,0,0,.3); }}
.ot {{ position:absolute; left:0; right:0; text-align:center; font-weight:800; letter-spacing:-.045em; color:#1d1d1f; line-height:1.05; }}
.ot.sub {{ font-weight:600; letter-spacing:-.01em; color:#6e6e73; }}
.ot.cta {{ left:50%; right:auto; width:max-content; margin-left:-{(430 if V else 440)}px; width:{860 if V else 880}px; padding:18px 0; border-radius:999px; background:#1d1d1f; color:#fff; font-weight:600; letter-spacing:-.01em; }}
.cap {{ position:absolute; left:50%; white-space:nowrap; padding:{'22px 44px' if V else '18px 40px'}; border-radius:999px; background:rgba(255,255,255,.82);
  backdrop-filter:blur(24px) saturate(1.6); -webkit-backdrop-filter:blur(24px) saturate(1.6);
  box-shadow:0 0 0 1px rgba(0,0,0,.06), 0 20px 50px -18px rgba(0,0,0,.35); font-size:{58 if V else 54}px; font-weight:800; letter-spacing:-.035em; color:#1d1d1f; z-index:60; }}
"""

index = f"""<!doctype html>
<html lang="en" data-resolution="{'portrait' if V else 'landscape'}">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width={W}, height={H}" />
    <script src="assets/gsap.min.js"></script>
    <style>{css}</style>
    <style>{FILM_CSS}</style>
  </head>
  <body>
    <div id="root" data-composition-id="main" data-start="0" data-duration="{TOTAL}" data-width="{W}" data-height="{H}">
      <div id="cam" data-layout-ignore><div class="bezel"><div class="viewport">{screen_html}</div></div><div class="base"></div></div>
      {hook_html}
      {caps_html}
      {out_html}
      {audio}
    </div>
    <script>{JS.replace('__DATA__', json.dumps(DATA))}</script>
  </body>
</html>
"""
open(f"{OUT}/index.html", "w").write(index)
print("wrote", OUT, "duration", TOTAL)
