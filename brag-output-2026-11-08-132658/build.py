"""Writes the Hyperframes composition for the Cortex brag film, landscape or portrait.

    python3 build.py landscape composition
    python3 build.py portrait  composition-vertical
"""
import json, os, sys

MODE = sys.argv[1]
OUT = sys.argv[2]
V = MODE == "portrait"
W, H = (1080, 1920) if V else (1920, 1080)

B, T0 = 60 / 110, 0.27                     # beat grid of the track: ~110 BPM, first beat at 0.27 s
def beat(n): return round(T0 + n * B, 3)

SCENES = [  # id, start beat, end beat
    ("hook", None, 6), ("reveal", 6, 13), ("dock", 13, 20.5), ("notch", 20.5, 27.5),
    ("music", 27.5, 34.5), ("cmdk", 34.5, 39), ("outro", 39, 45)]
starts = {}
for sid, a, b in SCENES:
    s = 0 if a is None else beat(a)
    starts[sid] = (s, round(beat(b) - s, 3))
TOTAL = beat(45)

def L(sid, n):
    """Local time (inside scene sid) of global beat n."""
    return round(beat(n) - starts[sid][0], 3)

BASE_CSS = f"""
  #root {{ position:absolute; inset:0; overflow:hidden; font-family: Inter, sans-serif; color: var(--color-ink); }}
  .full {{ position:absolute; inset:0; }}
  .cen {{ position:absolute; left:0; right:0; text-align:center; }}
  .hero {{ font-weight:900; letter-spacing:-0.055em; line-height:0.95; }}
  .quiet {{ font-weight:400; color: rgba(245,245,247,.82); letter-spacing:-0.01em; }}
  .w {{ display:inline-block; }}
  .glowA {{ position:absolute; width:{0.9*W:.0f}px; height:{0.9*W:.0f}px; border-radius:50%; left:{-0.2*W:.0f}px; top:{-0.25*H:.0f}px;
           background: radial-gradient(circle, rgba(255,69,58,.30), rgba(255,69,58,0) 62%); }}
  .glowB {{ position:absolute; width:{0.8*W:.0f}px; height:{0.8*W:.0f}px; border-radius:50%; right:{-0.2*W:.0f}px; top:{-0.1*H:.0f}px;
           background: radial-gradient(circle, rgba(10,132,255,.26), rgba(10,132,255,0) 62%); }}
  .glowC {{ position:absolute; width:{0.7*W:.0f}px; height:{0.7*W:.0f}px; border-radius:50%; left:{0.15*W:.0f}px; bottom:{-0.3*H:.0f}px;
           background: radial-gradient(circle, rgba(255,159,10,.18), rgba(255,159,10,0) 62%); }}
"""

def words(text, cls="w", prefix="w"):
    out, i = [], 0
    for line in text.split("|"):
        parts = []
        for word in line.split(" "):
            parts.append(f'<span class="{cls}" id="{prefix}{i}">{word}</span>')
            i += 1
        out.append(" ".join(parts))
    return "<br>".join(out), i

def scene(sid, css, body, js):
    s, d = starts[sid]
    return f"""<template>
<style>
{BASE_CSS}
{css}
</style>
<div id="root" data-composition-id="{sid}" data-width="{W}" data-height="{H}">
{body}
</div>
<script>
  const tl = gsap.timeline({{ paused: true }});
  const D = {d};
{js}
  window.__timelines["{sid}"] = tl;
</script>
</template>
"""

def glows(sid):
    return f'<div class="full" id="{sid}-bg" style="background:var(--color-ground)"></div><div class="glowA" id="{sid}-ga"></div><div class="glowB" id="{sid}-gb"></div><div class="glowC" id="{sid}-gc"></div>'

def drift(sid):
    # the light behind the stage turns slowly: the world moves, the titles don't
    return f"""
  tl.fromTo("#{sid}-ga", {{ x: 0, y: 0 }}, {{ x: {0.06*W:.0f}, y: {0.04*H:.0f}, duration: D, ease: "none" }}, 0);
  tl.fromTo("#{sid}-gb", {{ x: 0, y: 0 }}, {{ x: {-0.05*W:.0f}, y: {0.05*H:.0f}, duration: D, ease: "none" }}, 0);
  tl.fromTo("#{sid}-gc", {{ x: 0 }}, {{ x: {0.05*W:.0f}, duration: D, ease: "none" }}, 0);"""

def exit_all(sel, at):
    return f'  tl.to("{sel}", {{ opacity: 0, filter: "blur(8px)", duration: 0.16, ease: "power3.in" }}, {at});\n'

files = {}

# 1 · Hook — one word per beat, then "One app."
hw = ["Launchpad.", "Dock.", "Notch.", "Music."]
big = 150 if V else 230
body = glows("hook") + "".join(
    f'<div class="cen hero" id="hk{i}" style="top:{(H-big)/2-40:.0f}px;font-size:{big}px;opacity:0">{w}</div>' for i, w in enumerate(hw))
one = "One app."
letters = "".join(f'<span class="w" id="ol{i}" style="opacity:0">{c if c != " " else "&nbsp;"}</span>' for i, c in enumerate(one))
body += f'<div class="cen hero" id="hk-one" style="top:{(H-big)/2-40:.0f}px;font-size:{big}px">{letters}</div>'
js = drift("hook")
for i in range(4):
    t = beat(i)
    js += f'  tl.fromTo("#hk{i}", {{ opacity: 0, scale: 1.14, filter: "blur(14px)" }}, {{ opacity: 1, scale: 1, filter: "blur(0px)", duration: 0.2, ease: "expo.out" }}, {t});\n'
    js += f'  tl.to("#hk{i}", {{ opacity: 0, filter: "blur(10px)", duration: 0.1, ease: "power3.in" }}, {round(beat(i+1)-0.1,3)});\n'
for i in range(len(one)):
    js += f'  tl.fromTo("#ol{i}", {{ opacity: 0.0, y: 30, filter: "blur(6px)" }}, {{ opacity: 1, y: 0, filter: "blur(0px)", duration: 0.28, ease: "expo.out" }}, {round(beat(4)+i*0.035,3)});\n'
js += exit_all("#hk-one", round(starts["hook"][1]-0.17,3))
files["hook"] = scene("hook", "", body, js)

# 2 · Reveal — icon + name, the launcher tilts up into frame, then a punch-in on the widgets
macW = 980 if V else 1180
macTop = 620 if V else 330
cap, ncap = words("All your apps.|Plus your day." if V else "All your apps. Plus your day.", prefix="rc")
body = glows("reveal") + f"""
<div class="cen" id="rv-brand" style="top:{220 if V else 70}px">
  <img id="rv-icon" src="assets/img/cortex-icon-256.png" style="width:{120 if V else 110}px;height:{120 if V else 110}px;border-radius:26px;vertical-align:middle;display:inline-block">
  <span class="hero" id="rv-name" style="font-size:{110 if V else 110}px;vertical-align:middle;margin-left:22px;display:inline-block">Cortex</span>
</div>
<div class="cen quiet" id="rv-cap" style="top:{380 if V else 210}px;font-size:{50 if V else 46}px;line-height:1.2">{cap}</div>
<div id="rv-stage" style="position:absolute;left:{(W-macW)/2:.0f}px;top:{macTop}px;width:{macW}px;perspective:1600px">
  <div id="rv-mac">
    <div style="border-radius:22px 22px 6px 6px;overflow:hidden;border:12px solid #1b1b20;border-bottom-width:16px;box-shadow:0 50px 140px rgba(0,0,0,.7);background:#000">
      <img src="assets/img/launcher.jpg" style="width:100%;display:block">
    </div>
    <div style="height:20px;margin:0 -5%;background:linear-gradient(#cfd0d4,#8e8f94);border-radius:0 0 16px 16px"></div>
  </div>
</div>"""
js = drift("reveal")
js += '  tl.fromTo("#rv-icon", { opacity: 0, scale: 0.4, rotation: -12 }, { opacity: 1, scale: 1, rotation: 0, duration: 0.55, ease: "back.out(1.6)" }, 0.02);\n'
js += '  tl.fromTo("#rv-name", { opacity: 0, x: -24, filter: "blur(8px)" }, { opacity: 1, x: 0, filter: "blur(0px)", duration: 0.3, ease: "expo.out" }, 0.12);\n'
js += f'  tl.fromTo("#rv-mac", {{ y: {H*0.6:.0f}, rotationX: 38, scale: 0.9, transformOrigin: "50% 100%" }}, {{ y: 0, rotationX: 0, scale: 1, duration: 1.0, ease: "expo.out" }}, {L("reveal",7)});\n'
for i in range(ncap):
    js += f'  tl.fromTo("#rc{i}", {{ opacity: 0, filter: "blur(6px)" }}, {{ opacity: 1, filter: "blur(0px)", duration: 0.14, ease: "power4.out" }}, {round(L("reveal",8)+i*0.07,3)});\n'
# punch-in on the sidebar widgets (left side of the screenshot)
px, ps = (macW*0.36, 1.7) if not V else (macW*0.34, 1.7)
js += f'  tl.to("#rv-mac", {{ scale: {ps}, x: {px:.0f}, y: {(-60 if not V else -120)}, duration: 0.7, ease: "power3.inOut", transformOrigin: "0% 30%" }}, {L("reveal",10.5)});\n'
js += f'  tl.to("#rv-brand, #rv-cap", {{ opacity: 0, y: -40, filter: "blur(8px)", duration: 0.25, ease: "power3.in" }}, {round(L("reveal",10.5)-0.05,3)});\n'
js += exit_all("#rv-stage", round(starts["reveal"][1]-0.17,3))
files["reveal"] = scene("reveal", "", body, js)

# 3 · Dock — colour flood, the Dock whips up, punch-in on its widgets, presets drop in
t3, n3 = words("Truly|your Dock." if V else "Truly your Dock.", prefix="dt")
presets = [("Morning Tide", "#ffcc78", "#f58c4c"), ("Midnight Focus", "#3d3379", "#0f0f29"), ("Ocean Desk", "#409efa", "#1a40ad")]
chipW = 300 if V else 330
chips = ""
for i, (n, a, b) in enumerate(presets):
    left = (W - chipW) / 2 if V else W/2 - 1.5*chipW - 30 + i*(chipW+30)
    top = (1180 + i*190) if V else 790
    sw = "".join(f'<i style="display:block;flex:1;height:{62 if V else 56}px;border-radius:14px;background:linear-gradient(135deg,{a},{b})"></i>' for _ in range(3))
    chips += f'''<div id="pc{i}" style="position:absolute;left:{left:.0f}px;top:{top}px;width:{chipW}px;opacity:0">
      <div style="display:flex;gap:8px;padding:10px;border-radius:20px;background:rgba(255,255,255,.14)">{sw}<i style="display:block;width:{62 if V else 56}px;height:{62 if V else 56}px;border-radius:14px;background:rgba(255,255,255,.9)"></i></div>
      <div style="text-align:center;font-weight:700;font-size:{34 if V else 28}px;margin-top:12px">{n}</div></div>'''
dockW = W - (60 if V else 320)
dockSrc = "dock-widgets.jpg" if V else "dock.jpg"
body = f"""
<div class="full" style="background:var(--color-ground)"></div>
<div class="full" id="dk-flood" style="opacity:0;background:radial-gradient(80% 90% at 10% 0%,#ff7a45,transparent 60%),radial-gradient(70% 80% at 100% 100%,#c2185b,transparent 60%),#5a1c2a"></div>
<div class="cen hero" id="dk-title" style="top:{260 if V else 120}px;font-size:{150 if V else 140}px">{t3}</div>
<div class="cen quiet" id="dk-sub" style="top:{600 if V else 290}px;font-size:{44 if V else 40}px;color:rgba(255,255,255,.85);opacity:0">Widgets right in the bar · one-click presets</div>
<div id="dk-wrap" style="position:absolute;left:{(W-dockW)/2:.0f}px;top:{820 if V else 440}px;width:{dockW}px">
  <img id="dk-img" src="assets/img/{dockSrc}" style="width:100%;display:block;border-radius:26px;box-shadow:0 30px 80px rgba(0,0,0,.45)">
</div>
{chips}"""
js = '  tl.fromTo("#dk-flood", { opacity: 0 }, { opacity: 1, duration: 0.4, ease: "power2.inOut" }, 0);\n'
for i in range(n3):
    js += f'  tl.fromTo("#dt{i}", {{ opacity: 0.15 }}, {{ opacity: 1, duration: 0.12, ease: "none" }}, {round(0.12+i*0.09,3)});\n'
js += f'  tl.fromTo("#dk-sub", {{ opacity: 0, filter: "blur(8px)" }}, {{ opacity: 1, filter: "blur(0px)", duration: 0.18, ease: "power4.out" }}, {L("dock",14.5)});\n'
js += f'  tl.fromTo("#dk-wrap", {{ y: {H*0.5:.0f}, filter: "blur(14px)" }}, {{ y: 0, filter: "blur(0px)", duration: 0.45, ease: "expo.out" }}, {L("dock",14)});\n'
if not V:  # punch-in on the widget half of the bar, then back out as the presets arrive
    js += f'  tl.to("#dk-wrap", {{ scale: 1.9, x: {-dockW*0.33:.0f}, y: 60, duration: 0.6, ease: "power3.inOut" }}, {L("dock",15.5)});\n'
    js += f'  tl.to("#dk-wrap", {{ scale: 1, x: 0, y: -30, duration: 0.55, ease: "power3.inOut" }}, {L("dock",17.5)});\n'
else:
    js += f'  tl.fromTo("#dk-wrap", {{ scale: 1 }}, {{ scale: 1.06, duration: 0.6, ease: "power3.inOut" }}, {L("dock",15.5)});\n'
for i in range(3):
    js += f'  tl.fromTo("#pc{i}", {{ opacity: 0, y: 60, scale: 0.9 }}, {{ opacity: 1, y: 0, scale: 1, duration: 0.5, ease: "back.out(1.5)" }}, {round(L("dock",18)+i*0.12,3)});\n'
js += exit_all("#dk-title, #dk-sub, #dk-wrap, #pc0, #pc1, #pc2", round(starts["dock"][1]-0.17,3))
files["dock"] = scene("dock", "", body, js)

# 4 · Notch — the pill morphs into the Island Home page
islW, islH = (1000, 760) if V else (1180, 430)
cols = "1fr 1fr" if V else "1.7fr .8fr 1fr"
rows = "grid-template-rows:1.25fr 1fr;" if V else ""
fs = 1.4 if V else 1.3
t4, n4 = words("Hello,|notch." if V else "Hello, notch.", prefix="nt")
body = glows("notch") + f"""
<div id="nt-pill" style="position:absolute;left:{(W-islW)/2:.0f}px;top:0;width:{islW}px;height:{islH}px;background:#000;border-radius:0 0 {56 if V else 46}px {56 if V else 46}px;box-shadow:0 40px 100px rgba(0,0,0,.6)"></div>
<div id="nt-cards" style="position:absolute;left:{(W-islW)/2+24:.0f}px;top:24px;width:{islW-48}px;height:{islH-48}px;display:grid;grid-template-columns:{cols};{rows}gap:16px">
  <div id="nc0" style="border-radius:28px;position:relative;overflow:hidden;background:linear-gradient(135deg,#ff6a3d,#b5179e 55%,#3a0ca3);{'grid-column:1/-1;' if V else ''}">
    <div style="position:absolute;inset:0;background:linear-gradient(transparent 25%,rgba(0,0,0,.75))"></div>
    <div style="position:absolute;left:24px;right:24px;bottom:22px">
      <div style="font-weight:700;font-size:{30*fs:.0f}px">Night Drive</div>
      <div style="font-size:{19*fs:.0f}px;opacity:.75">The Example Band</div>
      <div style="height:6px;border-radius:3px;background:rgba(255,255,255,.25);margin-top:14px"><div id="nt-prog" style="height:6px;border-radius:3px;background:#fff;width:100%;transform-origin:0 50%"></div></div>
    </div>
  </div>
  <div id="nc1" style="border-radius:28px;background:rgba(255,255,255,.09);display:flex;flex-direction:column;align-items:center;justify-content:center">
    <div style="color:#ff453a;font-weight:700;font-size:{24*fs:.0f}px">Sun</div>
    <div style="font-size:{110*fs:.0f}px;line-height:1;font-weight:700">8</div>
    <div style="font-size:{18*fs:.0f}px;color:rgba(245,245,247,.45);margin-top:6px">November</div>
  </div>
  <div id="nc2" style="border-radius:28px;background:rgba(255,255,255,.09);padding:24px;font-weight:700;font-size:{30*fs:.0f}px;line-height:1.2">
    27° <span style="color:rgba(245,245,247,.42)">now in</span><br>your city<br><span style="color:rgba(245,245,247,.42)">H</span> 31° <span style="color:rgba(245,245,247,.42)">L</span> 24°<br>☾ Clear
  </div>
</div>
<div class="cen hero" id="nt-title" style="top:{1000 if V else 600}px;font-size:{150 if V else 150}px">{t4}</div>
<div class="cen quiet" id="nt-sub" style="top:{1340 if V else 790}px;font-size:{44 if V else 42}px;opacity:0">Music, date and weather{'<br>' if V else ' '}— one hover away</div>"""
js = drift("notch")
js += f'  tl.fromTo("#nt-pill", {{ scaleX: {300/islW:.3f}, scaleY: {44/islH:.3f}, transformOrigin: "50% 0%" }}, {{ scaleX: 1, scaleY: 1, duration: 0.8, ease: "power3.inOut" }}, 0.12);\n'
for i in range(3):
    js += f'  tl.fromTo("#nc{i}", {{ opacity: 0, y: -20, scale: 0.96 }}, {{ opacity: 1, y: 0, scale: 1, duration: 0.45, ease: "expo.out" }}, {round(0.72+i*0.08,3)});\n'
js += '  tl.fromTo("#nt-prog", { scaleX: 0.25 }, { scaleX: 0.62, duration: D, ease: "none" }, 0);\n'
for i in range(n4):
    js += f'  tl.fromTo("#nt{i}", {{ opacity: 0, filter: "blur(6px)" }}, {{ opacity: 1, filter: "blur(0px)", duration: 0.14, ease: "power4.out" }}, {round(L("notch",22.4)+i*0.08,3)});\n'
js += f'  tl.fromTo("#nt-sub", {{ opacity: 0, filter: "blur(8px)" }}, {{ opacity: 1, filter: "blur(0px)", duration: 0.18, ease: "power4.out" }}, {L("notch",23.2)});\n'
js += exit_all("#nt-pill, #nt-cards, #nt-title, #nt-sub", round(starts["notch"][1]-0.17,3))
files["notch"] = scene("notch", "", body, js)

# 5 · Music — sleeve slides in, the coloured vinyl slides out and spins, the sung line fills with light
t5, n5 = words("Your song,|full screen." if V else "Your song, full screen.", prefix="mt")
sx, sy, ss = (60, 470, 0.95) if V else (170, 260, 1)
lx, ly, lw = (80, 1180, 920) if V else (1110, 360, 720)
lfs = 56 if V else 48
body = f"""
<div class="full" style="background:radial-gradient(70% 90% at 20% 30%,#8f1d2c,transparent 70%),radial-gradient(60% 80% at 90% 80%,#3b0d1c,transparent 70%),#1a070c"></div>
<div class="cen hero" id="mu-title" style="top:{170 if V else 70}px;font-size:{120 if V else 100}px">{t5}</div>
<div id="mu-sleeve" style="position:absolute;left:{sx}px;top:{sy}px;width:840px;height:560px;transform-origin:0 0">
  <div id="mu-recw" style="position:absolute;top:14px;left:0;width:530px;height:530px">
    <div id="mu-rec" style="width:530px;height:530px;border-radius:50%;box-shadow:12px 16px 50px rgba(0,0,0,.5);
      background:radial-gradient(circle,#ddd 0 3%,#0e0e10 3.2% 18%,transparent 18.5%),repeating-radial-gradient(circle,rgba(0,0,0,.25) 0 1px,transparent 1px 5px),radial-gradient(circle,#ff3d6e 0 45%,#7a0f2b 70%,#120408 100%)"></div>
  </div>
  <div id="mu-art" style="position:absolute;left:0;top:0;width:560px;height:560px;border-radius:6px;box-shadow:20px 30px 70px rgba(0,0,0,.6);
    background:conic-gradient(from 210deg at 35% 40%,#ff9a3c,#ff3d6e,#7b2ff7,#1fb5d6,#ff9a3c)">
    <div style="position:absolute;left:26px;bottom:22px;font-weight:900;letter-spacing:.08em;font-size:36px">NIGHT DRIVE</div>
  </div>
</div>
<div id="mu-lyr" style="position:absolute;left:{lx}px;top:{ly}px;width:{lw}px;font-weight:900;letter-spacing:-.02em;font-size:{lfs}px;line-height:1.15">
  <div id="ly0" style="color:rgba(255,255,255,.3);margin:18px 0">Headlights on the open road</div>
  <div style="position:relative;margin:18px 0">
    <div style="color:rgba(255,255,255,.3)">Turn it up and let it go</div>
    <div id="ly1" style="position:absolute;inset:0;color:#fff;clip-path:inset(0 100% 0 0);text-shadow:0 0 22px rgba(255,255,255,.35)">Turn it up and let it go</div>
  </div>
  <div id="ly2" style="color:rgba(255,255,255,.3);margin:18px 0">Every street light knows our name</div>
</div>"""
js = ""
for i in range(n5):
    js += f'  tl.fromTo("#mt{i}", {{ opacity: 0, filter: "blur(6px)" }}, {{ opacity: 1, filter: "blur(0px)", duration: 0.14, ease: "power4.out" }}, {round(0.05+i*0.07,3)});\n'
js += f'  tl.fromTo("#mu-sleeve", {{ x: -700, scale: {ss} }}, {{ x: 0, scale: {ss}, duration: 0.6, ease: "expo.out" }}, {L("music",28)});\n'
js += f'  tl.fromTo("#mu-recw", {{ x: 0 }}, {{ x: 300, duration: 0.9, ease: "power3.inOut" }}, {L("music",29)});\n'
js += '  tl.fromTo("#mu-rec", { rotation: 0 }, { rotation: 300, duration: D, ease: "none" }, 0);\n'
js += f'  tl.fromTo("#mu-lyr", {{ opacity: 0, y: 30 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: "expo.out" }}, {L("music",29.5)});\n'
js += f'  tl.fromTo("#ly1", {{ clipPath: "inset(0 100% 0 0)" }}, {{ clipPath: "inset(0 0% 0 0)", duration: 1.6, ease: "none" }}, {L("music",30.0)});\n'
js += exit_all("#mu-title, #mu-sleeve, #mu-lyr", round(starts["music"][1]-0.17,3))
files["music"] = scene("music", "", body, js)

# 6 · ⌘K montage — four real screens, one per beat
shots = ["palette-home", "palette-convert", "palette-emoji", "palette-calc"]
labels = ["Running apps on top", "10 km → mi", ":heart  emoji", "12*(3+4)"]
cw = 900 if V else 760
body = glows("cmdk") + f'<div class="cen hero" id="ck-title" style="top:{230 if V else 110}px;font-size:{140 if V else 120}px">⌘K</div>'
body += f'<div class="cen quiet" id="ck-sub" style="top:{400 if V else 250}px;font-size:{46 if V else 42}px">Type it. It\'s done.</div>'
for i, s in enumerate(shots):
    body += f'<div id="ck{i}" style="position:absolute;left:{(W-cw)/2:.0f}px;top:{560 if V else 350}px;width:{cw}px;opacity:0"><img src="assets/img/{s}.jpg" style="width:100%;display:block;border-radius:28px;box-shadow:0 40px 100px rgba(0,0,0,.6)"></div>'
js = drift("cmdk")
js += '  tl.fromTo("#ck-title", { opacity: 0, filter: "blur(10px)", scale: 1.1 }, { opacity: 1, filter: "blur(0px)", scale: 1, duration: 0.2, ease: "expo.out" }, 0);\n'
js += '  tl.fromTo("#ck-sub", { opacity: 0 }, { opacity: 1, duration: 0.15, ease: "power4.out" }, 0.15);\n'
for i in range(4):
    t = round(L("cmdk", 34.5 + i), 3)
    js += f'  tl.fromTo("#ck{i}", {{ opacity: 0, scale: 1.05, filter: "blur(10px)" }}, {{ opacity: 1, scale: 1, filter: "blur(0px)", duration: 0.16, ease: "expo.out" }}, {max(t,0.05)});\n'
    if i < 3:
        js += f'  tl.to("#ck{i}", {{ opacity: 0, filter: "blur(8px)", duration: 0.12, ease: "power3.in" }}, {round(L("cmdk", 35.5 + i)-0.1,3)});\n'
js += exit_all("#ck-title, #ck-sub, #ck3", round(starts["cmdk"][1]-0.17,3))
files["cmdk"] = scene("cmdk", "", body, js)

# 7 · Outro — icon springs in, the name per letter, what it is, where to get it
name = "Cortex"
nl = "".join(f'<span class="w" id="on{i}">{c}</span>' for i, c in enumerate(name))
tag, nt = words("Launcher · Dock · Notch|Music · ⌘K" if V else "Launcher · Dock · Notch · Music · ⌘K", prefix="ot")
body = glows("outro") + f"""
<div class="cen" style="top:{660 if V else 190}px"><img id="o-icon" src="assets/img/cortex-icon-256.png" style="width:{240 if V else 210}px;height:{240 if V else 210}px;border-radius:50px;display:inline-block"></div>
<div class="cen hero" id="o-name" style="top:{970 if V else 440}px;font-size:{180 if V else 170}px">{nl}</div>
<div class="cen" id="o-tag" style="top:{1190 if V else 640}px;font-size:{52 if V else 50}px;font-weight:700;line-height:1.25;color:rgba(245,245,247,.82)">{tag}</div>
<div class="cen" id="o-cta" style="top:{1420 if V else 790}px;opacity:0">
  <span style="display:inline-block;font-size:{40 if V else 34}px;font-weight:700;padding:18px 34px;border-radius:999px;background:#fff;color:#000">Free for macOS · cortex.raycode.tech</span>
</div>"""
js = drift("outro")
js += '  tl.fromTo("#o-icon", { opacity: 0, y: -80, scale: 0.6 }, { opacity: 1, y: 0, scale: 1, duration: 0.7, ease: "back.out(1.7)" }, 0.02);\n'
for i in range(len(name)):
    js += f'  tl.fromTo("#on{i}", {{ opacity: 0.3, filter: "blur(4px)" }}, {{ opacity: 1, filter: "blur(0px)", duration: 0.2, ease: "power4.out" }}, {round(L("outro",39.5)+i*0.06,3)});\n'
for i in range(nt):
    js += f'  tl.fromTo("#ot{i}", {{ opacity: 0, filter: "blur(6px)" }}, {{ opacity: 1, filter: "blur(0px)", duration: 0.14, ease: "power4.out" }}, {round(L("outro",40.5)+i*0.06,3)});\n'
js += f'  tl.fromTo("#o-cta", {{ opacity: 0, y: 20 }}, {{ opacity: 1, y: 0, duration: 0.45, ease: "expo.out" }}, {L("outro",41.15)});\n'
files["outro"] = scene("outro", "", body, js)

# Root: scene hosts + music + sound on the visible actions
os.makedirs(f"{OUT}/compositions", exist_ok=True)
for sid, src in files.items():
    open(f"{OUT}/compositions/{sid}.html", "w").write(src)
hosts = ""
for i, (sid, _, _) in enumerate(SCENES):
    s, d = starts[sid]
    hosts += f'      <div id="{sid}" data-composition-id="{sid}" data-composition-src="compositions/{sid}.html" data-start="{s}" data-duration="{d}" data-track-index="{i+1}" data-track-kind="graphics" data-width="{W}" data-height="{H}"></div>\n'
sfx = []
for i in range(4): sfx.append(("click", beat(i), 0.22))
sfx.append(("impact", beat(4), 0.32))
for sid in ["reveal", "dock", "notch", "music", "outro"]: sfx.append(("impact", starts[sid][0], 0.3))
sfx.append(("swish", beat(14), 0.3))
sfx.append(("drop", round(starts["dock"][0] + L("dock", 18), 3), 0.25))
for i in range(4): sfx.append(("click", beat(34.5 + i), 0.2))
sfx.append(("drop", round(starts["outro"][0] + 0.05, 3), 0.3))
audio = f'      <audio id="music" class="clip" src="assets/music.mp3" data-start="0" data-duration="{TOTAL}" data-volume="0.85" data-fade-out="1.4" data-track-index="20"></audio>\n'
for k, (name_, t, v) in enumerate(sfx):
    audio += f'      <audio id="sfx{k}" class="clip" src="assets/sfx/{name_}.ogg" data-start="{t}" data-duration="{ {"click": 0.01, "impact": 0.18, "swish": 0.06, "drop": 0.11}[name_] }" data-volume="{v}" data-track-index="{21+k}"></audio>\n'
variables = json.dumps([
    {"id": "color-ground", "type": "color", "label": "Background", "default": "#0b0b0f"},
    {"id": "color-ink", "type": "color", "label": "Text", "default": "#f5f5f7"},
])
index = f"""<!doctype html>
<html lang="en" data-resolution="{'portrait' if V else 'landscape'}" data-composition-variables='{variables}'>
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width={W}, height={H}" />
    <script src="assets/gsap.min.js"></script>
    <style>
      :root {{ --color-ground: #0b0b0f; --color-ink: #f5f5f7; }}
      * {{ margin: 0; padding: 0; box-sizing: border-box; }}
      html, body {{ width: {W}px; height: {H}px; overflow: hidden; background: var(--color-ground); }}
      #root {{ width: 100%; height: 100%; font-family: Inter, sans-serif; }}
    </style>
  </head>
  <body>
    <div id="root" data-composition-id="main" data-start="0" data-duration="{TOTAL}" data-width="{W}" data-height="{H}">
{hosts}{audio}    </div>
    <script>
      window.__timelines = window.__timelines || {{}};
      window.__timelines["main"] = gsap.timeline({{ paused: true }});
    </script>
  </body>
</html>
"""
open(f"{OUT}/index.html", "w").write(index)
print("wrote", OUT, "duration", TOTAL, {k: v for k, v in starts.items()})
