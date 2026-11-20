#!/bin/sh
# Real-Lua -> real-UI end-to-end check.
#   1. tests/e2e/gen_states.lua runs the REAL driver (driver.lua + c4/* + np/*) on the C4 mock with
#      scripted Roku / Home Assistant / bridge / TMDB / OMDb / iTunes / Gracenote fixtures and
#      writes the exact STATE_JSON, DataToUI and GET_ARTWORK payloads (lua5.1 and luajit must agree).
#      plus the driver's real LAN relay answers (/api/state 200/304/401, /api/artwork bytes).
#   2. tests/e2e/render.js loads each into the real driver/www/index.html with Playwright through
#      the HTTP transport, the fake window.C4 transport and the LAN relay (silent JS API), asserts
#      what rendered, takes screenshots.
#   3. tests/e2e/mock_c4.js: the mock server's fake Navigator honouring the protocol/proxy flag,
#      GET_ARTWORK, the relay fallback, bad-key backoff and remote clients.
# Usage: sh tools/e2e.sh [out_dir]      (default build/e2e; screenshots in <out_dir>/shots)
set -eu
cd "$(dirname "$0")/.."
OUT="${1:-build/e2e}"
lua5.1 tests/e2e/gen_states.lua "$OUT"
if command -v luajit >/dev/null 2>&1; then
  luajit tests/e2e/gen_states.lua "$OUT/luajit" >/dev/null
  for f in "$OUT"/*.json; do cmp -s "$f" "$OUT/luajit/$(basename "$f")" || { echo "lua5.1/luajit differ: $f"; exit 1; }; done
fi
node tests/e2e/render.js "$OUT" "$OUT/shots"
NP_SHOTS="$OUT/shots" node tests/e2e/mock_c4.js
node tests/e2e/islan_parity.js
