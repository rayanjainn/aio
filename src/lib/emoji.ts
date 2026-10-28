/** Compact emoji set for `:` search. Char + searchable keywords. */
export interface Emoji { c: string; name: string; kw: string }

const EMOJI: Emoji[] = [
  { c: "😀", name: "grinning", kw: "smile happy face" },
  { c: "😂", name: "joy", kw: "laugh cry tears funny lol" },
  { c: "🤣", name: "rofl", kw: "rolling laughing floor lol" },
  { c: "😊", name: "blush", kw: "smile happy shy" },
  { c: "😍", name: "heart eyes", kw: "love crush adore" },
  { c: "😘", name: "kiss", kw: "love blow" },
  { c: "😎", name: "cool", kw: "sunglasses awesome" },
  { c: "🤔", name: "thinking", kw: "hmm consider doubt" },
  { c: "😴", name: "sleeping", kw: "sleep tired zzz" },
  { c: "😭", name: "sob", kw: "cry sad tears" },
  { c: "😡", name: "angry", kw: "mad rage" },
  { c: "🥳", name: "party", kw: "celebrate hooray birthday" },
  { c: "🤯", name: "mind blown", kw: "explode shock wow" },
  { c: "😶‍🌫️", name: "foggy", kw: "confused dazed" },
  { c: "👍", name: "thumbs up", kw: "yes ok approve like good" },
  { c: "👎", name: "thumbs down", kw: "no bad dislike" },
  { c: "👏", name: "clap", kw: "applause bravo congrats" },
  { c: "🙏", name: "pray", kw: "thanks please hope namaste" },
  { c: "🙌", name: "raised hands", kw: "celebrate praise hooray" },
  { c: "💪", name: "muscle", kw: "strong flex gym" },
  { c: "🤝", name: "handshake", kw: "deal agree partner" },
  { c: "👀", name: "eyes", kw: "look see watch" },
  { c: "🔥", name: "fire", kw: "lit hot flame awesome" },
  { c: "✨", name: "sparkles", kw: "shiny stars magic clean" },
  { c: "⭐", name: "star", kw: "favorite rating" },
  { c: "🌟", name: "glowing star", kw: "shine special" },
  { c: "💯", name: "hundred", kw: "100 perfect score keep it" },
  { c: "🎉", name: "tada", kw: "party celebrate congrats launch" },
  { c: "🎊", name: "confetti", kw: "party celebrate" },
  { c: "❤️", name: "red heart", kw: "love like" },
  { c: "🧡", name: "orange heart", kw: "love" },
  { c: "💛", name: "yellow heart", kw: "love" },
  { c: "💚", name: "green heart", kw: "love" },
  { c: "💙", name: "blue heart", kw: "love" },
  { c: "💜", name: "purple heart", kw: "love" },
  { c: "🖤", name: "black heart", kw: "love dark" },
  { c: "💔", name: "broken heart", kw: "sad breakup" },
  { c: "💕", name: "two hearts", kw: "love" },
  { c: "🚀", name: "rocket", kw: "launch ship fast deploy startup" },
  { c: "💡", name: "bulb", kw: "idea light tip" },
  { c: "✅", name: "check", kw: "done yes correct ok complete" },
  { c: "❌", name: "cross", kw: "no wrong cancel fail" },
  { c: "⚠️", name: "warning", kw: "caution alert danger" },
  { c: "🐛", name: "bug", kw: "error defect insect" },
  { c: "🎯", name: "target", kw: "goal bullseye aim direct hit" },
  { c: "📌", name: "pin", kw: "pinned location mark" },
  { c: "📎", name: "paperclip", kw: "attach clip" },
  { c: "📝", name: "memo", kw: "note write edit" },
  { c: "📁", name: "folder", kw: "directory files" },
  { c: "📂", name: "open folder", kw: "directory" },
  { c: "💻", name: "laptop", kw: "computer code dev" },
  { c: "🖥️", name: "desktop", kw: "computer monitor" },
  { c: "⌨️", name: "keyboard", kw: "type input" },
  { c: "📱", name: "phone", kw: "mobile cell device" },
  { c: "🔋", name: "battery", kw: "power charge" },
  { c: "🔌", name: "plug", kw: "power electric" },
  { c: "🌐", name: "globe", kw: "web internet world" },
  { c: "🔍", name: "search", kw: "find magnify look" },
  { c: "🔑", name: "key", kw: "password secret access" },
  { c: "🔒", name: "lock", kw: "secure private closed" },
  { c: "🔓", name: "unlock", kw: "open access" },
  { c: "⏰", name: "alarm", kw: "time clock wake" },
  { c: "⏳", name: "hourglass", kw: "wait time loading" },
  { c: "📅", name: "calendar", kw: "date schedule event" },
  { c: "✏️", name: "pencil", kw: "edit write" },
  { c: "📊", name: "chart", kw: "graph data stats analytics" },
  { c: "📈", name: "chart up", kw: "growth increase trend" },
  { c: "📉", name: "chart down", kw: "decline decrease loss" },
  { c: "💰", name: "money bag", kw: "cash rich dollars" },
  { c: "💸", name: "money wings", kw: "spend cash fly" },
  { c: "☕", name: "coffee", kw: "cafe drink tea morning" },
  { c: "🍕", name: "pizza", kw: "food slice" },
  { c: "🍔", name: "burger", kw: "food" },
  { c: "🎵", name: "music", kw: "note song audio" },
  { c: "🎮", name: "game", kw: "controller play" },
  { c: "🏆", name: "trophy", kw: "win award champion" },
  { c: "🎁", name: "gift", kw: "present box surprise" },
  { c: "🔔", name: "bell", kw: "notification alert" },
  { c: "📢", name: "loudspeaker", kw: "announce broadcast" },
  { c: "⚡", name: "zap", kw: "lightning fast power energy" },
  { c: "☀️", name: "sun", kw: "sunny weather hot day" },
  { c: "🌙", name: "moon", kw: "night dark sleep" },
  { c: "⛅", name: "cloud sun", kw: "weather partly" },
  { c: "🌧️", name: "rain", kw: "weather wet storm" },
  { c: "❄️", name: "snowflake", kw: "cold winter snow freeze" },
  { c: "🌈", name: "rainbow", kw: "colors pride" },
  { c: "💀", name: "skull", kw: "dead death danger" },
  { c: "👻", name: "ghost", kw: "spooky boo halloween" },
  { c: "🤖", name: "robot", kw: "bot ai machine" },
  { c: "👋", name: "wave", kw: "hello hi bye greeting" },
  { c: "🤙", name: "call me", kw: "shaka hang loose" },
  { c: "🙄", name: "eye roll", kw: "annoyed whatever" },
  { c: "😅", name: "sweat smile", kw: "phew nervous relief" },
  { c: "🥺", name: "pleading", kw: "puppy eyes please beg" },
  { c: "🤷", name: "shrug", kw: "dunno whatever idk" },
];

export function searchEmoji(query: string, limit = 8): Emoji[] {
  const q = query.trim().toLowerCase();
  if (!q) return EMOJI.slice(0, limit);
  const scored = EMOJI
    .map(e => {
      const hay = `${e.name} ${e.kw}`;
      let score = 0;
      if (e.name === q) score = 100;
      else if (e.name.startsWith(q)) score = 80;
      else if (e.name.includes(q)) score = 60;
      else if (hay.includes(q)) score = 40;
      else if (q.split(" ").every(w => hay.includes(w))) score = 20;
      return { e, score };
    })
    .filter(x => x.score > 0)
    .sort((a, b) => b.score - a.score);
  return scored.slice(0, limit).map(x => x.e);
}
