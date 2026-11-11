#!/usr/bin/env node
/*
 * Now Playing Info – mock dev server (no npm dependencies).
 *
 *   node tools/mock-server/server.js [--port 8099] [--fixture movie-full] [--cycle-seconds 20]
 *
 * Serves driver/www at "/" and a fake controller API at "/api/state".
 *
 * Fixture selection for /api/state (first match wins):
 *   1. ?fixture=<name> on the api request (the page forwards its own ?fixture= param)
 *   2. cookie  np_fixture=<name>
 *   3. the server-wide current fixture (--fixture, or set via /_mock/set?fixture=<name>)
 * The special name "cycle" rotates through all non-idle fixtures every --cycle-seconds
 * and periodically re-publishes the playback position (version bump) like a real driver.
 *
 * Dev/test endpoints:
 *   /_mock/                     index page with links to every fixture
 *   /_mock/set?fixture=<name>   change the server-wide fixture (no page reload needed)
 *   /_mock/fail?on=1|0          make /api/state fail with 503 (to test "reconnecting")
 *   /_mock/stats                request counters (200 vs 304) as JSON
 *   /_mock/img/<w>x<h>/<seed>.svg?label=..  generated same-origin artwork (offline testing)
 *
 * Fixture timestamps are written against the epoch 1790000000; the server shifts every
 * known time field so that "1790000000" means "the moment this fixture was activated".
 */
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const url = require('url');

const args = process.argv.slice(2);
function arg(name, def) {
  const i = args.indexOf('--' + name);
  return i >= 0 && args[i + 1] ? args[i + 1] : def;
}

const PORT = parseInt(arg('port', process.env.PORT || '8099'), 10);
const CYCLE_SECONDS = Math.max(3, parseFloat(arg('cycle-seconds', '20')));
const WWW = path.resolve(__dirname, '../../driver/www');
const FIXTURES = path.resolve(__dirname, 'fixtures');
const BASE_EPOCH = 1790000000;

let current = arg('fixture', 'movie-full');
let failMode = false;
let generation = 0; // bumped whenever the server-wide fixture changes
const activatedAt = {}; // fixture name -> epoch seconds when first served (per generation)
const stats = { ok: 0, notModified: 0, failed: 0 };

function listFixtures() {
  return fs.readdirSync(FIXTURES)
    .filter((f) => f.endsWith('.json'))
    .map((f) => f.slice(0, -5))
    .sort();
}

function loadFixture(name) {
  if (!/^[a-z0-9-]+$/i.test(name)) return null;
  const p = path.join(FIXTURES, name + '.json');
  if (!fs.existsSync(p)) return null;
  return JSON.parse(fs.readFileSync(p, 'utf8'));
}

const nowS = () => Date.now() / 1000;

function shiftTimes(state, delta) {
  const shift = (v) => (typeof v === 'number' ? v + delta : v);
  state.updated_at = shift(state.updated_at);
  if (state.playback) state.playback.position_updated_at = shift(state.playback.position_updated_at);
  const live = state.details && state.details.live;
  if (live) {
    live.program_start = shift(live.program_start);
    live.program_end = shift(live.program_end);
    if (live.next) live.next.start = shift(live.next.start);
  }
  return state;
}

function cycleNames() {
  return listFixtures().filter((n) => ['idle', 'off', 'all-null'].indexOf(n) < 0);
}

function resolveState(name) {
  const t = nowS();
  if (name === 'cycle') {
    const names = cycleNames();
    const slot = Math.floor(t / CYCLE_SECONDS);
    const fx = names[slot % names.length];
    const st = loadFixture(fx);
    const slotStart = slot * CYCLE_SECONDS;
    // Re-publish the position every 10 s like a real driver would (version bump).
    const tick = Math.floor((t - slotStart) / 10);
    const publishedAt = Math.floor(slotStart + tick * 10);
    shiftTimes(st, Math.floor(slotStart) - BASE_EPOCH);
    const pb = st.playback;
    if (pb && pb.state === 'playing' && typeof pb.position_s === 'number') {
      pb.position_s = pb.position_s + (publishedAt - Math.floor(slotStart));
      if (pb.duration_s && pb.position_s > pb.duration_s) pb.position_s = pb.position_s % pb.duration_s;
      pb.position_updated_at = publishedAt;
    }
    st.version = slot * 1000 + tick;
    st.updated_at = publishedAt;
    return st;
  }
  const st = loadFixture(name);
  if (!st) return null;
  const key = generation + ':' + name;
  if (!activatedAt[key]) activatedAt[key] = Math.floor(t);
  shiftTimes(st, activatedAt[key] - BASE_EPOCH);
  if (typeof st.version === 'number') st.version += generation * 1000;
  return st;
}

function parseCookies(req) {
  const out = {};
  (req.headers.cookie || '').split(';').forEach((p) => {
    const i = p.indexOf('=');
    if (i > 0) out[p.slice(0, i).trim()] = decodeURIComponent(p.slice(i + 1).trim());
  });
  return out;
}

const MIME = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.ico': 'image/x-icon',
};

function send(res, code, body, headers) {
  res.writeHead(code, Object.assign({ 'Cache-Control': 'no-cache' }, headers || {}));
  res.end(body);
}

function hashHue(s) {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
  return h % 360;
}

function mockImage(w, h, seed, label) {
  const hue = hashHue(seed);
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const hue2 = (hue + 40) % 360;
  return '<svg xmlns="http://www.w3.org/2000/svg" width="' + w + '" height="' + h + '" viewBox="0 0 ' + w + ' ' + h + '">' +
    '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">' +
    '<stop offset="0" stop-color="hsl(' + hue + ',70%,45%)"/><stop offset="1" stop-color="hsl(' + hue2 + ',60%,12%)"/></linearGradient>' +
    '<radialGradient id="r" cx="0.7" cy="0.3" r="0.6"><stop offset="0" stop-color="hsl(' + ((hue + 180) % 360) + ',80%,70%)" stop-opacity="0.55"/>' +
    '<stop offset="1" stop-color="#000" stop-opacity="0"/></radialGradient></defs>' +
    '<rect width="100%" height="100%" fill="url(#g)"/><rect width="100%" height="100%" fill="url(#r)"/>' +
    '<circle cx="' + w * 0.3 + '" cy="' + h * 0.62 + '" r="' + Math.min(w, h) * 0.22 + '" fill="hsl(' + hue + ',80%,65%)" opacity="0.35"/>' +
    (label ? '<text x="50%" y="88%" text-anchor="middle" font-family="Georgia,serif" font-size="' + Math.round(Math.min(w, h) / 9) +
      '" fill="#fff" opacity="0.9">' + esc(label) + '</text>' : '') + '</svg>';
}

function indexPage() {
  const items = listFixtures().concat(['cycle']).map((n) =>
    '<li><a href="/?fixture=' + n + '">' + n + '</a> · <a href="/?fixture=' + n + '&kiosk=1">kiosk</a> · ' +
    '<a href="/_mock/set?fixture=' + n + '">set global</a></li>').join('');
  return '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">' +
    '<title>Now Playing mock</title><body style="font:16px/1.6 sans-serif;background:#111;color:#ddd;padding:24px">' +
    '<h1>Now Playing Info – mock server</h1><p>Global fixture: <b>' + current + '</b> · fail mode: <b>' + failMode +
    '</b> (<a href="/_mock/fail?on=' + (failMode ? 0 : 1) + '">toggle</a>)</p><ul>' + items + '</ul>' +
    '<style>a{color:#f0b54a}</style>';
}

/*
 * Fake Control4 Navigator JS API, injected into index.html when the page URL has ?c4mock=1.
 * Mimics the driver side of the protocol: GET_STATE -> push full state; push again on every version change.
 * Rotates through several payload wrapper shapes to exercise the page's extractState().
 * ?c4drop=N  ignores the first N GET_STATE commands (tests the no-response -> retry path).
 * /_mock/fail?on=1 makes the fake driver go silent (no pushes, no replies).
 * window.__c4log records calls for tests.
 */
const C4_MOCK = '(' + function () {
  var q = {};
  location.search.replace(/^\?/, '').split('&').forEach(function (p) { var i = p.indexOf('='); if (i > 0) q[p.slice(0, i)] = decodeURIComponent(p.slice(i + 1)); });
  var drop = +(q.c4drop || 0), shape = 0, lastV = null, timer = null;
  var log = window.__c4log = [];
  function api() { return '/api/state' + (q.fixture ? '?fixture=' + encodeURIComponent(q.fixture) : ''); }
  function fetchState(cb) {
    fetch(api(), { cache: 'no-store' }).then(function (r) { return r.ok ? r.json() : null; }).then(cb, function () { cb(null); });
  }
  function deliver(st) {
    var json = JSON.stringify(st), s = shape++ % 5;
    log.push('push:' + s + ':' + st.version);
    if (s === 0) window.onVariable(JSON.stringify({ name: 'STATE_JSON', value: json }));
    else if (s === 1) window.onDataToUi(JSON.stringify({ STATE_JSON: json }));
    else if (s === 2) window.onDataToUi({ NOW_PLAYING: { state: json } });
    else if (s === 3) window.onDataToUi(json);
    else window.onVariable({ state: st });
  }
  function watch() { if (lastV === null) return; fetchState(function (st) { if (st && st.version !== lastV) { lastV = st.version; deliver(st); } }); }
  window.C4 = {
    subscribeToDataToUi: function (b) { log.push('subscribeToDataToUi:' + b); if (!timer) timer = setInterval(watch, 1000); },
    subscribeToVariable: function (n, b) { log.push('subscribeToVariable:' + n + ':' + b); },
    sendCommand: function (name, params, async, proto) {
      log.push('sendCommand:' + name + ':' + params + ':' + async + ':' + proto);
      if (name !== 'GET_STATE') return;
      if (drop > 0) { drop--; log.push('dropped'); return; }
      fetchState(function (st) { if (st) { lastV = st.version; deliver(st); } });
    },
  };
}.toString() + ')();';

const server = http.createServer((req, res) => {
  const u = url.parse(req.url, true);
  const p = decodeURIComponent(u.pathname || '/');

  if (p === '/api/state') {
    if (failMode) { stats.failed++; return send(res, 503, 'controller unavailable', { 'Content-Type': 'text/plain' }); }
    const cookies = parseCookies(req);
    const name = (u.query.fixture || cookies.np_fixture || current) + '';
    const st = resolveState(name);
    if (!st) return send(res, 404, JSON.stringify({ error: 'unknown fixture', fixtures: listFixtures() }), { 'Content-Type': 'application/json' });
    const body = JSON.stringify(st);
    const etag = 'W/"' + crypto.createHash('sha1').update(body).digest('hex').slice(0, 16) + '"';
    if (req.headers['if-none-match'] === etag) {
      stats.notModified++;
      return send(res, 304, '', { ETag: etag });
    }
    stats.ok++;
    return send(res, 200, body, { 'Content-Type': 'application/json; charset=utf-8', ETag: etag });
  }

  if (p === '/_mock' || p === '/_mock/') return send(res, 200, indexPage(), { 'Content-Type': 'text/html; charset=utf-8' });
  if (p === '/_mock/set') {
    const n = String(u.query.fixture || '');
    if (n !== 'cycle' && !loadFixture(n)) return send(res, 404, 'unknown fixture');
    current = n; generation++;
    return send(res, 200, JSON.stringify({ fixture: current }), { 'Content-Type': 'application/json' });
  }
  if (p === '/_mock/fail') {
    failMode = String(u.query.on) === '1';
    return send(res, 200, JSON.stringify({ failMode }), { 'Content-Type': 'application/json' });
  }
  if (p === '/_mock/stats') return send(res, 200, JSON.stringify(stats), { 'Content-Type': 'application/json' });
  const im = /^\/_mock\/img\/(\d{2,4})x(\d{2,4})\/([\w-]+)\.svg$/.exec(p);
  if (im) {
    return send(res, 200, mockImage(+im[1], +im[2], im[3], u.query.label || ''), {
      'Content-Type': 'image/svg+xml', 'Cache-Control': 'max-age=3600',
    });
  }

  // Static files from driver/www (no directory traversal).
  let rel = p === '/' ? '/index.html' : p;
  const file = path.normalize(path.join(WWW, rel));
  if (file.indexOf(WWW) !== 0) return send(res, 403, 'forbidden');
  fs.stat(file, (err, s) => {
    if (err || !s.isFile()) return send(res, 404, 'not found');
    let body = fs.readFileSync(file);
    if (rel === '/index.html' && u.query.c4mock === '1') {
      // Inject the fake Navigator API before the app script (mock server only; never shipped).
      const html = body.toString('utf8');
      const i = html.indexOf('<script>');
      body = html.slice(0, i) + '<script>' + C4_MOCK + '</script>\n' + html.slice(i);
    }
    send(res, 200, body, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
  });
});

server.listen(PORT, () => {
  console.log('Now Playing mock server on http://localhost:' + PORT + '/  (fixtures: /_mock/)');
  console.log('Fixtures: ' + listFixtures().join(', ') + ', cycle');
});
