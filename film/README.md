# AIO launch film

Built from the website's live Mac demo, so the film and the site look the same.

1. Serve the site: `cd marketing && python3 -m http.server 8765`
2. `node film/snapshot.js http://localhost:8765/ film/snapshot.json`
3. Put the track at `film/digital-clouds.mp3` ("Digital Clouds", Mixkit — not committed, the license forbids redistributing the file).
4. `python3 film/build.py landscape film/landscape` and `python3 film/build.py portrait film/portrait`
5. `cd film/landscape && npx hyperframes render -q delivery -o ../aio-film-raw.mp4`

Every frame is a pure function of time (`render(t)` in the generated page): camera, cursor, Island, Dock magnification, Launcher, ⌘K and the player.
