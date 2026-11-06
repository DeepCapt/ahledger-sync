--[[
  Watchlist tab, alerts, and the import window.

  /ahl                       open or close the window
  /ahl watch add <link>      track an item (shift-click a link into chat)
  /ahl watch remove <link>   stop tracking it
  /ahl watch alert <link> <price>   chat and sound alert when the median falls to <price> or
                             below, written like 12g 50s, 1250s, or 125000 (copper)
  /ahl watch appears <link> [price]   alert when the item is listed at all (at or below price)
  /ahl import                paste a price table from ahledger.com

  A watch entry: { name, below, above, pctBelow, qtyBelow, appears, appearsMax, appearsSeen }.
  Alerts fire when a price table loads or is imported, because prices only change with a new
  table; there is no polling. The last alerts are kept in AHledgerDB.alertLog and shown under
  the list. "appears" fires once when an item that was not on the house is listed (at or below
  appearsMax when set), and arms again once that stops holding (the house runs empty of it, or
  its lowest buyout rises over the cap), so a piece that sells and is relisted is announced again.
]]
local _, NS = ...
local UI = NS.UI
-- Modern clients (Forever runs the Mainline UI) moved item info under C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local ALERT_LOG_MAX = 30
local importFrame = nil
local tab = { selected = nil }

local function watched()
  return NS.Db().watch
end

local function saveWatch()
  if NS.PersistSave then NS.PersistSave() end
end

-- Item from a link, an item id, or a cached item name.
function NS.ItemFrom(arg)
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if arg == "" then return nil end
  local id = NS.ItemIdFromLink(arg)
  if not id and arg:match("^%d+$") then id = tonumber(arg) end
  if not id then
    local _, link = GetItemInfo(arg)
    id = link and NS.ItemIdFromLink(link) or nil
  end
  if id then
    local name = GetItemInfo(id)
    return id, name or arg:match("%[(.-)%]") or arg
  end
  return nil
end
local itemFrom = NS.ItemFrom

local function linkFor(id)
  local w = watched()[id]
  local _, link = GetItemInfo(id)
  return link or (w and w.name) or ("item " .. id)
end

-- One short label for the row: "<5g", ">12g", "-20%", "q<5", joined when several apply.
local function alertLabel(w)
  local parts = {}
  if w.below then parts[#parts + 1] = "<" .. UI.PlainGold(w.below) end
  if w.above then parts[#parts + 1] = ">" .. UI.PlainGold(w.above) end
  if w.pctBelow then parts[#parts + 1] = string.format("-%d%%", w.pctBelow) end
  if w.qtyBelow then parts[#parts + 1] = "q<" .. w.qtyBelow end
  if w.appears then parts[#parts + 1] = w.appearsMax and ("appears<" .. UI.PlainGold(w.appearsMax)) or "appears" end
  return #parts > 0 and table.concat(parts, " ") or (UI.GREY .. "none" .. UI.R)
end

function NS.WatchAdd(id, name)
  local db = NS.Db()
  local w = watched()[id]
  if not w then
    w = { addedAt = NS.Now() }
    watched()[id] = w
    -- Added again after a removal: the removal is no longer news for the site.
    if db.watchRemoved then db.watchRemoved[id] = nil end
  end
  w.name = name or w.name
  saveWatch()
  if NS.RefreshWindow then NS.RefreshWindow() end
  if NS.RefreshBar then NS.RefreshBar() end
  if NS.RefreshBagDots then NS.RefreshBagDots() end
end

-- Stops watching an item and notes when, so the account list on ahledger.com drops it too
-- (sync sends the note; WatchSyncApply below reads what came back).
function NS.WatchRemove(id)
  if not watched()[id] then return false end
  watched()[id] = nil
  local db = NS.Db()
  db.watchRemoved = db.watchRemoved or {}
  db.watchRemoved[id] = NS.Now()
  saveWatch()
  if NS.RefreshBagDots then NS.RefreshBagDots() end
  return true
end

-- ---------------------------------------------------------------------------------------------
-- One watchlist with the account (0.10.0). AHledger sync sends the saved file's watch table and
-- removal notes to ahledger.com and writes the merged list back into the data file as
--   AHledgerData.watch = { at = <server time>, savedAt = <when the saved file it read was
--   written>, items = { [item id] = 1 or "market", ... } }
-- At login the two lists are brought level. Something on the site's list and not here is added,
-- unless it was removed here after the site last saw this file. Something here and not on the
-- site's list was removed on the site, provided the site had seen it: it was in a file written
-- after it was added. Anything newer than the file the site read is left alone, so a watch set
-- a minute ago is never undone by an old answer. Pure; returns the ids added and removed.
-- ---------------------------------------------------------------------------------------------

function NS.WatchSyncApply(db, remote, nameOf)
  local added, removed = {}, {}
  if type(remote) ~= "table" or type(remote.items) ~= "table" then return added, removed end
  local at, savedAt = tonumber(remote.at) or 0, tonumber(remote.savedAt) or 0
  if at <= (tonumber(db.watchSyncAt) or 0) then return added, removed end
  db.watch = db.watch or {}
  db.watchRemoved = db.watchRemoved or {}
  for id in pairs(remote.items) do
    id = tonumber(id)
    if id and not db.watch[id] and not ((db.watchRemoved[id] or 0) > savedAt) then
      db.watch[id] = { name = nameOf and nameOf(id) or nil, addedAt = at, fromSite = true }
      added[#added + 1] = id
    end
  end
  for id, w in pairs(db.watch) do
    local onSite = remote.items[id] ~= nil or remote.items[tostring(id)] ~= nil
    if not onSite and (tonumber(w.addedAt) or 0) <= savedAt then
      db.watch[id] = nil
      removed[#removed + 1] = id
    end
  end
  for id, ts in pairs(db.watchRemoved) do
    if ts <= savedAt then db.watchRemoved[id] = nil end
  end
  table.sort(added)
  table.sort(removed)
  db.watchSyncAt = at
  return added, removed
end

-- At login: applies what sync wrote, says what changed, and refreshes what shows the list.
function NS.WatchSyncFromData()
  if not NS.Setting("watchSync") then return nil end
  local remote = AHledgerData and AHledgerData.watch
  if type(remote) ~= "table" then return nil end
  local added, removed = NS.WatchSyncApply(NS.Db(), remote, function(id) return (GetItemInfo(id)) end)
  if #added == 0 and #removed == 0 then return nil end
  local parts = {}
  if #added > 0 then parts[#parts + 1] = string.format("%d added from your account", #added) end
  if #removed > 0 then parts[#parts + 1] = string.format("%d removed on the site", #removed) end
  local line = "watchlist synced with ahledger.com: " .. table.concat(parts, ", ")
  NS.Print(line)
  saveWatch()
  if NS.RefreshWindow then NS.RefreshWindow() end
  if NS.RefreshBar then NS.RefreshBar() end
  if NS.RefreshBagDots then NS.RefreshBagDots() end
  return line
end

-- ---------------------------------------------------------------------------------------------
-- Tab
-- ---------------------------------------------------------------------------------------------

local function refresh()
  if not tab.list then return end
  local market = NS.Market()
  local rows = {}
  for id, w in pairs(watched()) do
    local p = NS.Price(id, market)
    local name = (GetItemInfo(id)) or w.name or ("item " .. id)
    rows[#rows + 1] = {
      itemID = id,
      name = name,
      link = linkFor(id),
      median = p and p.median or nil,
      change = p and UI.Pct(p.median, p.m7) or nil,
      changeText = p and UI.ChangeText(p) or "",
      range = p and (NS.Gold(p.lo or p.median) .. UI.GREY .. " to " .. UI.R .. NS.Gold(p.hi or p.median)) or "",
      qty = p and p.qty or nil,
      alert = alertLabel(w),
    }
  end
  if tab.selected and not watched()[tab.selected] then tab.selected = nil end
  tab.list.selectedKey = tab.selected
  tab.list:SetRows(rows)
  if tab.selected then
    local w = watched()[tab.selected]
    tab.selectedText:SetText("Selected: " .. linkFor(tab.selected))
    tab.belowBox:SetText(w.below and UI.PlainGold(w.below) or "")
    tab.aboveBox:SetText(w.above and UI.PlainGold(w.above) or "")
    tab.pctBox:SetText(w.pctBelow and tostring(w.pctBelow) or "")
    tab.qtyBox:SetText(w.qtyBelow and tostring(w.qtyBelow) or "")
    tab.appearsCheck:SetChecked(w.appears and true or false)
    tab.appearsMaxBox:SetText(w.appearsMax and UI.PlainGold(w.appearsMax) or "")
  else
    tab.selectedText:SetText(UI.GREY .. "Select a row to edit its alerts" .. UI.R)
    tab.belowBox:SetText("")
    tab.aboveBox:SetText("")
    tab.pctBox:SetText("")
    tab.qtyBox:SetText("")
    tab.appearsCheck:SetChecked(false)
    tab.appearsMaxBox:SetText("")
  end
  local log = NS.Db().alertLog or {}
  local lines = {}
  for i = #log, math.max(1, #log - 5), -1 do
    local e = log[i]
    if e then lines[#lines + 1] = UI.GREY .. (e.at or "") .. UI.R .. "  " .. (e.text or "") end
  end
  local empty = NS.AlertsPaused() and string.format("Alerts are paused while prices come from the %s snapshot that ships with the addon. They resume with live prices from AHledger sync (ahledger.com/download).", NS.TableDate() or "release")
    or "No alerts yet. Set a threshold on a watched item and they appear here and in chat."
  tab.logText:SetText(#lines > 0 and table.concat(lines, "\n") or (UI.GREY .. empty .. UI.R))
end

local function build(parent)
  tab.list = UI.List(parent, {
    x = 0, y = 0, width = 668, rows = 11, rowKey = "itemID",
    columns = {
      { key = "link", label = "Item", width = 220, format = function(v, r) return v or r.name end },
      { key = "median", label = "Median", width = 90, numeric = true, format = function(v) return v and NS.Gold(v) or (UI.GREY .. "not listed" .. UI.R) end },
      { key = "change", label = "7 day", width = 60, numeric = true, format = function(_, r) return r.changeText end },
      { key = "range", label = "30 day low to high", width = 170, sortable = false },
      { key = "qty", label = "Listed", width = 50, numeric = true, justify = "RIGHT", format = function(v) return v and UI.Comma(v) or "" end },
      { key = "alert", label = "Alerts", width = 66 },
    },
    empty = "Nothing watched yet. Shift-click an item into the box below and press Watch.",
    siteLink = function()
      return { text = "Email alerts for your watchlist: " .. NS.SITE .. "/watchlist", title = "Your watchlist, with email alerts", url = NS.SITE .. "/watchlist" }
    end,
    onClick = function(row, button)
      if button == "RightButton" and IsControlKeyDown and IsControlKeyDown() then NS.ShowItemLink(row.itemID, row.name) return end
      if button == "RightButton" then
        NS.WatchRemove(row.itemID)
        if tab.selected == row.itemID then tab.selected = nil end
        refresh()
      else
        tab.selected = row.itemID
        refresh()
      end
    end,
    onEnter = function(tt) tt:AddLine(UI.GREY .. "Click to select, right-click to remove, ctrl+right-click for its ahledger.com page" .. UI.R, nil, nil, nil, true) end,
  })
  tab.list:SetSort("name", "asc")

  local y = -(18 + 11 * 18 + 16) - 8
  UI.Label(parent, "Add item", "GameFontNormalSmall", 0, y - 4, 60)
  tab.addBox = UI.EditBox(parent, 300, 66, y, function() tab.watchClicked() end)
  local watchButton = UI.Button(parent, "Watch", 70, function() tab.watchClicked() end)
  watchButton:SetPoint("TOPLEFT", 372, y + 1)
  UI.Muted(parent, "shift-click an item link, or type its name", 450, y - 4, 220)

  y = y - 30
  UI.Label(parent, "Alerts", "GameFontNormalSmall", 0, y - 4, 60)
  UI.Muted(parent, "below", 66, y - 4, 40)
  tab.belowBox = UI.EditBox(parent, 80, 104, y, function() tab.setAlertsClicked() end)
  UI.Muted(parent, "above", 192, y - 4, 40)
  tab.aboveBox = UI.EditBox(parent, 80, 230, y, function() tab.setAlertsClicked() end)
  UI.Muted(parent, "% under 30d", 318, y - 4, 70)
  tab.pctBox = UI.EditBox(parent, 40, 392, y, function() tab.setAlertsClicked() end)
  UI.Muted(parent, "qty under", 440, y - 4, 60)
  tab.qtyBox = UI.EditBox(parent, 40, 500, y, function() tab.setAlertsClicked() end)
  local setButton = UI.Button(parent, "Set", 50, function() tab.setAlertsClicked() end)
  setButton:SetPoint("TOPLEFT", 550, y + 1)
  local clearButton = UI.Button(parent, "Clear", 60, function() tab.clearAlertsClicked() end)
  clearButton:SetPoint("TOPLEFT", 606, y + 1)
  y = y - 26
  -- The availability alert: an item that is not on the house right now, announced when it is.
  tab.appearsCheck = CreateFrame("CheckButton", "AHledgerWatchAppears", parent, "UICheckButtonTemplate")
  tab.appearsCheck:SetPoint("TOPLEFT", 62, y + 6)
  tab.appearsCheck:SetSize(24, 24)
  tab.appearsCheck:SetScript("OnClick", function() tab.setAlertsClicked() end)
  UI.Muted(parent, "alert when it appears on the auction house", 90, y - 4, 230)
  UI.Muted(parent, "at or below", 326, y - 4, 70)
  tab.appearsMaxBox = UI.EditBox(parent, 80, 400, y, function() tab.setAlertsClicked() end)
  UI.Muted(parent, "(optional)", 486, y - 4, 60)
  y = y - 28
  tab.selectedText = UI.Label(parent, "", "GameFontHighlightSmall", 0, y, 520)
  tab.selectedText:SetWordWrap(false)
  local removeButton = UI.Button(parent, "Stop watching", 110, function() tab.removeClicked() end)
  removeButton:SetPoint("TOPLEFT", 556, y + 4)

  y = y - 26
  UI.Label(parent, "Recent alerts", "GameFontNormalSmall", 0, y, 200)
  tab.logText = UI.Label(parent, "", "GameFontHighlightSmall", 0, y - 16, 668)
  tab.logText:SetSpacing(2)

  tab.watchClicked = function()
    local id, name = itemFrom(tab.addBox:GetText())
    if not id then
      NS.Print("shift-click an item link into the box, or type the exact name of an item you have seen")
      return
    end
    NS.WatchAdd(id, name)
    tab.selected = id
    tab.addBox:SetText("")
    tab.addBox:ClearFocus()
    refresh()
  end
  tab.setAlertsClicked = function()
    if not tab.selected then NS.Print("select an item in the list first") return end
    local w = watched()[tab.selected]
    local below = UI.ParsePrice(tab.belowBox:GetText())
    local above = UI.ParsePrice(tab.aboveBox:GetText())
    local pct = tonumber((tab.pctBox:GetText() or ""):match("%d+"))
    local qty = tonumber((tab.qtyBox:GetText() or ""):match("%d+"))
    w.below = below and below > 0 and below or nil
    w.above = above and above > 0 and above or nil
    w.pctBelow = pct and pct > 0 and pct < 100 and pct or nil
    w.qtyBelow = qty and qty > 0 and qty or nil
    local appears = tab.appearsCheck:GetChecked() and true or nil
    local appearsMax = UI.ParsePrice(tab.appearsMaxBox:GetText())
    w.appears = appears
    w.appearsMax = (appears and appearsMax and appearsMax > 0) and appearsMax or nil
    if not appears then w.appearsSeen = nil end
    for _, b in ipairs({ tab.belowBox, tab.aboveBox, tab.pctBox, tab.qtyBox, tab.appearsMaxBox }) do b:ClearFocus() end
    saveWatch()
    refresh()
  end
  tab.clearAlertsClicked = function()
    if not tab.selected then NS.Print("select an item in the list first") return end
    local w = watched()[tab.selected]
    w.below, w.above, w.pctBelow, w.qtyBelow = nil, nil, nil, nil
    w.appears, w.appearsMax, w.appearsSeen = nil, nil, nil
    saveWatch()
    refresh()
  end
  tab.removeClicked = function()
    if not tab.selected then NS.Print("select an item in the list first") return end
    NS.WatchRemove(tab.selected)
    tab.selected = nil
    refresh()
  end
  NS.WatchTab = tab
end

NS.RegisterTab({ key = "watch", label = "Watchlist", order = 1, build = build, refresh = refresh })

-- ---------------------------------------------------------------------------------------------
-- Slash subcommands
-- ---------------------------------------------------------------------------------------------

function NS.WatchCommand(arg)
  local sub, rest = (arg or ""):match("^(%S*)%s*(.-)$")
  sub = (sub or ""):lower()
  if sub == "add" then
    local id, name = itemFrom(rest)
    if not id then NS.Print("shift-click an item link: /ahl watch add [item]") return end
    NS.WatchAdd(id, name)
    NS.Print("watching " .. (name or id))
  elseif sub == "remove" or sub == "rm" then
    local id, name = itemFrom(rest)
    if id and watched()[id] then
      NS.WatchRemove(id)
      NS.Print("no longer watching " .. (name or id))
      if NS.RefreshWindow then NS.RefreshWindow() end
    else
      NS.Print("not watching that item")
    end
  elseif sub == "appears" then
    local id, name = itemFrom(rest)
    if not id then NS.Print("usage: /ahl watch appears [item] 12g 50s (the price is optional)") return end
    local price = UI.ParsePrice(rest:match("%](.*)$") or "")
    if not watched()[id] then NS.WatchAdd(id, name) end
    local w = watched()[id]
    if w.appears and not (price and price > 0) then
      w.appears, w.appearsMax, w.appearsSeen = nil, nil, nil
      NS.Print("appears alert cleared for " .. (name or id))
    else
      w.appears = true
      w.appearsMax = (price and price > 0) and price or nil
      w.appearsSeen = nil
      NS.Print(string.format("alert when %s appears on the auction house%s", name or id, w.appearsMax and (" at or below " .. NS.Gold(w.appearsMax)) or ""))
    end
    saveWatch()
    if NS.RefreshWindow then NS.RefreshWindow() end
  elseif sub == "alert" then
    local id, name = itemFrom(rest)
    local price = UI.ParsePrice(rest:match("%](.*)$") or "")
    if not id then NS.Print("usage: /ahl watch alert [item] 12g 50s") return end
    if not watched()[id] then NS.WatchAdd(id, name) end
    if price and price > 0 then
      watched()[id].below = price
      NS.Print(string.format("alert when %s drops to %s or below", name or id, NS.Gold(price)))
    else
      watched()[id].below = nil
      NS.Print("alert cleared for " .. (name or id))
    end
    saveWatch()
    if NS.RefreshWindow then NS.RefreshWindow() end
  else
    NS.ToggleWindow("watch")
  end
end

-- ---------------------------------------------------------------------------------------------
-- Alerts: runs when a table arrives. One chat line per hit and one sound per batch.
-- ---------------------------------------------------------------------------------------------

local function logAlert(itemID, text)
  local db = NS.Db()
  db.alertLog = db.alertLog or {}
  table.insert(db.alertLog, { at = date and date("%H:%M") or "", itemID = itemID, text = text })
  while #db.alertLog > ALERT_LOG_MAX do table.remove(db.alertLog, 1) end
end

-- Whether the "appears" rule holds against a price row: listed at all, and at or below the
-- cap when there is one. The cap reads the lowest buyout, since that is what a buyer pays.
local function appearsHolds(w, p)
  if not w.appears or not p or (p.qty or 0) < 1 then return false end
  if w.appearsMax then
    local price = p.min or p.median
    if not price or price > w.appearsMax then return false end
  end
  return true
end
NS.WatchAppearsHolds = appearsHolds

-- The thresholds one watched item meets right now, as sentences. Pure. `armed` is false when
-- the appears alert already announced the current listing; it is left out until the house is
-- empty of the item again.
local function alertHits(name, w, p, label, armed)
  local hits = {}
  if appearsHolds(w, p) and armed ~= false then
    hits[#hits + 1] = string.format("%s is on %s: %d listed, lowest %s%s", name, label, p.qty or 0, NS.Gold(p.min or p.median), w.appearsMax and (" (alert at or below " .. NS.Gold(w.appearsMax) .. ")") or "")
  end
  if w.below and p.median and p.median <= w.below then
    hits[#hits + 1] = string.format("%s is %s on %s (alert at or below %s)", name, NS.Gold(p.median), label, NS.Gold(w.below))
  end
  if w.above and p.median and p.median >= w.above then
    hits[#hits + 1] = string.format("%s is %s on %s (alert at or above %s)", name, NS.Gold(p.median), label, NS.Gold(w.above))
  end
  if w.pctBelow and p.median and p.m30 and p.m30 > 0 and p.median <= p.m30 * (1 - w.pctBelow / 100) then
    hits[#hits + 1] = string.format("%s is %s on %s, %.0f%% under its 30 day median of %s", name, NS.Gold(p.median), label, (1 - p.median / p.m30) * 100, NS.Gold(p.m30))
  end
  if w.qtyBelow and (p.qty or 0) < w.qtyBelow then
    hits[#hits + 1] = string.format("%s has only %d listed on %s (alert under %d)", name, p.qty or 0, label, w.qtyBelow)
  end
  return hits
end
NS.WatchAlertHits = alertHits
-- Every alert that holds against the current table, { { itemID, text } }, without printing:
-- the ledger bar counts these.
function NS.ActiveAlerts()
  local market = NS.Market()
  if NS.AlertsPaused(market) then return {} end
  local label = NS.MarketLabel(market)
  local out = {}
  for id, w in pairs(watched()) do
    local p = NS.Price(id, market)
    if p then
      local _, link = GetItemInfo(id)
      for _, text in ipairs(alertHits(link or w.name or tostring(id), w, p, label)) do
        out[#out + 1] = { itemID = id, text = text }
      end
    end
  end
  table.sort(out, function(a, b) return a.text < b.text end)
  return out
end

function NS.CheckAlerts()
  local market = NS.Market()
  if NS.AlertsPaused(market) then return 0 end
  local label = NS.MarketLabel(market)
  local fired = 0
  local changed = false
  for id, w in pairs(watched()) do
    local p = NS.Price(id, market)
    if p then
      local _, link = GetItemInfo(id)
      -- The appears alert announces a listing once, then waits for the rule to stop holding
      -- (nothing listed, or nothing at or below the cap) before it will announce the next one.
      local armed = not w.appearsSeen
      for _, text in ipairs(alertHits(link or w.name or tostring(id), w, p, label, armed)) do
        NS.Print(text)
        logAlert(id, text)
        fired = fired + 1
      end
      if w.appears then
        local seen = appearsHolds(w, p) and true or nil
        if seen ~= w.appearsSeen then w.appearsSeen = seen; changed = true end
      end
    end
  end
  if changed then saveWatch() end
  if fired > 0 and NS.Setting("alertSound") and PlaySound then
    PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959)
  end
  if NS.RefreshWindow then NS.RefreshWindow() end
  if NS.RefreshBar then NS.RefreshBar(fired > 0) end
  return fired
end

-- ---------------------------------------------------------------------------------------------
-- Import window: paste a table from ahledger.com/markets/<market> (the "Import string" link)
-- ---------------------------------------------------------------------------------------------

function NS.ShowImport()
  if not importFrame then
    importFrame = CreateFrame("Frame", "AHledgerImportFrame", UIParent, "BackdropTemplate")
    importFrame:SetSize(520, 300)
    importFrame:SetPoint("CENTER")
    importFrame:SetMovable(true)
    importFrame:EnableMouse(true)
    importFrame:RegisterForDrag("LeftButton")
    importFrame:SetScript("OnDragStart", importFrame.StartMoving)
    importFrame:SetScript("OnDragStop", importFrame.StopMovingOrSizing)
    importFrame:SetBackdrop({
      bgFile = "Interface/DialogFrame/UI-DialogBox-Background",
      edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 24,
      insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    importFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    tinsert(UISpecialFrames, "AHledgerImportFrame")

    local title = importFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 16, -14)
    title:SetText(UI.ACCENT .. "AHledger" .. UI.R .. " import price table")
    local hint = UI.Muted(importFrame, "Copy the import string from a market page on ahledger.com, paste it here, and press Import. AHledger sync does this for you automatically.", 16, -34, 480)
    local _ = hint

    local close = CreateFrame("Button", nil, importFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    local scroll = CreateFrame("ScrollFrame", "AHledgerImportScroll", importFrame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -70)
    scroll:SetPoint("BOTTOMRIGHT", -36, 48)
    local box = CreateFrame("EditBox", "AHledgerImportBox", scroll)
    box:SetMultiLine(true)
    box:SetAutoFocus(true)
    box:SetFontObject(ChatFontNormal)
    box:SetWidth(460)
    box:SetMaxLetters(0)
    box:SetScript("OnEscapePressed", function() importFrame:Hide() end)
    scroll:SetScrollChild(box)
    importFrame.box = box

    local button = UI.Button(importFrame, "Import", 100, function()
      local market, count = NS.ImportTable(box:GetText())
      if market then
        NS.Print(string.format("imported %d prices for %s", count, market))
        box:SetText("")
        importFrame:Hide()
        NS.CheckAlerts()
        if NS.RefreshBar then NS.RefreshBar() end
      else
        NS.Print("import failed: " .. tostring(count))
      end
    end)
    button:SetPoint("BOTTOMRIGHT", -16, 14)
  end
  importFrame.box:SetText("")
  importFrame:Show()
  importFrame.box:SetFocus()
end
