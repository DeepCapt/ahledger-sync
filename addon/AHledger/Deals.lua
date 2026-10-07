--[[
  Deal finder. Compares the player's own latest auction house scan (the listings the addon
  stored for this realm and faction) against the price table, and lists every item whose lowest
  buyout sits a chosen percent under its 30 day median. Clicking a row searches the auction
  house for the item so the player can buy it; nothing is bought automatically.

  Settings: dealsPercent (percent under the 30 day median, default 30), dealsMinValue (ignore
  items whose 30 day median is below this many copper, default 1 silver) and dealsSelling (only
  items estimated to sell at least one a day, default off). Each row carries the item's sell pace.
]]
local _, NS = ...
local UI = NS.UI
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local tab = {}

-- The newest stored scan for this client's realm and faction, or nil.
function NS.LatestLocalScan()
  local db = NS.Db()
  local info = NS.ClientInfo()
  local best = nil
  for _, s in ipairs(db.scans or {}) do
    if s.realm == info.realm and s.faction == info.faction and s.data then
      if not best or (s.ts or 0) > (best.ts or 0) then best = s end
    end
  end
  return best
end

-- Lowest unit buyout and the quantity available at that price, per item, from a scan string.
function NS.ScanMinima(scan)
  local minima = {}
  if not scan or type(scan.data) ~= "string" then return minima end
  for id, stack, buyout in scan.data:gmatch("(%d+):(%d+):(%d+):%d+:%d+") do
    id, stack, buyout = tonumber(id), tonumber(stack), tonumber(buyout)
    if buyout > 0 and stack > 0 then
      local unit = buyout / stack
      local m = minima[id]
      if not m or unit < m.unit - 0.5 then
        minima[id] = { unit = unit, qty = stack }
      elseif math.abs(unit - m.unit) <= 0.5 then
        m.qty = m.qty + stack
      end
    end
  end
  return minima
end

-- Rows for the deals list: items under (100 - pct)% of their 30 day median, biggest savings first.
function NS.ComputeDeals(pct, minValue)
  pct = pct or NS.Setting("dealsPercent") or 30
  minValue = minValue or NS.Setting("dealsMinValue") or 100
  local scan = NS.LatestLocalScan()
  if not scan then return {}, nil end
  local market = NS.Market()
  local rows = {}
  for id, m in pairs(NS.ScanMinima(scan)) do
    local p = NS.Price(id, market)
    local ref = p and (p.m30 or p.median)
    if ref and ref >= minValue and m.unit <= ref * (1 - pct / 100) then
      local name, link = GetItemInfo(id)
      rows[#rows + 1] = {
        itemID = id,
        name = name or ("item " .. id),
        link = link or name or ("item " .. id),
        unit = math.floor(m.unit),
        ref = ref,
        below = (1 - m.unit / ref) * 100,
        qty = m.qty,
        savings = math.floor((ref - m.unit) * m.qty),
        -- Estimated units sold a day on the market, and the price row for the pace colour.
        perDay = p.perDay,
        price = p,
      }
    end
  end
  table.sort(rows, function(a, b) return a.savings > b.savings end)
  return rows, scan
end

-- Deals on items estimated to sell at least one a day; items without an estimate are left out,
-- since nothing says they sell. Pure.
function NS.SellingDeals(rows)
  local out = {}
  for _, r in ipairs(rows or {}) do
    if r.perDay and r.perDay >= 1 then out[#out + 1] = r end
  end
  return out
end

-- The deal count and the top three for the bar and the post-scan line, computed once per
-- scan, table and threshold rather than on every bag event.
local summary = { key = nil }
function NS.DealSummary()
  local scan = NS.LatestLocalScan()
  if not scan then return nil end
  local market = NS.Market()
  local t = NS.TableFor(market)
  local key = table.concat({
    tostring(scan.ts or 0), tostring(t and t.updated or 0), market,
    tostring(NS.Setting("dealsPercent") or 30), tostring(NS.Setting("dealsMinValue") or 100),
  }, "|")
  if summary.key ~= key then
    local rows = NS.ComputeDeals()
    -- selling: how many of them sell at least one a day, for the bar ("Deals 9 (6 sell)").
    summary = { key = key, n = #rows, selling = #NS.SellingDeals(rows), top = { rows[1], rows[2], rows[3] }, scan = scan }
  end
  return summary
end

-- One chat line after a scan: how many deals it holds and the best three. Pure.
function NS.ScanSummaryText(s)
  if not s then return nil end
  local pct = NS.Setting("dealsPercent") or 30
  if s.n == 0 then
    return string.format("no deals in this scan at %d%% under the 30 day median%s (/ahl deals to change the threshold)", pct, NS.SnapshotSuffix())
  end
  local parts = {}
  for _, r in ipairs(s.top or {}) do
    parts[#parts + 1] = string.format("%s %s (%.0f%% under)", r.link or r.name, NS.Gold(r.unit), r.below)
  end
  return string.format("%d deal%s in this scan at %d%% under the 30 day median%s. Top: %s. /ahl deals for all of them",
    s.n, s.n == 1 and "" or "s", pct, NS.SnapshotSuffix(), table.concat(parts, ", "))
end

local function refresh()
  if not tab.list then return end
  local pct = NS.Setting("dealsPercent") or 30
  local minValue = NS.Setting("dealsMinValue") or 100
  tab.pctBox:SetText(tostring(pct))
  tab.minBox:SetText(UI.PlainGold(minValue))
  local rows, scan = NS.ComputeDeals(pct, minValue)
  local selling = NS.Setting("dealsSelling") and true or false
  tab.sellingBox:SetChecked(selling)
  if selling then rows = NS.SellingDeals(rows) end
  if scan then
    local age = NS.Now() - (scan.ts or NS.Now())
    tab.status:SetText(string.format("From your scan %s, %s listings on %s. %d item%s at least %d%% under the 30 day median%s%s.",
      UI.AgeText(age) or "", UI.Comma(scan.count or 0), NS.MarketLabel(NS.Market()), #rows, #rows == 1 and "" or "s", pct,
      selling and " that sell at least one a day on the AH" or "", NS.SnapshotSuffix()))
  else
    tab.status:SetText(UI.GREY .. "No scan for this realm and faction yet. Open the auction house and press Scan; deals compare your scan with the price table." .. UI.R)
  end
  tab.list:SetRows(rows)
end

local function apply()
  local pct = tonumber((tab.pctBox:GetText() or ""):match("%d+"))
  local minValue = UI.ParsePrice(tab.minBox:GetText())
  if pct and pct > 0 and pct < 100 then NS.SetSetting("dealsPercent", pct) end
  if minValue and minValue >= 0 then NS.SetSetting("dealsMinValue", minValue) end
  tab.pctBox:ClearFocus()
  tab.minBox:ClearFocus()
  refresh()
end

local function build(parent)
  UI.Label(parent, "% under 30 day median", "GameFontNormalSmall", 0, -4, 140)
  tab.pctBox = UI.EditBox(parent, 40, 146, 0, apply)
  UI.Label(parent, "Ignore items under", "GameFontNormalSmall", 200, -4, 110)
  tab.minBox = UI.EditBox(parent, 80, 316, 0, apply)
  local applyButton = UI.Button(parent, "Apply", 60, apply)
  applyButton:SetPoint("TOPLEFT", 404, 1)
  local scanButton = UI.Button(parent, "Scan now", 90, function() if NS.StartScan then NS.StartScan(true) end end)
  scanButton:SetPoint("TOPLEFT", 470, 1)
  -- Only items that sell: the estimated units sold a day must reach one.
  tab.sellingBox = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  tab.sellingBox:SetSize(24, 24)
  tab.sellingBox:SetPoint("TOPLEFT", 566, 2)
  local sellingLabel = tab.sellingBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  sellingLabel:SetPoint("LEFT", tab.sellingBox, "RIGHT", 0, 0)
  sellingLabel:SetText("Sells on the AH")
  tab.sellingBox:SetScript("OnClick", function(self)
    NS.SetSetting("dealsSelling", self:GetChecked() and true or false)
    refresh()
  end)
  tab.sellingBox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Only items that sell on the AH", 1, 1, 1)
    GameTooltip:AddLine("Leaves out deals on items estimated to sell under one a day on this auction house, and items without an estimate yet. A deep discount on an item nobody buys is gold you sit on.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  tab.sellingBox:SetScript("OnLeave", function() GameTooltip:Hide() end)
  tab.status = UI.Label(parent, "", "GameFontHighlightSmall", 0, -28, 668)
  tab.status:SetWordWrap(false)
  tab.list = UI.List(parent, {
    x = 0, y = -46, width = 668, rows = 20, rowKey = "itemID",
    columns = {
      { key = "link", label = "Item", width = 200 },
      { key = "unit", label = "Lowest buyout", width = 95, numeric = true, format = function(v) return NS.Gold(v) end },
      { key = "ref", label = "30 day median", width = 95, numeric = true, format = function(v) return NS.Gold(v) end },
      { key = "below", label = "Under", width = 55, numeric = true, justify = "RIGHT", format = function(v) return string.format("%s%.0f%%%s", UI.UP, v, UI.R) end },
      { key = "qty", label = "Qty", width = 45, numeric = true, justify = "RIGHT", format = function(v) return UI.Comma(v) end },
      { key = "savings", label = "Savings", width = 95, numeric = true, justify = "RIGHT", format = function(v) return NS.Gold(v) end },
      { key = "perDay", label = "Sold/day", width = 70, numeric = true, justify = "RIGHT", tip = "Estimated units sold a day on this auction house, from players' scans over the last week. Green sells fast, white steadily, yellow slowly, grey barely. /ahl pace explains it.", format = function(_, row) return NS.PaceCell(row.price) end },
    },
    empty = "No deals in your latest scan at this threshold.",
    siteLink = function()
      return { text = "Every deal on your house, with history: " .. NS.DealsURL(), title = "Deals on your auction house", url = NS.DealsURL() }
    end,
    onClick = function(row, button)
      if button == "RightButton" and IsControlKeyDown and IsControlKeyDown() then NS.ShowItemLink(row.itemID, row.name) return end
      if button == "RightButton" then
        NS.WatchAdd(row.itemID, row.name)
        NS.Print("watching " .. row.link)
      else
        NS.SearchAuctionHouse(row.name)
      end
    end,
    onEnter = function(tt, row)
      tt:AddLine(UI.GREY .. "Click to search the auction house, right-click to watch, ctrl+right-click for its ahledger.com page" .. UI.R, nil, nil, nil, true)
      tt:AddLine(string.format("%s at %s each, %s below the 30 day median", UI.Comma(row.qty), NS.Gold(row.unit), string.format("%.0f%%", row.below)))
      local pace = NS.Pace(row.price)
      if pace then tt:AddLine(NS.PaceColour(pace.tier) .. NS.PaceText(pace) .. UI.R) end
    end,
  })
  tab.list:SetSort("savings", "desc")
end

NS.RegisterTab({ key = "deals", label = "Deals", order = 2, build = build, refresh = refresh })
