# AIO on Instagram and YouTube — the playbook

Everything in order: **1 what you're selling → 2 the flow of every video → 3 create the accounts → 4 what to post (all of it is made)
→ 5 calendar → 6 reach → 7 numbers → 8 launch day.** Confidence tags: [Certain] / [Likely] / [Guessing].

## 0. The three things that decide whether this works

1. **⌘K is the product.** Every video leads with it, every end card says "⌘K · Launcher · Dock · Notch · Music". The Dock, notch and
   Launcher are the reasons to *stay*; ⌘K is the reason to *install*. (The film, covers and carousels were all re-cut that way.)
2. **The first-launch warning loses installs.** macOS says "could not verify AIO is free of malware" because the app isn't notarized.
   You've got a post (`install-in-60s`) and a line in every description for it. A $99/year Apple Developer account removes the warning
   for good and is the best money you can spend on conversion [Likely].
3. **Real screen recordings beat the website film.** The film is a recreation of the UI. Post it as "interactive demo", and post real
   recordings from `record/` as soon as you have them (a Reel of the real app is more believable and gets fewer "is this real?" comments).

## 1. The flow of every video (so it never "directly goes into features")

```
0.0 – 2.6 s   HOOK      a full-screen statement or question, no UI yet            "One bar for your whole Mac."
2.6 – ...     DEMO      the real screen, one idea, captions say what you're seeing  "Maths. Instantly." → "Any unit." → …
last 3.8 s    PAYOFF    end card: AIO · what it is · aio.raycode.tech · "Free for macOS · Link in bio" · "Follow for more Mac tricks"
```

The hero film (a long one, 54–67 s) has a longer version of the same shape:

| Time | Beat | What's on screen |
|---|---|---|
| 0:00–0:07 | **Problem** | five text cards: "Spotlight to search." → "Launchpad to open." → "A Dock to switch." → "A notch you ignore." → "What if one bar did it all?" |
| 0:07–0:10 | **Reveal** | the music drops, "AIO." slams in, "One bar. Your whole Mac." |
| 0:10–0:28 | **⌘K (the hero)** | five queries: maths, units, live currency, "event lunch tomorrow 1pm", emoji |
| 0:28–0:43 | **It's also…** | the notch, the Dock with presets, the Launcher with widgets you move |
| 0:43–1:00 | **Power moves** | snap windows, ⌥⇥ switcher, Act on this, music, desktop widgets |
| 1:00–1:07 | **CTA** | end card, URL held for 4+ seconds |

Rules that keep retention up [Likely]: one idea per video; the hook is readable in under a second; something moves in the
first frame; captions on everything (most people watch muted); the URL is on screen for ≥3 s at the end and in the caption.

## 2. What's been made for you

| What | Where | Use it for |
|---|---|---|
| Hero film, vertical 1080×1920 | `film/aio-film-vertical.mp4` | **Reel #1**, YouTube Short #1, TikTok |
| Hero film, landscape 1920×1080 | `film/aio-film.mp4` | the **YouTube channel trailer** and first video |
| 8 Reel covers | `social/covers/*.png` | Reel cover (set it when you post) |
| 3 carousels (25 slides) | `social/posts/<set>/NN.png` | Instagram feed posts (upload in order) |
| Avatar, YouTube banner, thumbnail | `social/avatar-1080.png`, `youtube-banner-2560x1440.png`, `thumbnail-1280x720.jpg` | profiles |
| Recording + editing scripts | `record/` (read `record/README.md`) | the 8 feature Reels and a long YouTube video, from the *real* app |
| Hook cards, caption pills, end cards | `record/edit/assets/` | used by the editor; regenerate with `node social/make-cards.js` |

## 3. Create the accounts — exact steps

Do both on the same day, use **the same handle** on both. Handles in use: **`aio.mac`** on Instagram and **`@aiomac`** on YouTube. On YouTube `@aio`, `@getaio` and `@aioapp` are taken [Likely]; `@aiomac` and
`@aio.mac` looked free when checked. Instagram can't be checked without logging in: try `aio.mac`, then `aiomac`, `getaio.app`,
`useaio.mac`. If you get a different handle, tell me and I'll update every card.

### 3.0 Before you start (10 minutes)
1. Make a **dedicated brand email**. Best: `hello@raycode.tech` using Cloudflare Email Routing (free, forwards to your inbox) if your
   domain is on Cloudflare; otherwise a new Gmail like `aio.mac.app@gmail.com`. Don't use your personal address [Likely: it keeps
   account recovery and spam separate].
2. Install an authenticator app (1Password, Authy, Google Authenticator) and a password manager. Create one strong password per site.
3. Put the files from §2 on your phone (AirDrop `avatar-1080.png`, the vertical film, a cover and the first carousel).

### 3.1 Instagram (phone)
1. App Store → **Instagram** → open → **Create new account** → sign up with **the brand email** → enter the code it sends.
2. **Username:** the handle above. **Name:** `AIO | ⌘K for your Mac` (the name field is searchable; 30 characters max).
   **Password:** from your password manager. Birthday: yours (it isn't shown).
3. Skip "find friends" and contacts sync. **Profile picture:** `avatar-1080.png`.
4. **Switch to a professional account:** Profile → ☰ → **Settings and activity** → **Account type and tools** →
   **Switch to professional account** → **Creator** (or Business) → category **Software** (or *Product/service*) → skip contact info
   or add the brand email. [Certain: this unlocks Insights, which you need for §7.]
5. **Edit profile → Bio** (paste this, line breaks included):
   ```
   ⌘K for your whole Mac.
   Launcher · Dock · Notch · Music. Free.
   Try the demo in your browser 👇
   ```
   **Links → Add external link:** `https://aio.raycode.tech` (title: `AIO for Mac`).
6. **Security:** Settings → **Accounts Center** → **Password and security** → **Two-factor authentication** → authentication app.
7. **Don't post yet.** Seed the profile first (§3.3), then announce.

### 3.2 YouTube (computer; Shorts later from the phone or the same Studio)
1. Go to **youtube.com**, sign in with the brand Google account (create one if needed: it needs a phone number for verification).
2. Click your profile picture → **Create a channel**. **Name:** `AIO` (or `AIO — ⌘K for Mac`, which is easier to find in search). **Handle:** `aiomac` (the page tells
   you if it's taken). Upload `avatar-1080.png`. **Create channel.**
3. Open **YouTube Studio** (studio.youtube.com) → **Customization**:
   * **Branding:** picture = avatar; **banner image** = `youtube-banner-2560x1440.png`; **video watermark** = the AIO icon.
   * **Basic info → Description** (paste):
     ```
     AIO is a free Mac app that puts ⌘K, a launcher, a Dock with live widgets, a notch Island and a full-screen music player in one place.
     Short videos on what it does and how to set it up.
     Try the demo in your browser: https://aio.raycode.tech
     ```
   * **Links:** *Website* → `https://aio.raycode.tech`; *GitHub* → `https://github.com/rayanjainn/aio`. **Contact email:** the brand email.
4. **Verify your phone** (Studio → Settings → Channel → Feature eligibility → Intermediate features → *Verify phone number*).
   [Certain: needed for custom thumbnails and long videos.]
5. **Channel trailer:** upload the landscape hero film first (§3.4), then Customization → **Layout → Video spotlight** → *Channel trailer
   for people who haven't subscribed* → pick it.
6. **Create the playlists** now so uploads have a home: `⌘K`, `Windows`, `Dock & notch`, `Music`, `Setup`.
7. **Security:** myaccount.google.com → Security → **2-Step Verification**.

### 3.3 Seed the profiles before you announce (Day 1–2)
A profile with 0 posts converts almost nobody [Likely]. Before telling anyone:
* **Instagram:** post **3 Reels** (hero, ⌘K, notch) and **2 carousels** (`aio-in-8-slides`, `cmdk-7-things`). Add Story **Highlights**:
  `Install`, `⌘K`, `Features` (use the carousel slides).
* **YouTube:** upload the hero film (trailer), the hero as a Short, and one feature Short.

### 3.4 Upload the first things — exact clicks
**Instagram Reel (the hero):** **+** → **Reel** → pick `film/aio-film-vertical.mp4` → *Next* → **Edit cover** → *Add from camera roll* →
`social/covers/cmdk.png` → *Add audio* (optional: a quiet trending track from Instagram's library; see §6) → *Next* → paste the caption
below → **Tag topics:** `macOS`, `Productivity` → turn **Also share to Facebook** off → **Share**. Then post a first comment with the
install tip (below), **pin it**, and share the Reel to your Story.

**YouTube video:** Studio → **Create → Upload videos** → `film/aio-film.mp4` → title/description from §4.1 → **Thumbnail:**
`thumbnail-1280x720.jpg` → *Playlists:* ⌘K → *Audience:* **No, it's not made for kids** → Next → **Add an end screen** in the last
10–20 s (video 1 + subscribe) → **Visibility: Public** → Save. **YouTube Short:** same Create → Upload with the vertical file (≤3 min,
vertical = Short automatically); put `https://aio.raycode.tech` in the description's first line.

## 4. What to post

### 4.1 The hero (Day 1) — Reel, Short and YouTube video
**Instagram caption:**
```
One bar for your whole Mac. Press ⌘K.
Maths, units, live currency, "event lunch tomorrow 1pm", emoji, every app. Plus a Launcher, a Dock with live widgets and a notch that finally does something.
Free for macOS: aio.raycode.tech (link in bio). This is an interactive demo of the UI; real screen recordings are coming.
Save this for later 🔖
#macos #macapps #mac #productivity #macsetup
```
**Pinned first comment:** `First launch: macOS may say it "could not verify AIO". Run  xattr -cr /Applications/AIO.app  in Terminal once, or Settings → Privacy & Security → Open Anyway. Full steps in the install post 👆`

**YouTube title:** `AIO — one bar for your whole Mac (⌘K, Launcher, Dock, Notch)` · **Short title:** `One bar for your whole Mac ⌘K #macos`
**YouTube description:**
```
AIO is a free Mac app: press ⌘K for maths, unit and currency conversion, quick-add events, emoji and every app, plus a Launcher with widgets you can move, a Dock with live widgets and presets, a notch Island, window snapping, a window switcher, Act on this for any selected text and a full-screen music player.

Try the demo in your browser (no install): https://aio.raycode.tech
Download (macOS 14+; Liquid Glass needs macOS 26): https://github.com/rayanjainn/aio/releases/latest

First launch: macOS says it "could not verify AIO is free of malware" because the app isn't notarized yet. Run this in Terminal once, then open AIO again:
  xattr -cr /Applications/AIO.app
or System Settings → Privacy & Security → Open Anyway.

Shown here: an interactive recreation of the interface. Real screen recordings are on the channel.
```
**Tags:** mac apps, macos, ⌘K, mac launcher, mac dock, notch, mac productivity, free mac apps, window manager mac, mac setup

### 4.2 The feature Reels (from the real app: `record/`)
Each is **hook → demo → end card**, 18–36 s. Cover = `social/covers/<id>.png`. Post one a day.

| # | Hook card | Captions on screen | Caption (first line is what shows) | Hashtags (3–5) |
|---|---|---|---|---|
| 1 `cmdk` | One bar for your whole Mac. | Press ⌘K · Maths. Instantly. · Any unit. · Live currency. · Schedule it by typing it. · Emoji in one word. · And every app on your Mac. | `Your Mac has a Spotlight. This one does maths, currency and your calendar.` | #macos #macapps #productivity #raycast |
| 2 `snap` | Snap windows with your keyboard. | Left half · Right half · Quarters · Maximize · Restore | `Snap windows with ⌃⌥ and arrow keys. No mouse.` | #macos #windowmanagement #productivity |
| 3 `switch` | Switch windows, not just apps. | Hold ⌥, press ⇥ · Every window. Every Space. | `⌥⇥ jumps to any window, not just any app.` | #macos #macproductivity |
| 4 `act` | Select text. Act on it. | Select any text · Press ⌃⌥A · Translate · Summarise · Fix · Reply | `Select text anywhere, press ⌃⌥A.` | #macos #ai #productivity |
| 5 `notch` | Your notch finally does something. | Hover the notch · Clipboard history · File shelf + AirDrop · Timer, mirror, tools · A better volume HUD | `Hover the notch. Clipboard, shelf and tools live there now.` | #macos #dynamicisland #macsetup |
| 6 `dock` | A Dock with live widgets. | Magnification · Music, clock, weather, battery · Presets in one click | `A Dock with live widgets and presets.` | #macdock #macos #desksetup |
| 7 `launcher` | Launchpad, but yours. | Every app, one keystroke · Instant search · Drag widgets to either side | `Put your Launcher widgets on whichever side you like. Left or right?` | #launchpad #macos #macapps |
| 8 `music` | Your song. Full screen. | Press ⌃⌥P · Five styles · All keyboard | `Your song, full screen, five styles.` | #macos #applemusic #spotify |

Every caption ends with: `Free: aio.raycode.tech (link in bio) 🔖 Save it for later`.

### 4.3 The feed posts (carousels, already made)
| Set | Slides | Caption | When |
|---|---|---|---|
| `aio-in-8-slides` | 8 | `Your Mac, from one bar. Swipe for 8 things AIO does. Free: aio.raycode.tech (link in bio).` + 4 hashtags | Day 1 |
| `cmdk-7-things` | 9 | `7 things you can type into ⌘K. Which one is your favourite? Free: aio.raycode.tech (link in bio).` | Day 3 |
| `install-in-60s` | 8 | `How to install AIO, including the one-time macOS warning. Save this.` | Day 5; **pin it to the top of the profile** |

Posting a carousel: **+** → **Post** → select the slides **in order** (tap the multi-select icon) → *Next* (keep 4:5) → add alt text →
caption → **Share**.

## 5. The calendar (first 30 days)

Cadence that is sustainable for one person [Likely]: **Instagram 5 Reels + 2 carousels a week + a Story every day; YouTube 2 Shorts a week + 1 long video every 2 weeks.**
Batch it: record on Sunday (`record/`, ~1 hour with edits), schedule through the week (Instagram → *Schedule*; YouTube Studio → *Schedule*).

| Week | Mon | Tue | Wed | Thu | Fri | Sat | Sun |
|---|---|---|---|---|---|---|---|
| **1: launch** | Hero Reel + Short + YouTube video | `cmdk` Reel | Carousel `cmdk-7-things` | `notch` Reel | Carousel `install-in-60s` | `dock` Reel | **Record batch #2**; Story poll "which feature next?" |
| **2: features** | `snap` | `launcher` | `act` | `switch` | `music` | Carousel `aio-in-8-slides` (re-cut) | Record; Reddit/HN posts (§6) |
| **3: proof** | "Why I made AIO" (to camera/voiceover, 45–60 s) | real install walkthrough (the warning, step by step) | best performer, re-cut with a new hook | `cmdk` v2: five new queries | answer the top 3 comments as Reels | carousel: your setup | long YouTube video: full walkthrough (`make-youtube.sh`) |
| **4: double down** | repeat the best 2 formats | collab: ask a Mac/productivity creator to try AIO | Reel from a comment/request | tips ("5 hidden AIO settings") | recap | Q&A Story | plan month 2 |

If a Reel gets 2–3× your average views, make **two follow-ups the same week** (different hook, same feature).

## 6. Reach — what actually moves it

**On Instagram** [Likely unless noted]
* Hook in the first 1–2 seconds and captions on screen: the cards already do this. **Shares and saves** matter most: end captions with
  "Save this" / "Send this to a Mac friend", and put useful info in carousels (they get saved).
* **3–5 relevant hashtags**, not 30. Put keywords in the caption's first line and in the **name field** (search uses them).
* **Audio:** a licensed track from Instagram's own library helps reach on Reels; stay at low volume under captions. Don't bake in a song you don't own.
* **Trial Reels** (Instagram's feature that shows a Reel to non-followers first) is a free way to test hooks: use it for the 2nd and 3rd versions of an idea.
* Post when your Insights say your followers are online (Professional account → Insights → Total followers → Most active times).
* **First hour after posting:** reply to every comment, post it to your Story, send it to 5 people who'd care. Comment genuinely on 10 posts from Mac/productivity creators each day (not "nice!": say something specific).
* **Collabs:** Instagram's **Collab** feature lets two accounts co-author a post. Offer a free walkthrough to small Mac/productivity creators.

**On YouTube** [Likely]
* Shorts find new people; long videos make them stay and subscribe. Put the URL in the **first line** of every description (it's the only clickable link).
* Titles: say the benefit ("One bar for your whole Mac"). Thumbnails: ≤4 words, one face or one UI, high contrast.
* Add **chapters** (`make-youtube.sh` prints them), a **pinned comment** with the install fix, and an **end screen** pointing to the next video.

**Off-platform** (this is where a free Mac utility usually gets its first real users) [Guessing on size; Likely on fit]
* **Reddit**: r/macapps and r/MacOS. **Read each sub's self-promotion rules first and follow them**; lead with what it does and be honest that you made it. One post per sub, answer every comment.
* **Hacker News** "Show HN: AIO, one bar for your whole Mac". **Product Hunt** (post on a weekday morning Pacific; have 3–5 people ready to leave honest comments, not votes-for-votes).
* **X / Mastodon / Bluesky**: post the hero film with the URL; reply to people complaining about Spotlight, Launchpad or Raycast pricing.
* **Directories:** AlternativeTo (as an alternative to Raycast, Alfred, Spotlight, Launchpad), MacUpdate, the GitHub repo's topics and README (add the hero film as a GIF).
* **Don't:** buy followers, use engagement groups, spam comments with the link, or post the same text in every sub.

## 7. Numbers to watch (Instagram Insights, YouTube Analytics, GitHub)

| Number | Why | Healthy sign [Guessing] |
|---|---|---|
| 3-second hold rate / "viewed vs. swiped away" | is the hook working | > 50% |
| Average watch time (Reels/Shorts) | is the demo too long | > 70% of the length |
| Shares + saves per 1,000 views | the strongest signal | ≥ 10 |
| Profile visits → link clicks | is the bio selling | clicks ≥ 3% of visits |
| Release downloads | the real goal | check `github.com/rayanjainn/aio/releases` download counts weekly |

Make a simple sheet: date, post, views, holds, shares, saves, link clicks, downloads that week. After 4 weeks, keep the 2 formats that won and drop the rest.
You said you care about reach: the single biggest lever is **volume of different hooks on the same feature**, not polish.

## 8. Launch day checklist

- [ ] Accounts created, 2FA on, profile picture / bio / link / banner done (§3)
- [ ] Hero film uploaded to YouTube as a public video + channel trailer; Short + Reel posted with covers; first comment pinned
- [ ] 3 Reels + 2 carousels posted before you tell anyone (§3.3)
- [ ] The install post (`install-in-60s`) pinned to the Instagram profile
- [ ] Website works on your phone (`aio.raycode.tech`); the Download button gives `AIO.dmg`
- [ ] Reply to every comment for 90 minutes
- [ ] Day 7: Reddit/HN/X posts (one per day, not all at once)
