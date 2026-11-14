// Captures the live Mac demo from marketing/index.html (markup, styles, command-bar results) for the film.
// Usage: node film/snapshot.js http://localhost:8765/ film/snapshot.json
const { chromium } = require('playwright');
const fs = require('fs');
(async () => {
  const [url, out] = process.argv.slice(2);
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1440, height: 380 } });   // demo stays off screen, so it never starts
  await p.clock.setFixedTime(new Date('2026-11-08T09:41:00'));
  await p.goto(url, { waitUntil: 'networkidle' });
  await p.waitForTimeout(400);
  const queries = ['12*(3+4)', '10 km to mi', '100 usd to eur', 'event lunch tomorrow 1pm', 'heart', 'note'];
  const data = await p.evaluate(async (queries) => {
    const css = [...document.querySelectorAll('style')].map(s => s.textContent).join('\n');
    const q = document.querySelector('#palq'), rows = {};
    const set = v => { q.value = v; q.dispatchEvent(new Event('input')); return document.querySelector('#rows').innerHTML; };
    rows[''] = set('');
    for (const full of queries) for (let i = 1; i <= full.length; i++) rows[full.slice(0, i)] = set(full.slice(0, i));
    set('');
    const screen = document.querySelector('#screen').cloneNode(true);
    screen.removeAttribute('style');
    return { css, rows, screen: screen.outerHTML };
  }, queries);
  fs.writeFileSync(out, JSON.stringify(data));
  console.log('rows', Object.keys(data.rows).length, 'screen', data.screen.length, 'css', data.css.length);
  await b.close();
})();
