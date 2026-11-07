--[[
  PvP (0.13.0). Two things, both off with a switch in /ahl.

  The tooltip line (option tooltipPvp). AHledger sync writes the ladder for your region into the
  data file: every character ahledger.com reads from Blizzard's own profiles, with its honor rank
  and honorable kills. Mouse over a player and the tooltip says "Rank 5 Sergeant Major, 1,234
  kills". The table is one long string, searched by name on each mouse-over and the answer kept
  for the session, so loading it costs nothing. A name the client keeps secret (an enemy in
  combat) is not looked up.

  Your own Rank Points (option pvpPoints, needs Contribute scans on; Forever only). The game keeps
  them on a hidden renown track and a currency; the addon notes their values at login, when they
  change, when a battleground starts and ends (and whether your side won), and a minute after
  the end. AHledger sync sends the notes, and ahledger.com shows your progress to the next rank
  on your character page and, across many players, what a win or a loss is worth. Only your own
  characters' numbers; nothing about anyone else. Turning the switch off deletes the notes.
]]
local _, NS = ...

-- ---------------------------------------------------------------------------------------------
-- The tooltip line
-- ---------------------------------------------------------------------------------------------

local TITLES = {
  Alliance = { "Private", "Corporal", "Sergeant", "Master Sergeant", "Sergeant Major", "Knight", "Knight-Lieutenant", "Knight-Captain", "Knight-Champion", "Lieutenant Commander", "Commander", "Marshal", "Field Marshal", "Grand Marshal" },
  Horde = { "Scout", "Grunt", "Sergeant", "Senior Sergeant", "First Sergeant", "Stone Guard", "Blood Guard", "Legionnaire", "Centurion", "Champion", "Lieutenant General", "General", "Warlord", "High Warlord" },
}
NS.PVP_TITLES = TITLES

local STALE_S = 30 * 86400 -- a table older than this is not shown
local CACHE_MAX = 2000
local NAME_MAX_BYTES = 90 -- two parts of 20 letters, any script, and the space
-- Control bytes spelled out: "%c" follows the C library's idea of a control character, which on
-- some builds takes in the bytes of every non-Latin letter.
local CONTROL_SEP = "[%z\1-\31\127:;|]"
local CONTROL_BAR = "[%z\1-\31\127|]"

local cache = {} -- name -> { rank, hk } or false, for the table it was read from
local cacheSize = 0
local cacheFor = nil -- the table's updated stamp the cache belongs to

local function comma(n)
  local s = tostring(math.floor(tonumber(n) or 0))
  return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

-- The table sync wrote, when it belongs to this region and is recent enough to show.
local function pvpTable(region, now)
  local t = AHledgerData and AHledgerData.pvp
  if type(t) ~= "table" or type(t.text) ~= "string" then return nil end
  if region and t.region ~= region then return nil end
  local updated = tonumber(t.updated) or 0
  if now and updated < now - STALE_S then return nil end
  return t
end

-- A name's rank and kills from the table, or nil. Sync writes the rows as
-- ";Name Surname:rank:kills;Name Surname:rank:kills;" (0.2.27), so every row, the first one
-- included, follows a ";". Lua drops the newline right after the opening long bracket, so a
-- table from an older sync starts with its first row bare; that row is checked on its own.
-- Pure apart from the cache; the harness calls it directly.
function NS.PvpLookup(name, region, now)
  if type(name) ~= "string" or #name < 5 or #name > NAME_MAX_BYTES or name:find(CONTROL_SEP) then return nil end
  local t = pvpTable(region, now)
  if not t then return nil end
  if cacheFor ~= t.updated then
    cache, cacheSize, cacheFor = {}, 0, t.updated
  end
  local hit = cache[name]
  if hit ~= nil then return hit or nil end
  local text = t.text
  local key = name .. ":"
  local e
  if text:sub(1, #key) == key then
    e = #key
  else
    local s
    s, e = text:find(";" .. key, 1, true)
    if not s then s, e = text:find("\n" .. key, 1, true) end
  end
  local found = false
  if e then
    local rank, hk = text:match("^(%d+):(%d+)", e + 1)
    if rank then found = { rank = tonumber(rank), hk = tonumber(hk) } end
  end
  if cacheSize >= CACHE_MAX then cache, cacheSize = {}, 0 end
  cache[name] = found
  cacheSize = cacheSize + 1
  return found or nil
end

-- "Rank 5 Sergeant Major, 1,234 kills" or "No rank, 87 kills". Pure.
function NS.PvpLine(entry, faction)
  if type(entry) ~= "table" then return nil end
  local rank = tonumber(entry.rank) or 0
  local kills = string.format("%s %s", comma(entry.hk), entry.hk == 1 and "kill" or "kills")
  if rank < 1 or rank > 14 then return "No rank, " .. kills end
  local title = TITLES[faction] and TITLES[faction][rank]
  if title then return string.format("Rank %d %s, %s", rank, title, kills) end
  return string.format("Rank %d, %s", rank, kills)
end

local function clear(v)
  if NS.ObserveClear then return NS.ObserveClear(v) end
  return v
end

-- A yes or no from the client, false when the client keeps it secret.
local function yes(v)
  if issecretvalue then
    local ok, secret = pcall(issecretvalue, v)
    if not ok or secret then return false end
  end
  return v and true or false
end

-- The name the table is keyed by: the character's own name, any "-Realm" removed.
local function unitName(unit)
  local name = clear(UnitName(unit))
  if type(name) ~= "string" then return nil end
  return (name:gsub("%-.*$", ""))
end

local function onUnitTooltip(tip)
  if not tip or (tip.IsForbidden and tip:IsForbidden()) then return end
  if tip ~= GameTooltip then return end
  if not NS.Setting("tooltipPvp") then return end
  if not tip.GetUnit then return end
  local _, unit = tip:GetUnit()
  unit = clear(unit)
  if type(unit) ~= "string" then return end
  if not UnitIsPlayer or not yes(UnitIsPlayer(unit)) then return end
  local name = unitName(unit)
  if not name then return end
  local region = NS.ClientInfo and NS.ClientInfo().region or nil
  local entry = NS.PvpLookup(name, region, NS.Now())
  if not entry then return end
  local faction = clear(UnitFactionGroup and UnitFactionGroup(unit) or nil)
  local line = NS.PvpLine(entry, faction)
  if not line then return end
  if tip.AddDoubleLine then
    tip:AddDoubleLine("|cffd4a017AHledger PvP|r", line, 1, 1, 1, 1, 1, 1)
  else
    tip:AddLine("|cffd4a017AHledger PvP|r  " .. line)
  end
  if tip.Show then tip:Show() end
end
NS.PvpUnitTooltip = function(tip) return pcall(onUnitTooltip, tip) end

local hooked = nil
if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tip)
    pcall(onUnitTooltip, tip)
  end)
  hooked = "data"
elseif GameTooltip and GameTooltip.HookScript then
  GameTooltip:HookScript("OnTooltipSetUnit", function(tip) pcall(onUnitTooltip, tip) end)
  hooked = "script"
end
NS.PvpTooltipHooked = function() return hooked end

-- ---------------------------------------------------------------------------------------------
-- Your own Rank Points
-- ---------------------------------------------------------------------------------------------

local FACTION_ID = 2800 -- the hidden "PvP Rank Points" renown track
local CURRENCY_POINTS = 3468 -- "Rank Points"
local CURRENCY_RANK = 3473 -- "Renown - PvP Rank", the rank itself
local CURRENCY_HONOR = 1792
local MAX_LOG = 400
local MAX_CHARACTERS = 30
local CHANGE_DELAY_S = 5 -- a burst of currency events is read once, this long after the first
local AFTER_S = 60 -- the reading after a match ends, once the points have landed
local MATCH_KEEP_S = 3 * 3600 -- a match remembered across a /reload no longer than this

local session = { login = false, inPvp = false, ended = false, changePending = false, map = nil }

local function pointsOn()
  if NS.IsForeverClient and not NS.IsForeverClient() then return false end
  return NS.Setting("contribute") and NS.Setting("pvpPoints") and true or false
end

-- A plain whole number from the client, or nil.
local function int(v)
  v = clear(v)
  if type(v) ~= "number" or v ~= v or v < 0 or v > 10000000 then return nil end
  return math.floor(v)
end

-- A currency the client knows; one it does not know comes back nameless.
local function currency(id)
  if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyInfo then return nil end
  local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, id)
  if not ok or type(info) ~= "table" then return nil end
  local name = clear(info.name)
  if type(name) ~= "string" or name == "" then return nil end
  return info
end

-- What the client says about this character's Rank Points right now. Every value is optional;
-- the site works out the total from whichever agree. Nil when the client says nothing at all.
function NS.PvpReading()
  local r = {}
  if C_MajorFactions and C_MajorFactions.GetMajorFactionData then
    local ok, d = pcall(C_MajorFactions.GetMajorFactionData, FACTION_ID)
    if ok and type(d) == "table" then
      r.lv = int(d.renownLevel)
      r.e = int(d.renownReputationEarned)
      r.th = int(d.renownLevelThreshold)
    end
  end
  if C_Reputation and C_Reputation.GetFactionDataByID then
    local ok, d = pcall(C_Reputation.GetFactionDataByID, FACTION_ID)
    if ok and type(d) == "table" then r.cs = int(d.currentStanding) end
  end
  local p = currency(CURRENCY_POINTS)
  if p then
    r.cq = int(p.quantity)
    r.ct = int(p.totalEarned)
    r.cw = int(p.quantityEarnedThisWeek)
  end
  local rk = currency(CURRENCY_RANK)
  if rk then r.rr = int(rk.quantity) end
  local h = currency(CURRENCY_HONOR)
  if h then r.h = int(h.quantity) end
  if next(r) == nil then return nil end
  return r
end

local VALUE_KEYS = { "lv", "e", "th", "cs", "cq", "ct", "cw", "rr" }
local function sameValues(a, b)
  if not a or not b then return false end
  for _, k in ipairs(VALUE_KEYS) do if a[k] ~= b[k] then return false end end
  return true
end

-- The class in English from the client's file token ("HUNTER" -> "Hunter"), whatever the
-- client's language; the localized name only when there is no token.
function NS.ClassEnglish(token, localized)
  token = clear(token)
  if type(token) == "string" and token:match("^%u+$") and #token <= 20 then
    return token:sub(1, 1) .. token:sub(2):lower()
  end
  localized = clear(localized)
  if type(localized) == "string" and #localized <= 20 then return localized end
  return nil
end

local function store()
  local db = NS.Db()
  if type(db.pvpPoints) ~= "table" then db.pvpPoints = {} end
  return db.pvpPoints
end

-- This character's entry, made when missing, with the oldest character dropped past the cap.
local function entryFor(name, now)
  local t = store()
  local e = t[name]
  if type(e) ~= "table" then
    local n, oldest, oldestAt = 0, nil, math.huge
    for k, v in pairs(t) do
      n = n + 1
      local at = type(v) == "table" and tonumber(v.t) or 0
      if at < oldestAt then oldest, oldestAt = k, at end
    end
    if n >= MAX_CHARACTERS and oldest then t[oldest] = nil end
    e = { log = {} }
    t[name] = e
  end
  if type(e.log) ~= "table" then e.log = {} end
  e.t = now
  return e
end

-- Writes one reading for the player. ev is login, change, start, end or after; extra carries
-- the map (m) and the result (w). Returns the reading written, or nil. A login or a change
-- that says nothing new is not written. Pure apart from the saved table and the client calls;
-- the harness drives it.
function NS.PvpNote(ev, extra, now)
  if not pointsOn() then return nil end
  local name = clear(UnitName and UnitName("player") or nil)
  if type(name) ~= "string" or #name < 2 or #name > NAME_MAX_BYTES or name:find(CONTROL_BAR) then return nil end
  local info = NS.ClientInfo and NS.ClientInfo() or {}
  if info.region ~= "us" and info.region ~= "eu" then return nil end
  local reading = NS.PvpReading()
  if not reading then return nil end
  now = now or NS.Now()
  local e = entryFor(name, now)
  local log = e.log
  if (ev == "change" or ev == "login") and sameValues(log[#log], reading) then return nil end
  reading.t = now
  reading.ev = ev
  if type(extra) == "table" then
    if extra.m then reading.m = int(extra.m) end
    if extra.w == 0 or extra.w == 1 then reading.w = extra.w end
  end
  e.region = info.region
  e.r = NS.RulesetFromRealm and NS.RulesetFromRealm(info.realm) or nil
  e.f = (info.faction == "Alliance" or info.faction == "Horde") and info.faction or nil
  if UnitClass then
    local localized, token = UnitClass("player")
    e.c = NS.ClassEnglish(token, localized)
  end
  local level = UnitLevel and int(UnitLevel("player")) or nil
  e.l = (level and level >= 1 and level <= 80) and level or nil
  log[#log + 1] = reading
  while #log > MAX_LOG do table.remove(log, 1) end
  return reading
end

-- 1 when the player's side won, 0 when it lost, nil for a draw or when the client cannot say.
-- winner is the client's 0 (Horde) or 1 (Alliance); the side is the battlefield's own record of
-- the player's team where the client has it (it differs from the faction in mercenary play).
local function result(winner)
  winner = clear(winner)
  if winner ~= 0 and winner ~= 1 then return nil end
  local side = nil
  if GetBattlefieldArenaFaction then
    local ok, s = pcall(GetBattlefieldArenaFaction)
    if ok then side = clear(s) end
  end
  if side ~= 0 and side ~= 1 then
    local f = UnitFactionGroup and clear(UnitFactionGroup("player")) or nil
    side = (f == "Alliance" and 1) or (f == "Horde" and 0) or nil
  end
  if side == nil then return nil end
  return winner == side and 1 or 0
end
NS.PvpResult = result

local function winnerNow()
  if not GetBattlefieldWinner then return nil end
  local ok, w = pcall(GetBattlefieldWinner)
  if not ok then return nil end
  return clear(w)
end

local function instance()
  if not IsInInstance then return false, nil end
  local inside, kind = IsInInstance()
  if not yes(inside) or clear(kind) ~= "pvp" then return false, nil end
  local map = GetInstanceInfo and int(select(8, GetInstanceInfo())) or nil
  return true, map
end

-- The match in progress, kept in the saved table so a /reload inside a battleground does not
-- start a second one: { t = when it started, m = the map, ended = true once the result is in }.
local function savedMatch(now)
  local db = NS.Db()
  local m = db.pvpMatch
  if type(m) ~= "table" or (tonumber(m.t) or 0) < now - MATCH_KEEP_S then return nil end
  return m
end

local function matchEnded(winner)
  if session.ended or not session.inPvp then return end
  session.ended = true
  local map = session.map
  local db = NS.Db()
  if type(db.pvpMatch) == "table" then db.pvpMatch.ended = true end
  NS.PvpNote("end", { w = result(winner), m = map })
  if C_Timer and C_Timer.After then
    C_Timer.After(AFTER_S, function() pcall(NS.PvpNote, "after", { m = map }) end)
  end
end

local function onWorld()
  local now = NS.Now()
  if not session.login then
    session.login = true
    NS.PvpNote("login")
  end
  local inside, map = instance()
  if inside and not session.inPvp then
    local db = NS.Db()
    local kept = savedMatch(now)
    session.inPvp, session.map = true, map
    if kept and kept.m == map then
      -- A /reload inside the same battleground: the match goes on, no new start.
      session.ended = kept.ended and true or false
    elseif winnerNow() ~= nil then
      -- Arrived after the result (a reload on the scoreboard): nothing to measure.
      session.ended = true
      db.pvpMatch = nil
    else
      session.ended = false
      db.pvpMatch = { t = now, m = map }
      NS.PvpNote("start", { m = map }, now)
    end
  elseif not inside and session.inPvp then
    session.inPvp, session.ended, session.map = false, false, nil
    NS.Db().pvpMatch = nil
  end
end

local function onChange()
  if session.changePending then return end
  session.changePending = true
  local function run()
    session.changePending = false
    NS.PvpNote("change")
  end
  if C_Timer and C_Timer.After then
    C_Timer.After(CHANGE_DELAY_S, function() pcall(run) end)
  else
    run()
  end
end

-- The switch going off deletes what was noted, so nothing older is sent later.
function NS.PvpSettingChanged(key)
  if (key == "pvpPoints" or key == "contribute") and not pointsOn() then
    local db = NS.Db()
    db.pvpPoints = nil
    db.pvpMatch = nil
  end
end

local frame = CreateFrame("Frame", "AHledgerPvpFrame")
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "CURRENCY_DISPLAY_UPDATE", "MAJOR_FACTION_RENOWN_LEVEL_CHANGED", "UPDATE_FACTION", "PVP_MATCH_COMPLETE", "UPDATE_BATTLEFIELD_STATUS" }) do
  pcall(frame.RegisterEvent, frame, e)
end
frame:SetScript("OnEvent", function(_, event, arg1)
  if not pointsOn() then return end
  local ok, err = pcall(function()
    if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then onWorld()
    elseif event == "CURRENCY_DISPLAY_UPDATE" or event == "MAJOR_FACTION_RENOWN_LEVEL_CHANGED" or event == "UPDATE_FACTION" then onChange()
    elseif event == "PVP_MATCH_COMPLETE" then matchEnded(arg1)
    elseif event == "UPDATE_BATTLEFIELD_STATUS" then
      if session.inPvp and not session.ended then
        local winner = winnerNow()
        if winner ~= nil then matchEnded(winner) end
      end
    end
  end)
  if not ok and NS.NoteError then NS.NoteError("pvp " .. tostring(event), err) end
end)

-- Test seams: the harness resets the session between cases.
NS.PvpSession = function() return session end
NS.PvpResetSession = function()
  session.login, session.inPvp, session.ended, session.changePending, session.map = false, false, false, false, nil
end
NS.PvpResetCache = function() cache, cacheSize, cacheFor = {}, 0, nil end
