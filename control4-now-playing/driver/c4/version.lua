--[[
c4.version -- single source of the driver version. tools/build.py derives the driver.xml
<version> integer from VERSION (major*10000 + minor*100 + patch) and stamps BUILD_DATE in
the packaged copy (the source tree keeps "dev").
]]

local M = {}

M.VERSION = "1.0.0"
M.BUILD_DATE = "dev"
M.DRIVER_FILENAME = "now_playing_info"   -- c4z name without extension (webview URL depends on it)
M.PROXY_BINDING = 5001
M.WEBVIEW_URL = "controller://driver/" .. M.DRIVER_FILENAME .. "/index.html"

function M.string()
  return M.VERSION .. " (" .. M.BUILD_DATE .. ")"
end

return M
