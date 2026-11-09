--[[
  The ledger (0.11.0): what you posted, sold, bought, and lost to expiry, and whether your
  auctions are undercut.

  Entries live in AHledgerDB.ledger, oldest first, sixty days or three thousand entries, each
  { t, k, id, name, q, p, cut, dep }: the time, the kind (post, sale, buy, expire, cancel), the
  item, the quantity, the money (gross for a sale, paid for a purchase, unit price times quantity
  for a post), the house's cut and the deposit. A post is noted by the hooks on the posting
  calls; a sale, purchase, expiry or cancellation when the mail that reports it is taken, by the
  hooks on the take calls, so each mail counts once. Nothing is taken, posted or cancelled by the
  addon; cancelling an undercut auction from the Ledger tab is your right-click.

  Undercut: when your auctions list loads, each listing's unit price is set against the lowest
  unit price for that item in your latest scan. One chat line names the undercut ones, once per
  visit to the house, and the tab lists them.
]]
local _, NS = ...
local UI = NS.UI
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local MAX_ENTRIES = 3000
local MAX_AGE_S = 60 * 86400
local KINDS = { post = "posted", sale = "sold", buy = "bought", expire = "expired", cancel = "cancelled" }
NS.LEDGER_KINDS = KINDS

local tab = {}

local function entries()
  local db = NS.Db()
  if type(db.ledger) ~= "table" then db.ledger = {} end
  return db.ledger
end

-- Adds one entry and trims the list by age and count. Returns the entry, or nil for junk.
function NS.LedgerAdd(e, now)
  if type(e) ~= "table" or not KINDS[e.k] then return nil end
  now = now or NS.Now()
  local db = NS.Db()
  local list = entries()
  e.t = e.t or now
  db.ledgerSeq = (tonumber(db.ledgerSeq) or 0) + 1
  e.s = db.ledgerSeq
  e.q = math.max(1, math.floor(tonumber(e.q) or 1))
  e.p = math.max(0, math.floor(tonumber(e.p) or 0))
  list[#list + 1] = e
  local cutoff = now - MAX_AGE_S
  -- Anything past sixty days goes, wherever it sits (a mail taken late carries an old time).
  for i = #list, 1, -1 do
    if (list[i].t or 0) < cutoff then table.remove(list, i) end
  end
  while #list > MAX_ENTRIES do table.remove(list, 1) end
  if NS.RefreshWindow then NS.RefreshWindow() end
  return e
end

-- ---------------------------------------------------------------------------------------------
-- Posts
-- ---------------------------------------------------------------------------------------------

local function nameOf(id)
  local name = id and GetItemInfo(id)
  return name or (id and ("item " .. id)) or "?"
end

function NS.LedgerPost(itemID, qty, unit, hours)
  if not NS.Setting("ledger") or not itemID or not unit or unit <= 0 then return nil end
  return NS.LedgerAdd({ k = "post", id = itemID, name = nameOf(itemID), q = qty or 1, p = (unit or 0) * (qty or 1), u = unit, h = hours })
end

local function itemIdFromLocation(location)
  if not location or not C_Item or not C_Item.GetItemID then return nil end
  local ok, id = pcall(C_Item.GetItemID, location)
  return ok and id or nil
end

local HOURS = { [1] = 12, [2] = 24, [3] = 48 }

local hooked = {}
local function hookPosting()
  if hooked.post then return end
  hooked.post = true
  pcall(function()
    if C_AuctionHouse and C_AuctionHouse.PostItem then
      hooksecurefunc(C_AuctionHouse, "PostItem", function(location, duration, quantity, bid, buyout)
        local id = itemIdFromLocation(location)
        local price = (buyout and buyout > 0) and buyout or bid
        if id and price then NS.LedgerPost(id, quantity or 1, price / math.max(1, quantity or 1), HOURS[duration] or duration) end
      end)
    end
    if C_AuctionHouse and C_AuctionHouse.PostCommodity then
      hooksecurefunc(C_AuctionHouse, "PostCommodity", function(location, duration, quantity, unitPrice)
        local id = itemIdFromLocation(location)
        if id and unitPrice then NS.LedgerPost(id, quantity or 1, unitPrice, HOURS[duration] or duration) end
      end)
    end
    -- Classic Era: one global call, the item from the sell slot.
    if PostAuction and GetAuctionSellItemInfo then
      hooksecurefunc("PostAuction", function(minBid, buyoutPrice, runTime, stackSize, numStacks)
        local _, _, count, _, _, _, _, _, _, itemID = GetAuctionSellItemInfo()
        local stacks = numStacks or 1
        local size = stackSize or count or 1
        local price = (buyoutPrice and buyoutPrice > 0) and buyoutPrice or minBid
        if itemID and price then
          for _ = 1, stacks do NS.LedgerPost(itemID, size, price / math.max(1, size), HOURS[runTime] or runTime) end
        end
      end)
    end
  end)
end

-- ---------------------------------------------------------------------------------------------
-- Mail: sales, purchases, expiries and cancellations, as the mail is taken
-- ---------------------------------------------------------------------------------------------

-- The entry for one auction mail, from its kind (Mail.lua's words) and its invoice:
-- { itemName, bid, buyout, deposit, consignment, count }. A sale's money is the bid (the buyout
-- when bought out), the house's cut is the consignment, the deposit comes back. nil for mail
-- that is not an auction's. Pure.
function NS.LedgerFromMail(kind, inv, attachedCount, itemID)
  inv = inv or {}
  local q = tonumber(inv.count) or tonumber(attachedCount) or nil
  local name = inv.itemName
  if kind == "sold" then
    return { k = "sale", id = itemID, name = name, q = q or 1, p = tonumber(inv.bid) or tonumber(inv.buyout) or 0, cut = tonumber(inv.consignment) or 0, dep = tonumber(inv.deposit) or 0 }
  elseif kind == "won" then
    return { k = "buy", id = itemID, name = name, q = q or 1, p = tonumber(inv.bid) or tonumber(inv.buyout) or 0 }
  elseif kind == "expired" then
    return { k = "expire", id = itemID, name = name, q = q or 1, p = 0 }
  elseif kind == "cancelled" then
    return { k = "cancel", id = itemID, name = name, q = q or 1, p = 0 }
  end
  return nil
end

-- A sale's quantity when the invoice has none (Classic Era): the post whose unit price times
-- quantity is the money, newest first. Pure.
function NS.LedgerMatchPost(list, name, money)
  for i = #list, 1, -1 do
    local e = list[i]
    if e.k == "post" and e.name == name and e.u and e.q and math.abs(e.u * e.q - money) < 1 then return e end
  end
  return nil
end

local taken = {} -- mail keys recorded this session, so a mail taken in two calls counts once

local function recordMail(index)
  if not NS.Setting("ledger") or not GetInboxHeaderInfo then return end
  local ok = pcall(function()
    local _, _, _, subject, money, _, daysLeft, hasItem = GetInboxHeaderInfo(index)
    local kind = NS.MailKind and NS.MailKind(subject)
    if not kind or kind == "pending" or kind == "outbid" then return end
    local key = table.concat({ tostring(subject), tostring(money), tostring(daysLeft) }, "|")
    if taken[key] then return end
    local inv = {}
    if GetInboxInvoiceInfo then
      local invoiceType, itemName, playerName, bid, buyout, deposit, consignment, _, _, _, count = GetInboxInvoiceInfo(index)
      inv = { invoiceType = invoiceType, itemName = itemName, bid = bid, buyout = buyout, deposit = deposit, consignment = consignment, count = count }
    end
    local attachedCount, itemID = nil, nil
    if hasItem and GetInboxItem then
      local _, id, _, count = GetInboxItem(index, 1)
      attachedCount, itemID = count, id
    end
    if not inv.itemName then inv.itemName = tostring(subject):match(":%s*(.+)$") end
    if not itemID and inv.itemName and GetItemInfo then
      local _, link = GetItemInfo(inv.itemName)
      itemID = link and NS.ItemIdFromLink(link) or nil
    end
    local e = NS.LedgerFromMail(kind, inv, attachedCount, itemID)
    if not e then return end
    if kind == "sold" and not inv.count then
      local post = NS.LedgerMatchPost(entries(), e.name, e.p)
      if post then
        e.q = post.q
        e.id = e.id or post.id
      end
    end
    taken[key] = true
    NS.LedgerAdd(e)
  end)
  local _ = ok
end

local function hookMail()
  if hooked.mail then return end
  hooked.mail = true
  pcall(function()
    for _, fn in ipairs({ "TakeInboxMoney", "TakeInboxItem", "AutoLootMailItem" }) do
      if _G[fn] then hooksecurefunc(fn, function(index) recordMail(index) end) end
    end
  end)
end

-- ---------------------------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------------------------

-- Per-item rows and totals for entries since `since`. Pure.
--   rows: { id, name, soldQ, revenue, cut, boughtQ, spent, net }
--   totals: { sold, revenue, cut, bought, spent, posted, expired, net }
function NS.LedgerSummary(list, since)
  local byName, rows = {}, {}
  local t = { sold = 0, revenue = 0, cut = 0, bought = 0, spent = 0, posted = 0, expired = 0, cancelled = 0 }
  for _, e in ipairs(list or {}) do
    if (e.t or 0) >= (since or 0) then
      local key = e.id or e.name or "?"
      local r = byName[key]
      if not r then
        r = { id = e.id, name = e.name or nameOf(e.id), soldQ = 0, revenue = 0, cut = 0, boughtQ = 0, spent = 0, expiredQ = 0 }
        byName[key] = r
        rows[#rows + 1] = r
      end
      if e.k == "sale" then
        r.soldQ = r.soldQ + (e.q or 1)
        r.revenue = r.revenue + (e.p or 0)
        r.cut = r.cut + (e.cut or 0)
        t.sold = t.sold + (e.q or 1)
        t.revenue = t.revenue + (e.p or 0)
        t.cut = t.cut + (e.cut or 0)
      elseif e.k == "buy" then
        r.boughtQ = r.boughtQ + (e.q or 1)
        r.spent = r.spent + (e.p or 0)
        t.bought = t.bought + (e.q or 1)
        t.spent = t.spent + (e.p or 0)
      elseif e.k == "post" then
        t.posted = t.posted + 1
      elseif e.k == "expire" then
        r.expiredQ = r.expiredQ + (e.q or 1)
        t.expired = t.expired + 1
      elseif e.k == "cancel" then
        t.cancelled = t.cancelled + 1
      end
    end
  end
  for _, r in ipairs(rows) do r.net = r.revenue - r.cut - r.spent end
  t.net = t.revenue - t.cut - t.spent
  table.sort(rows, function(a, b) return a.net > b.net end)
  return rows, t
end

-- "Last 7 days: sold 40 for 12g 30s (house cut 61s), bought 12 for 3g; net +8g 69s". Pure.
function NS.LedgerText(t, days)
  if not t or (t.sold == 0 and t.bought == 0 and t.posted == 0) then
    return string.format("Nothing in the last %d days. Posts, sales and purchases appear here as they happen and as you take the mail.", days or 7)
  end
  local parts = {}
  if t.sold > 0 then parts[#parts + 1] = string.format("sold %d for %s (house cut %s)", t.sold, NS.Gold(t.revenue), NS.Gold(t.cut)) end
  if t.bought > 0 then parts[#parts + 1] = string.format("bought %d for %s", t.bought, NS.Gold(t.spent)) end
  if t.posted > 0 then parts[#parts + 1] = string.format("%d post%s", t.posted, t.posted == 1 and "" or "s") end
  if t.expired > 0 then parts[#parts + 1] = string.format("%d expired", t.expired) end
  local net = t.net
  return string.format("Last %d days: %s; net %s%s%s", days or 7, table.concat(parts, ", "), net >= 0 and UI.UP .. "+" or UI.DOWN .. "-", UI.PlainGold(math.abs(net)), UI.R)
end

-- ---------------------------------------------------------------------------------------------
-- Undercut check
-- ---------------------------------------------------------------------------------------------

-- Your active auctions as { key, id, name, q, unit, auctionID or index }, whichever house the
-- client has. Empty when the house is closed or the list has not loaded.
function NS.OwnedAuctions()
  local out = {}
  pcall(function()
    if C_AuctionHouse and C_AuctionHouse.GetNumOwnedAuctions and C_AuctionHouse.GetOwnedAuctionInfo then
      local active = Enum and Enum.AuctionStatus and Enum.AuctionStatus.Active or 0
      for i = 1, C_AuctionHouse.GetNumOwnedAuctions() or 0 do
        local a = C_AuctionHouse.GetOwnedAuctionInfo(i)
        local id = a and a.itemKey and a.itemKey.itemID
        if a and id and (a.status == nil or a.status == active) and (a.buyoutAmount or 0) > 0 then
          local commodity = false
          if C_AuctionHouse.GetItemKeyInfo then
            local ok, info = pcall(C_AuctionHouse.GetItemKeyInfo, a.itemKey)
            commodity = ok and type(info) == "table" and info.isCommodity or false
          end
          local q = a.quantity or 1
          out[#out + 1] = { key = a.auctionID or i, auctionID = a.auctionID, id = id, name = nameOf(id), q = q, unit = commodity and a.buyoutAmount or (a.buyoutAmount / math.max(1, q)) }
        end
      end
    elseif GetNumAuctionItems and GetAuctionItemInfo then
      for i = 1, GetNumAuctionItems("owner") or 0 do
        local name, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, saleStatus, itemID = GetAuctionItemInfo("owner", i)
        if itemID and (buyout or 0) > 0 and (saleStatus or 0) == 0 then
          out[#out + 1] = { key = i, index = i, id = itemID, name = name or nameOf(itemID), q = count or 1, unit = buyout / math.max(1, count or 1) }
        end
      end
    end
  end)
  return out
end

-- Each auction against the lowest unit price for the item in the scan minima (Deals.lua):
-- undercut when somebody lists under yours. Pure.
function NS.UndercutRows(owned, minima)
  local rows = {}
  for _, a in ipairs(owned or {}) do
    local m = minima and minima[a.id]
    local r = { key = a.key, auctionID = a.auctionID, index = a.index, id = a.id, name = a.name, q = a.q, unit = a.unit, lowest = m and m.unit or nil }
    r.undercut = (m ~= nil and m.unit < a.unit - 0.5) and true or false
    r.gap = r.undercut and (a.unit - m.unit) / a.unit * 100 or 0
    rows[#rows + 1] = r
  end
  table.sort(rows, function(x, y)
    if x.undercut ~= y.undercut then return x.undercut end
    if x.gap ~= y.gap then return x.gap > y.gap end
    return (x.name or "") < (y.name or "")
  end)
  return rows
end

-- "3 of your 12 auctions are undercut: Linen Cloth (yours 20s, lowest 18s), ...", or nil. Pure.
function NS.UndercutText(rows)
  local n, names = 0, {}
  for _, r in ipairs(rows or {}) do
    if r.undercut then
      n = n + 1
      if #names < 4 then names[#names + 1] = string.format("%s (yours %s, lowest %s)", r.name, NS.Gold(r.unit), NS.Gold(r.lowest)) end
    end
  end
  if n == 0 then return nil end
  local more = n > #names and string.format(" and %d more", n - #names) or ""
  return string.format("%d of your %d auctions %s undercut: %s%s. The Ledger tab lists them.", n, #rows, n == 1 and "is" or "are", table.concat(names, ", "), more)
end

local saidThisVisit = false
local houseOpen = false
tab.undercut = {}

function NS.CheckUndercuts(say)
  -- The scan's lowest prices are read across frames when they are not kept yet (Deals.lua), and
  -- the check runs again once they are; the list of your auctions is read then, not now.
  local scan = NS.LatestLocalScan and NS.LatestLocalScan() or nil
  if scan and NS.ScanMinimaReady and not NS.ScanMinimaReady(scan) and NS.WithScanMinima then
    -- One waiting check, however often the owner list updates meanwhile. It speaks only if the
    -- house is still open when the read ends.
    NS.WithScanMinima(scan, function() pcall(NS.CheckUndercuts, say and houseOpen) end, "undercuts")
    return tab.undercut
  end
  local owned = NS.OwnedAuctions()
  local minima = NS.ScanMinima and NS.ScanMinima(scan) or {}
  tab.undercut = NS.UndercutRows(owned, minima)
  if say and NS.Setting("undercutCheck") and not saidThisVisit then
    local line = NS.UndercutText(tab.undercut)
    if line then
      saidThisVisit = true
      NS.Print(line)
    end
  end
  if NS.WindowShowing and NS.WindowShowing("ledger") and tab.refresh then tab.refresh() end
  return tab.undercut
end

-- Cancels one of your auctions. Your click; never called on its own.
local function cancelRow(r)
  local ok = pcall(function()
    if r.auctionID and C_AuctionHouse and C_AuctionHouse.CancelAuction then
      C_AuctionHouse.CancelAuction(r.auctionID)
    elseif r.index and CancelAuction then
      CancelAuction(r.index)
    else
      error("open the auction house first")
    end
  end)
  if ok then
    NS.Print("cancel requested for " .. (r.name or "?") .. "; it returns by mail")
    NS.LedgerAdd({ k = "cancel", id = r.id, name = r.name, q = r.q, p = 0 })
  else
    NS.Print("could not cancel " .. (r.name or "?") .. ": open the auction house and its Auctions tab first")
  end
end

-- ---------------------------------------------------------------------------------------------
-- Tab
-- ---------------------------------------------------------------------------------------------

local ROWS, UROWS = 10, 6

local function refresh()
  if not tab.list then return end
  local days = math.max(1, math.floor(tonumber(NS.Setting("ledgerDays")) or 7))
  if not tab.daysBox:HasFocus() then tab.daysBox:SetText(tostring(days)) end
  local rows, totals = NS.LedgerSummary(entries(), NS.Now() - days * 86400)
  tab.status:SetText(NS.LedgerText(totals, days))
  tab.list:SetRows(rows)
  local under = 0
  for _, r in ipairs(tab.undercut) do if r.undercut then under = under + 1 end end
  if #tab.undercut == 0 then
    tab.underTitle:SetText(UI.GREY .. "Your auctions: open the auction house and its Auctions tab to check them against your latest scan." .. UI.R)
  else
    tab.underTitle:SetText(string.format("Your auctions: %d listed, %s%d undercut%s in your latest scan. Right-click a row to cancel it.", #tab.undercut, under > 0 and UI.DOWN or UI.UP, under, UI.R))
  end
  tab.ulist:SetRows(tab.undercut)
end
tab.refresh = refresh

local function build(parent)
  tab.status = UI.Label(parent, "", "GameFontHighlightSmall", 0, -2, 560)
  tab.status:SetWordWrap(false)
  UI.Label(parent, "Days", "GameFontNormalSmall", 574, -4, 44)
  tab.daysBox = UI.EditBox(parent, 44, 620, 0, function(self)
    local n = tonumber((self:GetText() or ""):match("%d+"))
    if n then NS.SetSetting("ledgerDays", math.max(1, math.min(60, n))) end
    self:ClearFocus()
    refresh()
  end)
  tab.list = UI.List(parent, {
    x = 0, y = -24, width = 668, rows = ROWS, rowKey = "name",
    columns = {
      { key = "name", label = "Item", width = 200 },
      { key = "soldQ", label = "Sold", width = 50, numeric = true, justify = "RIGHT", format = function(v) return v > 0 and UI.Comma(v) or "" end },
      { key = "revenue", label = "Revenue", width = 100, numeric = true, format = function(v) return v > 0 and NS.Gold(v) or "" end },
      { key = "cut", label = "House cut", width = 80, numeric = true, format = function(v) return v > 0 and (UI.GREY .. NS.Gold(v) .. UI.R) or "" end },
      { key = "boughtQ", label = "Bought", width = 55, numeric = true, justify = "RIGHT", format = function(v) return v > 0 and UI.Comma(v) or "" end },
      { key = "spent", label = "Spent", width = 90, numeric = true, format = function(v) return v > 0 and NS.Gold(v) or "" end },
      { key = "net", label = "Net", width = 90, numeric = true, format = function(v)
        if not v or v == 0 then return UI.GREY .. "-" .. UI.R end
        return (v >= 0 and UI.UP or UI.DOWN) .. (v >= 0 and "+" or "-") .. UI.PlainGold(math.abs(v)) .. UI.R
      end },
    },
    empty = "No sales or purchases recorded yet.",
    onClick = function(row, button)
      if button == "RightButton" and IsControlKeyDown and IsControlKeyDown() and row.id then NS.ShowItemLink(row.id, row.name) return end
      if row.name then NS.SearchAuctionHouse(row.name) end
    end,
    onEnter = function(tt, row)
      if row.id then tt:SetItemByID(row.id) end
      tt:AddLine(UI.GREY .. "Click to search the auction house, ctrl+right-click for its ahledger.com page" .. UI.R, nil, nil, nil, true)
    end,
  })
  tab.list:SetSort("net", "desc")
  local y = -24 - (18 + ROWS * 18 + 16) - 6
  tab.underTitle = UI.Label(parent, "", "GameFontHighlightSmall", 0, y, 668)
  tab.underTitle:SetWordWrap(false)
  tab.ulist = UI.List(parent, {
    x = 0, y = y - 18, width = 668, rows = UROWS, rowKey = "key",
    columns = {
      { key = "name", label = "Your auction", width = 220 },
      { key = "q", label = "Qty", width = 45, numeric = true, justify = "RIGHT", format = function(v) return UI.Comma(v) end },
      { key = "unit", label = "Your price", width = 100, numeric = true, format = function(v) return NS.Gold(v) end },
      { key = "lowest", label = "Lowest in scan", width = 110, numeric = true, format = function(v) return v and NS.Gold(v) or (UI.GREY .. "not in scan" .. UI.R) end },
      { key = "gap", label = "Undercut by", width = 90, numeric = true, justify = "RIGHT", format = function(v, r) return r.undercut and (UI.DOWN .. string.format("%.0f%%", v) .. UI.R) or (UI.UP .. "lowest" .. UI.R) end },
    },
    empty = "",
    onClick = function(row, button)
      if button == "RightButton" then cancelRow(row) else NS.SearchAuctionHouse(row.name) end
    end,
    onEnter = function(tt, row)
      if row.id then tt:SetItemByID(row.id) end
      tt:AddLine(UI.GREY .. "Click to search the auction house, right-click to cancel this auction" .. UI.R, nil, nil, nil, true)
    end,
  })
  tab.ulist:SetSort("gap", "desc")
end

NS.RegisterTab({ key = "ledger", label = "Ledger", order = 5, build = build, refresh = refresh })

function NS.HookLedger()
  hookPosting()
  hookMail()
end

local events = CreateFrame("Frame", "AHledgerLedgerFrame")
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "OWNED_AUCTIONS_UPDATED", "AUCTION_OWNED_LIST_UPDATE", "MAIL_SHOW" }) do
  pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event)
  if event == "AUCTION_HOUSE_SHOW" then
    saidThisVisit = false
    houseOpen = true
    NS.HookLedger()
  elseif event == "AUCTION_HOUSE_CLOSED" then
    saidThisVisit = false
    houseOpen = false
  elseif event == "OWNED_AUCTIONS_UPDATED" or event == "AUCTION_OWNED_LIST_UPDATE" then
    pcall(NS.CheckUndercuts, true)
  elseif event == "MAIL_SHOW" then
    NS.HookLedger()
  end
end)
