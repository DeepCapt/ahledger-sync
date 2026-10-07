--[[
  The ledger bar: one movable strip with the numbers a player looks at most, each a click away
  from its tab. Bag value at the market median, gold this session with the hourly rate, watchlist
  alerts, deals in your latest scan, and a ticker that walks the watchlist one item at a time.
  With barPace on (0.9.0), the sell pace joins in: how much of the bags sells quickly, how many
  deals sell, and a pace word on each ticker item.
  Drag it anywhere; lock it with /ahl bar lock, right-click the AH mark, or the options panel.
  Hover the AH mark for what your scans have added to ahledger.com.

  Nothing here is new data: every segment reads what the other files already compute, so the
  bar costs one pass over the bags about once a second at most, and nothing while idle.
]]
local _, NS = ...
local UI = NS.UI

local bar = nil
local segments = {}
local mark = nil
local rotate = nil
local tickIndex = 0
local flashUntil = 0
local pending = false
local sessionStartMoney, sessionStartAt = nil, nil

local SEGMENT_GAP = 16
local TICK_S = 8
local RATE_AFTER_S = 300
local FLASH_S = 12
local DEFAULT_Y = -4

-- ---------------------------------------------------------------------------------------------
-- Session gold
-- ---------------------------------------------------------------------------------------------

-- Copper gained or lost since login or the last reset, and the seconds elapsed.
function NS.SessionGold()
  if not sessionStartMoney or not GetMoney then return nil end
  return (GetMoney() or 0) - sessionStartMoney, NS.Now() - (sessionStartAt or NS.Now())
end

function NS.ResetSession()
  sessionStartMoney = GetMoney and (GetMoney() or 0) or 0
  sessionStartAt = NS.Now()
  if NS.RefreshBar then NS.RefreshBar() end
end

-- "+42g 10s (18g/h)". The rate waits five minutes, so one vendor run at login does not read
-- as nine hundred gold an hour. Pure, so the harness can read it.
function NS.SessionText(delta, elapsed)
  if delta == nil then return nil end
  local tone = delta >= 0 and UI.UP or UI.DOWN
  local text = tone .. (delta >= 0 and "+" or "-") .. UI.PlainGold(math.abs(delta)) .. UI.R
  if elapsed and elapsed >= RATE_AFTER_S and delta ~= 0 then
    local perHour = delta / elapsed * 3600
    text = text .. UI.GREY .. string.format(" (%s%s/h)", perHour < 0 and "-" or "", UI.PlainGold(math.abs(perHour))) .. UI.R
  end
  return text
end

-- ---------------------------------------------------------------------------------------------
-- What your scans have added, written into the data file by AHledger sync 0.2.10 or later.
-- ---------------------------------------------------------------------------------------------

function NS.Contribution()
  local c = AHledgerData and AHledgerData.contribution
  if type(c) ~= "table" then return nil end
  return c
end

-- "Your scans added 1,240 listings in 3 scans, 36 quests in the last 7 days." Pure.
function NS.ContributionText(c)
  if type(c) ~= "table" then return nil end
  local parts = {}
  local scans = tonumber(c.scans) or 0
  if (tonumber(c.listings) or 0) > 0 then
    parts[#parts + 1] = string.format("%s listings in %d scan%s", UI.Comma(c.listings), scans, scans == 1 and "" or "s")
  end
  if (tonumber(c.sources) or 0) > 0 then parts[#parts + 1] = UI.Comma(c.sources) .. " item source lines" end
  if (tonumber(c.quests) or 0) > 0 then parts[#parts + 1] = UI.Comma(c.quests) .. " quests" end
  local days = tonumber(c.days) or 7
  if #parts == 0 then return string.format("Nothing from your scans reached the site in the last %d days.", days) end
  local text = string.format("Your scans added %s in the last %d days.", table.concat(parts, ", "), days)
  local rank, total = tonumber(c.rank), tonumber(c.contributors)
  if rank and rank > 0 and total and total > 0 then
    text = text .. string.format(" You rank %d of %d contributors.", rank, total)
  end
  return text
end

-- ---------------------------------------------------------------------------------------------
-- The numbers, computed once per refresh and shared with the minimap tooltip
-- ---------------------------------------------------------------------------------------------

function NS.BarStats()
  local s = {}
  if NS.AppraiseBags then
    local ok, rows, totals = pcall(NS.AppraiseBags)
    if ok and totals then
      s.bags, s.bagVendor, s.bagItems, s.bagRows = totals.median, totals.vendor, totals.items, rows
      s.bagQuick, s.bagSlow = totals.quick, totals.slow
    end
  end
  s.delta, s.elapsed = NS.SessionGold()
  s.alerts = NS.ActiveAlerts and NS.ActiveAlerts() or {}
  s.deals = NS.DealSummary and NS.DealSummary() or nil
  s.mail = NS.LastMail
  s.contribution = NS.Contribution()
  return s
end

-- The bags segment: "Bag value 45g · 31g sells fast" with the pace on: the value in items that sell
-- fast or steadily on the auction house. Pure.
function NS.BarBagsText(s, pace)
  local text = UI.GREY .. "Bag value " .. UI.R .. (s.bags and NS.Gold(s.bags) or (UI.GREY .. "-" .. UI.R))
  if pace and s.bags and (s.bagQuick or 0) > 0 then
    text = text .. UI.GREY .. " · " .. UI.R .. UI.UP .. NS.Gold(s.bagQuick) .. UI.R .. UI.GREY .. " sells fast" .. UI.R
  end
  return text
end

-- The deals segment: "Deals 9 (6 sell)" with the pace on. Pure.
function NS.BarDealsText(deals, pace)
  if not deals then return UI.GREY .. "Deals -" .. UI.R end
  local text = UI.GREY .. "Deals " .. UI.R .. (deals.n > 0 and (UI.UP .. deals.n .. UI.R) or (UI.GREY .. "0" .. UI.R))
  if pace and deals.n > 0 and deals.selling then
    text = text .. UI.GREY .. " (" .. deals.selling .. " sell)" .. UI.R
  end
  return text
end

-- " · sells fast" for the ticker and the hover lists, coloured; empty without a pace. Pure.
function NS.PaceSuffix(row)
  local pace = NS.Pace(row)
  if not pace then return "" end
  return UI.GREY .. " · " .. UI.R .. NS.PaceColour(pace.tier) .. NS.PacePhrase(pace.tier) .. UI.R
end

-- The same numbers as lines on a tooltip: the minimap button and the bar's AH mark. seedShown
-- when the caller already put the snapshot note at the top.
function NS.DashboardLines(tt, s, seedShown)
  s = s or NS.BarStats()
  if not seedShown and NS.TableIsSeed and NS.TableIsSeed() then tt:AddLine(NS.SeedNote(), 1, 0.82, 0.25, true) end
  if s.bags then
    tt:AddLine(string.format("Bag value: %s at median, %s at the vendor", NS.Gold(s.bags), NS.Gold(s.bagVendor or 0)), 1, 1, 1)
  end
  local session = NS.SessionText(s.delta, s.elapsed)
  if session then tt:AddLine("This session: " .. session, 1, 1, 1) end
  local n = #s.alerts
  if NS.AlertsPaused() then
    tt:AddLine("Watchlist alerts paused until live prices arrive", 0.7, 0.7, 0.72, true)
  else
    tt:AddLine(string.format("%d watchlist alert%s", n, n == 1 and "" or "s"), 1, 1, 1)
  end
  if s.deals then
    tt:AddLine(string.format("%d deal%s in your latest scan%s", s.deals.n, s.deals.n == 1 and "" or "s", NS.SnapshotSuffix()), 1, 1, 1)
  else
    tt:AddLine("No scan yet: open the auction house and deals appear here", 0.7, 0.7, 0.72, true)
  end
  local mailText = s.mail and NS.MailSummaryText and NS.MailSummaryText(s.mail) or nil
  if mailText then tt:AddLine("Last " .. mailText, 1, 1, 1) end
  local c = NS.ContributionText(s.contribution)
  if c then tt:AddLine(c, 0.7, 0.7, 0.72, true) end
end

-- ---------------------------------------------------------------------------------------------
-- The frame
-- ---------------------------------------------------------------------------------------------

local function locked()
  return NS.Setting("barLocked") and true or false
end

local function savePosition()
  if not bar or not bar.GetCenter or not UIParent then return end
  local cx = bar:GetCenter()
  local top = bar:GetTop()
  if not cx or not top then return end
  local scale = bar:GetEffectiveScale() / UIParent:GetEffectiveScale()
  NS.SetSetting("barX", math.floor(cx * scale - UIParent:GetWidth() / 2 + 0.5))
  NS.SetSetting("barY", math.floor(top * scale - UIParent:GetHeight() + 0.5))
end

local function applyPosition()
  if not bar then return end
  bar:ClearAllPoints()
  bar:SetPoint("TOP", UIParent, "TOP", NS.Setting("barX") or 0, NS.Setting("barY") or DEFAULT_Y)
end

local function menu()
  UI.Menu(mark, {
    { text = locked() and "Unlock the bar (drag to move)" or "Lock the bar", onClick = function() NS.SetSetting("barLocked", not locked()) end },
    { text = "Reset session gold", onClick = function() NS.ResetSession() end },
    { text = "Move back to the top", onClick = function()
      NS.SetSetting("barX", 0)
      NS.SetSetting("barY", DEFAULT_Y)
      applyPosition()
    end },
    { text = "Hide the bar (/ahl bar shows it again)", onClick = function() NS.SetSetting("bar", false) end },
    { text = "Open the AHledger window", onClick = function() NS.OpenWindow() end },
  })
end

local function segment(key, onClick, onEnter)
  local b = CreateFrame("Button", nil, bar)
  b:SetHeight(20)
  b.key = key
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetPoint("LEFT", 0, 0)
  b.text:SetJustifyH("LEFT")
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnClick", function(_, button) onClick(button) end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    onEnter(GameTooltip)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:SetHighlightTexture("Interface/QuestFrame/UI-QuestTitleHighlight", "ADD")
  -- Dragging a segment moves the bar, the same as dragging the strip itself.
  b:RegisterForDrag("LeftButton")
  b:SetScript("OnDragStart", function() if not locked() then bar:StartMoving() end end)
  b:SetScript("OnDragStop", function()
    bar:StopMovingOrSizing()
    savePosition()
  end)
  segments[#segments + 1] = b
  return b
end

local function ensureBar()
  if bar then return bar end
  bar = CreateFrame("Frame", "AHledgerBar", UIParent, "BackdropTemplate")
  bar:SetSize(300, 24)
  bar:SetFrameStrata("MEDIUM")
  bar:SetMovable(true)
  bar:SetClampedToScreen(true)
  bar:EnableMouse(true)
  bar:RegisterForDrag("LeftButton")
  bar:SetScript("OnDragStart", function(self) if not locked() then self:StartMoving() end end)
  bar:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    savePosition()
  end)
  bar:SetBackdrop({
    bgFile = "Interface/ChatFrame/ChatFrameBackground",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  bar:SetBackdropColor(0.05, 0.05, 0.07, 0.85)
  bar:SetBackdropBorderColor(0.3, 0.3, 0.35, 0.9)

  -- The AH mark: opens the window, right-click for the menu, hover for the dashboard.
  mark = segment("mark", function(button)
    if button == "RightButton" then menu() else NS.ToggleWindow() end
  end, function(tt)
    tt:AddLine(UI.ACCENT .. "AHledger" .. UI.R .. " " .. NS.VERSION)
    NS.DashboardLines(tt)
    tt:AddLine(UI.GREY .. (locked() and "Locked. Right-click to unlock or reset session gold." or "Drag to move. Right-click to lock, reset session gold, or hide.") .. UI.R, nil, nil, nil, true)
  end)
  mark.text:SetText(UI.ACCENT .. "AH" .. UI.R)

  segment("bags", function() NS.OpenWindow("bags") end, function(tt)
    local s = bar.stats or NS.BarStats()
    tt:AddLine("Bag value at the market median", 1, 1, 1)
    if s.bags then
      tt:AddLine(string.format("%s items: %s at median, %s at the vendor", UI.Comma(s.bagItems or 0), NS.Gold(s.bags), NS.Gold(s.bagVendor or 0)), 0.8, 0.8, 0.8, true)
      if NS.Setting("barPace") and ((s.bagQuick or 0) > 0 or (s.bagSlow or 0) > 0) then
        -- Split by how fast it sells on the auction house: what to post now, and what will sit.
        tt:AddLine(UI.GREY .. "Auction house sales speed, estimated from scans (/ahl pace)" .. UI.R)
        for _, group in ipairs({
          { title = "Sells fast or steadily", total = s.bagQuick, tiers = { fast = true, steady = true } },
          { title = "Sells slowly or barely", total = s.bagSlow, tiers = { slow = true, barely = true } },
        }) do
          if (group.total or 0) > 0 then
            tt:AddDoubleLine(group.title, NS.Gold(group.total), 1, 1, 1)
            local shown = 0
            for _, r in ipairs(s.bagRows or {}) do
              if r.total and r.paceTier and group.tiers[r.paceTier] and shown < 3 then
                shown = shown + 1
                tt:AddDoubleLine("  " .. (r.link or r.name) .. UI.GREY .. " ×" .. UI.Comma(r.count) .. UI.R .. NS.PaceSuffix(r.priceRow), NS.Gold(r.total))
              end
            end
          end
        end
      else
        local shown = 0
        for _, r in ipairs(s.bagRows or {}) do
          if r.total and shown < 5 then
            shown = shown + 1
            tt:AddDoubleLine((r.link or r.name) .. UI.GREY .. " ×" .. UI.Comma(r.count) .. UI.R, NS.Gold(r.total))
          end
        end
      end
    else
      tt:AddLine("No price table yet.", 0.7, 0.7, 0.72)
    end
    tt:AddLine(UI.GREY .. "Click for the full appraisal." .. UI.R)
  end)

  segment("session", function(button)
    if button == "RightButton" then NS.ResetSession() else NS.OpenWindow("bags") end
  end, function(tt)
    local delta, elapsed = NS.SessionGold()
    tt:AddLine("Gold this session", 1, 1, 1)
    if delta then
      local since = elapsed and elapsed >= 60 and ((UI.AgeText(elapsed) or ""):gsub(" old", "")) or "under a minute"
      tt:AddLine(string.format("%s over %s", NS.SessionText(delta, elapsed) or "", since), 0.8, 0.8, 0.8)
      if elapsed and elapsed < RATE_AFTER_S then tt:AddLine("The hourly rate shows after five minutes.", 0.7, 0.7, 0.72) end
    end
    tt:AddLine(UI.GREY .. "Right-click to start counting from now." .. UI.R)
  end)

  segment("alerts", function() NS.OpenWindow("watch") end, function(tt)
    local s = bar.stats or NS.BarStats()
    tt:AddLine("Watchlist alerts", 1, 1, 1)
    if NS.AlertsPaused() then
      tt:AddLine("Paused while prices come from the snapshot that ships with the addon. AHledger sync brings live prices: ahledger.com/download", 0.7, 0.7, 0.72, true)
    elseif #s.alerts == 0 then
      tt:AddLine("None of your thresholds are met right now.", 0.7, 0.7, 0.72, true)
    else
      for i, a in ipairs(s.alerts) do
        if i <= 6 then tt:AddLine(a.text, 0.8, 0.8, 0.8, true) end
      end
    end
    tt:AddLine(UI.GREY .. "Click for the watchlist." .. UI.R)
  end)

  segment("deals", function() NS.OpenWindow("deals") end, function(tt)
    local s = bar.stats or NS.BarStats()
    tt:AddLine("Deals in your latest scan", 1, 1, 1)
    if s.deals then
      if s.deals.n == 0 then
        tt:AddLine(string.format("Nothing at least %d%% under its 30 day median%s.", NS.Setting("dealsPercent") or 30, NS.SnapshotSuffix()), 0.7, 0.7, 0.72, true)
      end
      for _, r in ipairs(s.deals.top or {}) do
        tt:AddDoubleLine((r.link or r.name) .. (NS.Setting("barPace") and NS.PaceSuffix(r.price) or ""), string.format("%s  %s%.0f%% under%s", NS.Gold(r.unit), UI.UP, r.below, UI.R))
      end
      if s.deals.scan then tt:AddLine(UI.GREY .. "Scan " .. (UI.AgeText(NS.Now() - (s.deals.scan.ts or NS.Now())) or "") .. UI.R) end
    else
      tt:AddLine("No scan for this realm and faction yet. Open the auction house and press Scan.", 0.7, 0.7, 0.72, true)
    end
    tt:AddLine(UI.GREY .. "Click for the deal finder." .. UI.R)
  end)

  segment("ticker", function(button)
    if button == "RightButton" then
      NS.OpenWindow("watch")
    else
      local id = bar.tickerItem
      local name = id and GetItemInfo and (GetItemInfo(id)) or nil
      if not (name and NS.SearchAuctionHouse and (AuctionHouseFrame or AuctionFrame) and NS.SearchAuctionHouse(name)) then
        NS.OpenWindow("watch")
      end
    end
  end, function(tt)
    local id = bar.tickerItem
    if id and tt.SetItemByID then tt:SetItemByID(id) end
    tt:AddLine(UI.GREY .. "Your watchlist, one item at a time. Click to search the auction house when it is open; right-click for the list." .. UI.R, nil, nil, nil, true)
  end)

  applyPosition()
  return bar
end

-- ---------------------------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------------------------

local function tickerText()
  local ids = {}
  for id in pairs(NS.Db().watch or {}) do
    if type(id) == "number" then ids[#ids + 1] = id end
  end
  if #ids == 0 then return nil end
  table.sort(ids)
  tickIndex = (tickIndex % #ids) + 1
  local id = ids[tickIndex]
  bar.tickerItem = id
  local name = GetItemInfo and (GetItemInfo(id)) or (NS.Db().watch[id] and NS.Db().watch[id].name) or ("item " .. id)
  local p = NS.Price(id, NS.Market())
  if not p then return UI.WHITE .. name .. UI.R .. UI.GREY .. " not listed" .. UI.R end
  return string.format("%s%s%s %s %s%s", UI.WHITE, name, UI.R, NS.Gold(p.median), UI.ChangeText(p),
    NS.Setting("barPace") and NS.PaceSuffix(p) or "")
end

local function layout()
  local x = 8
  for _, b in ipairs(segments) do
    if b:IsShown() then
      local w = math.max(10, math.floor((b.text:GetStringWidth() or 60) + 0.5))
      b:SetWidth(w)
      b:ClearAllPoints()
      b:SetPoint("LEFT", bar, "LEFT", x, 0)
      x = x + w + SEGMENT_GAP
    end
  end
  bar:SetWidth(math.max(60, x - SEGMENT_GAP + 8))
end

local function startRotation()
  if rotate or not (C_Timer and C_Timer.NewTicker) then return end
  rotate = C_Timer.NewTicker(TICK_S, function()
    if not bar or not bar:IsShown() or not NS.Setting("barTicker") then
      rotate:Cancel()
      rotate = nil
      return
    end
    local t = tickerText()
    local seg = nil
    for _, b in ipairs(segments) do if b.key == "ticker" then seg = b end end
    if not seg then return end
    if t then
      seg.text:SetText(t)
      seg:Show()
    else
      seg:Hide()
    end
    layout()
  end)
end

-- Redraws every segment. flash = true marks the alerts for a moment, after new ones fired.
function NS.RefreshBar(flash)
  if not NS.Setting("bar") then
    if bar then bar:Hide() end
    return
  end
  ensureBar()
  local s = NS.BarStats()
  bar.stats = s
  if flash then flashUntil = NS.Now() + FLASH_S end
  local byKey = {}
  for _, b in ipairs(segments) do byKey[b.key] = b end

  local pace = NS.Setting("barPace") and true or false
  byKey.bags.text:SetText(NS.BarBagsText(s, pace))
  local session = NS.SessionText(s.delta, s.elapsed)
  if session then
    byKey.session.text:SetText(UI.GREY .. "Session " .. UI.R .. session)
    byKey.session:Show()
  else
    byKey.session:Hide()
  end
  local n = #s.alerts
  local flashing = NS.Now() < flashUntil
  byKey.alerts.text:SetText(UI.GREY .. "Alerts " .. UI.R .. (n > 0 and ((flashing and UI.ACCENT or UI.DOWN) .. n .. (flashing and " !" or "") .. UI.R) or (UI.GREY .. "0" .. UI.R)))
  byKey.deals.text:SetText(NS.BarDealsText(s.deals, pace))
  local t = NS.Setting("barTicker") and tickerText() or nil
  if t then
    byKey.ticker.text:SetText(t)
    byKey.ticker:Show()
    startRotation()
  else
    byKey.ticker:Hide()
  end
  layout()
  bar:Show()
  if flashing and C_Timer and C_Timer.After then C_Timer.After(FLASH_S, function() NS.RefreshBar() end) end
end

-- Bag and money events come in bursts; one refresh a second is plenty.
local function scheduleRefresh()
  if pending or not NS.Setting("bar") then return end
  pending = true
  if C_Timer and C_Timer.After then
    C_Timer.After(1, function()
      pending = false
      NS.RefreshBar()
    end)
  else
    pending = false
    NS.RefreshBar()
  end
end

-- /ahl bar [lock|unlock|reset]
function NS.BarCommand(arg)
  arg = (arg or ""):lower()
  if arg == "lock" or arg == "unlock" then
    NS.SetSetting("barLocked", arg == "lock")
    NS.Print("ledger bar " .. (arg == "lock" and "locked" or "unlocked: drag it where you want it"))
  elseif arg == "reset" then
    NS.SetSetting("barX", 0)
    NS.SetSetting("barY", DEFAULT_Y)
    applyPosition()
    NS.ResetSession()
    NS.Print("ledger bar moved back to the top; session gold counts from now")
  else
    NS.SetSetting("bar", not NS.Setting("bar"))
    NS.Print("ledger bar " .. (NS.Setting("bar") and "shown" or "hidden"))
  end
end

function NS.InitBar()
  sessionStartMoney = GetMoney and (GetMoney() or 0) or 0
  sessionStartAt = NS.Now()
  NS.RefreshBar()
end

local events = CreateFrame("Frame", "AHledgerBarFrame")
for _, e in ipairs({ "PLAYER_MONEY", "BAG_UPDATE_DELAYED" }) do pcall(events.RegisterEvent, events, e) end
events:SetScript("OnEvent", function() scheduleRefresh() end)
