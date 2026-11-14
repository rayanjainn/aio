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

# Beat grid of "Digital Clouds" (Mixkit), 129 BPM; the cut puts the drop on beat 6 and the second drop on beat 86.
B, T0 = 0.46511, 0.2
SH = 16                                  # beats of story intro before the old beat 0
SRC_START = round(26.971 - SH * B, 3)   # the music's drop stays on the reveal
BEATS = 100
def b(n): return round(T0 + (n + SH) * B, 3)   # the feature timeline
def r(n): return round(T0 + n * B, 3)          # the intro, from the first frame
SRC_END = b(BEATS)          # end of the source timeline
TOTAL = SRC_END             # the film is shorter or longer: set after the cut list below

K0 = 0.75 if V else 1.2          # screen scale at zoom 1: fills the frame width (portrait) or height (landscape)

def C(t, x, y, zl, zp, e="inout", rl=0, rp=0, yl=0, yp=0):
    """Camera keyframe for both cuts: focus point (screen px), zoom, tilt and y offset per orientation."""
    return [t, x, y, zp if V else zl, rp if V else rl, yp if V else yl, e]
def F(t, x, y, zl, zp, e="inout", xp=None, yp_=None):
    return C(t, xp if (V and xp is not None) else x, yp_ if (V and yp_ is not None) else y, zl, zp, e)

# ---------- Camera ----------
CAM = [
    C(b(0), 720, 450, .50, .9, "out", 26, 24, 420, 640),
    C(round(b(0) + 1.1, 3), 720, 450, .50, .9, "out", 26, 24, 300, 520),
    C(b(5.5), 720, 450, .50, .9, "inout", 26, 24, 300, 520),
    C(b(6.6), 720, 450, 1, 1, "expo"),
    C(b(7), 720, 450, 1, 1),
    F(b(8.4), 720, 175, 2.1, 2.0, yp_=150),            # notch: Island pages, then the volume HUD
    F(b(16.8), 720, 175, 2.1, 2.0, yp_=150),
    C(b(17.6), 720, 450, 1, 1),
    F(b(18.4), 420, 770, 1.75, 2.4),                    # Dock: magnify sweep
    F(b(20.6), 900, 770, 1.75, 2.4),
    F(b(21.4), 800, 720, 1.7, 2.1),                     # presets menu
    F(b(25.9), 800, 720, 1.7, 2.1),
    C(b(26.6), 720, 450, 1, 1),
    F(b(27.4), 720, 450, 1, 1.55, xp=540, yp_=380),     # Launcher
    F(b(30.4), 760, 430, 1.06, 1.55, xp=560, yp_=360),
    F(b(32.6), 940, 360, 1.18, 1.5, xp=1060, yp_=330),  # widget dragged to the right column
    F(b(37.3), 900, 380, 1.12, 1.5, xp=1040, yp_=340),
    C(b(38), 720, 450, 1, 1),
    C(b(48.2), 720, 450, 1, 1),                         # snapping, full desktop
    C(b(53.2), 720, 450, 1, 1),
    C(b(53.8), 720, 380, 1.3, 1.35),                    # switcher
    C(b(55.9), 720, 380, 1.3, 1.35),
    F(b(56.8), 340, 250, 2.2, 2.4, yp_=240),            # Act on this
    F(b(62.8), 340, 250, 2.2, 2.4, yp_=240),
    C(b(63.6), 720, 450, 1, 1),
    F(b(64.4), 560, 430, 1.15, 1.7, xp=380, yp_=400),   # music
    F(b(71.8), 900, 410, 1.2, 1.7, xp=1080, yp_=360),
    F(b(73.2), 1180, 250, 1.9, 2.2, xp=1180, yp_=260),  # desktop widgets
    F(b(77.2), 1150, 270, 1.95, 2.3, xp=1160, yp_=270),
    C(b(78.2), 720, 450, .9, 1.0),                      # "and more"
    C(b(85.8), 720, 450, .86, .96),
    C(b(87.6), 720, 450, .46, .82, "expo", 16, 14, 280, 470),
    C(SRC_END, 720, 450, .46, .8, "out", 16, 14, 280, 470),
]

# ---------- Cursor (screen px; names are measured from the page at runtime) ----------
CURSOR = [
    [b(6.6), 1040, 640, "inout"], [b(6.9), 1040, 640, "inout"], [b(8), 720, 14, "inout"],
    [b(9.9), 720, 60, "inout"], [b(10.3), "TAB1", "TABY", "inout"], [b(12.1), "TAB1", "TABY", "inout"], [b(12.3), "TAB2", "TABY", "inout"],
    [b(13.7), "TAB2", "TABY", "inout"], [b(13.9), "TAB3", "TABY", "inout"], [b(15.2), "TAB3", "TABY", "inout"], [b(15.9), 900, 420, "inout"],
    [b(17.4), 900, 420, "inout"], [b(18.2), "D0+10", 858, "inout"], [b(18.4), "D0+10", 858, "inout"],
    [b(20.6), "D8", 862, "inout"], [b(20.8), "D8", 862, "inout"], [b(21.1), "NP", 855, "inout"],
    [b(21.4), "NP", 855, "inout"], [b(21.9), "MI1X", "MI1", "inout"], [b(22.4), "NP", 855, "inout"],
    [b(22.7), "NP", 855, "inout"], [b(23.2), "MI2X", "MI2", "inout"], [b(23.7), "NP", 855, "inout"],
    [b(24.0), "NP", 855, "inout"], [b(24.5), "MI3X", "MI3", "inout"], [b(24.9), "NP", 855, "inout"],
    [b(25.2), "NP", 855, "inout"], [b(25.6), "MI0X", "MI0", "inout"], [b(26.2), "D0", 860, "inout"],
    [b(27.5), "D0", 860, "inout"], [b(28), 720, 74, "inout"], [b(30.1), 720, 74, "inout"], [b(30.8), "WCX", "WCY", "inout"],
    [b(31), "WCX", "WCY", "inout"], [b(32.5), 1210, 230, "inout"], [b(37.1), 1210, 230, "inout"], [b(37.8), 1000, 600, "inout"],
    [b(48), 1000, 600, "inout"], [b(48.4), 330, 112, "inout"], [b(53.2), 330, 112, "inout"], [b(53.8), 900, 560, "inout"],
    [b(56.1), 900, 560, "inout"], [b(56.6), "P0X", "P0Y", "inout"], [b(57.4), "P1X", "P1Y", "inout"],
    [b(58.1), "TRX", "TRY", "inout"], [b(60.1), "TRX", "TRY", "inout"], [b(60.4), "SUX", "SUY", "inout"],
    [b(62.4), "SUX", "SUY", "inout"], [b(63.2), "NP", 855, "inout"],
]
CURSOR_ON = [b(6.6), b(64.0)]
CLICKS = [b(10.4), b(12.4), b(14), b(21.3), b(22), b(23.3), b(24.6), b(25.7), b(26.4), b(28.1), b(58.3), b(60.5), b(63.4)]
BOUNCES = [["Launcher", b(26.4)], ["Music", b(63.4)], ["Terminal", b(55.7)]]

ISLAND = [[b(8), 0, "out"], [b(8.7), 1, "back"], [b(15.3), 1, "inout"], [b(15.8), 0, "inout"]]
PAGES = [[0, "home"], [b(10.4), "clip"], [b(12.4), "shelf"], [b(14), "tools"]]
HUD = [b(15.9), b(17.2), b(16.4)]                       # in, out, when the level steps up
DOCKMAG = [b(17.4), b(21.0)]
MENUS = [[b(21.3), b(22.05)], [b(22.6), b(23.35)], [b(23.9), b(24.65)], [b(25.1), b(25.75)]]
PRESET = [[0, "glass"], [b(22), "tide"], [b(23.3), "midnight"], [b(24.6), "ocean"], [b(25.7), "glass"]]
LAUNCH = [[b(26.6), 0, "out"], [b(27.3), 1, "out"], [b(37.4), 1, "out"], [b(38), 0, "out"]]
LP_TYPE = [[b(28.3), b(29.3), b(30.2), "note"]]
WDRAG = [b(31), b(32.5)]
KEYS = [[b(15.8), b(16.9), ["F12"]],
        [b(48.5), b(49.6), ["⌃", "⌥", "←"]], [b(50), b(51.1), ["⌃", "⌥", "→"]], [b(51.4), b(52.4), ["⌃", "⌥", "↑"]], [b(52.5), b(53.3), ["⌃", "⌥", "↓"]],
        [b(53.4), b(55.6), ["⌥", "⇥"]]]
WSNAP = [[0, "restore"], [b(48.6), "left"], [b(50.1), "right"], [b(51.5), "max"], [b(52.6), "restore"]]
SWITCH = [[b(53.5), 1], [b(54.2), 2], [b(54.9), 3], [b(55.7), -1]]
TOASTS = [[b(55.7), b(57.4), "Switched to Terminal — ~"]]
ACT = [b(57.3), b(57.6), b(62.7)]                       # highlight, popover in, popover out
ACT_RES = [[b(58.5), "translate"], [b(60.5), "summarise"]]
PLAYER = [b(63.6), b(72.2)]
LYRICS = [b(65), b(67), b(69), b(71)]
MORE = [b(77.6), b(85.8)]
MORE_LINES = ["Shelf + AirDrop", "Clipboard history", "Spaces for every setup", "Screen memory, off until you want it", "AI on your Mac", "No account. No tracking."]


# ---------- HERO: ⌘K. It lives in an unused stretch of the source timeline and is cut in right after the reveal ----------
H0, HE = 106, 38
def h(n): return b(H0 + n)
CAM += [C(h(0), 720, 450, 1, 1), C(h(1.0), 720, 450, 1, 1), C(h(2.2), 720, 330, 1.55, 1.75),
        C(h(36.4), 720, 330, 1.55, 1.75), C(h(37.6), 720, 450, 1, 1)]
HQ = [["12*(3+4)", 3.0, 5.4, 9.0], ["10 km to mi", 9.2, 11.9, 15.4], ["100 usd to eur", 15.6, 18.9, 22.0],
      ["event lunch tomorrow 1pm", 22.2, 27.2, 31.0], ["heart", 31.2, 33.4, 36.2]]
HERO_PAL = [[h(1.0), 0, "out"], [h(1.6), 1, "back"], [h(36.6), 1, "out"], [h(37.2), 0, "out"]]
HERO_TYPE = [[h(a), h(e), h(c), q] for q, a, e, c in HQ]
HERO_KEYS = [[h(0.3), h(1.5), ["⌘", "K"]], [h(36.0), h(37.0), ["esc"]]]
HERO_CAPS = [[h(1.6), h(8.8), "One bar for your whole Mac.", "bottom"], [h(9.2), h(15.2), "Convert anything.", "bottom"],
             [h(15.6), h(21.8), "Live currency.", "bottom"], [h(22.2), h(30.8), "Schedule it by typing it.", "bottom"],
             [h(31.2), h(36.2), "Emoji, clipboard, AI…", "bottom"]]
HERO_SFX = [("swish", h(1.0), .2)] + [("click", h(a), .2) for _, a, _, _ in HQ]

# cut list: film order -> source ranges. Cuts land on whole beats so the music stays on the grid.
SEGS_SRC = [(0.0, b(7)), (h(0), h(HE)), (b(7), b(38)), (b(48), SRC_END)]
SEGS, _f = [], 0.0
for _s0, _s1 in SEGS_SRC:
    SEGS.append([round(_f, 4), round(_s0, 4), round(_s1, 4)]); _f += _s1 - _s0
TOTAL = round(_f, 3)
def FT(ts):
    for f0, s0, s1 in SEGS:
        if s0 <= ts < s1: return round(f0 + ts - s0, 3)
    return None
PAL, PAL_TYPE = HERO_PAL, HERO_TYPE
KEYS += HERO_KEYS

# ---------- Captions: [in, out, text, where] ----------
def W2(l, p): return p if V else l
CAPS = [
    [b(8.7), b(10.3), "Hello, notch.", "bottom"],
    [b(10.6), b(15.3), W2("Clipboard, Shelf, Tools. One hover away.", "Clipboard. Shelf. Tools."), "bottom"],
    [b(18.2), b(21), "Truly your Dock.", W2("top", "bottom")],
    [b(21.4), b(25.9), "Presets in one click.", W2("top", "bottom")],
    [b(27.4), b(30.4), "All your apps. Plus your day.", W2("bottom", "top")],
    [b(30.8), b(37.2), "Put widgets where you want them.", W2("bottom", "top")],
    [b(48.6), b(53.2), "Snap windows from the keyboard.", W2("bottom", "top")],
    [b(53.6), b(56), "Switch windows, not just apps.", "bottom"],
    [b(57.5), b(62.7), "Act on any text.", "bottom"],
    [b(64.2), b(71.8), "Your song. The whole screen.", W2("bottom", "top")],
    [b(73.5), b(77.2), "Desktop widgets.", "bottom"],
] + HERO_CAPS

# Story intro (from the first frame): the problem, then the question, then the answer.
CARDS = [[r(-1.0), r(2.4), "Spotlight to search."], [r(2.5), r(4.9), "Launchpad to open."], [r(5.0), r(7.4), "A Dock to switch."],
         [r(7.5), r(9.9), "A notch you ignore."], [r(10.2), r(15.7), "What if one bar<br>did it all?"]]
CARD_T = [c[0] for c in CARDS]
CAM_ON = round(b(0) - 0.15, 3)

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

sfx = [("impact", b(6), .32), ("swish", b(6.1), .22), ("impact", b(86), .34), ("swish", b(86.1), .22)]
for t in CARD_T[:4]: sfx.append(("click", max(t, 0.05), .22))
sfx.append(("swish", CARD_T[4], .18)); sfx.append(("impact", b(0), .34)); sfx.append(("click", b(1.5), .2)); sfx.append(("click", b(3), .2))
for t in [b(7), b(17.5), b(38), b(48), b(53.4), b(56.2), b(63.6), b(72.4), b(77.6)]: sfx.append(("swish", t, .14))
for t in CLICKS: sfx.append(("click", t, .3))
for t in [b(27.9), b(28.1), b(48.5), b(50), b(51.4), b(52.5), b(53.4), b(54.2), b(54.9)]: sfx.append(("click", t, .22))
for i in range(len(MORE_LINES)): sfx.append(("click", round(MORE[0] + .25 + i * B, 3), .16))
sfx.append(("drop", b(87.1), .3))
sfx += HERO_SFX
sfx = [(n, FT(t), v) for (n, t, v) in sfx if FT(t) is not None]
sfx.sort(key=lambda x: x[1])
audio = f'<audio id="music" class="clip" src="assets/music.wav" data-start="0" data-duration="{TOTAL}" data-volume="0.8" data-fade-out="1.6" data-track-index="20"></audio>\n'
for k, (n, t, v) in enumerate(sfx):
    d = {"click": 0.01, "impact": 0.18, "swish": 0.06, "drop": 0.11}[n]
    audio += f'      <audio id="sfx{k}" class="clip" src="assets/sfx/{n}.ogg" data-start="{t}" data-duration="{d}" data-volume="{v}" data-track-index="{21 + k}"></audio>\n'

cards_html = "".join(f'<div class="cd" id="cd{i}">{t}</div>' for i, (_, _, t) in enumerate(CARDS))
if V:
    hook_html = ('<div class="hw" id="hw0" style="top:300px;font-size:300px">AIO.</div>'
                 '<div class="hw" id="hw1" style="top:600px;font-size:124px;line-height:1">One bar.<br>Your whole Mac.</div>'
                 '<div class="hw gray" id="hw2" style="top:880px;font-size:50px">⌘K · Launcher · Dock · Notch · Music</div>')
    out_html = """<img id="oicon" src="assets/aio-icon-256.png" style="top:280px;width:170px;height:170px;margin-left:-85px">
      <div class="ot" id="oname" style="top:470px;font-size:170px">AIO</div>
      <div class="ot sub" id="otag" style="top:670px;font-size:46px">One bar for your whole Mac:<br>⌘K · Launcher · Dock · Notch · Music</div>
      <div class="ot cta" id="octa" style="top:810px;font-size:58px">aio.raycode.tech</div>
      <div class="ot sub" id="ofree" style="top:930px;font-size:38px">Free for macOS · Link in bio</div>"""
else:
    hook_html = ('<div class="hw" id="hw0" style="top:40px;font-size:190px">AIO.</div>'
                 '<div class="hw" id="hw1" style="top:235px;font-size:92px">One bar. Your whole Mac.</div>'
                 '<div class="hw gray" id="hw2" style="top:348px;font-size:40px">⌘K · Launcher · Dock · Notch · Music</div>')
    out_html = """<img id="oicon" src="assets/aio-icon-256.png" style="top:40px;width:100px;height:100px;margin-left:-50px">
      <div class="ot" id="oname" style="top:150px;font-size:120px">AIO</div>
      <div class="ot sub" id="otag" style="top:290px;font-size:34px">One bar for your whole Mac: ⌘K · Launcher · Dock · Notch · Music</div>
      <div class="ot cta" id="octa" style="top:350px;font-size:52px">aio.raycode.tech</div>
      <div class="ot sub" id="ofree" style="top:462px;font-size:28px">Free for macOS · Link in the description</div>"""
more_html = '<div id="more">' + "".join(f'<div class="ml" id="ml{i}">{t}</div>' for i, t in enumerate(MORE_LINES)) + '</div>'
caps_html = "".join(f'<div class="cap" id="cap{i}" style="{"top:" + str(220 if V else 70) + "px" if w == "top" else "top:" + str(1600 if V else 920) + "px"}">{t}</div>' for i, (_, _, t, w) in enumerate(CAPS))

DATA = dict(TOTAL=TOTAL, K0=K0, W=W, H=H, CAM=CAM, CURSOR=CURSOR, CURSOR_ON=CURSOR_ON, CLICKS=CLICKS, BOUNCES=BOUNCES,
            ISLAND=ISLAND, DOCKMAG=DOCKMAG, LAUNCH=LAUNCH, LP_TYPE=LP_TYPE, PAL=PAL, PAL_TYPE=PAL_TYPE, KEYS=KEYS,
            PLAYER=PLAYER, LYRICS=LYRICS, CAPS=[c[:2] for c in CAPS], ROWS=SNAP["rows"],
            SEGS=SEGS, SRC_END=SRC_END, PAGES=PAGES, HUD=HUD, MENUS=MENUS, PRESET=PRESET, WDRAG=WDRAG, SNAP=WSNAP, SWITCH=SWITCH, TOASTS=TOASTS,
            ACT=ACT, ACT_RES=ACT_RES, MORE=MORE, MORE_N=len(MORE_LINES),
            CARDS=[c[:2] for c in CARDS], CAM_ON=CAM_ON,
            HOOK=[b(0), b(1.5), b(3)], HOOK_OUT=b(4.9), OUTRO=[b(87), b(87.6), b(88.4), b(89.2), b(90.2)], V=V)

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
const NAMED = {};
// Island tabs, measured with the Island open.
island.style.width = '690px'; island.style.height = '238px';
$$('#island .tabs b').forEach((tb, i) => { const p = pos(tb); NAMED['TAB' + i] = p.cx; NAMED.TABY = p.cy; });
island.style.width = island.style.height = '';
// Dock presets menu, placed the way the site places it (above the pointer).
const PRESETS = [['glass', 'Glass', '#e5e5ea'], ['tide', 'Morning Tide', 'linear-gradient(135deg,#ffcc78,#f58c4c)'], ['midnight', 'Midnight Focus', 'linear-gradient(135deg,#3d3379,#0f0f29)'], ['ocean', 'Ocean Desk', 'linear-gradient(135deg,#409efa,#1a40ad)'], ['paper', 'Paper', '#fff']];
const dmenu = $('#dmenu');
const buildMenu = cur => { dmenu.innerHTML = '<div class="h">Dock presets</div>' + PRESETS.map(([k, n, sw]) => `<div class="mi"><span>${k === cur ? '✓' : ''}</span>${n}<i style="background:${sw}"></i></div>`).join(''); };
buildMenu('glass');
const mh = dmenu.offsetHeight; dmenu.style.left = Math.min(1440 - 230, npX) + 'px'; dmenu.style.top = (855 - mh - 8) + 'px';
$$('#dmenu .mi').forEach((m, i) => { const p = pos(m); NAMED['MI' + i] = p.cy; NAMED['MI' + i + 'X'] = p.x + 60; });
// Launcher widget: the weather card, before and after moving to the right column.
const lpL = $('#lpwL'), lpR = $('#lpwR'), wcard = $('.lpw .c[data-w="weather"]'), gridEl = $('#apps'), lpEmpty = $('#lpempty');
const lpLayout = () => { const hasL = lpL.children.length > 0, hasR = lpR.children.length > 0, l = hasL ? 420 : 64, r = hasR ? 420 : 56;
  gridEl.style.left = lpEmpty.style.left = l + 'px'; gridEl.style.right = lpEmpty.style.right = r + 'px';
  gridEl.style.gridTemplateColumns = `repeat(${Math.max(4, Math.floor((1440 - l - r) / 122))},1fr)`; };
lpLayout();
const wPosL = pos(wcard); lpR.appendChild(wcard); lpLayout(); const wPosR = pos(wcard); lpL.appendChild(wcard); lpLayout();
NAMED.WCX = wPosL.cx; NAMED.WCY = wPosL.cy;
// Act on this: the sentence, and the popover under it.
const actp = $('#actp'), actEl = $('#act'), ap = pos(actp);
NAMED.P0X = ap.x + 4; NAMED.P0Y = ap.y + 8; NAMED.P1X = ap.x + ap.w - 8; NAMED.P1Y = ap.y + ap.h - 5;
actEl.style.left = Math.min(1440 - 400, ap.x) + 'px'; actEl.style.top = (ap.y + ap.h + 10) + 'px';
const tr = pos($('#act .ab b[data-a="translate"]')), su = pos($('#act .ab b[data-a="summarise"]'));
NAMED.TRX = tr.cx; NAMED.TRY = tr.cy; NAMED.SUX = su.cx; NAMED.SUY = su.cy;
const RES = { translate: 'Selecciona esta frase y elige una acción: tradúcela, resúmela o corrígela.<small>Translated to Spanish · by your AI</small>', summarise: 'Pick an action for the selected text.<small>Summary · by your AI</small>' };
// Window snapping rectangles.
const winEl = $('#win'), natH = winEl.offsetHeight;
const RECT = { restore: [96, 96, 470, natH], left: [8, 38, 708, 770], right: [724, 38, 708, 770], max: [8, 38, 1424, 770] };
const resolve = v => typeof v === 'number' ? v : v in NAMED ? NAMED[v] : v === 'NP' ? npX : (() => { const m = v.match(/^D(\d+)([+-]\d+)?$/); return base[+m[1]] + (+m[2] || 0); })();
const cur = D.CURSOR.map(([t, x, y, e]) => [t, resolve(x), resolve(y), e]);
const at = (list, t) => { let v = list[0][1]; for (const [a, x] of list) if (t >= a) v = x; return v; };
let lastPage = null, lastPreset = null, lastSw = null, lastRes = null, wIn = 'L';
const lyr = $$('#lyr p'), pgs = $$('.pg'), plbar = $('#plbar');
const palq = $('#palq'), rows = $('#rows'), lpq = $('#lpq'), apps = $$('#apps .app');
const keys = $('#keys'), clk = cursor.querySelector('.clk');
let lastRows = null, lastLp = null, lastKeys = null;
$('#lyr').style.transition = 'none';

const SRC = tf => { for (const [f0, s0, s1] of D.SEGS) if (tf < f0 + (s1 - s0)) return s0 + (tf - f0); return D.SEGS[D.SEGS.length - 1][2] - 0.001; };
function render(tf) {
  const t = SRC(tf);
  // camera
  const [px, py, z, rx, yo] = kf(t, D.CAM), k = D.K0 * z;
  const tx = -(px - 720) * k, ty = -(py - 450) * k + yo;
  cam.style.transform = `translate(${tx.toFixed(2)}px,${ty.toFixed(2)}px)` + (rx > .01 ? ` perspective(2600px) rotateX(${rx.toFixed(3)}deg)` : '') + ` scale(${k.toFixed(4)})`;
  cam.style.opacity = clamp((t - D.CAM_ON) / .5);

  // hook + outro text
  // story intro cards
  D.CARDS.forEach(([a0, z0], i) => { const el = $('#cd' + i), o = win(t, a0, z0, .28), p = E.out(clamp((t - a0) / .38));
    el.style.opacity = o.toFixed(3); el.style.transform = `translateY(${((1 - p) * 34).toFixed(1)}px) scale(${(.96 + .04 * p).toFixed(3)})`; el.style.filter = `blur(${((1 - p) * 12).toFixed(1)}px)`; });
  // "AIO." slam, then the line under it
  D.HOOK.forEach((h, i) => { const el = $('#hw' + i), p = (i === 0 ? E.back : E.out)(clamp((t - h) / .4)), o = 1 - clamp((t - D.HOOK_OUT) / .35);
    el.style.opacity = (clamp((t - h) / .15) * o).toFixed(3); el.style.transform = `translateY(${((1 - p) * 30 - (1 - o) * 50).toFixed(1)}px) scale(${(i === 0 ? 1.18 - .18 * p : 1).toFixed(3)})`; el.style.filter = `blur(${((1 - p) * 10).toFixed(1)}px)`; });
  ['#oicon', '#oname', '#otag', '#octa', '#ofree'].forEach((s, i) => { const el = $(s), p = (i === 0 ? E.back : E.out)(clamp((t - D.OUTRO[i]) / .5));
    el.style.opacity = (clamp((t - D.OUTRO[i]) / .3) * (t < D.SRC_END ? 1 : 0)).toFixed(3); el.style.transform = `translateY(${((1 - p) * 40).toFixed(1)}px) scale(${(.9 + .1 * p).toFixed(3)})`; });
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
  const page = at(D.PAGES, t);
  if (page !== lastPage) { lastPage = page; $$('#island .page').forEach(p => p.classList.toggle('on', p.classList.contains('pg-' + page))); $$('#island .tabs b').forEach(tb => tb.classList.toggle('on', tb.dataset.pg === page)); }
  const inn = island.querySelector('.page.on'), io = clamp((o - .45) / .55);
  inn.style.opacity = io.toFixed(3); inn.style.transform = `scale(${(.94 + .06 * io).toFixed(3)}) translateY(${(-8 * (1 - io)).toFixed(1)}px)`;
  island.querySelector('.tabs').style.opacity = io.toFixed(3);
  // volume HUD: the notch widens into a level bar
  const hu = win(t, D.HUD[0], D.HUD[1], .25);
  if (hu > 0 && o < .02) {
    const hp = E.out(hu); island.style.width = (196 + 224 * hp).toFixed(1) + 'px'; island.style.height = (32 + 12 * hp).toFixed(1) + 'px';
    island.style.borderRadius = `0 0 ${(14 + 8 * hp).toFixed(1)}px ${(14 + 8 * hp).toFixed(1)}px`;
  }
  const hc = island.querySelector('.hudc'); hc.style.opacity = clamp((hu - .5) * 2).toFixed(3);
  hc.querySelector('.hb i').style.width = (45 + 25 * E.out(clamp((t - D.HUD[2]) / .3))).toFixed(1) + '%';

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
  // widget drag: the weather card follows the pointer to the right column and settles there
  const [g0, g1] = D.WDRAG, grabX = NAMED.WCX, grabY = NAMED.WCY;
  const want = t >= g1 ? 'R' : 'L';
  if (want !== wIn) { (want === 'R' ? lpR : lpL).appendChild(wcard); lpLayout(); wIn = want; }
  lp.classList.toggle('dragging', t >= g0 && t < g1); lpR.classList.toggle('over', t >= g0 && t < g1 && cx > 720);
  if (t >= g0 && t < g1) { const dx = cx - grabX, dy = cy - grabY; wcard.style.transform = `translate(${dx.toFixed(1)}px,${dy.toFixed(1)}px) scale(1.04) rotate(${clamp(dx / 80, -3, 3).toFixed(2)}deg)`; wcard.classList.add('drag'); }
  else if (t >= g1) {
    const [ex, ey] = kf(g1, cur), fromX = wPosL.x + (ex - grabX) - wPosR.x, fromY = wPosL.y + (ey - grabY) - wPosR.y, sp = E.back(clamp((t - g1) / .55));
    wcard.style.transform = sp < 1 ? `translate(${(fromX * (1 - sp)).toFixed(1)}px,${(fromY * (1 - sp)).toFixed(1)}px) scale(${(1 + .04 * (1 - sp)).toFixed(3)})` : '';
    wcard.classList.toggle('drag', sp < 1);
  } else { wcard.style.transform = ''; wcard.classList.remove('drag'); }
  gridEl.style.opacity = (1 - .75 * Math.sin(Math.PI * clamp((t - g1 + .15) / .5))).toFixed(3);

  // command bar
  const p = clamp(kf(t, D.PAL)[0], 0, 1.05);
  pal.style.opacity = clamp(p).toFixed(3); pal.style.transform = `translateX(-50%) scale(${(.96 + .04 * p).toFixed(4)})`;
  const q = typed(t, D.PAL_TYPE);
  if (q !== lastRows) { lastRows = q; palq.value = q; rows.innerHTML = D.ROWS[q] ?? D.ROWS['']; }
  let kk = null; for (const [a, z2, ks] of D.KEYS) if (t >= a && t < z2) kk = ks;
  const ko = kk ? 1 : 0; if (kk && kk.join() !== lastKeys) { lastKeys = kk.join(); keys.innerHTML = kk.map(x => `<span>${x}</span>`).join(''); }
  keys.style.opacity = ko; keys.style.transform = 'translateX(-50%)';

  // music player
  const pt = t - D.PLAYER[0], po = clamp(pt / .28) * (1 - clamp((t - D.PLAYER[1]) / .4));
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

  // Dock presets: the menu opens at the Now Playing tile; each click swaps the widget colours
  const mo = D.MENUS.reduce((m, [a, z2]) => Math.max(m, win(t, a, z2, .12)), 0);
  const pr = at(D.PRESET, t);
  if (pr !== lastPreset) { lastPreset = pr; const d = $('#mdock'); PRESETS.forEach(([k]) => d.classList.remove('p-' + k)); if (pr !== 'glass') d.classList.add('p-' + pr); buildMenu(pr); }
  dmenu.style.opacity = mo.toFixed(3); dmenu.style.transform = `scale(${(.97 + .03 * mo).toFixed(3)})`;
  $$('#dmenu .mi').forEach((m, i) => m.classList.toggle('hv', mo > .5 && Math.abs(cy - NAMED['MI' + i]) < 12));

  // window snapping: each shortcut springs the window to its new frame
  let sIdx = 0; D.SNAP.forEach(([a], i) => { if (t >= a) sIdx = i; });
  const sTo = RECT[D.SNAP[sIdx][1]], sFrom = RECT[D.SNAP[Math.max(0, sIdx - 1)][1]], sp2 = E.back(clamp((t - D.SNAP[sIdx][0]) / .5));
  const rr = sTo.map((v, i) => sFrom[i] + (v - sFrom[i]) * (sIdx ? sp2 : 1));
  winEl.style.left = rr[0].toFixed(1) + 'px'; winEl.style.top = rr[1].toFixed(1) + 'px'; winEl.style.width = rr[2].toFixed(1) + 'px'; winEl.style.height = rr[3].toFixed(1) + 'px';

  // window switcher
  const swSel = at([[0, -1], ...D.SWITCH], t), so = swSel >= 0 ? 1 : 0;
  const sw = $('#switcher'); sw.style.opacity = so; sw.style.transform = `translateX(-50%) scale(${so ? 1 : .96})`;
  if (swSel !== lastSw) { lastSw = swSel; $$('#switcher .sw').forEach((e, j) => e.classList.toggle('sel', j === swSel)); }
  let tt = null; for (const [a, z2, txt] of D.TOASTS) if (t >= a - .3 && t < z2 + .3) tt = [a, z2, txt];
  const toastEl = $('#toast'); if (tt) { toastEl.textContent = tt[2]; } toastEl.style.opacity = tt ? win(t, tt[0], tt[1], .25).toFixed(3) : 0; toastEl.style.transform = 'translateX(-50%)';

  // Act on this
  actp.classList.toggle('hl', t >= D.ACT[0] && t < D.ACT[2] + .2);
  const ao = win(t, D.ACT[1], D.ACT[2], .2); actEl.style.opacity = ao.toFixed(3); actEl.style.transform = `translateY(${(-6 * (1 - ao)).toFixed(1)}px) scale(${(.97 + .03 * ao).toFixed(3)})`;
  const res = at([[0, null], ...D.ACT_RES], t);
  if (res !== lastRes) { lastRes = res; const r = actEl.querySelector('.res'); if (res) { r.innerHTML = RES[res]; r.classList.add('on'); } else r.classList.remove('on'); $$('#act .ab b').forEach(bb => bb.classList.toggle('on', bb.dataset.a === res)); }

  // "and more": one line per beat over a frosted desktop
  const mov = win(t, D.MORE[0], D.MORE[1], .35); $('#more').style.opacity = mov.toFixed(3);
  for (let i = 0; i < D.MORE_N; i++) { const el = $('#ml' + i), st = D.MORE[0] + .25 + i * 0.46511, pp = E.out(clamp((t - st) / .4));
    el.style.opacity = pp.toFixed(3); el.style.transform = `translateY(${((1 - pp) * 24).toFixed(1)}px)`; el.style.filter = `blur(${((1 - pp) * 8).toFixed(1)}px)`; }

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
.hw.gray {{ color:#6e6e73; font-weight:600; letter-spacing:-.01em; }}
.cd {{ position:absolute; left:0; right:0; top:{int(H*0.38)}px; text-align:center; font-size:{128 if V else 112}px; font-weight:800; letter-spacing:-.045em; color:#1d1d1f; line-height:1.04; padding:0 50px; opacity:0; }}
#oicon {{ position:absolute; left:50%; border-radius:24%; box-shadow:0 20px 40px -12px rgba(0,0,0,.3); }}
.ot {{ position:absolute; left:0; right:0; text-align:center; font-weight:800; letter-spacing:-.045em; color:#1d1d1f; line-height:1.05; }}
.ot.sub {{ font-weight:600; letter-spacing:-.01em; color:#6e6e73; }}
.ot.cta {{ left:50%; right:auto; width:max-content; margin-left:-{(430 if V else 440)}px; width:{860 if V else 880}px; padding:18px 0; border-radius:999px; background:#1d1d1f; color:#fff; font-weight:600; letter-spacing:-.01em; }}
#more {{ position:absolute; inset:0; display:flex; flex-direction:column; align-items:center; justify-content:center; gap:{26 if V else 14}px; z-index:55;
  background:rgba(245,245,247,.55); backdrop-filter:blur(26px) saturate(1.4); -webkit-backdrop-filter:blur(26px) saturate(1.4); opacity:0; }}
#more .ml {{ font-size:{72 if V else 64}px; font-weight:800; letter-spacing:-.04em; color:#1d1d1f; line-height:1.08; text-align:center; padding:0 40px; opacity:0; }}
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
      {cards_html}
      {hook_html}
      {more_html}
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
