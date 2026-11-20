#!/usr/bin/env node
/*
 * Real-Lua -> real-UI end-to-end check (Playwright/Chromium, no npm install needed when
 * `require('playwright')` resolves).
 *
 *   node tests/e2e/render.js <states_dir> [<shots_dir>]
 *
 * <states_dir> is the output of tests/e2e/gen_states.lua: the exact STATE_JSON / DataToUI /
 * GET_ARTWORK payloads the REAL driver produced. Every scenario is rendered by the REAL
 * driver/www/index.html through both transports:
 *
 *   http      ?api=/state/<name>  (LAN HTTP mode: images loaded directly)
 *   c4-dtu    fake window.C4: GET_STATE -> onDataToUi({NOW_PLAYING: {state: json}}) (the glue's
 *             SendDataToUI("NOW_PLAYING", {state=json}) wrapped by command name);
 *             GET_ARTWORK -> onDataToUi({NOW_PLAYING_ARTWORK: {url, data}}) from the driver's reply
 *   c4-var    fake window.C4: only the STATE_JSON variable ({name:"STATE_JSON", value: json})
 *   relay     fake window.C4 that never answers (field finding on a real touch screen) and the web
 *             view URL the driver announced (?relay=...&k=<token>, relay host swapped for a local
 *             server on ANOTHER port, i.e. cross-origin like controller:// -> http://). That server
 *             replays the driver's own LAN relay answers byte for byte (<name>.relay.json: 200 /
 *             304 via ?inm= / 401 / OPTIONS / /api/artwork image bytes). After ~5 s the page must
 *             poll the relay and load LAN artwork from <relay>/api/artwork.
 *
 * The browser clock is set to sent_at + 120 s, so the progress labels prove that the page
 * corrects clock skew with the driver's sent_at. Remote images are served by a local route
 * (placeholder SVGs); LAN images (192.168.x) are only reachable in http mode -- in Navigator
 * mode the page must ask the driver instead (asserted).
 * Scenarios with a <name>.pre.json (the state the engine publishes BEFORE enrichment, same
 * media_key) are also replayed as a live sequence on an open page (http and fake C4):
 * pre -> enriched -> enriched again with unchanged image URLs. The artwork must switch to the
 * enriched poster/backdrop, and the unchanged-URL update must keep the same <img> node.
 * Exit code 0 = all assertions passed. Screenshots go to <shots_dir> (default <states_dir>/shots).
 */
'use strict';
const fs = require('fs');
const path = require('path');
const http = require('http');
const { chromium } = require('playwright');

const STATES = path.resolve(process.argv[2] || 'build/e2e');
const SHOTS = path.resolve(process.argv[3] || path.join(STATES, 'shots'));
const WWW = path.resolve(process.env.NP_WWW || path.join(__dirname, '../../driver/www'));
const SKEW_S = 120;
const RELAY_AFTER_MS = 5500;
fs.mkdirSync(SHOTS, { recursive: true });

const index = JSON.parse(fs.readFileSync(path.join(STATES, 'index.json'), 'utf8'));
const read = (n) => fs.readFileSync(path.join(STATES, n), 'utf8');
const seqBody = {}; // sequence id -> state JSON currently served at /seq/<id> (http transport)

// ---------------------------------------------------------------- local server (page + states)
const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/' || u.pathname === '/index.html') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(fs.readFileSync(path.join(WWW, 'index.html')));
  }
  const sq = /^\/seq\/([\w-]+)$/.exec(u.pathname);
  if (sq) {
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    return res.end(seqBody[sq[1]] || '{}');
  }
  const m = /^\/state\/([\w-]+)$/.exec(u.pathname);
  if (m) {
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    return res.end(read(m[1] + '.json'));
  }
  res.writeHead(404); res.end('not found');
});

// ---------------------------------------------------------------- placeholder "network" images
function hue(s) { let h = 0; for (const c of s) h = (h * 31 + c.charCodeAt(0)) >>> 0; return h % 360; }
function svg(w, h, seed, label, transparent) {
  const a = hue(seed), b = (a + 50) % 360;
  const bg = transparent ? '' : `<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="hsl(${a},55%,42%)"/>` +
    `<stop offset="1" stop-color="hsl(${b},50%,12%)"/></linearGradient></defs><rect width="100%" height="100%" fill="url(#g)"/>` +
    `<circle cx="${w * 0.68}" cy="${h * 0.34}" r="${Math.min(w, h) * 0.2}" fill="hsl(${(a + 180) % 360},70%,70%)" opacity=".45"/>`;
  const fs_ = Math.round(Math.min(w, h) / (transparent ? 2.6 : 9));
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">${bg}` +
    (label ? `<text x="50%" y="${transparent ? '62%' : '88%'}" text-anchor="middle" font-family="Georgia,serif" font-weight="700" font-size="${fs_}" fill="#fff" opacity=".92">${label}</text>` : '') + '</svg>';
}
function imageFor(url) {
  if (/\/w500\/.*\.png/i.test(url)) return svg(500, 150, url, 'LOGO', true);
  if (/\/w1280\//.test(url)) return svg(1280, 720, url, '');
  if (/\/w185\//.test(url)) return svg(185, 278, url, '');
  if (/\/w780\/.*(still|\/[a-z0-9]{20,}\.jpg)/i.test(url) && /episode|still/i.test(url)) return svg(780, 439, url, '');
  if (/\/w780\//.test(url)) return svg(500, 750, url, 'POSTER');
  if (/mzstatic|scdn|cdn\.example|rumours/.test(url)) return svg(600, 600, url, 'ALBUM');
  if (/tmsimg/.test(url)) return svg(720, 540, url, 'ON AIR');
  if (/192\.168\./.test(url)) return svg(400, 600, url, 'LAN ART');
  return svg(600, 400, url, '');
}

function fmtDur(s) { s = Math.max(0, Math.floor(s)); const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60; const p = (n) => (n < 10 ? '0' : '') + n; return h ? `${h}:${p(m)}:${p(x)}` : `${m}:${p(x)}`; }
function parseDur(t) { const p = t.split(':').map(Number); return p.reduce((a, b) => a * 60 + b, 0); }
function isLan(u) { return /^https?:\/\/(10\.|127\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(u) || /^https?:\/\/[^/.]+(:\d+)?\//.test(u); }

const failures = [];
function check(cond, what) { if (!cond) failures.push(what); }

// replays one raw HTTP response recorded from the Lua relay (status line, headers, body bytes)
function replay(res, buf) {
  const i = buf.indexOf('\r\n\r\n');
  const head = buf.slice(0, i).toString('latin1').split('\r\n'), body = buf.slice(i + 4), h = {};
  head.slice(1).forEach((l) => { const j = l.indexOf(':'); h[l.slice(0, j)] = l.slice(j + 1).trim(); });
  res.writeHead(+head[0].split(' ')[1], h);
  res.end(body);
}
async function startRelay(rec, log) {
  const raw = (b) => Buffer.from(b, 'base64');
  const srv = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x');
    log.push(req.method + ' ' + u.pathname + u.search);
    let b;
    if (req.method === 'OPTIONS') b = rec.options;
    else if (u.searchParams.get('k') !== rec.token) b = rec.unauthorized;
    else if (u.pathname === '/api/state') b = (u.searchParams.get('inm') === rec.etag || req.headers['if-none-match'] === rec.etag) ? rec.not_modified : rec.state;
    else if (u.pathname === '/api/artwork') b = rec.artwork[u.searchParams.get('url')];
    if (!b) { res.writeHead(404, { 'Access-Control-Allow-Origin': '*' }); return res.end('not recorded'); }
    replay(res, raw(b));
  });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  return { srv, base: 'http://127.0.0.1:' + srv.address().port };
}

async function run(browser, base, sc, transport, viewport, shot, extraQuery) {
  let st = JSON.parse(read(sc.name + '.json'));
  const dtu = JSON.parse(read(sc.name + '.dtu.json'));
  const artReplies = JSON.parse(read(sc.name + '.artwork.json'));
  let relay = null, rec = null;
  const relayLog = [];
  if (transport === 'relay') {
    rec = JSON.parse(read(sc.name + '.relay.json'));
    relay = await startRelay(rec, relayLog);
    // the relay answers "now": its sent_at is the controller clock the page corrects against
    const body = Buffer.from(rec.state, 'base64').toString('utf8');
    st = JSON.parse(body.slice(body.indexOf('\r\n\r\n') + 4));
  }
  const ctx = await browser.newContext({ viewport, deviceScaleFactor: 1 });
  const page = await ctx.newPage();
  const errors = [];
  const netImages = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  await page.route(/^https?:\/\/(?!127\.0\.0\.1)/, (route) => {
    const url = route.request().url();
    netImages.push(url);
    route.fulfill({ status: 200, contentType: 'image/svg+xml', headers: { 'Access-Control-Allow-Origin': '*' }, body: imageFor(url) });
  });
  // relay: the replayed body is fetched ~5.5 s after load (the JS API's grace period), so start the
  // clock that much earlier -- a live relay stamps sent_at when it answers
  await page.clock.install({ time: new Date((st.sent_at + SKEW_S) * 1000 - (relay ? RELAY_AFTER_MS : 0)) });
  if (transport !== 'http') {
    await page.addInitScript(([mode, stateJson, dtuMsg, replies]) => {
      const log = window.__c4log = [];
      const send = (fn, x) => setTimeout(() => window[fn](x), 20);
      window.C4 = {
        subscribeToDataToUi: (b) => log.push('subscribeToDataToUi:' + b),
        subscribeToVariable: (name, b) => {
          log.push('subscribeToVariable:' + name);
          if (mode === 'c4-var' && name === 'STATE_JSON') send('onVariable', { name: 'STATE_JSON', value: stateJson });
        },
        sendCommand: (name, params, async, proto) => {
          log.push('sendCommand:' + name + ':' + params);
          if (mode === 'relay') return; // the JS API delivers nothing
          if (name === 'GET_STATE' && mode === 'c4-dtu') send('onDataToUi', { [dtuMsg.cmd]: dtuMsg.params });
          if (name === 'GET_ARTWORK') {
            const url = JSON.parse(params).url;
            const r = replies.find((x) => x.params.url === url);
            send('onDataToUi', { NOW_PLAYING_ARTWORK: r ? r.params : { url, error: 'not in current state' } });
          }
        },
      };
    }, [transport, JSON.stringify(st), dtu, artReplies]);
  }
  let q = (transport === 'http' ? '?api=/state/' + sc.name : '?x=1') + (extraQuery || '');
  if (relay) {
    // the driver's own web view URL, relay host swapped for the local replay server
    const wv = new URL(rec.webview_url.replace(/^controller:/, 'http:'));
    if (!/^http:\/\/192\.168\.1\.5:8487$/.test(wv.searchParams.get('relay')) || wv.searchParams.get('k') !== rec.token) failures.push(sc.name + ': driver web view URL ' + rec.webview_url);
    wv.searchParams.set('relay', relay.base);
    q = wv.search;
  }
  await page.goto(base + '/index.html' + q);
  if (relay) await page.clock.fastForward(RELAY_AFTER_MS); // the JS API had its ~5 s
  await page.waitForFunction(() => document.body.classList.contains('mode-np') ||
    (document.body.classList.contains('mode-idle') && document.getElementById('idle-title').textContent !== 'Connecting'), null, { timeout: 8000 })
    .catch(() => errors.push('never rendered'));
  await page.waitForTimeout(1800); // artwork, crossfades, GET_ARTWORK round trips
  const ui = await page.evaluate(() => {
    const t = (sel) => { const e = document.querySelector(sel); return e ? e.textContent.trim() : null; };
    const artImg = document.querySelector('#art-stack .art-layer.is-on img');
    const icon = document.querySelector('.app-icon');
    return {
      mode: document.body.className, title: t('h1.title'), ep: t('.ep-code'), subline: t('.subline'), artist: t('.artist'),
      chips: document.querySelectorAll('.ratings .chip').length, cast: document.querySelectorAll('.rail .person').length,
      progHidden: document.getElementById('progress').classList.contains('is-hidden'),
      left: t('#progress-left'), right: t('#progress-right'), foot: t('#foot'), idleTitle: t('#idle-title'), idleSub: t('#idle-sub'),
      art: artImg ? artImg.getAttribute('src') : null, gen: !!document.querySelector('#art-stack .art-layer.is-on .gen'),
      icon: icon ? icon.getAttribute('src') : null, nowS: Date.now() / 1000, c4log: window.__c4log || [],
      connOn: document.getElementById('conn').classList.contains('is-on'),
      meta: t('.info-body .meta'),
      secTop: (() => { const e = document.querySelector('#sections > *'); return e ? e.getBoundingClientRect().top : null; })(),
      vh: window.innerHeight, kiosk: document.body.classList.contains('kiosk'),
      sectionsShown: (() => { const e = document.getElementById('sections'); return !!e.firstChild && getComputedStyle(e).display !== 'none'; })(),
      raw: window.__npLast || null,
    };
  });
  const tag = `${sc.name}/${transport}${extraQuery ? extraQuery.replace(/^&/, '?') : ''}/${viewport.width}x${viewport.height}`;
  // "Reconnecting" pill must not cover the top bar's room name or clock
  const overlap = await page.evaluate(() => {
    const c = document.getElementById('conn');
    c.style.transition = 'none'; c.classList.add('is-on');
    const r = (e) => e.getBoundingClientRect(), a = r(c);
    const hit = (b) => b.width > 0 && !(a.right <= b.left || a.left >= b.right || a.bottom <= b.top || a.top >= b.bottom);
    const res = ['clock', 'room'].filter((id) => hit(r(document.getElementById(id))));
    c.classList.remove('is-on');
    return res;
  });
  errors.forEach((e) => failures.push(tag + ': ' + e));

  // ---- expectations derived from the REAL engine output
  const m = st.media, d = st.details, pb = st.playback;
  const idle = sc.name === 'idle' || sc.name === 'off';
  if (idle) {
    check(/mode-idle/.test(ui.mode), tag + ': idle mode');
    check(ui.idleTitle === 'Nothing playing in ' + st.room.name, tag + ': idle title ' + ui.idleTitle);
    if (pb.state === 'off') check(/ is off$/.test(ui.idleSub), tag + ': off sub ' + ui.idleSub);
  } else {
    check(/mode-np/.test(ui.mode), tag + ': np mode');
    const title = m.kind === 'episode' ? m.series_title : m.kind === 'live_tv' ? ((d && d.live && d.live.program_title) || m.title) : m.title;
    check(ui.title === title, `${tag}: title "${ui.title}" != "${title}"`);
    if (m.kind === 'episode') {
      check(ui.ep === `S${m.season} · E${m.episode}`, tag + ': S·E ' + ui.ep);
      check(ui.subline && ui.subline.indexOf((d && d.episode && d.episode.title) || m.episode_title) >= 0, tag + ': episode title in subline');
    }
    if (m.kind === 'music') {
      check(ui.artist === m.artist, tag + ': artist ' + ui.artist);
      const mt = /Track (\d+) of (\d+)/.exec(ui.meta || '');
      check(!mt || +mt[1] <= +mt[2], tag + ': inconsistent "' + (mt && mt[0]) + '"');
    }
    if (/mode-np/.test(ui.mode)) check(overlap.length === 0, tag + ': reconnecting pill overlaps ' + overlap.join(','));
    // above the fold: when sections follow the hero, the first one peeks in landscape desktop views
    if (ui.secTop != null && viewport.width >= 1024) check(ui.secTop < ui.vh - 24, `${tag}: next section does not peek (top ${Math.round(ui.secTop)} of ${ui.vh})`);
    if (d) {
      const r = d.ratings || {};
      const chips = (r.imdb && r.imdb.score > 0 ? 1 : 0) + (r.rotten_tomatoes != null ? 1 : 0) + (r.metacritic != null ? 1 : 0) + (r.tmdb > 0 ? 1 : 0);
      check(ui.chips === chips, `${tag}: rating chips ${ui.chips} != ${chips}`);
      const cast = (d.cast || []).filter((c) => c && c.name).length;
      check(ui.cast === (ui.kiosk ? 0 : Math.min(40, cast)), `${tag}: cast ${ui.cast} != ${cast}`);
      if ((d.attribution || []).length) check(ui.foot.indexOf('Metadata: ' + d.attribution.join(' · ')) >= 0, tag + ': attribution ' + ui.foot);
    } else {
      check(ui.chips === 0 && ui.cast === 0, tag + ': no details -> no chips/cast');
      check(ui.foot.indexOf('Metadata:') < 0, tag + ': no attribution without details');
    }
    if (pb.is_live || m.kind === 'live_tv') {
      check(!ui.progHidden && /–/.test(ui.left || '') && /left$/.test(ui.right || ''), `${tag}: live progress "${ui.left}" "${ui.right}"`);
    } else if (pb.duration_s) {
      let pos = pb.position_s || 0;
      if (pb.state === 'playing') pos += ui.nowS - SKEW_S - pb.position_updated_at;
      pos = Math.min(pos, pb.duration_s);
      const got = parseDur(ui.left || '0');
      check(!ui.progHidden && Math.abs(got - pos) <= 3, `${tag}: progress ${ui.left} expected ~${fmtDur(pos)} (sent_at skew correction)`);
    }
    // LAN images: direct in http mode; via GET_ARTWORK (never directly) in Navigator mode
    const lanUrls = [m.artwork_url, st.source.app_icon_url].filter((u) => u && isLan(u));
    for (const u of lanUrls) {
      if (transport === 'http') continue;
      check(netImages.indexOf(u) < 0, `${tag}: LAN image loaded directly in Navigator mode: ${u}`);
    }
    const viaRelay = (u) => relay.base + '/api/artwork?url=' + encodeURIComponent(u) + '&k=' + rec.token;
    if (transport !== 'http' && st.source.app_icon_url && isLan(st.source.app_icon_url)) {
      if (relay) check(ui.icon === viaRelay(st.source.app_icon_url), tag + ': app icon from the relay, got ' + String(ui.icon).slice(0, 60));
      else {
        check(ui.c4log.some((l) => l.indexOf('sendCommand:GET_ARTWORK:') === 0 && l.indexOf(JSON.stringify(st.source.app_icon_url)) > 0), tag + ': GET_ARTWORK for the app icon');
        check(/^data:image\/png/.test(ui.icon || ''), tag + ': app icon from driver data URI, got ' + String(ui.icon).slice(0, 40));
      }
    }
    const shownLan = !(d && d.poster_url) && m.artwork_url && isLan(m.artwork_url);
    if (shownLan) {
      if (transport === 'http') check(ui.art === m.artwork_url, `${tag}: artwork direct ${ui.art}`);
      else if (relay) check(ui.art === viaRelay(m.artwork_url), `${tag}: artwork via the relay, got ${String(ui.art).slice(0, 60)}`);
      else check(/^data:image\/png;base64,/.test(ui.art || ''), `${tag}: artwork via GET_ARTWORK, got ${String(ui.art).slice(0, 40)}`);
    }
  }
  check(!ui.connOn, tag + ': reconnecting pill shown');
  if (extraQuery && /kiosk=1/.test(extraQuery)) {
    check(ui.kiosk && !ui.sectionsShown && !/has-sections/.test(ui.mode), tag + ': kiosk = single screen, no sections');
  }
  if (transport === 'c4-dtu') check(ui.raw && ui.raw.dataToUi != null && ui.raw.via === 'dataToUi', tag + ': __npLast.dataToUi recorded');
  if (relay) {
    check(ui.raw && ui.raw.via === 'relay', tag + ': __npLast.via relay, got ' + (ui.raw && ui.raw.via));
    check(relayLog.some((l) => l.indexOf('GET /api/state?k=' + rec.token) === 0), tag + ': relay polled with k ' + relayLog.join(' | '));
    check(!relayLog.some((l) => /^OPTIONS/.test(l)), tag + ': no CORS preflight');
    for (const u of idle ? [] : Object.keys(rec.artwork)) {
      if (u === m.artwork_url && d && d.poster_url) continue; // hero shows the TMDB poster instead
      check(relayLog.some((l) => l.indexOf('GET /api/artwork?url=' + encodeURIComponent(u)) === 0), tag + ': LAN image via relay: ' + u);
    }
    check(!ui.c4log.some((l) => l.indexOf('sendCommand:GET_ARTWORK:') === 0), tag + ': no GET_ARTWORK in relay mode');
  }
  if (transport === 'c4-var') check(ui.raw && ui.raw.variable != null, tag + ': __npLast.variable recorded');
  if (transport !== 'http') check(ui.c4log.some((l) => /^sendCommand:GET_STATE/.test(l)), tag + ': GET_STATE sent');
  if (shot) await page.screenshot({ path: path.join(SHOTS, shot) });
  await ctx.close();
  if (relay) relay.srv.close();
  return ui;
}

// ---------------------------------------------------------------- same media_key: unenriched -> enriched
async function runSequence(browser, base, sc, transport) {
  const pre = read(sc.name + '.pre.json'), fin = read(sc.name + '.json');
  const ps = JSON.parse(pre), st = JSON.parse(fin), d = st.details;
  const bumped = JSON.parse(fin); // a later update of the same media, same image URLs (position moved)
  bumped.version += 1; bumped.playback.position_s = (bumped.playback.position_s || 0) + 5;
  const artReplies = JSON.parse(read(sc.name + '.artwork.json'));
  const tag = `${sc.name}/sequence/${transport}`;
  const id = sc.name + '-' + transport;
  seqBody[id] = pre;
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 });
  const page = await ctx.newPage();
  const errors = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  await page.route(/^https?:\/\/(?!127\.0\.0\.1)/, (route) => {
    route.fulfill({ status: 200, contentType: 'image/svg+xml', headers: { 'Access-Control-Allow-Origin': '*' }, body: imageFor(route.request().url()) });
  });
  if (transport !== 'http') {
    await page.addInitScript(([stateJson, replies]) => {
      const log = window.__c4log = [];
      const send = (fn, x) => setTimeout(() => window[fn](x), 20);
      window.__push = (json) => send('onDataToUi', { NOW_PLAYING: { state: json } });
      window.C4 = {
        subscribeToDataToUi: () => {}, subscribeToVariable: () => {},
        sendCommand: (name, params) => {
          log.push('sendCommand:' + name + ':' + params);
          if (name === 'GET_STATE') send('onDataToUi', { NOW_PLAYING: { state: stateJson } });
          if (name === 'GET_ARTWORK') {
            const url = JSON.parse(params).url, r = replies.find((x) => x.params.url === url);
            send('onDataToUi', { NOW_PLAYING_ARTWORK: r ? r.params : { url, error: 'not in current state' } });
          }
        },
      };
    }, [pre, artReplies]);
  }
  await page.goto(base + '/index.html' + (transport === 'http' ? '?api=/seq/' + id : '?x=1'));
  const artSrc = () => page.evaluate(() => { const i = document.querySelector('#art-stack .art-layer.is-on img'); return i ? i.getAttribute('src') : null; });
  const bgSrc = () => page.evaluate(() => { const i = document.querySelector('#bg .bg-layer.is-on .bg-photo img'); return i ? i.getAttribute('src') : null; });
  const waitFor = async (fn, want, ms) => {
    const end = Date.now() + ms; let v;
    while (Date.now() < end) { v = await fn(); if (want(v)) return v; await page.waitForTimeout(100); }
    return v;
  };
  // 1. unenriched: provider (LAN) artwork -- direct in http mode, driver data: URI in Navigator mode
  const a0 = await waitFor(artSrc, (v) => !!v, 6000);
  if (transport === 'http') check(a0 === ps.media.artwork_url, `${tag}: pre artwork ${a0}`);
  else check(/^data:image\/png;base64,/.test(a0 || ''), `${tag}: pre artwork via GET_ARTWORK, got ${String(a0).slice(0, 40)}`);
  // 2. same media_key, enrichment attached -> TMDB poster + backdrop replace the provider artwork
  if (transport === 'http') seqBody[id] = fin; else await page.evaluate((j) => window.__push(j), fin);
  const a1 = await waitFor(artSrc, (v) => v === d.poster_url, 6000);
  check(a1 === d.poster_url, `${tag}: enriched poster not shown (art ${String(a1).slice(0, 60)})`);
  if (d.backdrop_url) {
    const b1 = await waitFor(bgSrc, (v) => v === d.backdrop_url, 4000);
    check(b1 === d.backdrop_url, `${tag}: enriched backdrop not shown (${b1})`);
  }
  check(await page.evaluate((t) => document.querySelector('h1.title').textContent === t, st.media.title), tag + ': title');
  // 3. another update with the same image URLs: the artwork <img> node must survive (no reload / flicker)
  await page.waitForTimeout(1600); // let the crossfade finish
  await page.evaluate(() => { document.querySelector('#art-stack .art-layer.is-on img').__npMark = 1; });
  if (transport === 'http') seqBody[id] = JSON.stringify(bumped); else await page.evaluate((j) => window.__push(j), JSON.stringify(bumped));
  await page.waitForTimeout(transport === 'http' ? 2600 : 400); // http polls every 2 s
  const kept = await page.evaluate(() => {
    const layers = document.querySelectorAll('#art-stack .art-layer');
    const i = document.querySelector('#art-stack .art-layer.is-on img');
    return { n: layers.length, marked: !!(i && i.__npMark), src: i && i.getAttribute('src').slice(0, 70) };
  });
  check(kept.marked && kept.n === 1 && kept.src === d.poster_url.slice(0, 70), `${tag}: unchanged-URL update recreated the artwork (${JSON.stringify(kept)})`);
  errors.forEach((e) => failures.push(tag + ': ' + e));
  await ctx.close();
}

// ---------------------------------------------------------------- Apple TV driver source over time
// atv_seq.json: the real driver's states for playing (artwork) -> same title, ARTWORK_URL cleared +
// Paused -> VALID=0. The old picture must go (generated placeholder), progress must stop advancing
// while paused, VALID=0 must show the idle screen. Then the progress estimate bounds: past the
// duration it is held (stale, no "Ends"), with an unknown duration it stops 4 h after the observation.
async function runAtvLifecycle(browser, base) {
  const file = path.join(STATES, 'atv_seq.json');
  if (!fs.existsSync(file)) { failures.push('atv_seq.json missing'); return; }
  const steps = JSON.parse(fs.readFileSync(file, 'utf8')).steps;
  const s0 = JSON.parse(steps[0]);
  const tag = 'atv_lifecycle/c4-dtu';
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 });
  const page = await ctx.newPage();
  const errors = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  await page.route(/^https?:\/\/(?!127\.0\.0\.1)/, (route) => {
    route.fulfill({ status: 200, contentType: 'image/svg+xml', headers: { 'Access-Control-Allow-Origin': '*' }, body: imageFor(route.request().url()) });
  });
  await page.addInitScript((first) => {
    const send = (fn, x) => setTimeout(() => window[fn](x), 20);
    window.__push = (json) => send('onDataToUi', { NOW_PLAYING: { state: json } });
    window.C4 = {
      subscribeToDataToUi: () => {}, subscribeToVariable: () => {},
      sendCommand: (name, params) => {
        if (name === 'GET_STATE') send('onDataToUi', { NOW_PLAYING: { state: first } });
        if (name === 'GET_ARTWORK') send('onDataToUi', { NOW_PLAYING_ARTWORK: { url: JSON.parse(params).url, error: 'not in current state' } });
      },
    };
  }, steps[0]);
  await page.clock.install({ time: new Date((s0.sent_at + SKEW_S) * 1000) }); // device clock 2 min off
  await page.goto(base + '/index.html?x=1');
  const look = () => page.evaluate(() => {
    const on = document.querySelector('#art-stack .art-layer.is-on');
    const img = on && on.querySelector('img');
    const p = document.getElementById('progress');
    return {
      img: img ? img.getAttribute('src') : null, gen: !!(on && on.querySelector('.gen')),
      idle: document.body.classList.contains('mode-idle'), np: document.body.classList.contains('mode-np'),
      left: document.getElementById('progress-left').textContent, right: document.getElementById('progress-right').textContent,
      hidden: p.classList.contains('is-hidden'), paused: p.classList.contains('is-paused'), stale: p.classList.contains('is-stale'),
      idleTitle: document.getElementById('idle-title').textContent,
      bgImgs: Array.prototype.map.call(document.querySelectorAll('#bg .bg-layer.is-on img'), (i) => i.getAttribute('src')),
    };
  });
  const waitFor = async (want, ms) => {
    const end = Date.now() + ms; let v;
    while (Date.now() < end) { v = await look(); if (want(v)) return v; await page.waitForTimeout(100); }
    return v;
  };
  // 1. playing, artwork reported by the Apple TV driver
  let v = await waitFor((x) => x.img === s0.media.artwork_url, 6000);
  check(v.img === s0.media.artwork_url, `${tag}: artwork shown (${v.img})`);
  check(!v.stale && !v.hidden && !v.paused, `${tag}: live progress ${JSON.stringify(v)}`);
  // 2. same title, ARTWORK_URL cleared, Paused: the old picture must not stay
  await page.evaluate((j) => window.__push(j), steps[1]);
  v = await waitFor((x) => x.img === null && x.gen, 4000);
  check(v.img === null && v.gen, `${tag}: cleared artwork -> generated placeholder, got ${JSON.stringify(v)}`);
  await page.waitForTimeout(1600);
  v = await look();
  check(v.img === null && v.bgImgs.indexOf(s0.media.artwork_url) < 0, `${tag}: old image gone from artwork and backdrop`);
  check(v.paused && !v.stale, `${tag}: paused progress`);
  const left1 = v.left;
  await page.waitForTimeout(2200);
  v = await look();
  check(v.left === left1 && /^13:20/.test(v.left), `${tag}: paused progress does not advance (${left1} -> ${v.left})`);
  // 3. VALID=0: idle screen (metadata, artwork, progress and playback state cleared)
  await page.evaluate((j) => window.__push(j), steps[2]);
  v = await waitFor((x) => x.idle, 4000);
  check(v.idle && !v.np && /^Nothing playing/.test(v.idleTitle), `${tag}: VALID=0 -> idle screen, got ${JSON.stringify(v)}`);
  // 4. progress estimate bounds (same page, Playing again with an old observation)
  const stale = JSON.parse(steps[0]);
  stale.version += 10; stale.playback.position_updated_at = stale.sent_at - 3600; // 754 s + 1 h > 2280 s
  await page.evaluate((j) => window.__push(j), JSON.stringify(stale));
  v = await waitFor((x) => x.np && x.stale, 4000);
  check(v.stale && v.left === '38:00' && v.right === '−0:00' && v.right.indexOf('Ends') < 0,
    `${tag}: past the duration -> held at the duration, stale, no "Ends" (${JSON.stringify(v)})`);
  const open = JSON.parse(steps[0]);
  open.version += 20; open.playback.duration_s = null; open.playback.position_updated_at = open.sent_at - 5 * 3600;
  await page.evaluate((j) => window.__push(j), JSON.stringify(open));
  v = await waitFor((x) => x.np && x.stale && x.left !== '38:00', 4000);
  const want = '4:12:34'; // 754 s + 4 h, frozen
  check(v.stale && v.left === want, `${tag}: unknown duration -> stops 4 h after the observation (${v.left}, want ${want})`);
  await page.waitForTimeout(2200);
  check((await look()).left === want, `${tag}: frozen estimate does not advance`);
  const fresh = JSON.parse(steps[0]);
  fresh.version += 30; fresh.playback.duration_s = null; fresh.playback.position_updated_at = fresh.sent_at;
  await page.evaluate((j) => window.__push(j), JSON.stringify(fresh));
  v = await waitFor((x) => !x.stale, 4000);
  check(!v.stale, `${tag}: a fresh observation is live again`);
  await page.screenshot({ path: path.join(SHOTS, 'atv_lifecycle-stale.png') });
  errors.forEach((e) => failures.push(tag + ': ' + e));
  await ctx.close();
}

(async () => {
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = 'http://127.0.0.1:' + server.address().port;
  const browser = await chromium.launch();
  const DESK = { width: 1280, height: 800 }, PHONE = { width: 390, height: 844 }, HD = { width: 1920, height: 1080 };
  let runs = 0;
  for (const sc of index.scenarios) {
    for (const transport of ['http', 'c4-dtu', 'c4-var', 'relay']) {
      await run(browser, base, sc, transport, DESK, `${sc.name}-${transport}-1280x800.png`); runs++;
    }
    await run(browser, base, sc, 'c4-dtu', PHONE, `${sc.name}-c4-dtu-390x844.png`); runs++;
    if (['episode', 'music', 'movie'].indexOf(sc.name) >= 0) { await run(browser, base, sc, 'http', HD, `${sc.name}-http-1920x1080.png`); runs++; }
    if (['episode', 'music'].indexOf(sc.name) >= 0) { await run(browser, base, sc, 'http', DESK, `${sc.name}-kiosk-1280x800.png`, '&kiosk=1'); runs++; }
    if (sc.pre) for (const transport of ['http', 'c4-dtu']) { await runSequence(browser, base, sc, transport); runs++; }
  }
  await runAtvLifecycle(browser, base); runs++;
  await browser.close();
  server.close();
  if (failures.length) {
    console.log('E2E FAILED (' + failures.length + '):\n  ' + failures.join('\n  '));
    process.exit(1);
  }
  console.log(`E2E PASSED: ${index.scenarios.length} scenarios, ${runs} page renders, screenshots in ${SHOTS}`);
})().catch((e) => { console.error(e); process.exit(2); });
