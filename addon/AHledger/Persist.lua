--[[
  Beta workaround: the World of Warcraft: Forever beta client writes SavedVariables at logout
  and reload but never reads them back, so every session would start from defaults. Until
  Blizzard fixes the client, the small state that must survive (options, the market override,
  the watchlist with its alert prices) is mirrored into addon-registered CVars, which the client
  does persist. At load, if the saved variables came back empty, the mirror is restored. When a
  client loads saved variables normally, the mirror is never needed: loaded data always wins.

  Scans and imported price tables stay in the saved-variables file only. The file is still
  written correctly, and AHledger sync reads it from disk; price tables come from
  AHledger_Data.lua, which sync writes into the addon folder. What is mirrored about a scan is
  only when the last one happened and how big it was, so that after a reload the scan button can
  still count down the server's 15 minute allowance instead of inviting a request it will refuse.

  Format, one string split across CVars AHledgerM0..AHledgerM11 (200 characters each):
    v=1;autoScan=1;tooltip=0;...;market=forever.pvp.horde.us;ls=1758540000:53074:RealmName:Horde;w=12784:2000000:::,2589::::5
  Booleans are 1/0. ls is the last scan: time, listings, realm and faction with punctuation
  stripped. A watch entry is item id, alert below, alert above, percent under the 30 day
  median, and quantity under; an empty field is no alert.
]]
local _, NS = ...

local PREFIX = "AHledgerM"
local CHUNK = 200
local CHUNKS = 12
local registered = false

local function cvarApi()
  local c = rawget(_G, "C_CVar")
  if c and c.RegisterCVar and c.SetCVar and c.GetCVar then return c end
  return nil
end

local function register()
  local c = cvarApi()
  if NS.CVarBlocked then return nil end
  if not c or registered then return c end
  for i = 0, CHUNKS - 1 do pcall(c.RegisterCVar, PREFIX .. i, "") end
  registered = true
  return c
end

local function readMirror()
  local c = register()
  if not c then return nil end
  local parts = {}
  for i = 0, CHUNKS - 1 do
    local ok, v = pcall(c.GetCVar, PREFIX .. i)
    if not ok or type(v) ~= "string" or v == "" then break end
    parts[#parts + 1] = v
  end
  local s = table.concat(parts)
  return s ~= "" and s or nil
end

local overflowWarned = false
local function writeMirror(str)
  local c = register()
  if not c then return false end
  if #str > CHUNK * CHUNKS then
    if not overflowWarned then
      overflowWarned = true
      NS.Print(string.format("the watchlist is too long to keep across reloads on the beta client (about %d items fit); trim it or accept that it resets", math.floor((CHUNK * CHUNKS - 500) / 24)))
    end
    return false
  end
  for i = 0, CHUNKS - 1 do
    if NS.CVarBlocked then return false end
    pcall(c.SetCVar, PREFIX .. i, str:sub(i * CHUNK + 1, (i + 1) * CHUNK))
  end
  return true
end

-- Only plain characters go into the mirror: keys are known names, market keys are
-- game/ruleset/faction/region, numbers are digits. The separators ; = , : never pass.
local function clean(s)
  return (tostring(s):gsub("[^%w%./%-]", ""))
end

local function encode()
  local db = NS.Db()
  local out = { "v=1" }
  local keys = {}
  for k, v in pairs(db.settings) do
    if type(v) == "boolean" or type(v) == "string" or type(v) == "number" then keys[#keys + 1] = k end
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local v = db.settings[k]
    if type(v) == "boolean" then v = v and "1" or "0"
    elseif type(v) == "number" then v = tostring(math.floor(v))
    else v = clean(v) end
    out[#out + 1] = clean(k) .. "=" .. v
  end
  local function num(v) return v and tostring(math.floor(v)) or "" end
  if db.lastScanAt then
    out[#out + 1] = "ls=" .. table.concat({ num(db.lastScanAt), num(db.lastScanCount or 0), clean(db.lastScanRealm or ""), clean(db.lastScanFaction or "") }, ":")
  end
  local watch = {}
  for id, w in pairs(db.watch) do
    if type(id) == "number" then
      watch[#watch + 1] = table.concat({ tostring(id), num(w.below), num(w.above), num(w.pctBelow), num(w.qtyBelow) }, ":")
    end
  end
  table.sort(watch)
  out[#out + 1] = "w=" .. table.concat(watch, ",")
  return table.concat(out, ";")
end

local function decode(str)
  local settings, watch, last = {}, {}, nil
  for pair in str:gmatch("[^;]+") do
    local k, v = pair:match("^([%w]+)=(.*)$")
    if k == "ls" then
      local ts, count, realm, faction = v:match("^(%d+):(%d+):([^:]*):([^:]*)$")
      if ts then last = { ts = tonumber(ts), count = tonumber(count), realm = realm, faction = faction } end
    elseif k == "w" then
      for entry in v:gmatch("[^,]+") do
        local id, below, above, pct, qty = entry:match("^(%d+):(%d*):?(%d*):?(%d*):?(%d*)$")
        if id then
          watch[tonumber(id)] = { below = tonumber(below), above = tonumber(above), pctBelow = tonumber(pct), qtyBelow = tonumber(qty) }
        end
      end
    elseif k and k ~= "v" then
      settings[k] = v
    end
  end
  return settings, watch, last
end

local saveTimer = nil
local dirty = false

-- Writes the mirror, coalescing bursts of changes into one write.
function NS.PersistSave(immediate)
  if not cvarApi() then return end
  if immediate then
    dirty = false
    writeMirror(encode())
    return
  end
  dirty = true
  if saveTimer then return end
  if C_Timer and C_Timer.After then
    saveTimer = true
    C_Timer.After(2, function()
      saveTimer = nil
      if dirty then NS.PersistSave(true) end
    end)
  else
    NS.PersistSave(true)
  end
end

-- Called once at ADDON_LOADED after NS.Db(). Restores the mirror only when the client did not
-- load the saved variables (NS.DbCreated), so loaded data is never overwritten.
function NS.PersistRestore()
  NS.PersistState = "off"
  if not cvarApi() then return end
  NS.PersistState = "standby"
  if not NS.DbCreated then return end
  local str = readMirror()
  if not str then
    NS.PersistState = "empty"
    return
  end
  local settings, watch, last = decode(str)
  local db = NS.Db()
  local applied = 0
  if last and not db.lastScanAt then
    db.lastScanAt = last.ts
    db.lastScanCount = last.count
    db.lastScanRealm = last.realm
    db.lastScanFaction = last.faction
  end
  for k, v in pairs(settings) do
    local current = db.settings[k]
    if type(current) == "boolean" then
      db.settings[k] = (v == "1")
      applied = applied + 1
    elseif type(current) == "string" then
      db.settings[k] = v
      applied = applied + 1
    elseif type(current) == "number" and tonumber(v) then
      db.settings[k] = tonumber(v)
      applied = applied + 1
    end
  end
  for id, w in pairs(watch) do
    db.watch[id] = { below = w.below, above = w.above, pctBelow = w.pctBelow, qtyBelow = w.qtyBelow }
  end
  NS.PersistState = "restored"
  NS.PersistApplied = applied
end

function NS.PersistStatus()
  if NS.PersistState == "off" then return "saved data: client saved-variables only" end
  if NS.DbCreated then
    if NS.PersistState == "restored" then
      return "saved data: the client did not load saved variables (beta bug); options and watchlist restored from the CVar mirror"
    end
    return "saved data: the client did not load saved variables (beta bug); nothing in the CVar mirror yet, using defaults"
  end
  return "saved data: loaded from disk; CVar mirror on standby"
end
