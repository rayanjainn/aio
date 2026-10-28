# Using Cortex day-to-day

Cortex is your ⌘K command bar + memory. Press **⌘K** anywhere to open it.

## The basics
- **Launch apps** — start typing an app name → ↵. (Most-used float to top.)
- **Open files** — type a filename. Whole-home search (works even without Spotlight).
- **Switch / list tabs** — ask "what tabs do I have open" or use the Search Browser command.
- **Calculator** — type `1920*0.62`, `(3+4)^2`, or `10 km to mi`, `32f in c` → ↵ copies.
- **Emoji** — `:rocket`, `:fire`, `:tada` → ↵ copies.
- **Esc** clears the query / closes; click away also closes.

## Commands (the root list)
Open ⌘K and you'll see capability commands — ↵ to enter one:
- **Ask AI** — chat about your own data (multi-turn, sources are clickable).
- **Rewind** — what was on your screen earlier; type to search it.
- **Search Files** — whole-Mac filename search.
- **Search GitHub** — repos, issues, PRs, recent commits.
- **Search Browser History**, **Clipboard History**, **Git Commits**, **System Commands**.
- **Chat History** — resume or delete past AI chats (`→` on a row).
- **Calculator**, **Emoji Picker**.

## AI mode
- Prefix `?` or pick **Ask AI**. It answers from your data and shows clickable source items.
- Examples:
  - "what youtube videos did I watch recently"
  - "which repo did I commit to last / what did I push this week"
  - "what was I doing 20 minutes ago"
  - "find the file where I set the ECR lifecycle policy"
- Follow-up freely — it keeps context. Chats are saved (Chat History).

## Run commands with AI
- Prefix `>` and describe it: `> list git branches sorted by date`, `> kill whatever is on port 3000`.
- Cortex generates the shell command, shows it (with a destructive warning if risky), runs it on confirm.

## Actions on a result
- Select a result, press **→** for actions: Open, **Reveal in Finder** (⌘↵), **Quick Look** (⌥↵), Copy Path/Name/URL.

## Daily workflows
- **Morning**: ⌘K → "Rewind" to recall where you left off, or Ask AI "what was I working on yesterday".
- **Deep work**: ⌘K to jump between files/apps/tabs without leaving the keyboard.
- **Debugging**: `>` for one-off shell commands; Ask AI "what was on screen when that error appeared".
- **Standup**: Ask AI "what did I commit this week" / "what repos did I touch".
- **Privacy**: ⌘⇧P pauses capture. Add sensitive apps to Settings → blocked apps.

## Setup notes
- **AI / Rewind need [Ollama](https://ollama.ai)**: `ollama pull llama3.1:8b` (chat) + `ollama pull nomic-embed-text` (semantic). Cortex auto-uses the best installed model.
- **Rewind needs Screen Recording** permission (System Settings → Privacy). Memory is text-only — screenshots are discarded after OCR.
- **GitHub**: put your token in `~/.cortex/config.toml` under `[github] token = "ghp_…"`.
- **Run with logs**: `CORTEX_LOG=aio_cortex_lib=debug npm run tauri dev`.
