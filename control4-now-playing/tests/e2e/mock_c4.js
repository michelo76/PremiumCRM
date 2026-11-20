#!/usr/bin/env node
/*
 * Mock-server Navigator path (tools/mock-server fake window.C4 + LAN relay emulation):
 *   1. protocol flag (default runtime): the page subscribes / sends with protocol=true, renders, fetches
 *      LAN/relative artwork through GET_ARTWORK (never directly) and gets refused for foreign URLs.
 *   2. ?c4proxy=1 (a runtime where only the proxy flag works): the page still gets the state (proxy-flag
 *      retry) and its LAN artwork.
 *   3. ?c4dead=1 + ?relay=&k= (JS API silent, field finding): after ~5 s the page polls the LAN relay
 *      (cross origin, ETag via ?inm= -> 304) and loads LAN artwork from <relay>/api/artwork.
 *   4. wrong relay key: 401s back off (no spinning, no console spam).
 *   5. remote client (relay unreachable): C4 answering late wins and relay polling stops; C4 answering
 *      at once never touches the relay.
 *   6. ?c4dieafter=1 (the JS API delivers once, then goes dead): the GET_STATE heartbeat (visible page) or
 *      the re-request on returning to the page misses its deadline and the relay takes over with the newer
 *      state; C4 coming back stops relay polling; a hidden page sends no heartbeats; a remote client whose
 *      relay is unreachable stays bounded and shows the reconnecting pill.
 *   node tests/e2e/mock_c4.js   (starts tools/mock-server itself)
 */
'use strict';
const path = require('path');
const { spawn } = require('child_process');
const { chromium } = require('playwright');

const PORT = 8000 + Math.floor(Math.random() * 900);
const RPORT = PORT + 1000;
const KEY = 'mock-relay-key-0001';
const RELAY = `http://127.0.0.1:${RPORT}`;
const DEAD_RELAY = 'http://127.0.0.1:9'; // nothing listens there: what a phone away from home sees
const srv = spawn(process.execPath, [path.join(__dirname, '../../tools/mock-server/server.js'), '--port', String(PORT),
  '--relay-port', String(RPORT), '--relay-key', KEY], { stdio: 'pipe' });
const failures = [];
const check = (c, w) => { if (!c) failures.push(w); };
const base = `http://127.0.0.1:${PORT}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const getJson = async (u) => (await fetch(u)).json();

async function open(browser, q, opts) {
  opts = opts || {};
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  const errors = [], requests = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('request', (r) => requests.push({ url: r.url(), type: r.resourceType() }));
  page.on('requestfailed', (r) => requests.push({ url: r.url(), failed: true }));
  if (opts.clock) await page.clock.install();
  await page.goto(`${base}/?c4mock=1&${q}`);
  return { page, errors, requests };
}
const artSwapped = (page, re, ms) => page.waitForFunction((src) => {
  const im = document.querySelector('#art-stack .art-layer.is-on img');
  return im && new RegExp(src).test(im.getAttribute('src'));
}, re, { timeout: ms || 8000 }).then(() => true, () => false);
const lastInfo = (page) => page.evaluate(() => ({ log: window.__c4log || [], np: { via: window.__npLast.via, at: window.__npLast.at,
  counts: window.__npLast.counts, subscribe: window.__npLast.subscribe || [], transport: window.__npLast.transport,
  fallbacks: window.__npLast.fallbacks, heartbeats: window.__npLast.heartbeats, version: window.__npLast.raw && window.__npLast.raw.version },
  conn: document.getElementById('conn').classList.contains('is-on'), mode: document.body.className,
  title: (document.querySelector('h1.title') || {}).textContent || '' }));

// fake clock: advance n seconds, letting real fetches settle in between
async function advance(page, secs) { for (let i = 0; i < secs; i++) { await page.clock.runFor(1000); await sleep(40); } }
const setHidden = (page, h) => page.evaluate((hid) => {
  Object.defineProperty(document, 'hidden', { configurable: true, get: () => hid });
  Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => (hid ? 'hidden' : 'visible') });
  document.dispatchEvent(new Event('visibilitychange'));
}, h);
const getStates = (log) => log.filter((l) => /^sendCommand:GET_STATE:/.test(l)).length;
const relayHits = (requests, r) => requests.filter((x) => x.url.indexOf(r + '/api/state') === 0 && !x.failed).length;

(async () => {
  await new Promise((r) => { let seen = ''; srv.stdout.on('data', (d) => { seen += d; if (/mock server on/.test(seen) && /relay emulation/.test(seen)) r(); }); });
  const browser = await chromium.launch();

  // ---- 1. default runtime: protocol flag
  for (const fx of ['movie-local-art', 'music-local-art']) {
    const { page, errors, requests } = await open(browser, `fixture=${fx}`);
    const st = await getJson(`${base}/api/state?fixture=${fx}`);
    const lan = [st.media.artwork_url, st.source.app_icon_url].filter(Boolean).map((u) => new URL(u, base + '/').href);
    if (!await artSwapped(page, '^data:image/')) failures.push(fx + ': artwork never swapped to a data: URI');
    const res = await page.evaluate(() => new Promise((resolve) => {
      // a URL that is not in the state must be refused by the (fake) driver
      const prev = window.onDataToUi;
      window.onDataToUi = (x) => { prev(x); if (x && x.NOW_PLAYING_ARTWORK && /evil/.test(x.NOW_PLAYING_ARTWORK.url)) resolve({ log: window.__c4log, refused: x.NOW_PLAYING_ARTWORK }); };
      window.C4.sendCommand('GET_ARTWORK', JSON.stringify({ url: 'http://192.168.1.1/evil.png' }), true, true);
      setTimeout(() => resolve({ log: window.__c4log, refused: { error: 'no reply' } }), 5000);
    }));
    const info = await lastInfo(page);
    check(info.log.indexOf('subscribeToDataToUi:true') >= 0 && info.log.indexOf('subscribeToVariable:STATE_JSON:true') >= 0, fx + ': protocol subscriptions');
    check(info.log.indexOf('subscribeToDataToUi:false') >= 0 && info.log.indexOf('subscribeToVariable:STATE_JSON:false') >= 0, fx + ': proxy subscriptions kept as fallback');
    check(info.log.indexOf('sendCommand:GET_STATE:{}:true:true') >= 0, fx + ': GET_STATE with the protocol flag');
    check(info.log.indexOf('sendCommand:GET_STATE:{}:true:false') < 0, fx + ': no proxy-flag GET_STATE when protocol answers');
    check(res.log.some((l) => /^sendCommand:GET_ARTWORK:.*:true:true$/.test(l)), fx + ': GET_ARTWORK sent with the protocol flag');
    check(res.log.some((l) => /^artwork:.*:data$/.test(l)), fx + ': artwork answered with data');
    check(res.refused.error === 'not in current state', fx + ': foreign URL refused');
    check(info.np.via === 'dataToUi' || info.np.via === 'variable', fx + ': __npLast.via = ' + info.np.via);
    check(typeof info.np.at === 'number', fx + ': __npLast.at');
    check(info.np.subscribe.length === 4 && info.np.subscribe.every((x) => /:ok$/.test(x)), fx + ': __npLast.subscribe ' + info.np.subscribe);
    const direct = requests.filter((r) => lan.indexOf(r.url) >= 0 && r.type === 'image');
    check(direct.length === 0, fx + ': LAN artwork loaded directly: ' + direct.map((r) => r.url).join(', '));
    check(!requests.some((r) => r.url.indexOf(`:${RPORT}/`) >= 0), fx + ': no relay traffic without ?relay');
    errors.forEach((e) => failures.push(fx + ': ' + e));
    await page.close();
  }

  // ---- 1b. a throwing subscribe must not stop the others
  {
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    await page.addInitScript(() => {
      window.__sent = [];
      window.C4 = {
        subscribeToVariable: () => { throw new Error('not supported'); },
        subscribeToDataToUi: (b) => { window.__sent.push('dtu:' + b); },
        sendCommand: (n, p, a, proto) => { window.__sent.push(n + ':' + proto); if (n === 'GET_STATE' && proto === true) throw new Error('boom'); },
      };
    });
    await page.goto(`${base}/index.html`);
    await sleep(300);
    const r = await page.evaluate(() => ({ sent: window.__sent, sub: window.__npLast.subscribe || [] }));
    check(r.sent.indexOf('dtu:true') >= 0 && r.sent.indexOf('dtu:false') >= 0, 'throwing subscribeToVariable: DataToUI still subscribed ' + r.sent);
    check(r.sub.indexOf('variable:protocol:threw') >= 0 && r.sub.indexOf('dataToUi:protocol:ok') >= 0, 'subscribe outcome recorded ' + r.sub);
    errors.forEach((e) => failures.push('throwing C4: ' + e));
    await page.close();
  }

  // ---- 2. runtime where only the proxy flag works
  {
    const fx = 'movie-local-art';
    const { page, errors } = await open(browser, `fixture=${fx}&c4proxy=1`);
    const ok = await artSwapped(page, '^data:image/', 15000);
    const info = await lastInfo(page);
    check(ok, 'c4proxy: LAN artwork via proxy-flag GET_ARTWORK');
    check(/mode-np/.test(info.mode), 'c4proxy: rendered (' + info.mode + ')');
    check(info.log.indexOf('ignored:GET_STATE:true') >= 0, 'c4proxy: protocol GET_STATE ignored by this runtime');
    check(info.log.indexOf('sendCommand:GET_STATE:{}:true:false') >= 0, 'c4proxy: proxy-flag GET_STATE retry sent');
    check(info.log.some((l) => /^sendCommand:GET_ARTWORK:.*:true:false$/.test(l)), 'c4proxy: proxy-flag GET_ARTWORK sent');
    check(!info.conn, 'c4proxy: no reconnecting pill once data flows');
    errors.forEach((e) => failures.push('c4proxy: ' + e));
    await page.close();
  }

  // ---- 3. JS API silent -> LAN relay
  {
    await getJson(`${base}/_mock/set?fixture=movie-local-art`);
    const { page, errors, requests } = await open(browser, `c4dead=1&relay=${encodeURIComponent(RELAY)}&k=${KEY}`);
    await sleep(3000);
    check(!requests.some((r) => r.url.indexOf(RELAY) === 0), 'relay: not used before the JS API had ~5 s');
    const ok = await artSwapped(page, '^' + RELAY.replace(/[.:/]/g, '\\$&') + '/api/artwork\\?url=', 10000);
    check(ok, 'relay: hero artwork loaded from <relay>/api/artwork');
    await sleep(4500); // two more polls: ETag -> 304 via ?inm= (no preflight)
    const info = await lastInfo(page);
    const stats = await getJson(`${RELAY}/_stats`);
    check(/mode-np/.test(info.mode) && info.title.length > 0, 'relay: rendered ' + info.mode + ' "' + info.title + '"');
    check(info.np.via === 'relay', 'relay: __npLast.via = ' + info.np.via);
    check(stats.state >= 1 && stats.notModified >= 1, 'relay: 200 then 304 ' + JSON.stringify(stats));
    check(stats.unauthorized === 0, 'relay: key sent');
    check(!info.conn, 'relay: no reconnecting pill');
    check(!requests.some((r) => r.type === 'image' && /192\.168\.|^http:\/\/127\.0\.0\.1:\d+\/_mock\/img\/.*lan/.test(r.url) && r.url.indexOf(RELAY) !== 0 && r.failed),
      'relay: no failing direct LAN image loads');
    check(requests.every((r) => r.url.indexOf(RELAY) !== 0 || /[?&]k=/.test(r.url) || /\/_stats$/.test(r.url)), 'relay: every relay request carries k');
    errors.forEach((e) => failures.push('relay: ' + e));
    await page.screenshot({ path: path.join(process.env.NP_SHOTS || path.join(__dirname, '../../build/e2e/shots'), 'mock-relay-1280x800.png') }).catch(() => {});
    await page.close();
  }

  // ---- 4. wrong key: 401s back off (simulated minute)
  {
    const before = (await getJson(`${RELAY}/_stats`)).unauthorized;
    const { page, errors } = await open(browser, `c4dead=1&relay=${encodeURIComponent(RELAY)}&k=wrong-key-000000`, { clock: true });
    for (let i = 0; i < 60; i++) { await page.clock.runFor(1000); await sleep(25); }
    const n = (await getJson(`${RELAY}/_stats`)).unauthorized - before;
    check(n >= 3 && n <= 7, 'bad key: relay requests in one minute with backoff = ' + n);
    const info = await lastInfo(page);
    check(info.conn, 'bad key: reconnecting pill shown');
    const spam = errors.filter((e) => !/401|Unauthorized/i.test(e));
    check(spam.length === 0, 'bad key: unexpected errors ' + spam.join(' | '));
    check(errors.length <= 7, 'bad key: console errors bounded (' + errors.length + ')');
    await page.close();
  }

  // ---- 5. remote client: relay unreachable
  {
    const q = `fixture=movie-local-art&relay=${encodeURIComponent(DEAD_RELAY)}&k=${KEY}`;
    let { page, errors, requests } = await open(browser, q);
    await sleep(6500);
    let info = await lastInfo(page);
    check(/mode-np/.test(info.mode) && info.np.via !== 'relay', 'remote: C4 answering at once renders ' + info.mode);
    check(!requests.some((r) => r.url.indexOf(DEAD_RELAY) === 0), 'remote: relay never touched while C4 answers');
    errors.forEach((e) => failures.push('remote: ' + e));
    await page.close();

    ({ page, errors, requests } = await open(browser, q + '&c4delay=6500'));
    await page.waitForFunction(() => document.body.classList.contains('mode-np'), null, { timeout: 15000 }).catch(() => failures.push('remote/late C4: never rendered'));
    const tried = requests.filter((r) => r.url.indexOf(DEAD_RELAY) === 0).length;
    await sleep(9000);
    const after = requests.filter((r) => r.url.indexOf(DEAD_RELAY) === 0).length;
    info = await lastInfo(page);
    check(tried >= 1, 'remote/late C4: relay tried after ~5 s (' + tried + ')');
    check(after === tried, `remote/late C4: relay polling stopped once C4 delivered (${tried} -> ${after})`);
    check(info.np.via === 'dataToUi' || info.np.via === 'variable', 'remote/late C4: via ' + info.np.via);
    check(!info.conn, 'remote/late C4: no reconnecting pill');
    const spam = errors.filter((e) => !/ERR_CONNECTION_REFUSED|Failed to load resource|Failed to fetch/i.test(e));
    check(spam.length === 0, 'remote/late C4: ' + spam.join(' | '));
    await page.close();
  }

  // ---- 6. JS API delivers once, then dies
  {
    // 6a. silent death on a visible page: the heartbeat misses its deadline, the relay takes over
    await getJson(`${base}/_mock/set?fixture=movie-local-art`);
    const { page, errors, requests } = await open(browser, `c4dieafter=1&relay=${encodeURIComponent(RELAY)}&k=${KEY}`, { clock: true });
    await advance(page, 3);
    let info = await lastInfo(page);
    const title1 = info.title;
    check(/mode-np/.test(info.mode) && (info.np.via === 'dataToUi' || info.np.via === 'variable'), 'c4 dies: first state via C4 (' + info.np.via + ')');
    check(relayHits(requests, RELAY) === 0, 'c4 dies: relay untouched while C4 delivered');
    await getJson(`${base}/_mock/set?fixture=music-local-art`);
    const want = (await getJson(`${RELAY}/api/state?k=${KEY}`)).version;
    await advance(page, 70); // heartbeat (45 s) + 5 s deadline + relay poll
    info = await lastInfo(page);
    check(info.title !== title1 && info.title.length > 0, `c4 dies: new state picked up via the relay ("${title1}" -> "${info.title}")`);
    check(info.np.via === 'relay' && info.np.transport === 'relay', 'c4 dies: __npLast.via/transport = ' + info.np.via + '/' + info.np.transport);
    check(info.np.version === want, `c4 dies: relay version ${info.np.version} = ${want}`);
    check(info.np.fallbacks === 1, 'c4 dies: one fallback, no flapping (' + info.np.fallbacks + ')');
    check(!info.conn, 'c4 dies: no reconnecting pill while the relay delivers');
    check(getStates(info.log) <= 8, 'c4 dies: GET_STATE retries bounded (' + getStates(info.log) + ')');

    // 6c. C4 comes back: relay polling stops
    await page.evaluate(() => window.__c4ctl.revive());
    await advance(page, 40);
    const n1 = relayHits(requests, RELAY);
    await advance(page, 20);
    info = await lastInfo(page);
    check(relayHits(requests, RELAY) === n1, `c4 back: relay polling stopped (${n1} -> ${relayHits(requests, RELAY)})`);
    check((info.np.via === 'dataToUi' || info.np.via === 'variable') && info.np.transport === 'c4', 'c4 back: via/transport = ' + info.np.via + '/' + info.np.transport);
    check(!info.conn, 'c4 back: no reconnecting pill');
    check(info.np.fallbacks === 1, 'c4 back: fallbacks = ' + info.np.fallbacks);
    errors.forEach((e) => failures.push('c4 dies: ' + e));
    await page.close();
  }
  {
    // 6b. the reported case: Navigator backgrounded and reopened after the channel died (real time)
    await getJson(`${base}/_mock/set?fixture=movie-local-art`);
    const { page, errors } = await open(browser, `c4dieafter=1&relay=${encodeURIComponent(RELAY)}&k=${KEY}`);
    await page.waitForFunction(() => document.body.classList.contains('mode-np'), null, { timeout: 8000 }).catch(() => failures.push('reopen: never rendered'));
    const title1 = (await lastInfo(page)).title;
    await getJson(`${base}/_mock/set?fixture=music-local-art`);
    await setHidden(page, true); await sleep(1000); await setHidden(page, false);
    const t0 = Date.now();
    const ok = await page.waitForFunction((t) => { const h = document.querySelector('h1.title'); return h && h.textContent !== t && window.__npLast.via === 'relay'; },
      title1, { timeout: 12000 }).then(() => true, () => false);
    const info = await lastInfo(page);
    check(ok, `reopen: relay delivered the new state after the C4 deadline (${Date.now() - t0} ms, via ${info.np.via}, "${info.title}")`);
    check(!info.conn, 'reopen: no reconnecting pill');
    errors.forEach((e) => failures.push('reopen: ' + e));
    await page.close();
  }
  {
    // 6d. heartbeats only while visible; they never re-render
    const { page, errors } = await open(browser, 'fixture=movie-local-art', { clock: true });
    await advance(page, 3);
    await page.evaluate(() => { const h = document.querySelector('h1.title'); if (h) h.__mark = 1; window.__np0 = document.getElementById('np').innerHTML; });
    const n0 = getStates((await lastInfo(page)).log);
    await setHidden(page, true);
    await advance(page, 150);
    const n1 = getStates((await lastInfo(page)).log);
    check(n1 === n0, `hidden: no heartbeats while hidden (${n0} -> ${n1})`);
    await setHidden(page, false);
    await advance(page, 140);
    const info = await lastInfo(page);
    const hb = getStates(info.log) - n1;
    check(hb >= 3 && hb <= 5, 'visible: GET_STATE on return + heartbeats in 140 s = ' + hb);
    check(info.np.heartbeats >= 2, 'visible: __npLast.heartbeats = ' + info.np.heartbeats);
    const same = await page.evaluate(() => { const h = document.querySelector('h1.title'); return !!(h && h.__mark); });
    check(same, 'heartbeat: unchanged-version replies do not rebuild the page');
    check(info.np.fallbacks === 0 && !info.conn, 'heartbeat: answered heartbeats never fall back / show the pill');
    errors.forEach((e) => failures.push('heartbeat: ' + e));
    await page.close();
  }
  {
    // 6e. remote client, relay unreachable, C4 dies: bounded retries, pill shown
    const { page, errors, requests } = await open(browser, `fixture=movie-local-art&c4dieafter=1&relay=${encodeURIComponent(DEAD_RELAY)}&k=${KEY}`, { clock: true });
    await advance(page, 3);
    await advance(page, 180);
    const info = await lastInfo(page);
    const tries = requests.filter((r) => r.url.indexOf(DEAD_RELAY) === 0 && !r.failed).length; // request events only
    check(tries >= 2 && tries <= 10, 'remote/c4 dies: relay requests in 3 min = ' + tries);
    check(getStates(info.log) <= 16, 'remote/c4 dies: GET_STATE in 3 min = ' + getStates(info.log));
    check(info.conn, 'remote/c4 dies: reconnecting pill shown');
    check(/mode-np/.test(info.mode), 'remote/c4 dies: last state kept on screen');
    const spam = errors.filter((e) => !/ERR_CONNECTION_REFUSED|Failed to load resource|Failed to fetch/i.test(e));
    check(spam.length === 0, 'remote/c4 dies: ' + spam.join(' | '));
    check(errors.length <= 12, 'remote/c4 dies: console errors bounded (' + errors.length + ')');
    await page.close();
  }

  await browser.close();
  srv.kill();
  if (failures.length) { console.log('MOCK C4 FAILED:\n  ' + failures.join('\n  ')); process.exit(1); }
  console.log('MOCK C4 PASSED: protocol flag, proxy-only runtime, LAN relay fallback, bad key backoff, remote client, C4 death -> relay / heartbeat');
})().catch((e) => { console.error(e); srv.kill(); process.exit(2); });
