--[[
  Bag appraisal. Every item in the player's bags with its count, the market median, the total
  at median, the vendor total, and whether the auction house beats the vendor by a margin.
  Also the tooltip line "You have N, worth X at median" (option tooltipBags).
]]
local _, NS = ...
local UI = NS.UI
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local AH_OVER_VENDOR = 1.5 -- median must beat the vendor price by this factor to say "auction"
local tab = {}

local function numSlots(bag)
  if C_Container and C_Container.GetContainerNumSlots then return C_Container.GetContainerNumSlots(bag) or 0 end
  if GetContainerNumSlots then return GetContainerNumSlots(bag) or 0 end
  return 0
end

local function slotItem(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if info then return info.itemID, info.stackCount or 1, info.hyperlink end
    return nil
  end
  if GetContainerItemInfo then
    local _, count, _, _, _, _, link, _, _, itemID = GetContainerItemInfo(bag, slot)
    return itemID, count or 1, link
  end
  return nil
end

-- "auction" when the median beats the vendor by AH_OVER_VENDOR, "vendor" when the vendor pays
-- more than the median (or there is no median), "either" in between, nil with neither. Pure.
function NS.SellVerdict(median, vendor)
  median, vendor = tonumber(median), tonumber(vendor)
  if vendor and vendor <= 0 then vendor = nil end
  if median and (not vendor or median >= vendor * AH_OVER_VENDOR) then return "auction" end
  if vendor and (not median or median < vendor) then return "vendor" end
  if median then return "either" end
  return nil
end

-- Rows per item id across all bags, plus totals. Pure, so the harness can drive it.
function NS.AppraiseBags()
  local market = NS.Market()
  local byId = {}
  local lastBag = (NUM_BAG_SLOTS or 4)
  if NUM_REAGENTBAG_SLOTS then lastBag = lastBag + NUM_REAGENTBAG_SLOTS end
  for bag = 0, lastBag do
    for slot = 1, numSlots(bag) do
      local id, count, link = slotItem(bag, slot)
      if id then
        local r = byId[id]
        if not r then
          r = { itemID = id, count = 0, link = link }
          byId[id] = r
        end
        r.count = r.count + (count or 1)
        r.link = r.link or link
      end
    end
  end
  local rows, totalMedian, totalVendor, stacks = {}, 0, 0, 0
  -- Value at the median by how fast it sells: quick (fast or steady, gone within about three
  -- days) and slow (slow or barely moves); items without an estimate count in neither.
  local quick, slow = 0, 0
  for id, r in pairs(byId) do
    local name, link, _, _, _, _, _, _, _, _, vendor = GetItemInfo(id)
    local p = NS.Price(id, market)
    r.name = name or ("item " .. id)
    r.link = link or r.link or r.name
    r.median = p and p.median or nil
    r.vendor = vendor and vendor > 0 and vendor or nil
    r.total = r.median and r.median * r.count or nil
    r.vendorTotal = r.vendor and r.vendor * r.count or nil
    r.sell = NS.SellVerdict(r.median, r.vendor) or ""
    r.priceRow = p
    r.perDay = p and p.perDay or nil
    local pace = NS.Pace(p)
    r.paceTier = pace and pace.tier or nil
    if r.total and pace then
      if pace.tier == "fast" or pace.tier == "steady" then quick = quick + r.total else slow = slow + r.total end
    end
    totalMedian = totalMedian + (r.total or 0)
    totalVendor = totalVendor + (r.vendorTotal or 0)
    stacks = stacks + 1
    rows[#rows + 1] = r
  end
  table.sort(rows, function(a, b) return (a.total or -1) > (b.total or -1) end)
  return rows, { median = totalMedian, vendor = totalVendor, items = stacks, quick = quick, slow = slow }
end

-- Tooltip line for one item: count across bags and bank, and its value at the median.
function NS.BagLine(itemID, row)
  if not GetItemCount then return nil end
  local n = GetItemCount(itemID, true) or 0
  if n <= 0 then return nil end
  if row and row.median then
    return string.format("You have %s, worth %s at median", UI.Comma(n), NS.Gold(n * row.median))
  end
  return string.format("You have %s", UI.Comma(n))
end

local function refresh()
  if not tab.list then return end
  local rows, totals = NS.AppraiseBags()
  tab.totals:SetText(string.format("%s items: %s at median, %s at the vendor. \"Auction\" marks items worth at least %.1fx their vendor price.",
    UI.Comma(totals.items), NS.Gold(totals.median), NS.Gold(totals.vendor), AH_OVER_VENDOR))
  tab.list:SetRows(rows)
end

local function build(parent)
  tab.totals = UI.Label(parent, "", "GameFontHighlightSmall", 0, -2, 668)
  tab.totals:SetWordWrap(false)
  tab.list = UI.List(parent, {
    x = 0, y = -24, width = 668, rows = 21, rowKey = "itemID",
    columns = {
      { key = "link", label = "Item", width = 200 },
      { key = "count", label = "Count", width = 50, numeric = true, justify = "RIGHT", format = function(v) return UI.Comma(v) end },
      { key = "median", label = "Median", width = 95, numeric = true, format = function(v) return v and NS.Gold(v) or (UI.GREY .. "-" .. UI.R) end },
      { key = "total", label = "Total", width = 100, numeric = true, format = function(v) return v and NS.Gold(v) or "" end },
      { key = "vendorTotal", label = "Vendor", width = 90, numeric = true, format = function(v) return v and NS.Gold(v) or "" end },
      { key = "sell", label = "Sell at", width = 55, format = function(v) return v == "auction" and (UI.UP .. "auction" .. UI.R) or v end },
      { key = "perDay", label = "AH sales", width = 70, numeric = true, justify = "RIGHT", tip = "How fast it sells on this auction house: fast (listings clear in under a day), steadily (within 3 days), slowly (within 2 weeks) or barely. Estimated from players' scans; /ahl pace explains it.", format = function(_, row)
        if not row.paceTier then return UI.GREY .. "-" .. UI.R end
        return NS.PaceColour(row.paceTier) .. NS.PaceShort(row.paceTier) .. UI.R
      end },
    },
    empty = "Your bags are empty, or the container API is not available on this client.",
    onClick = function(row, button)
      if button == "RightButton" and IsControlKeyDown and IsControlKeyDown() then NS.ShowItemLink(row.itemID, row.name) return end
      if button == "RightButton" then
        NS.WatchAdd(row.itemID, row.name)
        NS.Print("watching " .. row.link)
      else
        NS.SearchAuctionHouse(row.name)
      end
    end,
    onEnter = function(tt) tt:AddLine(UI.GREY .. "Click to search the auction house, right-click to watch, ctrl+right-click for its ahledger.com page" .. UI.R, nil, nil, nil, true) end,
  })
  tab.list:SetSort("total", "desc")
end

NS.RegisterTab({ key = "bags", label = "Bags", order = 4, build = build, refresh = refresh })

-- ---------------------------------------------------------------------------------------------
-- Bag slot dots (0.10.0). A small square in the bottom-left corner of a bag slot: green, worth
-- auctioning (the median beats the vendor by the same 1.5x the appraisal uses); yellow, vendor
-- it (the vendor pays more than the auction median); grey, junk; blue, on your watchlist. Slots
-- that are none of these stay as they are, so most of a bag is untouched.
-- ---------------------------------------------------------------------------------------------

NS.BAG_DOT = {
  watch = { 0.35, 0.62, 1 },
  auction = { 0.24, 0.86, 0.42 },
  vendor = { 1, 0.82, 0.25 },
  junk = { 0.5, 0.5, 0.52 },
}
NS.BAG_DOT_WORD = { watch = "on your watchlist", auction = "worth auctioning", vendor = "vendor it", junk = "junk" }

-- "watch" | "auction" | "vendor" | "junk" | nil for an item. The vendor dot needs a known median
-- (the vendor beats the auction house), so soulbound gear with no listing stays plain. Pure.
function NS.BagDotKind(itemID, median, vendor, quality, watched)
  if not itemID then return nil end
  if watched then return "watch" end
  if quality == 0 then return "junk" end
  local verdict = NS.SellVerdict(median, vendor)
  if verdict == "auction" then return "auction" end
  if verdict == "vendor" and median then return "vendor" end
  return nil
end

function NS.BagDotForSlot(bag, slot)
  local id, _, link = slotItem(bag, slot)
  if not id then return nil end
  local p = NS.Price(id, NS.Market())
  local _, _, quality, _, _, _, _, _, _, _, vendor = GetItemInfo(link or id)
  local w = NS.Db().watch
  return NS.BagDotKind(id, p and p.median, vendor, quality, w and w[id] ~= nil)
end

local DOT_SIZE, DOT_INSET = 8, 3
-- The dots live here, keyed by button, never as a field on the button: bag slots are protected
-- frames, and nothing of ours is written into them.
local dots = setmetatable({}, { __mode = "k" })

local function paint(button, bag, slot)
  if type(button) ~= "table" then return end
  local kind = NS.Setting("bagDots") and NS.BagDotForSlot(bag, slot) or nil
  local dot = dots[button]
  if not kind then
    if dot then dot:Hide() end
    return
  end
  if not dot then
    dot = button:CreateTexture(nil, "OVERLAY", nil, 7)
    dot:SetSize(DOT_SIZE, DOT_SIZE)
    dot:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", DOT_INSET, DOT_INSET)
    dots[button] = dot
  end
  local c = NS.BAG_DOT[kind]
  dot:SetColorTexture(c[1], c[2], c[3], 0.95)
  dot:Show()
end

-- Every slot of one container frame, whichever shape the client gives it: the modern frame
-- enumerates its item buttons, the Classic frame names them ContainerFrameNItemM.
local function paintFrame(frame)
  if type(frame) ~= "table" or not frame.GetID then return end
  local bag = frame:GetID()
  if frame.EnumerateValidItems then
    for a, b in frame:EnumerateValidItems() do
      local button = type(b) == "table" and b or a
      if type(button) == "table" and button.GetID then
        local id = (button.GetBagID and button:GetBagID()) or bag
        pcall(paint, button, id, button:GetID())
      end
    end
  elseif frame.GetName and frame:GetName() then
    local name = frame:GetName()
    for i = 1, (frame.size or 36) do
      local button = _G[name .. "Item" .. i]
      if button and button.IsShown and button:IsShown() and button.GetID then pcall(paint, button, bag, button:GetID()) end
    end
  end
end

-- Every open bag again: after a setting or watchlist change, and when a price table loads.
function NS.RefreshBagDots()
  local frames = {}
  for i = 1, (NUM_CONTAINER_FRAMES or 13) do
    local f = _G["ContainerFrame" .. i]
    if f and f.IsShown and f:IsShown() then frames[#frames + 1] = f end
  end
  if ContainerFrameCombinedBags and ContainerFrameCombinedBags:IsShown() then frames[#frames + 1] = ContainerFrameCombinedBags end
  for _, f in ipairs(frames) do pcall(paintFrame, f) end
end

local bagsHooked = false
function NS.HookBags()
  if bagsHooked then return end
  bagsHooked = true
  pcall(function()
    local any = false
    for i = 1, (NUM_CONTAINER_FRAMES or 13) do
      local f = _G["ContainerFrame" .. i]
      if f and f.UpdateItems then
        hooksecurefunc(f, "UpdateItems", paintFrame)
        any = true
      end
    end
    if ContainerFrameCombinedBags and ContainerFrameCombinedBags.UpdateItems then
      hooksecurefunc(ContainerFrameCombinedBags, "UpdateItems", paintFrame)
      any = true
    end
    if not any and ContainerFrame_Update then hooksecurefunc("ContainerFrame_Update", paintFrame) end
  end)
end

-- Refresh the tab when bag contents change, at most once a second.
local pending = false
local events = CreateFrame("Frame")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:SetScript("OnEvent", function()
  if pending then return end
  pending = true
  if C_Timer and C_Timer.After then
    C_Timer.After(1, function()
      pending = false
      if NS.WindowShowing and NS.WindowShowing("bags") then refresh() end
      NS.RefreshBagDots()
    end)
  else
    pending = false
  end
end)
