--[[
Now Playing Info -- Control4 DriverWorks driver (entry points only).

Shows what is playing in a room (Roku ECP, Apple TV via the companion bridge, Home
Assistant media players, Control4 room media), enriched with TMDB / OMDb / Gracenote /
iTunes+MusicBrainz metadata, as Control4 variables + events and as a web view button.
Purely informational: no transport control.

All logic lives in c4/*.lua (glue) and np/*.lua (platform-agnostic core). Every entry point
below goes through app:dispatch, which runs it under xpcall and logs the traceback: a Lua
error never kills the driver.
]]

local ok_load, App = pcall(require, "c4.app")
local app
if ok_load then
  app = App.new(C4, {
    properties = function() return Properties or {} end,
    print = function(...) print(...) end,
  })
else
  print("NowPlaying: failed to load c4.app: " .. tostring(App))
  if C4 and C4.ErrorLog then pcall(C4.ErrorLog, C4, "NowPlaying: failed to load c4.app: " .. tostring(App)) end
end

NOW_PLAYING_APP = app -- for tests / debugging from the Lua console

local function call(method, ...)
  if not app then return nil end
  return app:dispatch(method, ...)
end

function OnDriverInit(driverInitType) call("on_init", driverInitType) end
function OnDriverLateInit(driverInitType) call("on_late_init", driverInitType) end
function OnDriverDestroyed(driverInitType) call("on_destroyed", driverInitType) end

function OnPropertyChanged(strProperty) call("on_property_changed", strProperty) end

function ExecuteCommand(strCommand, tParams) call("execute_command", strCommand, tParams) end

-- Synchronous request from the web view (C4.sendCommand(..., async=false)): returns a string.
function UIRequest(strCommand, tParams)
  local res = call("ui_request", strCommand, tParams)
  if type(res) ~= "string" then return "" end
  return res
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  call("received_from_proxy", idBinding, strCommand, tParams)
end

function OnWatchedVariableChanged(idDevice, idVariable, strValue)
  call("on_watched_variable_changed", idDevice, idVariable, strValue)
end

function OnServerDataIn(nHandle, strData) call("on_server_data_in", nHandle, strData) end

function OnServerConnectionStatusChanged(nHandle, nPort, strStatus)
  call("on_server_status", nHandle, nPort, strStatus)
end
