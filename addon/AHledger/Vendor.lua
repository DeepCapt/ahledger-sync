--[[
  Vendor flips. At a merchant, an item that sells on the auction house for well over its
  vendor price gets a green "flip +2g 10s" on its row, with the stock left when the vendor
  carries a limited number. Limited-stock recipes are the classic case. The tooltip still
  shows the median; this is the at-a-glance version. Buying stays the player's click.

  What vendors charge (0.14.1). A recipe's reagents are costed at the cheaper of the vendor
  price and the market median (Crafting.lua), so Leaded Vial counts at its vendor price, not at
  an auction house price ten times higher. Two sources: the prices seen at the merchants this
  account visits (AHledgerDB.vendorPrices, one price per character, since a reputation discount
  is one character's), and the table shipped with the release (AHledger_Vendor.lua, Forever
  only): recipe reagents two or more accounts saw a vendor sell lately, at the highest price
  seen. The shipped table does not know about stock, so an item this account has only seen in
  limited stock is never costed at a vendor price.
]]
local _, NS = ...
local UI = NS.UI

local MIN_RATIO = 1.5 -- the median must beat the vendor price by this much
local MIN_PROFIT = 100 -- copper per unit; under a silver is not a flip

-- Profit per unit when an item is worth flipping, else nil. Pure.
function NS.VendorFlip(price, median)
  price, median = tonumber(price), tonumber(median)
  if not price or price <= 0 or not median then return nil end
  local profit = median - price
  if median < price * MIN_RATIO or profit < MIN_PROFIT then return nil end
  return math.floor(profit)
end

local MAX_SEEN = 3000 -- items noted at merchants; the oldest go first past this
local TRIM_SEEN_TO = 2500
local OWN_FRESH_S = 60 * 86400 -- a character's own price older than this yields to the table

-- The shipped table, read once (at login, or on first use if that comes sooner): id -> copper.
-- Forever only; Classic Era vendors are another game's. The text is dropped once read.
local shipped = nil
local function shippedTable()
  if shipped then return shipped end
  shipped = {}
  local t = AHledgerVendor
  if type(t) ~= "table" or type(t.text) ~= "string" then return shipped end
  if not (t.game == "forever" and NS.IsForeverClient and not NS.IsForeverClient()) then
    for id, price in t.text:gmatch("(%d+):(%d+)") do
      id, price = tonumber(id), tonumber(price)
      if id and price and price > 0 then shipped[id] = price end
    end
  end
  t.text = nil
  return shipped
end
NS.LoadVendorTable = shippedTable
-- The harness swaps the table between checks.
function NS.ResetVendorTable() shipped = nil end

-- This character, as the key a noted price is filed under. Saved variables are shared by every
-- character on the account, and a price one character pays (a reputation discount) is not
-- what another pays.
local function me()
  local name = UnitName and UnitName("player") or nil
  local realm = NS.ClientInfo and NS.ClientInfo().realm or (GetRealmName and GetRealmName() or nil)
  -- "" is what the client gives for a realm since build 71037; the resolved name keeps the key
  -- this character's prices were noted under.
  return tostring(name or "?") .. "-" .. tostring(realm or "?")
end
NS.VendorCharacter = me

-- The noted prices, read straight from the saved table: NS.Db() also fills in every default,
-- which is too much once per reagent of every recipe.
local function noted()
  local db = AHledgerDB
  return type(db) == "table" and type(db.vendorPrices) == "table" and db.vendorPrices or nil
end

-- A noted price, as a number, or nil: saved data from another version may hold anything.
local function priceOf(v)
  local p = type(v) == "table" and tonumber(v.p) or nil
  return (p and p > 0) and p or nil
end

-- Copper for one unit at a vendor, and where the number came from ("seen" or "table"), or nil
-- when no vendor is known to sell the item for gold in unlimited stock. An entry is
-- { by = { [character] = { p, t } }, t, limited }.
--   * This character's own price is what it pays, and wins while it is under 60 days old.
--   * Otherwise the highest of the shipped price and what the account's characters saw, so one
--     character's reputation discount never lowers another's cost below the list price. With a
--     shipped price, a sighting over 60 days old no longer counts: vendors change prices in a
--     patch, and the shipped table follows.
--   * An item the account has only ever seen in limited stock is never a vendor price: three of
--     something is not a supply to cost a recipe with.
function NS.VendorPrice(itemID)
  itemID = tonumber(itemID)
  if not itemID then return nil end
  local list = shippedTable()[itemID]
  local all = noted()
  local e = all and all[itemID]
  if type(e) == "table" then
    local by = type(e.by) == "table" and e.by or nil
    if by then
      local now = NS.Now()
      local function fresh(v) return not list or now - (tonumber(v.t) or 0) <= OWN_FRESH_S end
      local own = by[me()]
      local op = priceOf(own)
      if op and fresh(own) then return op, "seen" end
      local best = nil
      for _, v in pairs(by) do
        local p = priceOf(v)
        if p and fresh(v) and (not best or p > best) then best = p end
      end
      if best then
        if list and list >= best then return list, "table" end
        return best, "seen"
      end
    end
    -- Limited stock and no unlimited price: also the shape an early 0.14.1 build saved.
    if e.limited and not (by and next(by)) then return nil end
  end
  if list then return list, "table" end
  return nil
end

local function trim(db)
  local list = {}
  for id, e in pairs(db.vendorPrices) do list[#list + 1] = { id = id, t = type(e) == "table" and tonumber(e.t) or 0 } end
  table.sort(list, function(a, b) return a.t > b.t end)
  local keep = {}
  for i = 1, math.min(#list, TRIM_SEEN_TO) do keep[list[i].id] = db.vendorPrices[list[i].id] end
  db.vendorPrices = keep
  db.vendorPriceCount = math.min(#list, TRIM_SEEN_TO)
end

-- Notes one merchant row: this character's unit price for an item sold for gold in unlimited
-- stock, or that the item was seen in limited stock. A limited sighting never wipes a price
-- seen in unlimited stock elsewhere, and an unlimited one clears the limited mark. `who` is the
-- character key, passed by a merchant pass so it is built once. Pure apart from the saved
-- table. Returns true when it noted a price.
function NS.NoteVendorPrice(itemID, price, qty, available, extendedCost, who)
  itemID, price = tonumber(itemID), tonumber(price)
  if not itemID or not price or price <= 0 or extendedCost then return false end
  -- The saved table itself: NS.Db() fills in every default, too much once per merchant row.
  local db = type(AHledgerDB) == "table" and AHledgerDB or NS.Db()
  if type(db.vendorPrices) ~= "table" then db.vendorPrices = {} end
  local e = db.vendorPrices[itemID]
  -- Counted once per item: an entry in an older shape is reshaped, not counted again.
  local isNew = e == nil
  if type(e) ~= "table" then
    e = {}
    db.vendorPrices[itemID] = e
  end
  if type(e.by) ~= "table" then e.by = {} end
  e.t = NS.Now()
  -- numAvailable is -1 for unlimited stock; anything else is a count that runs out.
  local limited = available ~= nil and tonumber(available) ~= nil and tonumber(available) >= 0
  if limited then
    e.limited = true
  else
    -- A stack sold together is costed per unit, rounded up: 5 for 102c costs 21c each, not 20c.
    local p = math.ceil(price / math.max(1, tonumber(qty) or 1))
    who = who or me()
    local mine = e.by[who]
    if type(mine) == "table" and mine.p == p then mine.t = e.t else e.by[who] = { p = p, t = e.t } end
    e.limited = nil
  end
  if isNew then
    db.vendorPriceCount = (tonumber(db.vendorPriceCount) or 0) + 1
    if db.vendorPriceCount > MAX_SEEN then trim(db) end
  end
  return not limited
end

-- Every row of the open merchant, noted. Read on MERCHANT_SHOW and MERCHANT_UPDATE: a few dozen
-- rows, one small table each.
local function noteMerchant()
  local count = GetMerchantNumItems and GetMerchantNumItems() or 0
  local who = me()
  for index = 1, count do
    local id = NS.ItemIdFromLink(GetMerchantItemLink and GetMerchantItemLink(index) or nil)
    if id then
      local price, qty, available, extendedCost = NS.MerchantItem(index)
      NS.NoteVendorPrice(id, price, qty, available, extendedCost, who)
    end
  end
end
NS.NoteMerchantPrices = noteMerchant

local warned = false
local function decorate()
  if not MerchantFrame or not MerchantFrame.IsShown or not MerchantFrame:IsShown() then return end
  local ok, err = pcall(function()
    local per = MERCHANT_ITEMS_PER_PAGE or 10
    local page = MerchantFrame.page or 1
    local onMerchantTab = (MerchantFrame.selectedTab or 1) == 1
    local count = GetMerchantNumItems and GetMerchantNumItems() or 0
    for i = 1, per do
      local row = _G["MerchantItem" .. i]
      if row then
        local fs = rawget(row, "AHledgerFlip")
        if not fs then
          fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
          fs:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, 10)
          fs:SetJustifyH("RIGHT")
          row.AHledgerFlip = fs
        end
        local text = ""
        local index = (page - 1) * per + i
        if NS.Setting("vendorFlips") and onMerchantTab and index <= count then
          local link = GetMerchantItemLink and GetMerchantItemLink(index) or nil
          local id = NS.ItemIdFromLink(link)
          local price, qty, available, extendedCost = NS.MerchantItem(index)
          if id and not extendedCost and price and price > 0 then
            local p = NS.Price(id, NS.Market())
            local unit = price / math.max(1, tonumber(qty) or 1)
            local profit = NS.VendorFlip(unit, p and p.median)
            if profit then
              text = UI.UP .. "flip +" .. UI.PlainGold(profit * math.max(1, tonumber(qty) or 1)) .. UI.R
              if available and available > 0 then text = text .. UI.GREY .. "  " .. available .. " left" .. UI.R end
            end
          end
        end
        fs:SetText(text)
      end
    end
  end)
  if not ok and not warned then
    warned = true
    NS.Print("vendor flips are off for this session: " .. tostring(err))
  end
end

if hooksecurefunc and MerchantFrame_UpdateMerchantInfo then
  hooksecurefunc("MerchantFrame_UpdateMerchantInfo", decorate)
end

local frame = CreateFrame("Frame", "AHledgerVendorFrame")
for _, e in ipairs({ "MERCHANT_SHOW", "MERCHANT_UPDATE" }) do pcall(frame.RegisterEvent, frame, e) end
pcall(frame.RegisterEvent, frame, "PLAYER_LOGIN")
local noteWarned = false
local pending = false
local function run()
  pending = false
  -- Each under its own guard: a fault in the flip marks never stops the prices being noted.
  pcall(decorate)
  local ok, err = pcall(noteMerchant)
  if not ok and not noteWarned then
    noteWarned = true
    if NS.NoteError then NS.NoteError("vendor prices", err) end
  end
end
frame:SetScript("OnEvent", function(_, event)
  -- The shipped table is read once at login, so the first tooltip or recipe does not pay for it.
  if event == "PLAYER_LOGIN" then pcall(shippedTable) return end
  -- Opening a merchant fires SHOW and UPDATE together, and every purchase another UPDATE: the
  -- events of one frame share one pass, a frame later, when the rows are filled in.
  if pending then return end
  if C_Timer and C_Timer.After then
    pending = true
    C_Timer.After(0, run)
  else
    run()
  end
end)
NS.RefreshVendorFlips = decorate
