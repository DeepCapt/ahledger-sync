--[[
  Auction house integration.

  Posting helper: when an item is placed in the sell frame, a side panel shows its median,
  minimum buyout, 7 day change, 30 day range and units listed, with buttons that fill the price
  field (undercut the current minimum, match the median, or add a markup). The click that posts
  the auction stays the player's.

  Results column: each browse result row gains "median · under/over %" so value is visible
  without hovering.

  Both work on the modern auction house (Forever) and fall back to the Classic Era
  frames where those exist. Every hook is guarded: if a client build renames something, the
  feature switches itself off for the session instead of erroring on every click.
]]
local _, NS = ...
local UI = NS.UI
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local MARKUP = 1.10
local panel = nil
local setQuantity -- defined below the plan; the panel's Qty button closes over this local
local hooked = {}
local warned = {}

local function guard(key, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok and not warned[key] then
    warned[key] = true
    NS.Print(string.format("%s is off for this session: %s", key, tostring(err)))
  end
  return ok
end

-- Searches the auction house for an item name. Returns false when the house is closed.
function NS.SearchAuctionHouse(name)
  if not name or name == "" then return false end
  if AuctionHouseFrame and AuctionHouseFrame:IsShown() then
    return guard("auction house search", function()
      local bar = AuctionHouseFrame.SearchBar
      if bar and bar.SearchBox and bar.StartSearch then
        bar.SearchBox:SetText(name)
        bar:StartSearch()
      elseif C_AuctionHouse and C_AuctionHouse.SendBrowseQuery then
        C_AuctionHouse.SendBrowseQuery({ searchString = name, sorts = {}, filters = {} })
      end
      if AuctionHouseFrame.SetDisplayMode and AuctionHouseFrameDisplayMode and AuctionHouseFrameDisplayMode.Buy then
        AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
      end
    end)
  end
  if AuctionFrame and AuctionFrame:IsShown() and BrowseName then
    return guard("auction house search", function()
      if AuctionFrameTab_OnClick and AuctionFrameTab1 then AuctionFrameTab_OnClick(AuctionFrameTab1) end
      BrowseName:SetText(name)
      if AuctionFrameBrowse_Search then AuctionFrameBrowse_Search() end
    end)
  end
  NS.Print("open the auction house first, then click the item again")
  return false
end

-- ---------------------------------------------------------------------------------------------
-- Posting helper
-- ---------------------------------------------------------------------------------------------

-- Suggested prices for an item. live = the lowest current listing from the house's own search,
-- when known. Pure, so the harness can check it.
function NS.PostingSuggestions(itemID, live)
  local row = NS.Price(itemID, NS.Market())
  local floor = live or (row and row.min) or (row and row.median)
  if not row and not live then return nil end
  local out = { row = row, live = live }
  if floor and floor > 1 then out.undercut = math.max(1, math.floor(floor - 1)) end
  if row and row.median then
    out.median = math.floor(row.median)
    out.markup = math.floor(row.median * MARKUP)
  elseif live then
    out.median = math.floor(live)
    out.markup = math.floor(live * MARKUP)
  end
  return out
end

local function setPrice(copper)
  if not copper or copper <= 0 then return end
  local ok = false
  if AuctionHouseFrame then
    for _, frame in ipairs({ AuctionHouseFrame.ItemSellFrame, AuctionHouseFrame.CommoditiesSellFrame }) do
      if frame and frame:IsShown() and frame.PriceInput and frame.PriceInput.SetAmount then
        frame.PriceInput:SetAmount(copper)
        ok = true
      end
    end
  end
  if not ok and BuyoutPrice and MoneyInputFrame_SetCopper then
    MoneyInputFrame_SetCopper(BuyoutPrice, copper)
    if StartPrice then MoneyInputFrame_SetCopper(StartPrice, math.max(1, math.floor(copper * 0.95))) end
    ok = true
  end
  if ok then NS.Print("price set to " .. NS.Gold(copper) .. "; check it and post when ready") end
end

local function ensurePanel(anchor)
  if panel then
    panel:SetParent(anchor)
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, -28)
    return panel
  end
  panel = CreateFrame("Frame", "AHledgerPostingPanel", anchor, "BackdropTemplate")
  panel:SetSize(250, 168)
  panel:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, -28)
  panel:SetBackdrop({
    bgFile = "Interface/DialogFrame/UI-DialogBox-Background",
    edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 16,
    insets = { left = 5, right = 5, top = 5, bottom = 5 },
  })
  panel.title = UI.Label(panel, UI.ACCENT .. "AHledger" .. UI.R .. " posting", "GameFontNormal", 12, -10)
  panel.item = UI.Label(panel, "", "GameFontHighlightSmall", 12, -30, 226)
  panel.item:SetWordWrap(false)
  panel.lines = UI.Label(panel, "", "GameFontHighlightSmall", 12, -46, 226)
  panel.lines:SetSpacing(2)
  panel.undercut = UI.Button(panel, "Undercut", 74, function() setPrice(panel.s and panel.s.undercut) end)
  panel.undercut:SetPoint("BOTTOMLEFT", 10, 10)
  panel.median = UI.Button(panel, "Median", 74, function() setPrice(panel.s and panel.s.median) end)
  panel.median:SetPoint("LEFT", panel.undercut, "RIGHT", 4, 0)
  panel.markup = UI.Button(panel, "+10%", 74, function() setPrice(panel.s and panel.s.markup) end)
  panel.markup:SetPoint("LEFT", panel.median, "RIGHT", 4, 0)
  -- The plan's quantity, above the price buttons, for commodities only.
  panel.qty = UI.Button(panel, "Qty", 74, function() setQuantity(panel.qty.n) end)
  panel.qty:SetPoint("BOTTOMLEFT", 10, 36)
  panel.qty:Hide()
  return panel
end

-- The lowest unit price among a search's rows, leaving out rows that are all the player's own
-- (undercutting yourself only lowers your price). rows = { { price, quantity, own } } in the
-- house's order. nil when there is none. Pure, for the harness.
function NS.LowestListing(rows)
  local best = nil
  for _, r in ipairs(rows or {}) do
    local qty = math.max(1, tonumber(r.quantity) or 1)
    local own = tonumber(r.own) or 0
    if r.price and r.price > 0 and own < qty then
      local unit = math.floor(r.price)
      if not best or unit < best then best = unit end
    end
  end
  return best
end

local LIVE_ROWS = 40 -- the first rows of a search; the house sorts them cheapest first

-- The lowest live listing for an item from the house's own search, the one the sell frame runs
-- when an item is placed in it. Up to 0.13.1 this was read only as the item was placed, before
-- the search had answered, so the panel showed the price table's lowest even with cheaper
-- listings on screen; the panel now redraws when the results arrive.
local function liveMinimum(itemID, isCommodity, itemKey)
  if not C_AuctionHouse then return nil end
  local ok, value = pcall(function()
    local rows = {}
    if isCommodity and C_AuctionHouse.GetCommoditySearchResultInfo and C_AuctionHouse.GetNumCommoditySearchResults then
      local n = math.min(LIVE_ROWS, C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0)
      for i = 1, n do
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if r then rows[#rows + 1] = { price = r.unitPrice, quantity = r.quantity, own = r.numOwnerItems } end
      end
    elseif itemKey and C_AuctionHouse.GetItemSearchResultInfo and C_AuctionHouse.GetNumItemSearchResults then
      local n = math.min(LIVE_ROWS, C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0)
      for i = 1, n do
        local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if r and r.buyoutAmount then
          local qty = math.max(1, r.quantity or 1)
          rows[#rows + 1] = { price = r.buyoutAmount / qty, quantity = qty, own = r.containsOwnerItem and qty or 0 }
        end
      end
    end
    return NS.LowestListing(rows)
  end)
  return ok and value or nil
end

-- When the lowest listing on the house is this far under the price table's, the table is behind
-- the market and the panel says so.
local STALE_SHARE = 0.6

-- The posting panel's pace lines, or nil: "AH sales: sells steadily, ~200 sold a day" and, when
-- you carry some, "At that pace your 120 would sell in about 14 hours". Pure, for the harness.
function NS.PostingPaceLines(row, carried)
  if not NS.Setting("tooltipPace") then return nil end
  local pace = NS.Pace(row)
  if not pace then return nil end
  local out = { "AH sales: " .. NS.PaceColour(pace.tier) .. NS.PacePhrase(pace.tier) .. UI.R .. UI.GREY .. ", " .. NS.SoldText(pace.perDay) .. UI.R }
  local clear = NS.ClearText(pace, carried)
  if clear then out[#out + 1] = UI.GREY .. (clear:gsub("^%l", string.upper)) .. UI.R end
  return out
end

-- ---------------------------------------------------------------------------------------------
-- Posting plan (0.10.0): how many to post and for how long, from the sales pace. An auction that
-- expires costs its deposit, so the plan picks the shortest duration in which what you post
-- would sell, and when you carry more than two days of sales it says how many to hold back.
-- { qty, hours, hold, text } or nil without a pace or a count. Pure.
-- ---------------------------------------------------------------------------------------------

local DURATIONS = { 12, 24, 48 }

function NS.PostingPlan(row, carried)
  local pace = NS.Pace(row)
  carried = math.floor(tonumber(carried) or 0)
  if not pace or carried <= 0 then return nil end
  if pace.perDay <= 0 then
    return { qty = 1, hours = 48, hold = carried - 1, text = "None sold this week: post one for 48 hours and see whether it goes before listing more." }
  end
  for _, hours in ipairs(DURATIONS) do
    local sells = math.floor(pace.perDay * hours / 24)
    if carried <= sells then
      return { qty = carried, hours = hours, hold = 0, text = string.format("Post all %d for %d hours: about %s sell in that time.", carried, hours, NS.RoughCount(sells)) }
    end
  end
  local qty = math.max(1, math.floor(pace.perDay * 2))
  return { qty = qty, hours = 48, hold = carried - qty, text = string.format("Post %d of your %d for 48 hours: about that many sell in two days. List the rest once they go, so no deposit is lost on an expired auction.", qty, carried) }
end

-- Fills the quantity box of the commodities sell frame. Posting stays the player's click.
setQuantity = function(n)
  if not n or n <= 0 then return end
  local ok = guard("posting plan", function()
    local frame = AuctionHouseFrame and AuctionHouseFrame.CommoditiesSellFrame
    if not frame or not frame:IsShown() or not frame.QuantityInput then error("no commodity in the sell frame") end
    local q = frame.QuantityInput
    if q.SetQuantity then q:SetQuantity(n)
    elseif q.InputBox and q.InputBox.SetNumber then q.InputBox:SetNumber(n)
    else error("the quantity box has no setter on this client") end
  end)
  if ok then NS.Print("quantity set to " .. n .. "; check the duration and post when ready") end
end

local shown = nil -- { anchor, itemID, isCommodity, itemKey } of the item in the panel

function NS.ShowPosting(anchor, itemID, isCommodity, itemKey)
  if not NS.Setting("postingHelper") then return end
  if not itemID then
    shown = nil
    if panel then panel:Hide() end
    return
  end
  shown = { anchor = anchor, itemID = itemID, isCommodity = isCommodity, itemKey = itemKey }
  local live = liveMinimum(itemID, isCommodity, itemKey)
  local s = NS.PostingSuggestions(itemID, live)
  local p = ensurePanel(anchor)
  p.s = s
  local name, link = GetItemInfo(itemID)
  p.item:SetText(link or name or ("item " .. itemID))
  p.qty:Hide()
  if not s then
    p.lines:SetText(UI.GREY .. "No price for this item on " .. NS.MarketLabel(NS.Market()) .. " yet." .. UI.R)
    p.undercut:Disable()
    p.median:Disable()
    p.markup:Disable()
    p:SetHeight(168)
  else
    local row = s.row
    local lines = {}
    if row and row.median then lines[#lines + 1] = "Median " .. NS.Gold(row.median) .. "  " .. UI.ChangeText(row) end
    if row and row.min then lines[#lines + 1] = "Lowest in table " .. NS.Gold(row.min) end
    if live then lines[#lines + 1] = "Lowest right now " .. NS.Gold(live) end
    local floor = row and (row.min or row.median)
    if live and floor and live < floor * STALE_SHARE then
      lines[#lines + 1] = UI.DOWN .. "Listed now far under the table" .. UI.R
    end
    local age = row and NS.PricesAgeText(NS.Market())
    if age then lines[#lines + 1] = UI.GREY .. "Table: " .. age .. UI.R end
    if row and (row.lo or row.hi) then lines[#lines + 1] = "30 day " .. NS.Gold(row.lo or row.median) .. UI.GREY .. " to " .. UI.R .. NS.Gold(row.hi or row.median) end
    if row and row.qty and row.qty > 0 then lines[#lines + 1] = UI.Comma(row.qty) .. " listed" end
    local getItemCount = (C_Item and C_Item.GetItemCount) or GetItemCount
    local carried = getItemCount and getItemCount(itemID) or 0
    -- Sell pace, and how long what you carry would take to sell at it.
    for _, l in ipairs(NS.PostingPaceLines(row, carried) or {}) do
      lines[#lines + 1] = l
    end
    -- The plan: how many, for how long, and what to hold back.
    local plan = NS.Setting("postingPlan") and NS.PostingPlan(row, carried) or nil
    local extra = 0
    if plan then
      lines[#lines + 1] = UI.ACCENT .. "Plan" .. UI.R .. UI.GREY .. ": " .. plan.text .. UI.R
      extra = 2 -- the plan wraps to a second or third line
      if isCommodity and plan.qty > 0 and plan.qty < carried then
        p.qty:SetText("Qty " .. plan.qty)
        p.qty.n = plan.qty
        p.qty:Show()
        extra = extra + 2
      end
    end
    p.lines:SetText(table.concat(lines, "\n"))
    -- Room for every line above the buttons.
    p:SetHeight(math.max(168, 46 + (#lines + extra) * 15 + 44))
    if s.undercut then p.undercut:Enable() else p.undercut:Disable() end
    if s.median then p.median:Enable() else p.median:Disable() end
    if s.markup then p.markup:Enable() else p.markup:Disable() end
  end
  p:Show()
end

-- The house answered a search. When it is for the item in the panel, the panel is drawn again
-- with the lowest listing. arg = the item id (commodities) or the item key (other items).
function NS.OnAuctionSearchResults(event, arg)
  if not shown or not panel or not panel:IsShown() then return end
  local id = type(arg) == "table" and arg.itemID or arg
  if id ~= shown.itemID then return end
  if event == "ITEM_SEARCH_RESULTS_UPDATED" and type(arg) == "table" then shown.itemKey = shown.itemKey or arg end
  NS.ShowPosting(shown.anchor, shown.itemID, shown.isCommodity, shown.itemKey)
end

local function itemKeyFromLocation(location)
  if not location or not C_AuctionHouse or not C_AuctionHouse.GetItemKeyFromItem then return nil end
  local ok, key = pcall(C_AuctionHouse.GetItemKeyFromItem, location)
  return ok and key or nil
end

local function itemIdFromLocation(location)
  if not location then return nil end
  if C_Item and C_Item.GetItemID and C_Item.DoesItemExist then
    local ok, exists = pcall(C_Item.DoesItemExist, location)
    if ok and exists then
      local ok2, id = pcall(C_Item.GetItemID, location)
      if ok2 then return id end
    end
  end
  return nil
end

local function hookModernSell()
  if not AuctionHouseFrame or hooked.modernSell then return end
  hooked.modernSell = true
  guard("posting helper", function()
    local itemFrame = AuctionHouseFrame.ItemSellFrame
    local commodityFrame = AuctionHouseFrame.CommoditiesSellFrame
    if itemFrame and itemFrame.SetItem then
      hooksecurefunc(itemFrame, "SetItem", function(self, location)
        NS.ShowPosting(AuctionHouseFrame, itemIdFromLocation(location), false, itemKeyFromLocation(location))
      end)
      itemFrame:HookScript("OnHide", function() shown = nil; if panel then panel:Hide() end end)
    end
    if commodityFrame and commodityFrame.SetItem then
      hooksecurefunc(commodityFrame, "SetItem", function(self, location)
        NS.ShowPosting(AuctionHouseFrame, itemIdFromLocation(location), true)
      end)
      commodityFrame:HookScript("OnHide", function() shown = nil; if panel then panel:Hide() end end)
    end
  end)
end

-- Classic Era: NEW_AUCTION_UPDATE fires when an item lands in the sell slot.
local function classicSellUpdate()
  if not GetAuctionSellItemInfo or not AuctionFrame then return end
  guard("posting helper", function()
    local name, _, count, _, _, _, _, _, _, itemID = GetAuctionSellItemInfo()
    if itemID and itemID > 0 then
      NS.ShowPosting(AuctionFrame, itemID, false)
    elseif panel then
      panel:Hide()
    end
    local _ = name
    local _ = count
  end)
end

-- ---------------------------------------------------------------------------------------------
-- Results column
-- ---------------------------------------------------------------------------------------------

-- "median · 18% under" for a listing price against the table. Pure.
function NS.ResultColumnText(itemID, price, bare)
  local row = NS.Price(itemID, NS.Market())
  if not row or not row.median then return "" end
  local text = (bare and "" or "med ") .. NS.Gold(row.median)
  if price and price > 0 then
    local pct = (price - row.median) / row.median * 100
    if pct <= -5 then
      text = text .. string.format("  %s%.0f%% under%s", UI.UP, -pct, UI.R)
    elseif pct >= 5 then
      text = text .. string.format("  %s%.0f%% over%s", UI.DOWN, pct, UI.R)
    end
  end
  return text
end

-- Custom fields on Blizzard frames are read with rawget so a frame metatable cannot answer.
-- Used by the Classic list, which has no table builder; the modern list is drawn below.
local function decorate(frame, itemID, price)
  local fs = rawget(frame, "AHledgerText")
  if not fs then
    fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("RIGHT", frame, "RIGHT", -4, 0)
    fs:SetJustifyH("RIGHT")
    fs:SetTextColor(0.7, 0.7, 0.72)
    frame.AHledgerText = fs
  end
  fs:SetText(NS.Setting("ahColumn") and NS.ResultColumnText(itemID, price) or "")
end

-- ---------------------------------------------------------------------------------------------
-- The median on the modern browse list
--
-- The Forever client builds the browse list with Blizzard's table builder: Price, Name (which
-- stretches to fill), an optional level column, Available, and the favourite star. From 0.6.0
-- to 0.13.3 the addon added a real Median column by wrapping the list's layout function. That
-- put an addon function inside Blizzard's own path: AuctionHouseItemListMixin calls the layout
-- function directly while the auction house opens, OpenAllBags runs in the same call, and the
-- bags then registered their gamepad bindings tainted. With gamepad mode on, every window
-- opened or closed afterwards was blocked ("AHledger has been blocked from an action only
-- available to the Blizzard UI: SetPreferredGamepadInteractTarget()") until a reload.
--
-- Rule: never call SetTableBuilderLayout, never add a column, never hand this list a function,
-- template or mixin of ours to run. The text is drawn after a row is built instead, from
-- hooksecurefunc post-hooks on the list's table builder (AddRow, plus Arrange, which rebuilds
-- the cells of rows already shown). Post-hooks run after Blizzard's code has returned, so they
-- cannot taint it. The text sits at the right end of the Name cell and the name's right edge
-- (and Blizzard's own truncation text, ExtraInfo) moves left of it, so a long name shortens
-- instead of running under the price. Cells come from a shared pool: every cell whose anchors
-- we moved is put back as the template had them when its row goes or the layout is reset.
-- Bookkeeping lives in weak tables here, not in fields on Blizzard's frames.
-- ---------------------------------------------------------------------------------------------

local medianText = setmetatable({}, { __mode = "k" }) -- row -> our FontString
local touched = setmetatable({}, { __mode = "k" }) -- cell -> the row whose text it now ends at
local MEDIAN_GAP = 8
local browseBuilder = nil

-- The Name cell of a built row: the one carrying the item text and Blizzard's truncation text.
function NS.BrowseNameCell(row)
  local cells = type(row) == "table" and rawget(row, "cells")
  if type(cells) ~= "table" then return nil end
  for _, cell in ipairs(cells) do
    if type(cell) == "table" and rawget(cell, "Text") and rawget(cell, "ExtraInfo") then return cell end
  end
  return nil
end

local function truncate(cell)
  if cell.HandleItemNameTruncation then pcall(cell.HandleItemNameTruncation, cell) end
end

-- Puts a cell's name back to the template's anchors, if we moved them (for `row`, when given).
local function restoreCell(cell, row)
  local owner = touched[cell]
  if not owner or (row and owner ~= row) then return end
  touched[cell] = nil
  rawget(cell, "Text"):SetPoint("RIGHT", cell, "RIGHT", 1, 0)
  rawget(cell, "ExtraInfo"):SetPoint("RIGHT", cell, "RIGHT", 1, 0)
  truncate(cell)
end

local function clearRow(row)
  local fs = medianText[row]
  if fs then
    fs:SetText("")
    fs:Hide()
  end
end

local function decorateRow(row)
  local cell = NS.BrowseNameCell(row)
  local data = rawget(row, "rowData")
  local key = type(data) == "table" and data.itemKey
  local text = ""
  if cell and NS.Setting("ahColumn") and type(key) == "table" and key.itemID then
    text = NS.ResultColumnText(key.itemID, data.minPrice, true)
  end
  if text == "" then
    clearRow(row)
    if cell then restoreCell(cell) end
    return
  end
  local fs = medianText[row]
  if not fs then
    fs = row:CreateFontString(nil, "OVERLAY", "Number14FontWhite")
    fs:SetJustifyH("RIGHT")
    fs:SetTextColor(0.7, 0.7, 0.72)
    medianText[row] = fs
  end
  fs:ClearAllPoints()
  fs:SetPoint("RIGHT", cell, "RIGHT", 0, 0)
  fs:SetText(text)
  fs:Show()
  rawget(cell, "Text"):SetPoint("RIGHT", fs, "LEFT", -MEDIAN_GAP, 0)
  rawget(cell, "ExtraInfo"):SetPoint("RIGHT", fs, "LEFT", -MEDIAN_GAP, 0)
  touched[cell] = row
  truncate(cell)
end

local function undecorateRow(row)
  clearRow(row)
  for cell, owner in pairs(touched) do
    if owner == row then restoreCell(cell, row) end
  end
end

local function restoreAll()
  for cell in pairs(touched) do restoreCell(cell) end
end

local function sweep(tb)
  local rows = tb and rawget(tb, "rows")
  if type(rows) ~= "table" then return end
  for _, row in ipairs(rows) do pcall(decorateRow, row) end
end

local function hookBrowseBuilder(tb)
  if hooked.browseBuilder or type(tb) ~= "table" or not tb.AddRow then return end
  hooked.browseBuilder = true
  browseBuilder = tb
  hooksecurefunc(tb, "AddRow", function(_, row) pcall(decorateRow, row) end)
  if tb.RemoveRow then hooksecurefunc(tb, "RemoveRow", function(_, row) pcall(undecorateRow, row) end) end
  if tb.Reset then hooksecurefunc(tb, "Reset", function() pcall(restoreAll) end) end
  if tb.Arrange then hooksecurefunc(tb, "Arrange", function(self) pcall(sweep, self) end) end
  sweep(tb)
end

-- Redraws the rows on screen after the option is flipped, without a reload.
function NS.RefreshMedianColumn()
  if browseBuilder then sweep(browseBuilder) end
end

local function hookModernBrowse()
  if not AuctionHouseFrame or hooked.modernBrowse then return end
  guard("results column", function()
    local browse = AuctionHouseFrame.BrowseResultsFrame
    local list = type(browse) == "table" and rawget(browse, "ItemList")
    if type(list) ~= "table" then return end
    hooked.modernBrowse = true
    local tb = rawget(list, "tableBuilder")
    if tb then
      hookBrowseBuilder(tb)
    elseif list.Init then
      -- The list makes its table builder in Init, the first time it is shown.
      hooksecurefunc(list, "Init", function(self) pcall(hookBrowseBuilder, rawget(self, "tableBuilder")) end)
    end
  end)
end

local function decorateClassic()
  if not AuctionFrameBrowse or not NS.Setting("ahColumn") then return end
  guard("results column", function()
    local offset = FauxScrollFrame_GetOffset and FauxScrollFrame_GetOffset(BrowseScrollFrame) or 0
    for i = 1, (NUM_BROWSE_TO_DISPLAY or 8) do
      local button = _G["BrowseButton" .. i]
      if button and button:IsShown() then
        local index = offset + i
        local link = GetAuctionItemLink and GetAuctionItemLink("list", index)
        local itemID = NS.ItemIdFromLink(link)
        local _, _, count, _, _, _, _, _, _, buyout = GetAuctionItemInfo("list", index)
        if itemID then
          decorate(button, itemID, (buyout or 0) > 0 and count and count > 0 and buyout / count or nil)
        elseif rawget(button, "AHledgerText") then
          button.AHledgerText:SetText("")
        end
      end
    end
  end)
end

local function hookClassicBrowse()
  if hooked.classicBrowse or not AuctionFrameBrowse_Update then return end
  hooked.classicBrowse = true
  hooksecurefunc("AuctionFrameBrowse_Update", decorateClassic)
end

function NS.HookAuctionHouse()
  hookModernSell()
  hookModernBrowse()
  hookClassicBrowse()
end

local events = CreateFrame("Frame")
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "NEW_AUCTION_UPDATE", "ADDON_LOADED",
    "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED" }) do
  -- NEW_AUCTION_UPDATE exists only on Classic clients and the search events only on the modern
  -- house; an unknown event must not abort the file.
  pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event, arg1)
  if event == "AUCTION_HOUSE_SHOW" then
    NS.HookAuctionHouse()
  elseif event == "AUCTION_HOUSE_CLOSED" then
    shown = nil
    if panel then panel:Hide() end
  elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" or event == "ITEM_SEARCH_RESULTS_UPDATED" then
    guard("posting helper", NS.OnAuctionSearchResults, event, arg1)
  elseif event == "NEW_AUCTION_UPDATE" then
    classicSellUpdate()
  elseif event == "ADDON_LOADED" and (arg1 == "Blizzard_AuctionHouseUI" or arg1 == "Blizzard_AuctionUI") then
    NS.HookAuctionHouse()
  end
end)
