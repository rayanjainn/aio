// Captures every feature state of the website's live Mac demo as 2880x1800 PNGs (social/shots/*.png).
// Usage: (cd marketing && python3 -m http.server 8765) &   node social/capture-states.js http://localhost:8765/
const { chromium } = require('playwright');
(async () => {
  const url = process.argv[2] || 'http://localhost:8765/';
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.goto(url, { waitUntil: 'networkidle' });
  await p.evaluate(() => { document.documentElement.style.scrollBehavior = 'auto'; document.querySelector('#demo').scrollIntoView({ block: 'center' }); });
  await p.waitForTimeout(600);
  const vp = await p.$('#viewport'), bx = await vp.boundingBox();
  const at = (fx, fy) => [bx.x + bx.width * fx, bx.y + bx.height * fy];
  const move = async (fx, fy, steps = 8) => { const [x, y] = at(fx, fy); await p.mouse.move(x, y, { steps }); };
  const shot = async n => { await p.waitForTimeout(900); await vp.screenshot({ path: `social/shots/${n}.png` }); console.log('shot', n); };
  const idle = async () => { await p.keyboard.press('Escape'); await p.mouse.move(...at(.5, .55), { steps: 6 }); await p.waitForTimeout(700); };
  // take over from the self-playing demo
  await move(.4, .5); await move(.42, .52); await p.waitForTimeout(500); await p.keyboard.press('Escape'); await p.waitForTimeout(800);
  await shot('desktop');

  // ⌘K
  const q = async (text, name) => { await p.keyboard.press('Control+A'); await p.keyboard.type(text, { delay: 25 }); await shot(name); };
  await p.keyboard.press('Control+K'); await shot('cmdk-home');
  await q('12*(3+4)', 'cmdk-calc'); await q('10 km to mi', 'cmdk-convert'); await q('100 usd to eur', 'cmdk-currency');
  await q('event lunch tomorrow 1pm', 'cmdk-event'); await q('remind call mom at 6pm', 'cmdk-remind'); await q('heart', 'cmdk-emoji'); await q('mus', 'cmdk-apps');
  await idle();

  // Island
  await move(.5, .004, 10); await shot('island-home');
  for (const pg of ['clip', 'shelf', 'tools']) { await p.click(`#island .tabs b[data-pg="${pg}"]`); await shot('island-' + pg); }
  await p.click('#island .tabs b[data-pg="home"]'); await move(.5, .5, 12); await p.waitForTimeout(500);
  await p.keyboard.press('ArrowUp'); await shot('island-hud'); await idle();

  // Dock + presets
  await move(.42, .965, 10); await shot('dock-hover');
  await p.mouse.click(...at(.5, .965), { button: 'right' }); await shot('dock-menu');
  await p.locator('#dmenu .mi').nth(3).click(); await move(.55, .965, 10); await shot('dock-ocean');
  await p.mouse.click(...at(.5, .965), { button: 'right' }); await p.waitForTimeout(400); await p.locator('#dmenu .mi').nth(1).click(); await move(.55, .965, 10); await shot('dock-tide');
  await p.mouse.click(...at(.5, .965), { button: 'right' }); await p.waitForTimeout(400); await p.locator('#dmenu .mi').nth(0).click(); await idle();

  // Launcher + widget drag
  await p.keyboard.press('l'); await shot('launcher');
  const wc = await (await p.$('.lpw .c[data-w="weather"]')).boundingBox();
  await p.mouse.move(wc.x + wc.width / 2, wc.y + wc.height / 2); await p.mouse.down();
  await p.mouse.move(...at(.84, .3), { steps: 18 }); await shot('launcher-drag');
  await p.mouse.up(); await shot('launcher-moved'); await idle();

  // snapping, switcher, act on this
  await move(.5, .5); await p.keyboard.press('Control+Alt+ArrowLeft'); await shot('snap-left');
  await p.keyboard.press('Control+Alt+ArrowRight'); await shot('snap-right');
  await p.keyboard.press('Control+Alt+ArrowUp'); await shot('snap-max'); await p.keyboard.press('Control+Alt+ArrowDown'); await p.waitForTimeout(900);
  await p.keyboard.down('Alt'); await p.keyboard.press('Tab'); await p.keyboard.press('Tab'); await shot('switcher'); await p.keyboard.up('Alt'); await p.waitForTimeout(700);
  await p.keyboard.press('Control+Alt+a'); await shot('act'); await p.click('#act .ab b[data-a="translate"]'); await shot('act-translate'); await idle();

  // music
  await p.keyboard.press('p'); await p.waitForTimeout(1500); await shot('music'); await idle();
  console.log('errors', errs); await b.close();
})();
