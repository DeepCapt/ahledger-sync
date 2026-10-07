--[[
  Item sources, observed. When a loot window opens, a vendor is browsed, a quest is offered or
  hands out its reward, or a fish lands, the addon notes which source gave which item, in which zone, and
  keeps one aggregated line per source, item and hour in AHledgerDB.observations. AHledger
  sync uploads that table beside scans, the site sums it across contributors, and item pages
  say "dropped by", "sold by", "quest reward from" and "fished in" without anyone typing it in.

  What is recorded: the source's id and the name the client showed for it (a creature, object,
  quest or vendor), the zone, the item ids, counts and vendor prices. Nothing about the
  character, the account, or other players. Both the "contribute" and the "observe" options
  must be on; either off, nothing is written and no unit events are listened to.

  Loot windows also count how often a source was opened (item 0 rows), which is what turns
  "seen 12 times" into a drop rate once enough people have looted it. Each line carries a
  session id: the beta client starts every session with an empty table, and the server sums
  sessions rather than keeping the larger count.
]]
local _, NS = ...

local MAX_RECORDS = 5000
local MAX_AGE_S = 3 * 86400
local MAX_VENDOR_ITEMS = 200
local NAME_CACHE = 60 -- recent deaths remembered for naming corpses
local RECENT_S = 20 -- how long a tooltip name or a used container stays usable
local RELOOT_S = 60 -- the same corpse or chest opened again within this is one look
local RECENT_LOOT_MAX = 40

local SESSION = math.random(1, 1000000000)

local index = nil -- key -> record, rebuilt from the saved list at load
local deaths = {} -- guid -> name, most recent NAME_CACHE
local deathOrder = {}
local lastObject = { name = nil, guid = nil, at = 0 }
local lastContainer = { id = nil, name = nil, at = 0 }
local recentLoot = {} -- guid -> time it was last counted
local recentLootOrder = {}

-- The Forever client hands addons "secret" values for some names and ids: enemies in combat,
-- and some tooltips. An addon may pass one along but must not compare, index, match or store
-- it; trying raises a Lua error popup. Every name and id read from units, tooltips and loot
-- sources goes through clear(), which returns the value only when it is a plain string or
-- number, and nil otherwise.
local function clear(v)
  if v == nil then return nil end
  if issecretvalue then
    local ok, secret = pcall(issecretvalue, v)
    if not ok or secret then return nil end
  end
  local t = type(v)
  if t ~= "string" and t ~= "number" then return nil end
  -- Clients without issecretvalue: a value that cannot be compared is not a plain value.
  if not pcall(function() return v == v and v ~= "" end) then return nil end
  return v
end
NS.ObserveClear = clear

-- A world object's name as a tooltip showed it, made safe to store: icon and colour codes
-- removed, and anything that is clearly interface text rather than a chest, node or plant
-- ("16,343 / 25,200 ( 65% )", "AHledger 0.8.4", "Press F6 ...") refused.
local function cleanName(s)
  s = clear(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  s = s:match("^%s*(.-)%s*$") or ""
  if s == "" or #s > 60 then return nil end
  if s:find("%d%s*/%s*%d") or s:find("%%") or s:find("|", 1, true) then return nil end
  if s:find("^AHledger") or s:find("^Press ") or s:find("^Click ") or s:find("^Right%-click") then return nil end
  return s
end
NS.ObserveCleanName = cleanName

local function db()
  local d = NS.Db()
  if type(d.observations) ~= "table" then d.observations = {} end
  return d
end

local function enabled()
  return NS.Setting("contribute") and NS.Setting("observe") and true or false
end

local function hourBucket()
  local t = NS.Now()
  return t - (t % 3600)
end

local function zoneInfo()
  -- Inside a dungeon or raid the client draws no zone map, so the instance is named from the
  -- game's instance info, the same name its map table carries.
  if IsInInstance and GetInstanceInfo then
    local inInstance, instanceType = IsInInstance()
    if inInstance and (instanceType == "party" or instanceType == "raid") then
      local name = GetInstanceInfo()
      local sub = GetSubZoneText and GetSubZoneText() or nil
      if sub == "" then sub = nil end
      if name and name ~= "" then return 0, name, sub end
    end
  end
  local mapId = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player") or nil
  local zn = nil
  if mapId and C_Map.GetMapInfo then
    local info = C_Map.GetMapInfo(mapId)
    zn = info and info.name or nil
  end
  if not zn and GetZoneText then zn = GetZoneText() end
  local sz = GetSubZoneText and GetSubZoneText() or nil
  if sz == "" then sz = nil end
  return mapId or 0, zn, sz
end

local function keyOf(kind, source, zone, item, hour, session)
  return kind .. "|" .. source .. "|" .. zone .. "|" .. item .. "|" .. hour .. "|" .. (session or 0)
end

local function rebuildIndex()
  index = {}
  local list = db().observations
  local cutoff = NS.Now() - MAX_AGE_S
  local kept = {}
  for _, r in ipairs(list) do
    if type(r) == "table" and r.k and r.s and r.i and r.h and r.h >= cutoff then
      kept[#kept + 1] = r
      index[keyOf(r.k, r.s, r.z or 0, r.i, r.h, r.x)] = r
    end
  end
  db().observations = kept
end

-- How full the source table is, 0 to 1, for the status line and the bar.
function NS.ObserveFullness()
  return #db().observations / MAX_RECORDS
end

-- The tables are sent from the saved file, which the client writes only at logout or reload.
-- A player who runs ten zones in one sitting fills them before anything is sent, so the first
-- time either passes four fifths the addon says so, once.
local NUDGE_AT = 0.8
local nudged = false
local function nudge(kind, n, max)
  if nudged or n < max * NUDGE_AT then return end
  nudged = true
  NS.Print(string.format("your %s table is %d%% full (%d of %d). Type /reload so AHledger sync can send it before the oldest lines are dropped.", kind, math.floor(n / max * 100), n, max))
end

-- Drop the oldest hour's records when the table is full, so it stays a bounded file.
local function makeRoom()
  local list = db().observations
  nudge("item source", #list, MAX_RECORDS)
  if #list < MAX_RECORDS then return end
  local oldest = nil
  for _, r in ipairs(list) do
    if not oldest or r.h < oldest then oldest = r.h end
  end
  local kept = {}
  for _, r in ipairs(list) do
    if r.h > oldest then kept[#kept + 1] = r else index[keyOf(r.k, r.s, r.z or 0, r.i, r.h, r.x)] = nil end
  end
  db().observations = kept
end

-- Returns the record for the key, creating it.
local function record(kind, source, name, item)
  if not index then rebuildIndex() end
  local zone, zn, sz = zoneInfo()
  local hour = hourBucket()
  local key = keyOf(kind, source, zone, item, hour, SESSION)
  local r = index[key]
  if not r then
    makeRoom()
    r = { k = kind, s = source, i = item, h = hour, c = 0, x = SESSION }
    if zone > 0 then r.z = zone end
    if zn then r.zn = zn end
    if sz then r.sz = sz end
    index[key] = r
    local list = db().observations
    list[#list + 1] = r
  end
  if name and not r.n then r.n = name end
  return r
end

local function itemIdFromLink(link)
  link = clear(link)
  if type(link) ~= "string" then return nil end
  local id = link:match("item:(%d+)")
  return id and tonumber(id) or nil
end

-- "Creature-0-4379-0-2660-1234-000045A1B2" -> "Creature", 1234
local function parseGuid(guid)
  guid = clear(guid)
  if type(guid) ~= "string" then return nil, nil end
  local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
  if kind then return kind, tonumber(id) end
  local itemKind = guid:match("^(Item)%-")
  return itemKind, nil
end

local function nameForCreature(guid)
  guid = clear(guid)
  if not guid then return nil end
  for _, unit in ipairs({ "target", "mouseover" }) do
    if UnitGUID and clear(UnitGUID(unit)) == guid then
      local name = clear(UnitName and UnitName(unit))
      if name then return name end
    end
  end
  return deaths[guid]
end

local function rememberDeath(guid, name)
  guid, name = clear(guid), clear(name)
  if not guid or not name or deaths[guid] then return end
  deaths[guid] = name
  deathOrder[#deathOrder + 1] = guid
  if #deathOrder > NAME_CACHE then
    local old = table.remove(deathOrder, 1)
    deaths[old] = nil
  end
end

-- True the first time a corpse or chest is looked at; false when it was counted a moment ago.
local function firstLook(guid)
  local now = NS.Now()
  local last = recentLoot[guid]
  if last and now - last < RELOOT_S then return false end
  if not last then
    recentLootOrder[#recentLootOrder + 1] = guid
    if #recentLootOrder > RECENT_LOOT_MAX then
      local old = table.remove(recentLootOrder, 1)
      recentLoot[old] = nil
    end
  end
  recentLoot[guid] = now
  return true
end

-- What a loot source GUID is: kind, source id, and the name the client showed, or nil for
-- sources the site cannot place (players, unknown).
local function classify(guid)
  local gkind, gid = parseGuid(guid)
  if gkind == "Creature" or gkind == "Vehicle" or gkind == "Pet" then
    if not gid then return nil end
    return "drop", gid, nameForCreature(guid)
  elseif gkind == "GameObject" then
    if not gid then return nil end
    -- The remembered tooltip names this object only when it was this object: the same GUID
    -- where the client gave one, otherwise shown in the last few seconds.
    local name = nil
    if NS.Now() - lastObject.at <= RECENT_S then
      if lastObject.guid then
        if lastObject.guid == clear(guid) then name = lastObject.name end
      else
        name = lastObject.name
      end
    end
    return "object", gid, name
  elseif gkind == "Item" then
    if NS.Now() - lastContainer.at > RECENT_S or not lastContainer.id then return nil end
    return "container", lastContainer.id, lastContainer.name
  end
  return nil
end

-- ---------------------------------------------------------------------------------------------
-- Loot windows: creatures, objects, containers, fishing
-- ---------------------------------------------------------------------------------------------

function NS.ObserveLoot()
  if not enabled() then return nil end
  local n = GetNumLootItems and GetNumLootItems() or 0
  if n == 0 then return nil end
  local fishing = IsFishingLoot and IsFishingLoot() or false
  local items, sources = 0, 0
  if fishing then
    -- Every cast is a look of its own; there is no corpse to reopen.
    local head = record("fish", 0, nil, 0)
    head.o = (head.o or 0) + 1
    sources = 1
    for i = 1, n do
      if (GetLootSlotType and GetLootSlotType(i) or 1) == 1 then
        local id = itemIdFromLink(GetLootSlotLink and GetLootSlotLink(i))
        if id then
          local _, _, quantity = GetLootSlotInfo(i)
          local r = record("fish", 0, nil, id)
          r.c = r.c + 1
          r.q = (r.q or 0) + (tonumber(quantity) or 1)
          items = items + 1
        end
      end
    end
    return "fish", 0, items
  end
  -- Area loot puts several corpses in one window, each slot with its own source, so sources
  -- are resolved per slot and each is counted as opened once.
  local counted = {}
  for i = 1, n do
    local guid = clear(GetLootSourceInfo and GetLootSourceInfo(i) or nil)
    if guid then
      local kind, source, name = classify(guid)
      if kind then
        if counted[guid] == nil then
          counted[guid] = firstLook(guid)
          if counted[guid] then
            local head = record(kind, source, name, 0)
            head.o = (head.o or 0) + 1
            sources = sources + 1
          end
        end
        if counted[guid] and (GetLootSlotType and GetLootSlotType(i) or 1) == 1 then
          local id = itemIdFromLink(GetLootSlotLink and GetLootSlotLink(i))
          if id then
            local _, _, quantity = GetLootSlotInfo(i)
            local r = record(kind, source, name, id)
            r.c = r.c + 1
            r.q = (r.q or 0) + (tonumber(quantity) or 1)
            items = items + 1
          end
        end
      end
    end
  end
  return sources, items
end

-- ---------------------------------------------------------------------------------------------
-- Vendors
-- ---------------------------------------------------------------------------------------------

function NS.ObserveMerchant()
  if not enabled() then return nil end
  local guid = clear(UnitGUID and UnitGUID("npc") or nil)
  local gkind, npcId = parseGuid(guid)
  if gkind ~= "Creature" or not npcId then return nil end
  local name = clear(UnitName and UnitName("npc") or nil)
  local n = math.min(GetMerchantNumItems and GetMerchantNumItems() or 0, MAX_VENDOR_ITEMS)
  local items = 0
  for i = 1, n do
    local id = itemIdFromLink(GetMerchantItemLink and GetMerchantItemLink(i))
    if id then
      local price, quantity, _, extendedCost = NS.MerchantItem(i)
      local r = record("vendor", npcId, name, id)
      r.c = math.max(r.c, 1)
      if not extendedCost and price and price > 0 then
        r.p = math.floor(price / math.max(1, tonumber(quantity) or 1))
      end
      items = items + 1
    end
  end
  return npcId, items
end

-- ---------------------------------------------------------------------------------------------
-- Quests: the offer window, the log entry once accepted, and the turn-in window
-- ---------------------------------------------------------------------------------------------
-- What is kept per quest: id, title, level, the giver and receiver (creature or object id and
-- the name shown), the zone it was picked up in, the reward and choice item ids, money and
-- experience, and the objectives as the log counts them ("Kobold Vermin slain: 0/10" becomes
-- the name and the 10). Never the quest's description or dialogue text: those stay in the game.

local MAX_QUESTS = 1500
local questIndex = nil

local function questList()
  local d = NS.Db()
  if type(d.quests) ~= "table" then d.quests = {} end
  return d.quests
end

local function questRecord(questId)
  local list = questList()
  if not questIndex then
    questIndex = {}
    for _, q in ipairs(list) do
      if type(q) == "table" and q.id then questIndex[q.id] = q end
    end
  end
  local q = questIndex[questId]
  if not q then
    nudge("quest", #list, MAX_QUESTS)
    if #list >= MAX_QUESTS then
      local oldest, at = nil, nil
      for i, r in ipairs(list) do
        if not oldest or (r.h or 0) < (oldest.h or 0) then oldest, at = r, i end
      end
      if at then
        questIndex[oldest.id] = nil
        table.remove(list, at)
      end
    end
    q = { id = questId }
    list[#list + 1] = q
    questIndex[questId] = q
  end
  q.h = hourBucket()
  return q
end

local function questItemIds(kindArg, count)
  local out = {}
  for i = 1, count do
    local id = itemIdFromLink(GetQuestItemLink and GetQuestItemLink(kindArg, i))
    if id then out[#out + 1] = id end
  end
  return out
end

-- The unit the quest window belongs to: a creature or an object, by id, with its name.
local function questUnit(q, key)
  local guid = clear(UnitGUID and UnitGUID("npc") or nil)
  local gkind, gid = parseGuid(guid)
  if not gid or (gkind ~= "Creature" and gkind ~= "GameObject") then return end
  q[key] = gid
  q[key .. "k"] = gkind == "GameObject" and "obj" or "npc"
  local name = clear(UnitName and UnitName("npc") or nil)
  if name and name ~= "" then q[key .. "n"] = name end
end

-- Rewards, money and experience as the open quest window shows them (offer or turn-in).
local function questWindow(q)
  local title = GetTitleText and GetTitleText() or nil
  if title and title ~= "" then q.t = title end
  local money = GetRewardMoney and GetRewardMoney() or nil
  if money and money > 0 then q.m = money end
  local xp = GetRewardXP and GetRewardXP() or nil
  if xp and xp > 0 then q.x = xp end
  local r = questItemIds("reward", GetNumQuestRewards and GetNumQuestRewards() or 0)
  local c = questItemIds("choice", GetNumQuestChoices and GetNumQuestChoices() or 0)
  if #r > 0 then q.r = r end
  if #c > 0 then q.c = c end
end

-- The offer window: who gives it, where, and what it pays.
function NS.ObserveQuestOffer()
  if not enabled() then return nil end
  local questId = GetQuestID and GetQuestID() or 0
  if not questId or questId == 0 then return nil end
  local q = questRecord(questId)
  questWindow(q)
  questUnit(q, "g")
  local zone, zn = zoneInfo()
  if zone > 0 then q.z = zone end
  if zn then q.zn = zn end
  return q
end

-- "Kobold Vermin slain: 0/10" -> { n = "Kobold Vermin slain", q = 10 }; anything else keeps its text.
local function objectiveFromText(text, need)
  local name, total = text:match("^(.-):%s*%d+%s*/%s*(%d+)$")
  if name then return { n = name, q = tonumber(total) } end
  if need and need > 0 then return { n = text, q = need } end
  return { n = text }
end

-- The modern quest log (the Forever client runs the Mainline UI): level from the log entry and
-- objectives from the quest's own list. Nil where the client lacks it, so the Classic Era path
-- below runs instead. Every call is checked on its own: Classic Era 1.15 has some of them.
local function questFromModernLog(questId)
  local api = rawget(_G, "C_QuestLog")
  if type(api) ~= "table" or not api.GetInfo or not api.GetLogIndexForQuestID then return nil end
  local ok, index = pcall(api.GetLogIndexForQuestID, questId)
  if not ok or not index then return nil end
  local ok2, info = pcall(api.GetInfo, index)
  if not ok2 or type(info) ~= "table" or info.isHeader then return nil end
  local out = { title = info.title, level = tonumber(info.level) or tonumber(info.difficultyLevel) }
  if api.GetQuestObjectives then
    local ok3, list = pcall(api.GetQuestObjectives, questId)
    if ok3 and type(list) == "table" then
      local o, bare = {}, false
      for _, ob in ipairs(list) do
        if type(ob) == "table" and type(ob.text) == "string" and ob.text ~= "" then
          local parsed = objectiveFromText(ob.text, tonumber(ob.numRequired))
          -- Right at acceptance the client can hand out "0/7" with the name still loading.
          if parsed.n:find("%a") then o[#o + 1] = parsed else bare = true end
        end
      end
      out.objectives = o
      out.bare = bare
    end
  end
  return out
end

local OBJECTIVE_RETRY_S = 2
local OBJECTIVE_RETRIES = 3
local function readObjectivesLater(questId, attempt)
  if not (C_Timer and C_Timer.After) then return end
  C_Timer.After(OBJECTIVE_RETRY_S, function()
    if not enabled() then return end
    local m = questFromModernLog(questId)
    if m and m.objectives and #m.objectives > 0 and not m.bare then
      questRecord(questId).o = m.objectives
    elseif attempt < OBJECTIVE_RETRIES then
      readObjectivesLater(questId, attempt + 1)
    end
  end)
end

-- Once accepted, the log carries the level and the objectives as counters.
function NS.ObserveQuestAccepted(a, b)
  if not enabled() then return nil end
  local questId = tonumber(b) or tonumber(a)
  if not questId or questId == 0 then return nil end
  local modern = questFromModernLog(questId)
  if modern then
    local q = questRecord(questId)
    if modern.title and modern.title ~= "" and not q.t then q.t = modern.title end
    if modern.level and modern.level > 0 then q.l = modern.level end
    if modern.objectives and #modern.objectives > 0 and not modern.bare then
      q.o = modern.objectives
    elseif modern.bare then
      readObjectivesLater(questId, 1)
    end
    return q
  end
  if not GetQuestLogTitle then return nil end
  local n = GetNumQuestLogEntries and GetNumQuestLogEntries() or 0
  for i = 1, n do
    local title, level, _, isHeader, _, _, _, id = GetQuestLogTitle(i)
    if not isHeader and id == questId then
      local q = questRecord(questId)
      if title and title ~= "" and not q.t then q.t = title end
      if level and level > 0 then q.l = level end
      local count = GetNumQuestLeaderBoards and GetNumQuestLeaderBoards(i) or 0
      local o = {}
      for j = 1, count do
        local text = GetQuestLogLeaderBoard and GetQuestLogLeaderBoard(j, i) or nil
        if type(text) == "string" and text ~= "" then o[#o + 1] = objectiveFromText(text) end
      end
      if #o > 0 then q.o = o end
      return q
    end
  end
  return nil
end

-- The turn-in window: the reward items become item sources, and the quest notes who takes it.
function NS.ObserveQuest()
  if not enabled() then return nil end
  local questId = GetQuestID and GetQuestID() or 0
  if not questId or questId == 0 then return nil end
  local title = GetTitleText and GetTitleText() or nil
  local items = 0
  local function take(kindArg, count)
    for i = 1, count do
      local id = itemIdFromLink(GetQuestItemLink and GetQuestItemLink(kindArg, i))
      if id then
        local r = record("quest", questId, title, id)
        r.c = math.max(r.c, 1)
        items = items + 1
      end
    end
  end
  take("reward", GetNumQuestRewards and GetNumQuestRewards() or 0)
  take("choice", GetNumQuestChoices and GetNumQuestChoices() or 0)
  local q = questRecord(questId)
  questWindow(q)
  questUnit(q, "e")
  q.d = 1
  return questId, items
end

function NS.QuestCount()
  return #questList()
end

-- ---------------------------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------------------------

function NS.ObservationCount()
  return #db().observations
end

local frame = CreateFrame("Frame", "AHledgerObserveFrame")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("QUEST_COMPLETE")
frame:RegisterEvent("QUEST_DETAIL")
frame:RegisterEvent("QUEST_ACCEPTED")
local function onEvent(event, arg1, arg2)
  if event == "LOOT_OPENED" then
    NS.ObserveLoot()
  elseif event == "MERCHANT_SHOW" then
    NS.ObserveMerchant()
  elseif event == "QUEST_COMPLETE" then
    NS.ObserveQuest()
  elseif event == "QUEST_DETAIL" then
    NS.ObserveQuestOffer()
  elseif event == "QUEST_ACCEPTED" then
    NS.ObserveQuestAccepted(arg1, arg2)
  elseif event == "PLAYER_TARGET_CHANGED" then
    if UnitGUID then pcall(function() rememberDeath(UnitGUID("target"), UnitName("target")) end) end
  elseif event == "UPDATE_MOUSEOVER_UNIT" then
    if UnitGUID then pcall(function() rememberDeath(UnitGUID("mouseover"), UnitName("mouseover")) end) end
  elseif event == "NAME_PLATE_UNIT_ADDED" and arg1 and UnitGUID then
    -- A nameplate names every enemy that comes close, targeted or not: area pulls included.
    local unit = clear(arg1)
    if unit then pcall(function() rememberDeath(UnitGUID(unit), UnitName(unit)) end) end
  end
end

frame:SetScript("OnEvent", function(_, event, arg1, arg2)
  local ok, err = pcall(onEvent, event, arg1, arg2)
  if not ok then NS.NoteError("item sources (" .. tostring(event) .. ")", err) end
end)

-- Creature names for corpses looted after the target moved on come from the last units the
-- player targeted, pointed at, or saw a nameplate for. Up to 0.5.2 this read the combat log's UNIT_DIED instead; on
-- the Forever client registering COMBAT_LOG_EVENT_UNFILTERED is an action reserved for the
-- Blizzard UI, and the attempt raised the "blocked" popup at every login. These two events
-- are ordinary, and are only listened to while sources are being recorded.
local NAME_EVENTS = { "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED" }
local listening = false
function NS.ObserveRefresh()
  local want = enabled()
  if want and not listening then
    for _, e in ipairs(NAME_EVENTS) do frame:RegisterEvent(e) end
    listening = true
  elseif not want and listening then
    for _, e in ipairs(NAME_EVENTS) do frame:UnregisterEvent(e) end
    listening = false
  end
  return listening
end
NS.ObserveRefresh()

-- The name of a world object under the cursor, for chests and nodes: the loot window itself
-- does not say what it was opened from. Up to 0.8.4 this read the first line of every tooltip
-- the game showed. On the Forever client an enemy's name in combat arrives there as a secret
-- value, and comparing it raised a Lua error popup; any other tooltip (the experience bar, an
-- action button, this addon's own minimap button) was taken for an object's name. Now only the
-- game's world-object tooltips are read, with their GUID, and nothing at all while item sources
-- are off. Every callback runs inside pcall, so a value the client withholds can never surface
-- as an error.
local function noteObject(name, guid)
  if not enabled() then return end
  name = cleanName(name)
  if not name then return end
  lastObject.name, lastObject.guid, lastObject.at = name, clear(guid), NS.Now()
end

local function noteContainerTooltip(tip)
  if not enabled() or not tip or not tip.GetItem then return end
  if tip.IsForbidden and tip:IsForbidden() then return end
  local name, link = tip:GetItem()
  local id = itemIdFromLink(link)
  if id then lastContainer.id, lastContainer.name, lastContainer.at = id, clear(name), NS.Now() end
end

local function onObjectTooltip(tip, data)
  if not enabled() then return end
  if tip and tip.IsForbidden and tip:IsForbidden() then return end
  if type(data) ~= "table" then return end
  local line = type(data.lines) == "table" and data.lines[1] or nil
  local name = type(line) == "table" and line.leftText or nil
  noteObject(name, data.guid)
end
NS.ObserveObjectTooltip = function(data, tip) pcall(onObjectTooltip, tip, data) end

local dataTypes = Enum and Enum.TooltipDataType
if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and dataTypes and dataTypes.Object then
  TooltipDataProcessor.AddTooltipPostCall(dataTypes.Object, function(tip, data)
    pcall(onObjectTooltip, tip, data)
  end)
  if dataTypes.Item then
    -- An item tooltip is the bag item under the cursor: the container a player is about to
    -- open. Reading the tooltip needs no hook on the protected use function.
    TooltipDataProcessor.AddTooltipPostCall(dataTypes.Item, function(tip)
      pcall(noteContainerTooltip, tip)
    end)
  end
elseif GameTooltip and GameTooltip.HookScript then
  -- Clients without tooltip data types: the first line of a tooltip that is neither a unit, an
  -- item nor a spell, owned by the world rather than an interface frame.
  GameTooltip:HookScript("OnShow", function(tip)
    pcall(function()
      if not enabled() then return end
      if tip.IsForbidden and tip:IsForbidden() then return end
      if tip.GetUnit and clear(tip:GetUnit()) then return end
      if tip.GetItem and select(2, tip:GetItem()) then
        noteContainerTooltip(tip)
        return
      end
      if tip.GetSpell and tip:GetSpell() then return end
      if tip.GetOwner and UIParent and tip:GetOwner() ~= UIParent then return end
      local left = _G["GameTooltipTextLeft1"]
      noteObject(left and left.GetText and left:GetText() or nil, nil)
    end)
  end)
end

-- Containers opened from bags are named by the item tooltip above. 0.5.0 and 0.5.1 hooked
-- C_Container.UseContainerItem for this instead; on the Forever client hooking that protected
-- function is itself the action the game blocks at login, so no hook is placed on it.

-- Test seams: the harness has no tooltip or bag hooks and feeds these directly.
NS.ObserveNoteObject = function(name, guid) lastObject.name, lastObject.guid, lastObject.at = name, guid, NS.Now() end
NS.ObserveNoteContainer = function(id, name) lastContainer.id, lastContainer.name, lastContainer.at = id, name, NS.Now() end
NS.ObserveNoteDeath = rememberDeath
NS.ObserveSession = function() return SESSION end
