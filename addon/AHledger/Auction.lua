--[[
  Auction house integration.

  Posting helper: when an item is placed in the sell frame, a side panel shows its median,
  minimum buyout, 7 day change, 30 day range and units listed, with buttons that fill the price
  field (undercut the current minimum, match the median, or add a markup). The click that posts
  the auction stays the player's.

  Results column: each browse result row gains "median · under/over %" so value is visible
  without hovering.

  Both work on the modern auction house (the Forever beta) and fall back to the Classic Era
  frames where those exist. Every hook is guarded: if a client build renames something, the
  feature switches itself off for the session instead of erroring on every click.
]]
local _, NS = ...
local UI = NS.UI
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local MARKUP = 1.10
local panel = nil
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
  return panel
end

-- The lowest live listing for an item from the house's own search, when the sell frame ran one.
local function liveMinimum(itemID, isCommodity)
  if not C_AuctionHouse then return nil end
  local ok, value = pcall(function()
    if isCommodity and C_AuctionHouse.GetCommoditySearchResultInfo and C_AuctionHouse.GetNumCommoditySearchResults then
      if (C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0) > 0 then
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
        return r and r.unitPrice or nil
      end
    end
    return nil
  end)
  return ok and value or nil
end

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

function NS.ShowPosting(anchor, itemID, isCommodity)
  if not NS.Setting("postingHelper") then return end
  if not itemID then
    if panel then panel:Hide() end
    return
  end
  local live = liveMinimum(itemID, isCommodity)
  local s = NS.PostingSuggestions(itemID, live)
  local p = ensurePanel(anchor)
  p.s = s
  local name, link = GetItemInfo(itemID)
  p.item:SetText(link or name or ("item " .. itemID))
  if not s then
    p.lines:SetText(UI.GREY .. "No price for this item on " .. NS.MarketLabel(NS.Market()) .. " yet." .. UI.R)
    p.undercut:Disable()
    p.median:Disable()
    p.markup:Disable()
  else
    local row = s.row
    local lines = {}
    if row and row.median then lines[#lines + 1] = "Median " .. NS.Gold(row.median) .. "  " .. UI.ChangeText(row) end
    if row and row.min then lines[#lines + 1] = "Lowest in table " .. NS.Gold(row.min) end
    if live then lines[#lines + 1] = "Lowest right now " .. NS.Gold(live) end
    if row and (row.lo or row.hi) then lines[#lines + 1] = "30 day " .. NS.Gold(row.lo or row.median) .. UI.GREY .. " to " .. UI.R .. NS.Gold(row.hi or row.median) end
    if row and row.qty and row.qty > 0 then lines[#lines + 1] = UI.Comma(row.qty) .. " listed" end
    -- Sell pace, and how long what you carry would take to sell at it.
    for _, l in ipairs(NS.PostingPaceLines(row, GetItemCount and GetItemCount(itemID) or 0) or {}) do
      lines[#lines + 1] = l
    end
    p.lines:SetText(table.concat(lines, "\n"))
    -- Room for every line above the buttons.
    p:SetHeight(math.max(168, 46 + #lines * 15 + 44))
    if s.undercut then p.undercut:Enable() else p.undercut:Disable() end
    if s.median then p.median:Enable() else p.median:Disable() end
    if s.markup then p.markup:Enable() else p.markup:Disable() end
  end
  p:Show()
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
        NS.ShowPosting(AuctionHouseFrame, itemIdFromLocation(location), false)
      end)
      itemFrame:HookScript("OnHide", function() if panel then panel:Hide() end end)
    end
    if commodityFrame and commodityFrame.SetItem then
      hooksecurefunc(commodityFrame, "SetItem", function(self, location)
        NS.ShowPosting(AuctionHouseFrame, itemIdFromLocation(location), true)
      end)
      commodityFrame:HookScript("OnHide", function() if panel then panel:Hide() end end)
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
-- Used by the Classic list, which has no table builder; the modern list gets a real column.
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
-- The Median column on the modern browse list
--
-- The Forever client builds the browse list with Blizzard's table builder: Price, Name (which
-- stretches to fill), an optional level column, Available, and the favourite star. Up to 0.5.4
-- the addon drew its text over the row's right edge, on top of Available and iLvl. Now it
-- adds a column of its own through the same builder, placed after Name, so the name column
-- gives up the space and nothing overlaps at any window width. The cell template is in
-- AHledger.xml; this mixin fills it. The list's layout function is wrapped rather than
-- replaced, so whatever Blizzard's layout does on this build is kept as is.
-- ---------------------------------------------------------------------------------------------

-- A cell must answer everything the row asks of Blizzard's cells: the row calls OnLineEnter
-- and OnLineLeave on every cell when the pointer crosses it, and a cell without them threw
-- "attempt to call a nil value" from TableBuilder.lua (0.6.0). Derive from Blizzard's cell
-- mixin where it exists and define the two anyway.
AHledgerMedianCellMixin = (CreateFromMixins and TableBuilderCellMixin) and CreateFromMixins(TableBuilderCellMixin) or {}

function AHledgerMedianCellMixin:Init(owner)
  self.owner = owner
end

function AHledgerMedianCellMixin:OnLineEnter() end
function AHledgerMedianCellMixin:OnLineLeave() end

function AHledgerMedianCellMixin:Populate(rowData)
  local key = rowData and rowData.itemKey
  local itemID = key and key.itemID
  self.Text:SetText(itemID and NS.ResultColumnText(itemID, rowData.minPrice, true) or "")
end

local MEDIAN_COLUMN_WIDTH = 132
local MEDIAN_COLUMN_AFTER = 2 -- Price, Name, then ours

-- Moves the column just added (the last one) to sit after the Name column. Pure, for the
-- harness: takes the builder's column list and returns it.
function NS.PlaceMedianColumn(columns)
  local n = #columns
  if n <= MEDIAN_COLUMN_AFTER + 1 then return columns end
  local ours = table.remove(columns, n)
  table.insert(columns, MEDIAN_COLUMN_AFTER + 1, ours)
  return columns
end

local function medianLayout(list, original)
  return function(tableBuilder)
    original(tableBuilder)
    if not NS.Setting("ahColumn") then return end
    if not tableBuilder.AddUnsortableFixedWidthColumn or not tableBuilder.GetColumns then return end
    local owner = AuctionHouseFrame.BrowseResultsFrame
    local header = NS.MedianHeaderText and NS.MedianHeaderText() or "Median"
    tableBuilder:AddUnsortableFixedWidthColumn(owner, 0, MEDIAN_COLUMN_WIDTH, 10, 0, header, "AHledgerMedianCellTemplate")
    NS.PlaceMedianColumn(tableBuilder:GetColumns())
  end
end

-- Wraps the layout the browse list currently holds, once, and re-applies it. Called when the
-- auction house UI loads and again whenever Blizzard sets a new layout on the list.
local function installMedianColumn(list)
  if not list or not list.SetTableBuilderLayout then return end
  local current = rawget(list, "tableBuilderLayoutFunction")
  if not current or current == rawget(list, "AHledgerLayout") then return end
  local wrapped = medianLayout(list, current)
  list.AHledgerLayout = wrapped
  list:SetTableBuilderLayout(wrapped)
end

-- Rebuilds the column after the option is flipped, without a reload.
function NS.RefreshMedianColumn()
  local browse = AuctionHouseFrame and AuctionHouseFrame.BrowseResultsFrame
  local list = browse and browse.ItemList
  if not list or not rawget(list, "AHledgerLayout") then return end
  list:SetTableBuilderLayout(list.AHledgerLayout)
end

local function hookModernBrowse()
  if not AuctionHouseFrame or hooked.modernBrowse then return end
  hooked.modernBrowse = true
  guard("results column", function()
    local browse = AuctionHouseFrame.BrowseResultsFrame
    local list = browse and browse.ItemList
    if not list then return end
    installMedianColumn(list)
    if browse.SetupTableBuilder then
      hooksecurefunc(browse, "SetupTableBuilder", function(self) installMedianColumn(self.ItemList) end)
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
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "NEW_AUCTION_UPDATE", "ADDON_LOADED" }) do
  -- NEW_AUCTION_UPDATE exists only on Classic clients; an unknown event must not abort the file.
  pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event, arg1)
  if event == "AUCTION_HOUSE_SHOW" then
    NS.HookAuctionHouse()
  elseif event == "AUCTION_HOUSE_CLOSED" then
    if panel then panel:Hide() end
  elseif event == "NEW_AUCTION_UPDATE" then
    classicSellUpdate()
  elseif event == "ADDON_LOADED" and (arg1 == "Blizzard_AuctionHouseUI" or arg1 == "Blizzard_AuctionUI") then
    NS.HookAuctionHouse()
  end
end)
