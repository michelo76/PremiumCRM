#!/usr/bin/env node
/* The page's isLan() (driver/www/index.html) and c4/artwork.lua is_lan() must agree: the page
 * asks the driver for exactly the URLs the driver considers LAN-only.  node tests/e2e/islan_parity.js */
'use strict';
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const root = path.resolve(__dirname, '../..');
const html = fs.readFileSync(path.join(root, 'driver/www/index.html'), 'utf8');
const grab = (name) => { const i = html.indexOf('function ' + name + '('); const j = html.indexOf('\n  }\n', i); if (i < 0 || j < 0) throw new Error('no ' + name); return html.slice(i, j + 4); };
// eslint-disable-next-line no-new-func
const isLan = new Function(grab('str') + grab('isLan') + 'return isLan;')();
const URLS = ['http://10.1.2.3/a.jpg', 'http://172.16.0.1:8080/x', 'http://172.31.255.1/x', 'http://172.32.0.1/x',
  'http://192.168.1.10:8765/v1/devices/a/artwork?v=1', 'http://homeassistant.local:8123/api/x', 'http://nas.lan/x',
  'http://router.home.arpa/x', 'http://127.0.0.1/x', 'http://169.254.1.1/x', 'http://nas/x', 'http://localhost:8123/x',
  '/api/media_player_proxy/x', 'img/x.png', 'http://[fd00::1]:80/x', 'http://[fe80::1]/x', 'http://[::1]/x', 'http://[2001:db8::1]/x',
  'http://user:pw@192.168.0.2/x', 'https://image.tmdb.org/t/p/w500/x.jpg', 'http://8.8.8.8/x', 'https://is1-ssl.mzstatic.com/x.jpg',
  'data:image/png;base64,AAAA', 'HTTP://192.168.1.2/X', 'https://cdn.example.com:443/a.jpg'];
const lua = 'package.path="' + root + '/driver/?.lua;"..package.path; local A=require("c4.artwork"); for l in io.lines() do io.write(A.is_lan(l) and "1" or "0", "\\n") end';
const out = execFileSync('lua5.1', ['-e', lua], { input: URLS.join('\n') + '\n' }).toString().trim().split('\n');
const bad = URLS.filter((u, i) => (out[i] === '1') !== isLan(u)).map((u, i) => u + ' lua=' + out[URLS.indexOf(u)] + ' js=' + isLan(u));
if (bad.length) { console.log('isLan PARITY FAILED:\n  ' + bad.join('\n  ')); process.exit(1); }
console.log('isLan parity PASSED (' + URLS.length + ' URLs)');
