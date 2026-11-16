#!/usr/bin/env node
/*
 * Rasterize the driver icons from the SVG sources with Playwright/Chromium.
 *   node tools/icons/render.js
 * Writes driver/www/icons/np_<size>.png, np_playing_<size>.png (16..1024) and the Composer
 * icons device_sm.png (16x16) / device_lg.png (32x32). Transparent background.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const SRC = __dirname;
const OUT = path.resolve(__dirname, '../../driver/www/icons');
const SIZES = [16, 32, 70, 90, 300, 512, 1024];
const VARIANTS = { np: 'np_default.svg', np_playing: 'np_playing.svg' };

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch();
  const page = await browser.newPage();
  for (const [prefix, file] of Object.entries(VARIANTS)) {
    const svg = fs.readFileSync(path.join(SRC, file), 'utf8');
    for (const size of SIZES) {
      await page.setViewportSize({ width: size, height: size });
      await page.setContent(
        '<!doctype html><html><body style="margin:0;background:transparent">' +
        svg.replace('<svg ', `<svg style="display:block;width:${size}px;height:${size}px" `) +
        '</body></html>');
      const buf = await page.screenshot({ omitBackground: true, clip: { x: 0, y: 0, width: size, height: size } });
      const name = `${prefix}_${size}.png`;
      fs.writeFileSync(path.join(OUT, name), buf);
      if (prefix === 'np' && size === 16) fs.writeFileSync(path.join(OUT, 'device_sm.png'), buf);
      if (prefix === 'np' && size === 32) fs.writeFileSync(path.join(OUT, 'device_lg.png'), buf);
      console.log(name, buf.length, 'bytes');
    }
  }
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
