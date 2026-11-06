--[[
  Players seen (0.12.0). Every player character the client shows the addon, by name: your
  target, what you mouse over, nameplates, your group, the battleground scoreboard, your guild
  roster and a /who list. One line per name in AHledgerDB.sightings with the faction, class,
  level and ruleset the client showed, and when. AHledger sync sends the table to ahledger.com,
  where the names seed the PvP ladder, which reads Blizzard's own character profiles for the
  kills and ranks. Nothing about you is in it, and nothing about what anyone did: a name and
  what any player in the same zone can read by looking.

  Needs the contribute and sightings options on; either off, nothing is written and no event
  is listened to. Names the Forever client keeps secret (an enemy in combat) are skipped the
  way Observe.lua skips them.
]]
local _, NS = ...

local MAX_NAMES = 5000
local TRIM_TO = 4500 -- once past the cap, trim down to this, so the sort runs rarely
local SAME_NAME_S = 300 -- a name seen again within this is one sighting
local SCAN_EVERY_S = 60 -- the roster, scoreboard and who list are read at most this often

local lastAt = {} -- name -> when it was last written, this session
local size = nil -- names on the table, counted once and kept
local scannedAt = {} -- list -> when it was last read

local function on()
  return NS.Setting("contribute") and NS.Setting("sightings") and true or false
end

local function table_()
  local db = NS.Db()
  if type(db.sightings) ~= "table" then db.sightings = {} end
  return db.sightings
end

local function count(t)
  if size == nil then
    size = 0
    for _ in pairs(t) do size = size + 1 end
  end
  return size
end

-- Keeps the table under its cap: past it, the oldest lines go until TRIM_TO remain, so the
-- sort happens once per few hundred new names rather than once per name.
local function trim(t)
  if count(t) <= MAX_NAMES then return end
  local names = {}
  for name, e in pairs(t) do names[#names + 1] = { name = name, t = e.t or 0 } end
  table.sort(names, function(a, b) return a.t < b.t end)
  for i = 1, #names - TRIM_TO do t[names[i].name] = nil end
  size = TRIM_TO
end

-- Writes one sighting. name is the name as shown ("Alla Jin", "Alla Jin-Realm"); faction is
-- "Alliance" or "Horde"; class is the English class name; level a number; ruleset the market
-- ruleset word. Pure apart from the table; returns true when a line was written or refreshed.
function NS.NoteSighting(name, faction, class, level, ruleset, now)
  name = NS.ObserveClear and NS.ObserveClear(name) or name
  if type(name) ~= "string" then return false end
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if #name < 2 or #name > 90 or name:find("[|%c]") then return false end
  now = now or NS.Now()
  if (lastAt[name] or 0) > now - SAME_NAME_S then return false end
  lastAt[name] = now
  local t = table_()
  local e = t[name]
  if not e then
    e = {}
    size = count(t) + 1
  end
  if faction == "Alliance" or faction == "Horde" then e.f = faction end
  if type(class) == "string" and #class <= 20 then e.c = class end
  if type(level) == "number" and level >= 1 and level <= 80 then e.l = math.floor(level) end
  if type(ruleset) == "string" then e.r = ruleset end
  e.t = now
  e.n = (e.n or 0) + 1
  t[name] = e
  trim(t)
  return true
end

function NS.SightingCount()
  return count(table_())
end

local function unitSighting(unit)
  if not on() or not UnitIsPlayer or not UnitIsPlayer(unit) then return end
  if UnitIsUnit and UnitIsUnit(unit, "player") then return end
  local name, realm = UnitName(unit)
  if name and realm and realm ~= "" then name = name .. "-" .. realm end
  local faction = UnitFactionGroup and UnitFactionGroup(unit) or nil
  local class = UnitClass and select(1, UnitClass(unit)) or nil
  local level = UnitLevel and UnitLevel(unit) or nil
  local ruleset = NS.RulesetFromRealm and NS.RulesetFromRealm(GetRealmName and GetRealmName() or "") or nil
  NS.NoteSighting(name, faction, class, level and level > 0 and level or nil, ruleset)
end

-- True once per SCAN_EVERY_S per list, so a roster that updates every frame is read once a minute.
local function due(list)
  local now = NS.Now()
  if (scannedAt[list] or 0) > now - SCAN_EVERY_S then return false end
  scannedAt[list] = now
  return true
end

local function groupSightings()
  if not on() or not due("group") then return end
  local n = GetNumGroupMembers and GetNumGroupMembers() or 0
  if n == 0 then return end
  local prefix = (IsInRaid and IsInRaid()) and "raid" or "party"
  for i = 1, n do pcall(unitSighting, prefix .. i) end
end

local function scoreboardSightings()
  if not on() or not GetNumBattlefieldScores or not GetBattlefieldScore or not due("scoreboard") then return end
  local ruleset = NS.RulesetFromRealm and NS.RulesetFromRealm(GetRealmName and GetRealmName() or "") or nil
  for i = 1, GetNumBattlefieldScores() or 0 do
    -- name, killing blows, honorable kills, deaths, honor, faction, race, class, class token.
    local ok, name, _, _, _, _, faction, _, class = pcall(GetBattlefieldScore, i)
    if ok and name then
      -- The scoreboard's faction is 0 for Horde and 1 for Alliance.
      local f = faction == 1 and "Alliance" or (faction == 0 and "Horde") or nil
      NS.NoteSighting(name, f, class, nil, ruleset)
    end
  end
end

local function guildSightings()
  if not on() or not GetNumGuildMembers or not GetGuildRosterInfo or not due("guild") then return end
  local faction = UnitFactionGroup and UnitFactionGroup("player") or nil
  local ruleset = NS.RulesetFromRealm and NS.RulesetFromRealm(GetRealmName and GetRealmName() or "") or nil
  local n = GetNumGuildMembers() or 0
  for i = 1, math.min(n, 1000) do
    local ok, name, _, _, level, class = pcall(GetGuildRosterInfo, i)
    if ok and name then NS.NoteSighting(name, faction, class, level, ruleset) end
  end
end

local function whoSightings()
  if not on() or not C_FriendList or not C_FriendList.GetNumWhoResults or not C_FriendList.GetWhoInfo or not due("who") then return end
  local faction = UnitFactionGroup and UnitFactionGroup("player") or nil
  local ruleset = NS.RulesetFromRealm and NS.RulesetFromRealm(GetRealmName and GetRealmName() or "") or nil
  for i = 1, C_FriendList.GetNumWhoResults() or 0 do
    local ok, info = pcall(C_FriendList.GetWhoInfo, i)
    if ok and type(info) == "table" and info.fullName then
      NS.NoteSighting(info.fullName, faction, info.classStr, info.level, ruleset)
    end
  end
end

local frame = CreateFrame("Frame", "AHledgerSightingsFrame")
for _, e in ipairs({ "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED", "GROUP_ROSTER_UPDATE", "UPDATE_BATTLEFIELD_SCORE", "GUILD_ROSTER_UPDATE", "WHO_LIST_UPDATE" }) do
  pcall(frame.RegisterEvent, frame, e)
end
frame:SetScript("OnEvent", function(_, event, arg1)
  local ok, err = pcall(function()
    if event == "PLAYER_TARGET_CHANGED" then unitSighting("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then unitSighting("mouseover")
    elseif event == "NAME_PLATE_UNIT_ADDED" then if arg1 then unitSighting(arg1) end
    elseif event == "GROUP_ROSTER_UPDATE" then groupSightings()
    elseif event == "UPDATE_BATTLEFIELD_SCORE" then scoreboardSightings()
    elseif event == "GUILD_ROSTER_UPDATE" then guildSightings()
    elseif event == "WHO_LIST_UPDATE" then whoSightings() end
  end)
  if not ok and NS.NoteError then NS.NoteError("sightings " .. tostring(event), err) end
end)
