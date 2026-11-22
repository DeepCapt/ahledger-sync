--[[
  Bags and bank on every character (0.15.0).

  Each character's gold, bag contents and bank contents are kept in AHledgerDB.inventory, keyed
  "Name-Realm", so the Bags tab can show the bank and every alt, and AHledger sync can send them
  to the player's account for the net worth page on ahledger.com (option inventorySync):

    AHledgerDB.inventory["Name-Realm"] = {
      n = name, r = realm, f = "horde" | "alliance", m = market key,
      g = copper on hand, t = when the bags were counted, bt = when the bank was counted (0: never),
      b = bags, k = bank: "id:count:bound,id:count:bound", one entry per item id, sorted by id
    }

  Bags are counted at login, when they change and when gold changes. The bank can be read only
  while it is open, so it is counted then and kept until the next visit. Mail and auctions are
  not counted. Reading containers is all this does; nothing is moved or used.
]]
local _, NS = ...
local UI = NS.UI

local MAX_CHARACTERS = 50
local MAX_ITEMS = 2000

local function numSlots(bag)
  if C_Container and C_Container.GetContainerNumSlots then return C_Container.GetContainerNumSlots(bag) or 0 end
  if GetContainerNumSlots then return GetContainerNumSlots(bag) or 0 end
  return 0
end

-- id, count, bound for one slot, or nil.
local function slotInfo(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if info and info.itemID then return info.itemID, info.stackCount or 1, info.isBound and true or false end
    return nil
  end
  if GetContainerItemInfo then
    local _, count, _, _, _, _, _, _, _, itemID = GetContainerItemInfo(bag, slot)
    if itemID then return itemID, count or 1, false end
  end
  return nil
end

-- The containers on each side. Enum.BagIndex names them on clients that have it (the bank moved
-- to tabs on newer clients); the numbers are the fallback. Warband (account) tabs are left out:
-- every character would count them.
function NS.InventoryContainers(side)
  local out, seen = {}, {}
  local function add(i) if type(i) == "number" and not seen[i] then seen[i] = true; out[#out + 1] = i end end
  local nBags = (NUM_BAG_SLOTS or 4)
  local nReagent = NUM_REAGENTBAG_SLOTS or 0
  if side == "bags" then
    for i = 0, nBags + nReagent do add(i) end
    return out
  end
  local E = Enum and Enum.BagIndex
  local tabs, bags, account = {}, {}, {}
  if E then
    for k, v in pairs(E) do
      if type(k) == "string" and type(v) == "number" then
        if k:match("^CharacterBankTab_%d+$") then tabs[#tabs + 1] = v
        elseif k:match("^BankBag_%d+$") then bags[#bags + 1] = v
        elseif k:match("^AccountBankTab_%d+$") then account[v] = true end
      end
    end
  end
  -- A client with bank tabs: the character's tabs only (an older name for the same numbers can
  -- point at the warband tabs, which every character would count). Otherwise the bank, the
  -- reagent bank and the bank bags, by name or by number.
  local function addBank(i) if not account[i] then add(i) end end
  if #tabs > 0 then
    for _, v in ipairs(tabs) do addBank(v) end
    if E.Bank then addBank(E.Bank) end
  else
    addBank(E and E.Bank or BANK_CONTAINER or -1)
    if E and E.Reagentbank then addBank(E.Reagentbank) end
    if #bags > 0 then
      for _, v in ipairs(bags) do addBank(v) end
    else
      for i = nBags + nReagent + 1, nBags + nReagent + (NUM_BANKBAGSLOTS or 7) do addBank(i) end
    end
  end
  table.sort(out)
  return out
end

-- Counts from slots { {id, count, bound}, ... } as the saved string, one entry per item id in id
-- order. Pure.
function NS.HoldingString(slots)
  local byId, ids = {}, {}
  for _, s in ipairs(slots) do
    local id, count = tonumber(s[1]), tonumber(s[2]) or 1
    if id and id > 0 and count > 0 then
      local r = byId[id]
      if not r then
        r = { 0, 0 }
        byId[id] = r
        ids[#ids + 1] = id
      end
      r[1] = r[1] + count
      if s[3] then r[2] = r[2] + count end
    end
  end
  table.sort(ids)
  local parts = {}
  for i = 1, math.min(#ids, MAX_ITEMS) do
    local id = ids[i]
    parts[#parts + 1] = string.format("%d:%d:%d", id, byId[id][1], byId[id][2])
  end
  return table.concat(parts, ",")
end

-- The saved string back into { [id] = { count, bound } }. Pure.
function NS.ParseHolding(s)
  local out = {}
  for id, count, bound in tostring(s or ""):gmatch("(%d+):(%d+):?(%d*)") do
    id, count = tonumber(id), tonumber(count)
    if id and count and count > 0 then
      local r = out[id] or { 0, 0 }
      r[1] = r[1] + count
      r[2] = math.min(r[1], r[2] + (tonumber(bound) or 0))
      out[id] = r
    end
  end
  return out
end

-- One side read from the containers: the string and the number of slots read (0: not loaded).
local function readSide(side)
  local slots, total = {}, 0
  for _, bag in ipairs(NS.InventoryContainers(side)) do
    local n = numSlots(bag)
    total = total + n
    for slot = 1, n do
      local id, count, bound = slotInfo(bag, slot)
      if id then slots[#slots + 1] = { id, count, bound } end
    end
  end
  return NS.HoldingString(slots), total
end

function NS.InventoryKey()
  local name = UnitName and UnitName("player") or nil
  if not name or name == "" or name == UNKNOWNOBJECT then return nil end
  -- The realm as the addon resolves it (0.15.1): build 71037 gives no realm name, and the key
  -- must stay the one this character was counted under before.
  local realm = NS.ClientInfo and NS.ClientInfo().realm or (GetRealmName and GetRealmName() or "")
  return name .. "-" .. realm, name, realm
end

local function records()
  local db = NS.Db()
  if type(db.inventory) ~= "table" then db.inventory = {} end
  return db.inventory
end
NS.InventoryRecords = records

-- Drops the characters counted longest ago past the cap. Pure on the table it is given.
function NS.InventoryPrune(inv, keep)
  keep = keep or MAX_CHARACTERS
  local keys = {}
  for k in pairs(inv) do keys[#keys + 1] = k end
  if #keys <= keep then return 0 end
  table.sort(keys, function(a, b) return (tonumber(inv[a].t) or 0) > (tonumber(inv[b].t) or 0) end)
  for i = keep + 1, #keys do inv[keys[i]] = nil end
  return #keys - keep
end

-- Counts one side now ("bags" or "bank") for this character. Returns the record, or nil when
-- the containers are not loaded yet (a login before the bags arrive reads no slots at all).
-- With `keepIfEmptied`, a side that reads empty where it held something is left as it was: the
-- read as the bank closes can come back blank on some clients.
-- With `minSlots`, a read of fewer slots than that (bank bags not loaded yet) is left out too.
function NS.InventorySnapshot(side, now, keepIfEmptied, minSlots)
  local key, name, realm = NS.InventoryKey()
  if not key then return nil end
  local held, slots = readSide(side)
  if slots == 0 or (minSlots and slots < minSlots) then return nil end
  now = now or NS.Now()
  local inv = records()
  local r = inv[key]
  if keepIfEmptied and held == "" and type(r) == "table" and (r[side == "bags" and "b" or "k"] or "") ~= "" then return nil end
  if type(r) ~= "table" then
    r = { n = name, r = realm, t = 0, bt = 0, b = "", k = "" }
    inv[key] = r
  end
  local faction = UnitFactionGroup and UnitFactionGroup("player") or nil
  r.f = faction and faction:lower() or r.f
  -- The server number from the GUID (0.15.1), so a record can be told from a same-named
  -- character elsewhere now that the game names no realm.
  r.s = NS.ServerId and NS.ServerId() or r.s
  -- 0.15.0 on game build 71037 counted this character again under "Name-" with no realm. Once
  -- the realm is known again that second record is the same character: its newer bank count is
  -- kept and the record dropped, so the character is not listed and valued twice.
  if realm ~= "" then
    local orphan = inv[name .. "-"]
    if type(orphan) == "table" and orphan ~= r and (orphan.r or "") == "" and (orphan.f == nil or orphan.f == r.f) then
      if (tonumber(orphan.bt) or 0) > (tonumber(r.bt) or 0) then
        r.k = orphan.k or r.k
        r.bt = orphan.bt
      end
      inv[name .. "-"] = nil
    end
  end
  -- The market only when it is known: a guess would have the site value these bags on the
  -- Normal realm's prices.
  if NS.ClientMarket then
    local market, known = NS.ClientMarket()
    if known then r.m = market end
  end
  if side == "bags" then
    r.b = held
    r.t = now
    r.g = GetMoney and GetMoney() or r.g
  else
    r.k = held
    r.bt = now
  end
  NS.InventoryPrune(inv)
  NS.InventoryChanged()
  return r, slots
end

-- Gold alone, when it changes without the bags changing (a repair, a quest). The bags are as
-- last counted (any change recounts them), so the count's time moves with the gold.
local function snapshotMoney()
  local key = NS.InventoryKey()
  local r = key and records()[key]
  if r and GetMoney then
    r.g = GetMoney()
    if (tonumber(r.t) or 0) > 0 then r.t = NS.Now() end
  end
end

-- ---------------------------------------------------------------------------------------------
-- Reading the records
-- ---------------------------------------------------------------------------------------------

-- What a stack is worth, the rule the net worth page on ahledger.com uses: tradeable units at the
-- better of the median and the vendor price, soulbound units at the vendor price. Pure.
function NS.HoldingValue(count, bound, median, vendor)
  count = math.max(0, tonumber(count) or 0)
  bound = math.min(count, math.max(0, tonumber(bound) or 0))
  local m = (tonumber(median) or 0) > 0 and tonumber(median) or 0
  local v = (tonumber(vendor) or 0) > 0 and tonumber(vendor) or 0
  return (count - bound) * math.max(m, v) + bound * v
end

-- Item counts for a scope: "bank" (this character's bank as last seen) or "all" (bags and bank
-- of every character). { [id] = { count, bound, holders = { {name, bags, bank}, ... } } }, and
-- the records it read. Pure on the table it is given.
function NS.InventoryHoldings(inv, scope, key)
  local out, used = {}, {}
  for k, r in pairs(inv or {}) do
    if type(r) == "table" and (scope == "all" or k == key) then
      used[#used + 1] = r
      local sides = scope == "all" and { { "bags", r.b }, { "bank", r.k } } or { { "bank", r.k } }
      for _, s in ipairs(sides) do
        for id, c in pairs(NS.ParseHolding(s[2])) do
          local h = out[id]
          if not h then
            h = { count = 0, bound = 0, holders = {}, by = {} }
            out[id] = h
          end
          h.count = h.count + c[1]
          h.bound = h.bound + c[2]
          local who = h.by[r.n or k]
          if not who then
            who = { name = r.n or k, bags = 0, bank = 0 }
            h.by[r.n or k] = who
            h.holders[#h.holders + 1] = who
          end
          who[s[1]] = who[s[1]] + c[1]
        end
      end
    end
  end
  for _, h in pairs(out) do
    h.by = nil
    table.sort(h.holders, function(a, b) return (a.bags + a.bank) > (b.bags + b.bank) end)
  end
  return out, used
end

-- How many of an item the player's other characters hold, bags and bank. Pure on the table.
function NS.AltCount(inv, itemID, key)
  local n = 0
  for k, r in pairs(inv or {}) do
    if k ~= key and type(r) == "table" then
      for _, s in ipairs({ r.b, r.k }) do
        local c = NS.ParseHolding(s)[itemID]
        if c then n = n + c[1] end
      end
    end
  end
  return n
end

-- The tooltip asks for alt counts on every hover: an index of every other character's items,
-- built once per change.
local invVersion, altIndex, altVersion, altKey = 0, nil, -1, nil
function NS.InventoryChanged() invVersion = invVersion + 1 end

function NS.AltCountCached(itemID)
  local key = NS.InventoryKey()
  if altVersion ~= invVersion or altKey ~= key or not altIndex then
    altIndex = {}
    for k, r in pairs(records()) do
      if k ~= key and type(r) == "table" then
        for _, s in ipairs({ r.b, r.k }) do
          for id, c in pairs(NS.ParseHolding(s)) do altIndex[id] = (altIndex[id] or 0) + c[1] end
        end
      end
    end
    altVersion, altKey = invVersion, key
  end
  return altIndex[itemID] or 0
end

-- Gold and items across every character, items valued on `market` by NS.HoldingValue.
-- { gold, items, total, characters } in copper.
function NS.NetWorth(market, priceOf, vendorOf)
  local holdings, used = NS.InventoryHoldings(records(), "all")
  local gold = 0
  for _, r in ipairs(used) do gold = gold + (tonumber(r.g) or 0) end
  local items = 0
  for id, h in pairs(holdings) do
    local p = priceOf and priceOf(id, market) or nil
    items = items + NS.HoldingValue(h.count, h.bound, p and p.median, vendorOf and vendorOf(id))
  end
  return { gold = gold, items = items, total = gold + items, characters = #used }
end

-- /ahl alts forget <name>: drops a character's record (on any realm with that name).
function NS.InventoryForget(name)
  name = tostring(name or ""):lower()
  if name == "" then return 0 end
  local inv, n = records(), 0
  for k, r in pairs(inv) do
    if tostring(r.n or ""):lower() == name or k:lower() == name then
      inv[k] = nil
      n = n + 1
    end
  end
  if n > 0 then NS.InventoryChanged() end
  return n
end

-- ---------------------------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------------------------

local bankOpen = false
local bankSlots = 0 -- slots in the last bank read while it was open
-- Something changed while the bank was open and has not been read yet.
local bankDirty = false
local pending = false
local events = CreateFrame("Frame")
NS.InventoryFrame = events

local function flush()
  pending = false
  NS.InventorySnapshot("bags")
  if bankOpen then
    local _, slots = NS.InventorySnapshot("bank")
    if slots then bankSlots = slots end
    bankDirty = false
  end
  if NS.WindowShowing and NS.WindowShowing("bags") and NS.RefreshWindow then NS.RefreshWindow() end
end

local function soon(delay)
  if pending then return end
  pending = true
  if C_Timer and C_Timer.After then C_Timer.After(delay or 2, flush) else flush() end
end

events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("PLAYER_MONEY")
events:RegisterEvent("BANKFRAME_OPENED")
events:RegisterEvent("BANKFRAME_CLOSED")
events:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
events:RegisterEvent("PLAYER_LOGOUT")
events:SetScript("OnEvent", function(_, event)
  if event == "BANKFRAME_OPENED" then
    bankOpen = true
    bankDirty = false
    local _, slots = NS.InventorySnapshot("bank")
    bankSlots = slots or 0
    NS.InventorySnapshot("bags")
  elseif event == "BANKFRAME_CLOSED" then
    -- Moves made in the last moment before closing: read once more, never wiping what was seen.
    if bankOpen and bankDirty then
      NS.InventorySnapshot("bank", nil, true, bankSlots)
      NS.InventorySnapshot("bags", nil, true)
    end
    bankOpen = false
    bankDirty = false
  elseif event == "PLAYER_MONEY" then
    snapshotMoney()
  elseif event == "PLAYER_LOGOUT" then
    NS.InventorySnapshot("bags", nil, true)
  else
    if bankOpen then bankDirty = true end
    soon(bankOpen and 0.3 or 2)
  end
end)

NS.InventoryTestHooks = { flush = flush, isBankOpen = function() return bankOpen end }
local _ = UI
