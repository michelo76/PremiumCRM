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
 *
 * The browser clock is set to sent_at + 120 s, so the progress labels prove that the page
 * corrects clock skew with the driver's sent_at. Remote images are served by a local route
 * (placeholder SVGs); LAN images (192.168.x) are only reachable in http mode -- in Navigator
 * mode the page must ask the driver instead (asserted).
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
fs.mkdirSync(SHOTS, { recursive: true });

const index = JSON.parse(fs.readFileSync(path.join(STATES, 'index.json'), 'utf8'));
const read = (n) => fs.readFileSync(path.join(STATES, n), 'utf8');

// ---------------------------------------------------------------- local server (page + states)
const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/' || u.pathname === '/index.html') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(fs.readFileSync(path.join(WWW, 'index.html')));
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

async function run(browser, base, sc, transport, viewport, shot, extraQuery) {
  const st = JSON.parse(read(sc.name + '.json'));
  const dtu = JSON.parse(read(sc.name + '.dtu.json'));
  const artReplies = JSON.parse(read(sc.name + '.artwork.json'));
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
  await page.clock.install({ time: new Date((st.sent_at + SKEW_S) * 1000) });
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
  const q = (transport === 'http' ? '?api=/state/' + sc.name : '?x=1') + (extraQuery || '');
  await page.goto(base + '/index.html' + q);
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
    if (transport !== 'http' && st.source.app_icon_url && isLan(st.source.app_icon_url)) {
      check(ui.c4log.some((l) => l.indexOf('sendCommand:GET_ARTWORK:') === 0 && l.indexOf(JSON.stringify(st.source.app_icon_url)) > 0), tag + ': GET_ARTWORK for the app icon');
      check(/^data:image\/png/.test(ui.icon || ''), tag + ': app icon from driver data URI, got ' + String(ui.icon).slice(0, 40));
    }
    const shownLan = !(d && d.poster_url) && m.artwork_url && isLan(m.artwork_url);
    if (shownLan) {
      if (transport === 'http') check(ui.art === m.artwork_url, `${tag}: artwork direct ${ui.art}`);
      else check(/^data:image\/png;base64,/.test(ui.art || ''), `${tag}: artwork via GET_ARTWORK, got ${String(ui.art).slice(0, 40)}`);
    }
  }
  check(!ui.connOn, tag + ': reconnecting pill shown');
  if (extraQuery && /kiosk=1/.test(extraQuery)) {
    check(ui.kiosk && !ui.sectionsShown && !/has-sections/.test(ui.mode), tag + ': kiosk = single screen, no sections');
  }
  if (transport === 'c4-dtu') check(ui.raw && ui.raw.dataToUi != null, tag + ': __npLast.dataToUi recorded');
  if (transport === 'c4-var') check(ui.raw && ui.raw.variable != null, tag + ': __npLast.variable recorded');
  if (transport !== 'http') check(ui.c4log.some((l) => /^sendCommand:GET_STATE/.test(l)), tag + ': GET_STATE sent');
  if (shot) await page.screenshot({ path: path.join(SHOTS, shot) });
  await ctx.close();
  return ui;
}

(async () => {
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = 'http://127.0.0.1:' + server.address().port;
  const browser = await chromium.launch();
  const DESK = { width: 1280, height: 800 }, PHONE = { width: 390, height: 844 }, HD = { width: 1920, height: 1080 };
  let runs = 0;
  for (const sc of index.scenarios) {
    for (const transport of ['http', 'c4-dtu', 'c4-var']) {
      await run(browser, base, sc, transport, DESK, `${sc.name}-${transport}-1280x800.png`); runs++;
    }
    await run(browser, base, sc, 'c4-dtu', PHONE, `${sc.name}-c4-dtu-390x844.png`); runs++;
    if (['episode', 'music', 'movie'].indexOf(sc.name) >= 0) { await run(browser, base, sc, 'http', HD, `${sc.name}-http-1920x1080.png`); runs++; }
    if (['episode', 'music'].indexOf(sc.name) >= 0) { await run(browser, base, sc, 'http', DESK, `${sc.name}-kiosk-1280x800.png`, '&kiosk=1'); runs++; }
  }
  await browser.close();
  server.close();
  if (failures.length) {
    console.log('E2E FAILED (' + failures.length + '):\n  ' + failures.join('\n  '));
    process.exit(1);
  }
  console.log(`E2E PASSED: ${index.scenarios.length} scenarios, ${runs} page renders, screenshots in ${SHOTS}`);
})().catch((e) => { console.error(e); process.exit(2); });
