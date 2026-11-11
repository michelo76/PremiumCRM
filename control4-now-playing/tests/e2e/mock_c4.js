#!/usr/bin/env node
/*
 * Mock-server Navigator path: the page in fake-C4 mode (?c4mock=1) must fetch LAN/relative
 * artwork through GET_ARTWORK (never directly), swap in the data: URI, and get refused for URLs
 * that are not in the state.   node tests/e2e/mock_c4.js   (starts tools/mock-server itself)
 */
'use strict';
const path = require('path');
const { spawn } = require('child_process');
const { chromium } = require('playwright');

const PORT = 8000 + Math.floor(Math.random() * 900);
const srv = spawn(process.execPath, [path.join(__dirname, '../../tools/mock-server/server.js'), '--port', String(PORT)], { stdio: 'pipe' });
const failures = [];
const check = (c, w) => { if (!c) failures.push(w); };

(async () => {
  await new Promise((r) => srv.stdout.once('data', r));
  const browser = await chromium.launch();
  for (const fx of ['movie-local-art', 'music-local-art']) {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [], direct = [];
    page.on('pageerror', (e) => errors.push(e.message));
    page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
    // the hero artwork / app icon must come through the driver (cast and artist photos may load directly)
    const st = await (await fetch(`http://127.0.0.1:${PORT}/api/state?fixture=${fx}`)).json();
    const lan = [st.media.artwork_url, st.source.app_icon_url].filter(Boolean).map((u) => new URL(u, `http://127.0.0.1:${PORT}/`).href);
    page.on('request', (r) => { if (lan.indexOf(r.url()) >= 0 && r.resourceType() === 'image') direct.push(r.url()); });
    await page.goto(`http://127.0.0.1:${PORT}/?c4mock=1&fixture=${fx}`);
    await page.waitForFunction(() => {
      const im = document.querySelector('#art-stack .art-layer.is-on img');
      return im && /^data:image\//.test(im.getAttribute('src'));
    }, null, { timeout: 8000 }).catch(() => failures.push(fx + ': artwork never swapped to a data: URI'));
    const res = await page.evaluate(() => new Promise((resolve) => {
      // a URL that is not in the state must be refused by the (fake) driver
      const prev = window.onDataToUi;
      window.onDataToUi = (x) => { prev(x); if (x && x.NOW_PLAYING_ARTWORK && /evil/.test(x.NOW_PLAYING_ARTWORK.url)) resolve({ log: window.__c4log, refused: x.NOW_PLAYING_ARTWORK }); };
      window.C4.sendCommand('GET_ARTWORK', JSON.stringify({ url: 'http://192.168.1.1/evil.png' }), true, false);
    }));
    check(res.log.some((l) => /^sendCommand:GET_ARTWORK:/.test(l)), fx + ': GET_ARTWORK sent');
    check(res.log.some((l) => /^artwork:.*:data$/.test(l)), fx + ': artwork answered with data');
    check(res.refused.error === 'not in current state', fx + ': foreign URL refused');
    check(direct.length === 0, fx + ': LAN artwork loaded directly: ' + direct.join(', '));
    errors.forEach((e) => failures.push(fx + ': ' + e));
    await page.close();
  }
  await browser.close();
  srv.kill();
  if (failures.length) { console.log('MOCK C4 FAILED:\n  ' + failures.join('\n  ')); process.exit(1); }
  console.log('MOCK C4 PASSED: GET_ARTWORK via the mock server fake C4 (2 fixtures)');
})().catch((e) => { console.error(e); srv.kill(); process.exit(2); });
