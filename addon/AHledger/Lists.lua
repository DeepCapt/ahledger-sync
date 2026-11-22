--[[
  Shopping lists (0.15.0). Lists are made on ahledger.com/lists and reach the game two ways:

  - AHledger sync writes the account's lists into the data file:
      AHledgerData.lists = { at = <server time>, lists = {
        { id = <list id>, name = "Raid night", items = {
          { id = <item id>, qty = 20, max = <copper or 0>, bought = 4, at = <when bought was set> }, ... } }, ... } }
  - a line copied from the site, pasted with /ahl list import:
      AHL-LIST:1:<name>:<id>x<qty>[@<max copper>],<id>x<qty>,...

  What has been bought is kept per list and item in AHledgerDB.listProgress["<list>:<item>"] =
  { b = bought, t = when }. A site list's key is its id, so sync sends those entries back and
  the site shows the same progress; an imported list's key starts with "i" and stays here.
  Whichever side changed last wins: a reset on the site beats an older count here, a purchase
  here beats an older count on the site.

  A purchase counts when its auction house mail is taken (Ledger.lua calls NS.ListsOnBuy), on any
  character. Nothing is bought, searched or taken by the addon: a click on a list item fills the
  auction house search, and the search is the player's.
]]
local _, NS = ...
local UI = NS.UI
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local MAX_IMPORTED = 20
local MAX_ITEMS = 100
local MAX_QTY = 10000
local NAME_MAX = 40
local tab = {}

local function db()
  local d = NS.Db()
  if type(d.listProgress) ~= "table" then d.listProgress = {} end
  if type(d.importedLists) ~= "table" then d.importedLists = {} end
  return d
end

-- A list name as the site allows it: letters, digits, spaces and a little punctuation, at most
-- 40 characters. Pure.
function NS.CleanListName(s)
  s = tostring(s or ""):gsub("|", ""):gsub("[%c]", " ")
  s = s:gsub("[^%w%s'%-_%.,%(%)&%+#!%?\128-\255]", ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
  if #s > NAME_MAX then
    s = s:sub(1, NAME_MAX)
    -- Never end inside a multi-byte character: find where the last one starts, and drop it when
    -- the cut took some of its bytes.
    local i = #s
    while i > 1 and s:byte(i) >= 128 and s:byte(i) < 192 do i = i - 1 end
    local lead = s:byte(i)
    if lead and lead >= 192 then
      local need = lead >= 240 and 4 or (lead >= 224 and 3 or 2)
      if #s - i + 1 < need then s = s:sub(1, i - 1) end
    end
    s = s:match("^(.-)%s*$")
  end
  return s
end

-- The import line into { name, items = { {id, qty, max} } }, or nil and why. Pure.
function NS.ParseListImport(text)
  text = tostring(text or ""):gsub("%s+$", ""):gsub("^%s+", "")
  local version, name, body = text:match("^AHL%-LIST:(%d+):([^:]*):(.*)$")
  if not version then return nil, "that is not a shopping list line from ahledger.com/lists" end
  if version ~= "1" then return nil, "that list line is from a newer AHledger; update the addon" end
  name = NS.CleanListName(name)
  if name == "" then name = "List" end
  local items, seen = {}, {}
  for part in body:gmatch("[^,]+") do
    local id, qty, max = part:match("^%s*(%d+)x(%d+)@?(%d*)%s*$")
    id, qty, max = tonumber(id), tonumber(qty), tonumber(max)
    if id and qty and id > 0 and qty > 0 and not seen[id] and #items < MAX_ITEMS then
      seen[id] = true
      items[#items + 1] = { id = id, qty = math.min(qty, MAX_QTY), max = (max and max > 0) and max or nil }
    end
  end
  if #items == 0 then return nil, "the list line has no items" end
  return { name = name, items = items }
end

-- Every list, site lists first in the site's order and then the imported ones, each item with its
-- bought count. Server counts newer than the local ones are taken into `progress` here. Pure on
-- the tables it is given.
--   { { key, id, name, source = "site" | "import", items = { {id, qty, max, bought} } } }
function NS.ListsBuild(data, progress, imported)
  local out = {}
  if type(data) == "table" and type(data.lists) == "table" then
    for _, l in ipairs(data.lists) do
      local id = tonumber(l.id)
      if id and type(l.items) == "table" then
        local list = { key = tostring(id), id = id, name = NS.CleanListName(l.name) ~= "" and NS.CleanListName(l.name) or "List", source = "site", items = {} }
        for _, it in ipairs(l.items) do
          local item, qty = tonumber(it.id), tonumber(it.qty)
          if item and qty and qty > 0 then
            local pk = list.key .. ":" .. item
            local at, bought = tonumber(it.at) or 0, math.max(0, tonumber(it.bought) or 0)
            local p = progress[pk]
            if at > 0 and (type(p) ~= "table" or at > (tonumber(p.t) or 0)) then
              p = { b = bought, t = at }
              progress[pk] = p
            end
            list.items[#list.items + 1] = { id = item, qty = qty, max = (tonumber(it.max) or 0) > 0 and tonumber(it.max) or nil, bought = type(p) == "table" and (tonumber(p.b) or 0) or 0 }
          end
        end
        out[#out + 1] = list
      end
    end
  end
  for _, l in ipairs(type(imported) == "table" and imported or {}) do
    local list = { key = l.key, name = l.name, source = "import", items = {} }
    for _, it in ipairs(l.items or {}) do
      local p = progress[l.key .. ":" .. it.id]
      list.items[#list.items + 1] = { id = it.id, qty = it.qty, max = it.max, bought = type(p) == "table" and (tonumber(p.b) or 0) or 0 }
    end
    out[#out + 1] = list
  end
  return out
end

-- Progress for site lists that are no longer on the account goes, once sync has written lists.
-- Pure on the tables.
function NS.ListsPrune(progress, lists, haveSiteData)
  local live = {}
  for _, l in ipairs(lists) do
    for _, it in ipairs(l.items) do live[l.key .. ":" .. it.id] = true end
  end
  local n = 0
  for k in pairs(progress) do
    local site = k:match("^%d+:%d+$") ~= nil
    if not live[k] and (not site or haveSiteData) then
      progress[k] = nil
      n = n + 1
    end
  end
  return n
end

-- Whether any list has an item still to buy: the mail hook reads purchases only then.
function NS.HasLists()
  for _, l in ipairs(NS.Lists()) do
    for _, it in ipairs(l.items) do if it.bought < it.qty then return true end end
  end
  return false
end

function NS.Lists()
  local d = db()
  return NS.ListsBuild(AHledgerData and AHledgerData.lists, d.listProgress, d.importedLists)
end

-- The tooltip reads lists on every hover; it uses an index built once per change.
local version, lineIndex, lineVersion = 0, nil, -1
function NS.ListsChanged() version = version + 1 end

-- Sets one item's bought count on one list (a purchase, or a correction by hand).
function NS.ListSetBought(listKey, itemID, bought, now)
  local d = db()
  d.listProgress[listKey .. ":" .. itemID] = { b = math.max(0, math.floor(tonumber(bought) or 0)), t = now or NS.Now() }
  NS.ListsChanged()
end

-- A purchase of `q` of an item: each list that still needs it takes what it needs, in list
-- order; what is left over is not counted anywhere. Returns { {list, name, item, bought, qty} }.
function NS.ListsCredit(lists, itemID, q, now, set)
  local credited = {}
  q = math.max(0, math.floor(tonumber(q) or 0))
  for _, l in ipairs(lists) do
    if q <= 0 then break end
    for _, it in ipairs(l.items) do
      if it.id == itemID and it.bought < it.qty then
        local take = math.min(q, it.qty - it.bought)
        it.bought = it.bought + take
        q = q - take
        set(l.key, itemID, it.bought, now)
        credited[#credited + 1] = { list = l.key, name = l.name, item = itemID, bought = it.bought, qty = it.qty }
        break
      end
    end
  end
  return credited
end

function NS.ListsOnBuy(itemID, q, now)
  itemID = tonumber(itemID)
  if not itemID then return nil end
  local credited = NS.ListsCredit(NS.Lists(), itemID, q, now or NS.Now(), NS.ListSetBought)
  if #credited == 0 then return credited end
  if not (NS.IsScannerOnly and NS.IsScannerOnly()) then
    local name = (GetItemInfo(itemID)) or ("item " .. itemID)
    for _, c in ipairs(credited) do
      local done = c.bought >= c.qty
      NS.Print(string.format("shopping list %s: %s %s of %s%s", c.name, name, UI.Comma(c.bought), UI.Comma(c.qty), done and (UI.UP .. " done" .. UI.R) or ""))
    end
  end
  if NS.RefreshWindow then NS.RefreshWindow() end
  if NS.RefreshListsPanel then NS.RefreshListsPanel() end
  return credited
end

-- Adds or replaces an imported list (same name: replaced, its progress kept for items still on
-- it). Returns the list, or nil and why.
function NS.ListImport(text)
  local parsed, why = NS.ParseListImport(text)
  if not parsed then return nil, why end
  local d = db()
  local list
  for _, l in ipairs(d.importedLists) do
    if l.name:lower() == parsed.name:lower() then list = l end
  end
  if not list then
    if #d.importedLists >= MAX_IMPORTED then return nil, string.format("%d imported lists is the most; remove one with /ahl list remove <name>", MAX_IMPORTED) end
    d.importSeq = (tonumber(d.importSeq) or 0) + 1
    list = { key = "i" .. d.importSeq }
    d.importedLists[#d.importedLists + 1] = list
  end
  list.name = parsed.name
  list.items = parsed.items
  list.at = NS.Now()
  NS.ListsChanged()
  NS.ListsPrune(d.listProgress, NS.Lists(), false)
  if NS.RefreshWindow then NS.RefreshWindow() end
  if NS.RefreshListsPanel then NS.RefreshListsPanel() end
  return list
end

-- Removes an imported list by name. Site lists are removed on the site.
function NS.ListRemove(name)
  local d = db()
  name = tostring(name or ""):lower():match("^%s*(.-)%s*$")
  for i, l in ipairs(d.importedLists) do
    if l.name:lower() == name then
      table.remove(d.importedLists, i)
      NS.ListsChanged()
      NS.ListsPrune(d.listProgress, NS.Lists(), false)
      if NS.RefreshWindow then NS.RefreshWindow() end
      if NS.RefreshListsPanel then NS.RefreshListsPanel() end
      return l
    end
  end
  return nil
end

-- Items still to buy, across lists, one row per list and item.
local function openRows(lists, market)
  local rows, left = {}, 0
  for _, l in ipairs(lists) do
    for _, it in ipairs(l.items) do
      local p = NS.Price(it.id, market)
      local name, link = GetItemInfo(it.id)
      local need = math.max(0, it.qty - it.bought)
      local low = p and tonumber(p.min) or nil
      rows[#rows + 1] = {
        key = l.key .. ":" .. it.id, listKey = l.key, list = l.name, source = l.source, itemID = it.id,
        name = name or ("item " .. it.id), link = link or name or ("item " .. it.id),
        qty = it.qty, bought = math.min(it.bought, it.qty), need = need, max = it.max,
        median = p and p.median or nil, lowest = low,
        over = it.max and low and low > it.max or false,
      }
      left = left + need
    end
  end
  return rows, left
end
NS.ListOpenRows = openRows

-- The tooltip line for an item on a list that still needs it, or nil.
function NS.ListLine(itemID)
  if lineVersion ~= version or not lineIndex then
    lineIndex = {}
    for _, l in ipairs(NS.Lists()) do
      for _, it in ipairs(l.items) do
        if it.bought < it.qty and not lineIndex[it.id] then
          lineIndex[it.id] = string.format("Shopping list %s: %s of %s bought%s", l.name, UI.Comma(it.bought), UI.Comma(it.qty), it.max and (", max " .. NS.Gold(it.max) .. " each") or "")
        end
      end
    end
    lineVersion = version
  end
  return lineIndex[itemID]
end

-- ---------------------------------------------------------------------------------------------
-- Purchases: counted when the item reaches the bags. The mail hook runs when a take is asked
-- for, which can fail (full bags); so the count of the item in the bags is watched for a few
-- seconds, and a purchase counts only once that many have arrived. Two mails of the same item
-- share one baseline, so each arrival is counted once.
-- ---------------------------------------------------------------------------------------------

local pendingBuys = {}   -- { key, id, q, tries }, oldest first
local baseline = {}      -- [item id] = bag count before the first pending take of it
local creditedMail = {}  -- this session's mail keys already counted
local checking = false

local function bagCount(id)
  return GetItemCount and (GetItemCount(id) or 0) or 0
end

function NS.ListsCheckBuys()
  -- Per item, what has arrived since the baseline goes to the pending mails it fits: a mail
  -- of exactly that many first, then the oldest that fit. A mail that cannot be matched
  -- waits a few more seconds, then is dropped (its take failed).
  local arrivedOf, credit = {}, {}
  for _, p in ipairs(pendingBuys) do
    if arrivedOf[p.id] == nil then arrivedOf[p.id] = bagCount(p.id) - (baseline[p.id] or 0) end
  end
  local function take(p)
    credit[p] = true
    arrivedOf[p.id] = arrivedOf[p.id] - p.q
    baseline[p.id] = (baseline[p.id] or 0) + p.q
  end
  for _, p in ipairs(pendingBuys) do
    if not credit[p] and p.q == arrivedOf[p.id] then take(p) end
  end
  for _, p in ipairs(pendingBuys) do
    if not credit[p] and p.q <= arrivedOf[p.id] then take(p) end
  end
  local keep, done = {}, {}
  for _, p in ipairs(pendingBuys) do
    if credit[p] then
      creditedMail[p.key] = true
      done[#done + 1] = p
    else
      p.tries = p.tries + 1
      if p.tries < 6 then keep[#keep + 1] = p end
    end
  end
  pendingBuys = keep
  -- A failure while counting one (a window refresh) never stops the checks for the session.
  for _, p in ipairs(done) do pcall(NS.ListsOnBuy, p.id, p.q) end
  local still = {}
  for _, p in ipairs(pendingBuys) do still[p.id] = true end
  for id in pairs(baseline) do if not still[id] then baseline[id] = nil end end
  if #pendingBuys > 0 and C_Timer and C_Timer.After then
    C_Timer.After(1, NS.ListsCheckBuys)
  else
    checking = false
  end
end

function NS.ListsExpectBuy(key, itemID, q)
  itemID, q = tonumber(itemID), math.floor(tonumber(q) or 0)
  if not itemID or q <= 0 or creditedMail[key] then return end
  for _, p in ipairs(pendingBuys) do if p.key == key then return end end
  if not baseline[itemID] then baseline[itemID] = bagCount(itemID) end
  pendingBuys[#pendingBuys + 1] = { key = key, id = itemID, q = q, tries = 0 }
  if not checking and C_Timer and C_Timer.After then
    checking = true
    C_Timer.After(1, NS.ListsCheckBuys)
  end
end

-- ---------------------------------------------------------------------------------------------
-- Login: take what sync wrote, and drop progress for lists the account no longer has
-- ---------------------------------------------------------------------------------------------

function NS.ListsFromData()
  NS.ListsChanged()
  local d = db()
  local data = AHledgerData and AHledgerData.lists
  local lists = NS.ListsBuild(data, d.listProgress, d.importedLists)
  NS.ListsPrune(d.listProgress, lists, type(data) == "table")
  return lists
end

-- ---------------------------------------------------------------------------------------------
-- Import window
-- ---------------------------------------------------------------------------------------------

local importFrame
function NS.ShowListImport()
  if not importFrame then
    importFrame = CreateFrame("Frame", "AHledgerListImportFrame", UIParent, "BackdropTemplate")
    importFrame:SetSize(460, 130)
    importFrame:SetPoint("CENTER")
    importFrame:SetMovable(true)
    importFrame:EnableMouse(true)
    importFrame:RegisterForDrag("LeftButton")
    importFrame:SetScript("OnDragStart", importFrame.StartMoving)
    importFrame:SetScript("OnDragStop", importFrame.StopMovingOrSizing)
    if importFrame.SetBackdrop then
      importFrame:SetBackdrop({
        bgFile = "Interface/DialogFrame/UI-DialogBox-Background",
        edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
      })
    end
    importFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    if UISpecialFrames then tinsert(UISpecialFrames, "AHledgerListImportFrame") end
    local title = importFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 16, -14)
    title:SetText(UI.ACCENT .. "AHledger" .. UI.R .. " import a shopping list")
    UI.Muted(importFrame, "Copy the line under a list on ahledger.com/lists and paste it here. With AHledger sync connected your lists arrive on their own.", 16, -34, 420)
    local close = CreateFrame("Button", nil, importFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    local box = UI.EditBox(importFrame, 420, 20, -66)
    box:SetMaxLetters(4000)
    box:SetScript("OnEscapePressed", function() importFrame:Hide() end)
    importFrame.box = box
    local function go()
      local list, why = NS.ListImport(box:GetText())
      if list then
        NS.Print(string.format("shopping list %s imported: %d items", list.name, #list.items))
        importFrame:Hide()
        if NS.OpenWindow then NS.OpenWindow("lists") end
      else
        NS.Print("list import failed: " .. tostring(why))
      end
    end
    box:SetScript("OnEnterPressed", go)
    local button = UI.Button(importFrame, "Import", 100, go)
    button:SetPoint("BOTTOMRIGHT", -16, 14)
  end
  importFrame.box:SetText("")
  importFrame:Show()
  importFrame.box:SetFocus()
end

-- ---------------------------------------------------------------------------------------------
-- Tab
-- ---------------------------------------------------------------------------------------------

local function menuFor(row, anchor)
  UI.Menu(anchor or tab.list, {
    { text = "Search the auction house", onClick = function() NS.SearchAuctionHouse(row.name) end },
    { text = "Count one more bought", onClick = function() NS.ListSetBought(row.listKey, row.itemID, row.bought + 1); NS.RefreshWindow(); if NS.RefreshListsPanel then NS.RefreshListsPanel() end end },
    { text = "Count all " .. UI.Comma(row.qty) .. " bought", onClick = function() NS.ListSetBought(row.listKey, row.itemID, row.qty); NS.RefreshWindow(); if NS.RefreshListsPanel then NS.RefreshListsPanel() end end },
    { text = "Count none bought", onClick = function() NS.ListSetBought(row.listKey, row.itemID, 0); NS.RefreshWindow(); if NS.RefreshListsPanel then NS.RefreshListsPanel() end end },
  }, 220)
end

local function refresh()
  if not tab.list then return end
  local lists = NS.Lists()
  local rows, left = openRows(lists, NS.Market())
  local spend, unpriced = 0, 0
  for _, r in ipairs(rows) do
    if r.need > 0 then
      local unit = r.lowest or r.median
      if unit then spend = spend + unit * r.need else unpriced = unpriced + 1 end
    end
  end
  if #lists == 0 then
    tab.totals:SetText("No shopping lists yet. Make one on ahledger.com/lists; AHledger sync brings it here, or paste its line with Import a list.")
  else
    tab.totals:SetText(string.format("%d %s, %s still to buy, about %s at the lowest listed%s.", #lists, #lists == 1 and "list" or "lists",
      UI.Comma(left), NS.Gold(spend), unpriced > 0 and string.format(" (%d unpriced)", unpriced) or ""))
  end
  tab.list:SetRows(rows)
end

local function build(parent)
  tab.totals = UI.Label(parent, "", "GameFontHighlightSmall", 0, -2, 540)
  tab.totals:SetWordWrap(false)
  local import = UI.Button(parent, "Import a list", 120, function() NS.ShowListImport() end)
  import:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 2)
  tab.list = UI.List(parent, {
    x = 0, y = -24, width = 668, rows = 21, rowKey = "key",
    columns = {
      { key = "list", label = "List", width = 110 },
      { key = "link", label = "Item", width = 190 },
      { key = "need", label = "Bought", width = 80, numeric = true, justify = "RIGHT", format = function(_, row)
        if row.need == 0 then return UI.UP .. "done" .. UI.R end
        return UI.Comma(row.bought) .. UI.GREY .. " of " .. UI.R .. UI.Comma(row.qty)
      end },
      { key = "lowest", label = "Lowest", width = 90, numeric = true, tip = "The lowest buyout in the latest scan of this market.", format = function(v, row)
        if not v then return UI.GREY .. "-" .. UI.R end
        return row.over and ("|cffff6060" .. NS.Gold(v) .. "|r") or NS.Gold(v)
      end },
      { key = "median", label = "Median", width = 85, numeric = true, format = function(v) return v and NS.Gold(v) or (UI.GREY .. "-" .. UI.R) end },
      { key = "max", label = "Max each", width = 80, numeric = true, format = function(v) return v and NS.Gold(v) or (UI.GREY .. "any" .. UI.R) end },
    },
    empty = "Nothing on your shopping lists.",
    onClick = function(row, button)
      if button == "RightButton" then menuFor(row) else NS.SearchAuctionHouse(row.name) end
    end,
    onEnter = function(tt, row)
      if row.over then tt:AddLine("|cffff6060The lowest listing is above your max price.|r", nil, nil, nil, true) end
      if row.source == "import" then tt:AddLine(UI.GREY .. "Imported here; /ahl list remove " .. row.list .. " removes the list." .. UI.R, nil, nil, nil, true) end
      tt:AddLine(UI.GREY .. "Click to search the auction house, right-click to correct the bought count" .. UI.R, nil, nil, nil, true)
    end,
  })
  tab.list:SetSort("need", "desc")
end

NS.RegisterTab({ key = "lists", label = "Lists", order = 4.5, build = build, refresh = refresh })

-- ---------------------------------------------------------------------------------------------
-- Auction house panel: what is left to buy, beside the house. A click fills the search.
-- ---------------------------------------------------------------------------------------------

local PANEL_ROWS = 14
local panel
local hidden = false -- closed by the player for this visit

-- The auction house window: the modern one (Forever) or the classic AuctionFrame (Classic Era).
local function house()
  if AuctionHouseFrame and AuctionHouseFrame.IsShown and AuctionHouseFrame:IsShown() then return AuctionHouseFrame end
  if AuctionFrame and AuctionFrame.IsShown and AuctionFrame:IsShown() then return AuctionFrame end
  return AuctionHouseFrame or AuctionFrame
end

local function place()
  local frame = house()
  if not panel or not frame then return end
  panel:ClearAllPoints()
  local posting = _G.AHledgerPostingPanel
  if posting and posting.IsShown and posting:IsShown() then
    panel:SetPoint("TOPLEFT", posting, "BOTTOMLEFT", 0, -6)
  else
    panel:SetPoint("TOPLEFT", frame, "TOPRIGHT", 6, -28)
  end
end

local function ensurePanel()
  local frame = house()
  if panel or not frame then return panel end
  panel = CreateFrame("Frame", "AHledgerListsPanel", frame, "BackdropTemplate")
  panel:SetSize(250, 52 + PANEL_ROWS * 16)
  if panel.SetBackdrop then
    panel:SetBackdrop({
      bgFile = "Interface/DialogFrame/UI-DialogBox-Background-Dark",
      edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
  end
  panel.title = UI.Label(panel, UI.ACCENT .. "AHledger" .. UI.R .. " shopping list", "GameFontNormalSmall", 10, -8, 200)
  local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
  close:SetSize(20, 20)
  close:SetPoint("TOPRIGHT", -2, -2)
  close:SetScript("OnClick", function() hidden = true; panel:Hide() end)
  panel.rows = {}
  for i = 1, PANEL_ROWS do
    local b = CreateFrame("Button", nil, panel)
    b:SetSize(232, 16)
    b:SetPoint("TOPLEFT", 9, -24 - (i - 1) * 16)
    b.left = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.left:SetPoint("LEFT", 0, 0)
    b.left:SetWidth(150)
    b.left:SetJustifyH("LEFT")
    b.left:SetWordWrap(false)
    b.right = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.right:SetPoint("RIGHT", 0, 0)
    b.right:SetJustifyH("RIGHT")
    b:SetHighlightTexture("Interface/QuestFrame/UI-QuestTitleHighlight", "ADD")
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function(self, button)
      if not self.row then return end
      if button == "RightButton" then menuFor(self.row, self) else NS.SearchAuctionHouse(self.row.name) end
    end)
    b:SetScript("OnEnter", function(self)
      local r = self.row
      if not r or GameTooltip:IsForbidden() then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(r.name, 1, 1, 1)
      GameTooltip:AddLine(string.format("%s: %s of %s bought", r.list, UI.Comma(r.bought), UI.Comma(r.qty)), 0.8, 0.8, 0.8)
      if r.max then GameTooltip:AddLine("Max " .. NS.Gold(r.max) .. " each" .. (r.over and " |cffff6060(lowest is above it)|r" or ""), 0.8, 0.8, 0.8) end
      GameTooltip:AddLine("Click to search, right-click to correct the count", 0.6, 0.6, 0.62)
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    panel.rows[i] = b
  end
  panel.foot = UI.Muted(panel, "", 10, -28 - PANEL_ROWS * 16, 230)
  return panel
end

function NS.RefreshListsPanel()
  if not panel or not panel:IsShown() then return end
  local rows, left = openRows(NS.Lists(), NS.Market())
  local open = {}
  for _, r in ipairs(rows) do if r.need > 0 then open[#open + 1] = r end end
  if #open == 0 then panel:Hide() return end
  for i, b in ipairs(panel.rows) do
    local r = open[i]
    b.row = r
    if r then
      b.left:SetText(UI.Comma(r.need) .. " x " .. r.link)
      local unit = r.lowest or r.median
      b.right:SetText(unit and (r.over and ("|cffff6060" .. NS.Gold(unit) .. "|r") or NS.Gold(unit)) or (UI.GREY .. "-" .. UI.R))
      b:Show()
    else
      b:Hide()
    end
  end
  panel.foot:SetText(string.format("%s to buy on %d %s%s", UI.Comma(left), #open, #open == 1 and "line" or "lines", #open > PANEL_ROWS and string.format(", first %d shown; /ahl list for all", PANEL_ROWS) or ""))
end

function NS.ShowListsPanel()
  if hidden or not NS.Setting("listsPanel") then return end
  if NS.IsScannerOnly and NS.IsScannerOnly() then return end
  if not ensurePanel() then return end
  place()
  panel:Show()
  NS.RefreshListsPanel()
  local posting = _G.AHledgerPostingPanel
  if posting and not panel.hookedPosting and posting.HookScript then
    panel.hookedPosting = true
    posting:HookScript("OnShow", place)
    posting:HookScript("OnHide", place)
  end
end

local events = CreateFrame("Frame")
events:RegisterEvent("AUCTION_HOUSE_SHOW")
events:RegisterEvent("AUCTION_HOUSE_CLOSED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    NS.ListsFromData()
  elseif event == "AUCTION_HOUSE_SHOW" then
    hidden = false
    NS.ShowListsPanel()
  elseif event == "AUCTION_HOUSE_CLOSED" then
    if panel then panel:Hide() end
  end
end)

-- /ahl list [import | remove <name>]
function NS.ListCommand(arg)
  local sub, rest = tostring(arg or ""):match("^(%S*)%s*(.-)$")
  sub = (sub or ""):lower()
  if sub == "import" then
    -- The chat box holds 255 characters and cuts what is past them, which could leave a
    -- shorter quantity that still reads; a line that long goes through the window instead.
    -- "/ahl list import " is 17 of the 255, so a cut line is at most 238 here.
    if #rest >= 225 then
      NS.Print("that line is too long for the chat box, which cuts it. Type /ahl list import alone and paste it into the window.")
      NS.ShowListImport()
    elseif rest ~= "" then
      local list, why = NS.ListImport(rest)
      NS.Print(list and string.format("shopping list %s imported: %d items", list.name, #list.items) or ("list import failed: " .. tostring(why)))
    else
      NS.ShowListImport()
    end
  elseif sub == "remove" then
    local l = NS.ListRemove(rest)
    NS.Print(l and ("removed the imported list " .. l.name) or "no imported list has that name; lists from your account are removed on ahledger.com/lists")
  elseif sub == "panel" then
    hidden = false
    local frame = house()
    if frame and frame:IsShown() then NS.ShowListsPanel() else NS.Print("the list panel opens with the auction house") end
  else
    if NS.OpenWindow then NS.OpenWindow("lists") end
  end
end
