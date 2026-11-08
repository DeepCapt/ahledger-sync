--[[
  Price tables. A table is one market's prices as a compact string, either written into
  AHledger_Data.lua by the sync app or pasted in game as an import string. Both use the same
  text format the API serves at /v1/pricetable/<market>:

    AHL1|<market>|<updated unix seconds>|<rows>
    <item id>:<median>:<min buyout>:<quantity>:<median 7d>:<median 30d>:<low 30d>:<high 30d>:<sold a day x10>

  Prices are copper; an empty field is unknown. The ninth field (from 0.9.0) is the estimated
  units sold a day times ten, which the sell pace reads; tables without it simply have no pace. The string is parsed into a lookup on first use
  and cached, so loading costs nothing until a tooltip asks for a price.
]]
local ADDON_NAME, NS = ...

local FORMAT = "AHL1"
local cache = {} -- market -> { updated = n, count = n, items = { [id] = row } }

local function parseRows(text, into)
  local n = 0
  for line in text:gmatch("[^\n;]+") do
    local id, median, min, qty, m7, m30, lo, hi, sold = line:match("^(%d+):(%d*):(%d*):(%d*):(%d*):(%d*):(%d*):(%d*):?(%d*)")
    if id then
      id = tonumber(id)
      sold = tonumber(sold)
      -- Over ten million a day is not a market, and a pasted figure can overflow to infinity.
      if sold and not (sold >= 0 and sold <= 100000000) then sold = nil end
      into[id] = {
        median = tonumber(median),
        min = tonumber(min),
        qty = tonumber(qty) or 0,
        m7 = tonumber(m7),
        m30 = tonumber(m30),
        lo = tonumber(lo),
        hi = tonumber(hi),
        -- Estimated units sold a day; nil when the table has no estimate for it.
        perDay = sold and sold / 10 or nil,
      }
      n = n + 1
    end
  end
  return n
end

-- Parses a full table (header and rows). Returns market, updated, items, count or nil, error.
function NS.ParseTable(text)
  if type(text) ~= "string" then return nil, "empty" end
  text = text:gsub("^%s+", "")
  local header, rest = text:match("^([^\n]+)\n?(.*)$")
  if not header then return nil, "empty" end
  -- The client escapes every pipe typed or pasted into an edit box as "||" (a lone pipe starts
  -- a colour or link code), so a table pasted with /ahl import arrives with a doubled header.
  -- Rows hold digits and colons only, so only the header needs putting back.
  header = header:gsub("||", "|")
  local fmt, market, updated, declared = header:match("^(%w+)|([%w/%-]+)|(%d+)|(%d+)")
  if fmt ~= FORMAT then return nil, "not an AHledger price table" end
  local items = {}
  local n = parseRows(rest or "", items)
  if n == 0 then return nil, "no rows" end
  return market, tonumber(updated), items, n
end

-- Newest available source for a market: the sync app's data file, an in-game import, or the
-- seed that ships with the release. The seed only stands in when it is strictly newer than the
-- others, which in practice means when there are no others.
local function sourceFor(market)
  local fromFile = AHledgerData and AHledgerData[market]
  local db = NS.Db()
  local fromImport = db.tables and db.tables[market]
  local fromSeed = AHledgerSeed and AHledgerSeed[market]
  local best = nil
  if fromFile and fromFile.text then best = fromFile end
  if fromImport and fromImport.text and (not best or (fromImport.updated or 0) > (best.updated or 0)) then
    best = fromImport
  end
  if fromSeed and fromSeed.text and (not best or (fromSeed.updated or 0) > (best.updated or 0)) then
    best = fromSeed
  end
  return best
end

function NS.TableFor(market)
  local c = cache[market]
  local src = sourceFor(market)
  if not src then return nil end
  if c and c.updated == src.updated then return c end
  local items = {}
  local n = parseRows(src.text, items)
  c = { updated = src.updated or 0, count = n, items = items, market = market, seed = src.seed and true or false }
  cache[market] = c
  return c
end

-- ---------------------------------------------------------------------------------------------
-- The player's own scan, folded into the prices (0.13.1). A table's prices are as old as the
-- newest scan anybody uploaded, and the game reads a new table only at login or /reload, so a
-- player who had just scanned kept seeing "2 h old" until two reloads later (one to send the
-- scan, one to load the table built from it). The scan is already here, so the lowest buyout,
-- the median and the number listed come from it as soon as it is read; the 7 and 30 day
-- figures and the sell pace stay the table's. Only the market the scan was taken on, only
-- while the scan is newer than the table: once a table built after it is loaded, the table
-- (which then holds the scan) is used again.
-- ---------------------------------------------------------------------------------------------

-- The same rules the site applies to an upload (packages/shared/src/addon.ts and the upload
-- validator), so the numbers match the table that will be built from this scan.
local MAX_COPPER = 10000000000000 -- a listing above this is garbage and is dropped whole
local MAX_QUANTITY = 10000
local UNIT_CEILING = 250000 * 10000 -- no unit kept above 250,000 gold
local NO_HISTORY_CEILING = 50000 * 10000 -- nor above 50,000 gold without a 30 day median
local OUTLIER_MULTIPLE = 20 -- nor beyond 20x either side of the 30 day median
local ENTRIES_PER_STEP = 4000
local ITEMS_PER_STEP = 500

local overlay = nil -- { market, ts, items = { [id] = { median, min, qty } }, merged = {} }
local building = nil -- the scan being read, between frames

-- Lowest buyout, quantity-weighted median and units listed for one item, from { [unit] = qty }.
local function summarize(units)
  local prices, total = {}, 0
  for unit, qty in pairs(units) do
    prices[#prices + 1] = unit
    total = total + qty
  end
  if total <= 0 then return nil end
  table.sort(prices)
  local target, cumulative, median = math.max(1, math.ceil(total * 0.5)), 0, prices[#prices]
  for _, unit in ipairs(prices) do
    cumulative = cumulative + units[unit]
    if cumulative >= target then median = unit break end
  end
  return { median = median, min = prices[1], qty = total }
end

-- One listing into the per-item buckets, or nothing when the site would drop it.
local function addListing(byItem, history, id, stack, buyout, bid)
  id, stack, buyout, bid = tonumber(id), tonumber(stack), tonumber(buyout), tonumber(bid)
  if not id or id <= 0 or not stack or stack <= 0 or stack > MAX_QUANTITY then return end
  if not buyout or buyout <= 0 or buyout > MAX_COPPER or (bid or 0) > MAX_COPPER then return end
  local unit = math.max(1, math.floor(buyout / stack + 0.5))
  if unit > UNIT_CEILING then return end
  local row = history and history[id]
  local m30 = row and row.m30
  if m30 and m30 > 0 then
    if unit > m30 * OUTLIER_MULTIPLE or unit < m30 / OUTLIER_MULTIPLE then return end
  elseif unit > NO_HISTORY_CEILING then
    return
  end
  local units = byItem[id]
  if not units then units = {} byItem[id] = units end
  units[unit] = (units[unit] or 0) + stack
end

local LISTING = "(%d+):(%d+):(%d+):(%d+):%d+"

-- Every item's lowest buyout, median and units listed from a scan's data string, in one go.
-- `history` is the market's table items (for the 30 day medians the outlier rule needs), or
-- nil. Pure, for the harness; the game reads a scan a few thousand listings a frame instead.
function NS.SummarizeScan(data, history)
  local byItem, items = {}, {}
  if type(data) ~= "string" then return items end
  for id, stack, buyout, bid in data:gmatch(LISTING) do addListing(byItem, history, id, stack, buyout, bid) end
  for id, units in pairs(byItem) do items[id] = summarize(units) end
  return items
end

-- The market the client itself is on, whatever the options pin. A scan always belongs to it.
local function scanMarket()
  return NS.ClientMarket and NS.ClientMarket() or NS.Market()
end

local function overlayActive(market)
  if not overlay or overlay.market ~= market then return false end
  local t = NS.TableFor(market)
  -- A table stamped at or after the scan was built from it (or from something newer).
  return not t or t.seed or (t.updated or 0) < overlay.ts
end

local function overlayDone(scan, market, items)
  building = nil
  overlay = { market = market, ts = scan.ts, items = items, merged = {}, count = scan.count }
  if NS.CrossMarketReset then NS.CrossMarketReset() end
  if NS.OnPricesChanged then pcall(NS.OnPricesChanged) end
end

-- Reads a scan into the prices: right after the scanner saves one, and at login for a scan
-- newer than the table that loaded. Spread over frames so a full house does not stall the game;
-- `sync` reads it at once (the harness, or a client without C_Timer). Returns true when started.
function NS.UseOwnScan(scan, sync)
  if type(scan) ~= "table" or type(scan.data) ~= "string" or not scan.ts or scan.full == false then return false end
  local market = scanMarket()
  local t = NS.TableFor(market)
  if t and not t.seed and (t.updated or 0) >= scan.ts then return false end -- the table already has it
  if overlay and overlay.market == market and overlay.ts >= scan.ts then return false end
  local history = t and t.items or nil
  if sync or not (C_Timer and C_Timer.After) then
    overlayDone(scan, market, NS.SummarizeScan(scan.data, history))
    return true
  end
  local job = { scan = scan, market = market, history = history, byItem = {}, next = scan.data:gmatch(LISTING) }
  building = job
  local function step()
    if building ~= job then return end -- a newer scan took over
    local ok, err = pcall(function()
      if job.next then
        for _ = 1, ENTRIES_PER_STEP do
          local id, stack, buyout, bid = job.next()
          if not id then
            job.next = nil
            job.ids, job.items, job.i = {}, {}, 0
            for k in pairs(job.byItem) do job.ids[#job.ids + 1] = k end
            break
          end
          addListing(job.byItem, job.history, id, stack, buyout, bid)
        end
      else
        local stop = math.min(job.i + ITEMS_PER_STEP, #job.ids)
        for i = job.i + 1, stop do
          local id = job.ids[i]
          job.items[id] = summarize(job.byItem[id])
          job.byItem[id] = nil
        end
        job.i = stop
        if stop >= #job.ids then overlayDone(job.scan, job.market, job.items) return end
      end
      C_Timer.After(0, step)
    end)
    if not ok then
      building = nil
      if NS.NoteError then NS.NoteError("own scan prices", err) end
    end
  end
  step()
  return true
end

-- Forgets the scan overlay; the harness and /ahl clear use it.
function NS.ForgetOwnScan()
  overlay, building = nil, nil
end

-- When the market's prices were seen and whether they come from the player's own scan:
-- ts (unix seconds) and true for the scan, the table's stamp and false, or nil.
function NS.PricesSeen(market)
  market = market or NS.Market()
  if overlayActive(market) then return overlay.ts, true end
  local t = NS.TableFor(market)
  if not t or not t.updated or t.updated == 0 then return nil, false end
  return t.updated, false
end

-- True while the market's lowest prices and listed counts come from the player's own scan.
function NS.OwnScanInUse(market)
  return overlayActive(market or NS.Market())
end

-- The row a tooltip reads: the table's, with the scan's lowest, median and listed laid over it.
-- An item the table prices but the scan did not see is listed by nobody now: no lowest, none
-- listed, the table's median kept as the last one known.
local function mergedRow(id, base)
  local hit = overlay.merged[id]
  if hit ~= nil then return hit or nil end
  local s = overlay.items[id]
  local row = false
  if s or base then
    row = {}
    if base then for k, v in pairs(base) do row[k] = v end end
    if s then
      row.median, row.min, row.qty = s.median, s.min, s.qty
    else
      row.min, row.qty = nil, 0
    end
    row.ownScan = true
  end
  overlay.merged[id] = row
  return row or nil
end

-- The table's own row, without the player's scan: for comparing that scan against the table.
function NS.TablePrice(itemID, market)
  local t = NS.TableFor(market or NS.Market())
  return t and t.items[itemID] or nil, t
end

function NS.Price(itemID, market)
  market = market or NS.Market()
  local t = NS.TableFor(market)
  if overlayActive(market) then return mergedRow(itemID, t and t.items[itemID] or nil), t end
  if not t then return nil, t end
  return t.items[itemID], t
end

-- Every market with a table loaded, for the options dropdown.
function NS.KnownMarkets()
  local seen, list = {}, {}
  local db = NS.Db()
  for k, v in pairs(AHledgerData or {}) do
    if type(v) == "table" and v.text then seen[k] = true end
  end
  for k, v in pairs(AHledgerSeed or {}) do
    if type(v) == "table" and v.text then seen[k] = true end
  end
  for k, v in pairs(db.tables or {}) do
    if type(v) == "table" and v.text then seen[k] = true end
  end
  for k in pairs(seen) do list[#list + 1] = k end
  table.sort(list)
  return list
end

-- Stores a pasted import string. Returns market, count or nil, error.
function NS.ImportTable(text)
  local market, updated, _, n = NS.ParseTable(text)
  if not market then return nil, updated end
  local db = NS.Db()
  db.tables = db.tables or {}
  local _, body = text:gsub("^%s+", ""):match("^([^\n]+)\n?(.*)$")
  db.tables[market] = { updated = updated or NS.Now(), count = n, text = body }
  cache[market] = nil
  if NS.CrossMarketReset then NS.CrossMarketReset() end
  return market, n
end

-- True while the market is priced from the seed that ships with the addon.
function NS.TableIsSeed(market)
  local t = NS.TableFor(market or NS.Market())
  return t ~= nil and t.seed == true
end

-- "Oct 1" for the table in use, for the snapshot labels.
function NS.TableDate(market)
  local t = NS.TableFor(market or NS.Market())
  if not t or not t.updated or t.updated == 0 then return nil end
  return date and date("%b %d", t.updated):gsub(" 0", " ") or tostring(t.updated)
end

-- The one sentence that explains the seed and how to get past it.
function NS.SeedNote(market)
  return string.format("Prices for %s are the %s snapshot that ships with the addon. For prices every 30 minutes, install AHledger sync: ahledger.com/download", NS.MarketLabel(market or NS.Market()), NS.TableDate(market) or "release")
end

-- " in the Oct 1 snapshot" while the market runs on the shipped snapshot, else "". Appended to
-- every sentence that compares against the median, so a deal found against old prices says so.
function NS.SnapshotSuffix(market)
  if not NS.TableIsSeed(market) then return "" end
  return string.format(" in the %s snapshot", NS.TableDate(market) or "release")
end

-- Watchlist alerts wait for live prices: a threshold met only against an old snapshot would
-- send the player to the auction house for nothing.
-- The player's own scan is live prices too.
function NS.AlertsPaused(market)
  market = market or NS.Market()
  return NS.TableIsSeed(market) and not overlayActive(market)
end

-- Age of the prices in use, in seconds, or nil when there are none: since the player's own scan
-- while it is in use (0.13.1), else since the newest scan in the table.
function NS.TableAge(market)
  local ts = NS.PricesSeen(market)
  if not ts then return nil end
  return math.max(0, NS.Now() - ts)
end

-- "scanned 2 h ago", "your scan 4 min ago" or the snapshot's date: what the prices' age means,
-- in the words every surface uses. nil without prices. Pure apart from the tables.
function NS.PricesAgeText(market)
  market = market or NS.Market()
  local ts, own = NS.PricesSeen(market)
  if not ts then return nil end
  if own then return "your scan " .. NS.UI.AgoText(math.max(0, NS.Now() - ts)) end
  if NS.TableIsSeed(market) then return (NS.TableDate(market) or "release") .. " snapshot" end
  return "scanned " .. NS.UI.AgoText(math.max(0, NS.Now() - ts))
end

-- ---------------------------------------------------------------------------------------------
-- Sell pace: how fast an item sells, from the estimated units sold a day (ahledger.com works it
-- out from consecutive scans of the house) against the units listed now. Pure, for the harness.
-- ---------------------------------------------------------------------------------------------

-- Days of stock at which each pace ends.
NS.PACE_FAST_DAYS = 1
NS.PACE_STEADY_DAYS = 3
NS.PACE_SLOW_DAYS = 14

-- { tier = "fast" | "steady" | "slow" | "barely", perDay, days } or nil without an estimate.
-- days is the units listed over the units sold a day: how long what is listed would last.
function NS.Pace(row)
  if type(row) ~= "table" or type(row.perDay) ~= "number" then return nil end
  local perDay, qty = row.perDay, row.qty or 0
  if qty <= 0 then
    -- Sold out: what sells at a day or more is fast; under that it barely moves.
    return { tier = perDay >= 1 and "fast" or "barely", perDay = perDay, days = nil, soldOut = true }
  end
  local days = perDay > 0 and qty / perDay or nil
  local tier
  if not days or days > NS.PACE_SLOW_DAYS then tier = "barely"
  elseif days < NS.PACE_FAST_DAYS then tier = "fast"
  elseif days <= NS.PACE_STEADY_DAYS then tier = "steady"
  else tier = "slow" end
  return { tier = tier, perDay = perDay, days = days }
end

-- The words are the same on ahledger.com: say what is measured (auction house sales) and how fast.
local PACE_WORD = { fast = "Sells fast", steady = "Sells steadily", slow = "Sells slowly", barely = "Barely sells" }
-- For a column headed "AH sales".
local PACE_SHORT = { fast = "fast", steady = "steadily", slow = "slowly", barely = "barely" }
local PACE_COLOUR = { fast = "|cff3ddc6a", steady = "|cffededf2", slow = "|cffffd23f", barely = "|cff9d9d9d" }

local PACE_PHRASE = { fast = "sells fast", steady = "sells steadily", slow = "sells slowly", barely = "barely sells" }

function NS.PaceWord(tier) return PACE_WORD[tier] end
-- "sells fast", "barely moves": for a line that already says something else.
function NS.PacePhrase(tier) return PACE_PHRASE[tier] end
function NS.PaceShort(tier) return PACE_SHORT[tier] end
function NS.PaceColour(tier) return PACE_COLOUR[tier] or "|cff9d9d9d" end

-- 36000 -> "36,000", 1437 -> "1,400", 37 -> "37", 0.4 -> "<1": the way the site rounds it, since
-- an estimate printed to the unit claims more than it knows.
function NS.RoughCount(n)
  if not n then return "?" end
  if n > 0 and n < 1 then return "<1" end
  if n < 10 then return tostring(math.floor(n + 0.5)) end
  local step = 10 ^ (math.floor(math.log10 and math.log10(n) or (math.log(n) / math.log(10))) - 1)
  local v = math.floor(n / step + 0.5) * step
  local s = tostring(math.floor(v))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

-- How long what is listed now would last: "listings clear in ~2 days".
local function stockText(days)
  if not days then return nil end
  if days < 1 then return "listings clear in under a day" end
  if days < 1.5 then return "listings clear in about a day" end
  if days > 60 then return "listings would take over two months to clear" end
  return string.format("listings clear in ~%d days", math.floor(days + 0.5))
end

-- "~36,000 sold a day", "under one sold a day", "none sold this week".
function NS.SoldText(perDay)
  if not perDay or perDay <= 0 then return "none sold this week" end
  if perDay < 1 then return "under one sold a day" end
  return "~" .. NS.RoughCount(perDay) .. " sold a day"
end

-- "Sells steadily on the AH: ~200 sold a day, listings clear in ~2 days", without the colour.
-- Pure.
function NS.PaceText(p)
  if not p then return nil end
  if p.perDay <= 0 then return PACE_WORD.barely .. " on the AH: none sold this week" end
  local stock = p.soldOut and "none listed now" or stockText(p.days)
  return PACE_WORD[p.tier] .. " on the AH: " .. NS.SoldText(p.perDay) .. (stock and (", " .. stock) or "")
end

-- What /ahl pace prints: what the line means and where it comes from.
function NS.PaceHelp()
  return {
    "Auction house sales speed: how fast an item sells on your auction house, estimated by ahledger.com from players' scans over the last week.",
    "Sells fast: what is listed now clears in under a day. Sells steadily: within 3 days. Sells slowly: within 2 weeks. Barely sells: longer, or none sold this week.",
    "\"~200 sold a day\" is the estimate; it leans low. Switch it off with /ahl set tooltipPace off and /ahl set barPace off.",
  }
end

-- How long a quantity would take to sell at the auction house's pace, for the posting panel:
-- "at that pace your 120 would sell in about 14 hours". nil without a pace or a quantity.
function NS.ClearText(p, count)
  if not p or not count or count <= 0 then return nil end
  if p.perDay <= 0 then return string.format("none sold this week; your %d may wait", count) end
  local days = count / p.perDay
  local when
  if days < 1 / 24 then when = "would sell within the hour"
  elseif days < 1 then when = string.format("would sell in about %d hours", math.max(1, math.floor(days * 24 + 0.5)))
  elseif days < 1.5 then when = "would sell in about a day"
  elseif days > 60 then when = "would take over two months to sell"
  else when = string.format("would sell in about %d days", math.floor(days + 0.5)) end
  return string.format("at that pace your %d %s", count, when)
end

-- A list cell for the tabs ("Sold/day"): "36,000" in the pace colour, "<1", or a grey dash.
function NS.PaceCell(row)
  local pace = NS.Pace(row)
  if not pace then return "|cff9d9d9d-|r" end
  return NS.PaceColour(pace.tier) .. NS.RoughCount(pace.perDay) .. "|r"
end

-- ---------------------------------------------------------------------------------------------
-- Other markets (0.10.0): the same item on the other faction's house and on the cheapest house
-- in the region. AHledger sync writes every market's table into the data file, so this is a
-- lookup in what is already loaded, never a download. Pure.
-- ---------------------------------------------------------------------------------------------

-- The other faction's market key, or nil when the key names no faction.
function NS.OtherFaction(market)
  local game, ruleset, faction, region = (market or ""):match("^([^/]+)/([^/]+)/([^/]+)/([^/]+)$")
  if not game then return nil end
  local other = faction == "horde" and "alliance" or (faction == "alliance" and "horde") or nil
  if not other then return nil end
  return string.format("%s/%s/%s/%s", game, ruleset, other, region)
end

local regionCache = {} -- market -> its region's other markets
local crossCache = {} -- market .. ":" .. item -> CrossMarket's answer

-- Forgotten whenever a table changes (an import, a login): the lists and answers below are
-- cheap to build once and costly to build per tooltip.
function NS.CrossMarketReset()
  regionCache = {}
  crossCache = {}
end

-- Every market with a table in the same game and region as `market`, other than itself.
function NS.RegionMarkets(market)
  local hit = regionCache[market]
  if hit then return hit end
  local game, _, _, region = (market or ""):match("^([^/]+)/([^/]+)/([^/]+)/([^/]+)$")
  local out = {}
  if not game then return out end
  for _, m in ipairs(NS.KnownMarkets()) do
    if m ~= market and m:sub(1, #game + 1) == game .. "/" and m:sub(-(#region + 1)) == "/" .. region then
      out[#out + 1] = m
    end
  end
  regionCache[market] = out
  return out
end

-- { other = { market, row } or nil, cheapest = { market, row } or nil }: the other faction's row
-- when its table prices the item, and the region market with the lowest median when it is under
-- this market's (or any priced market when the item is not priced here). Shipped snapshots are
-- skipped, since a snapshot price is not one to travel for.
function NS.CrossMarket(itemID, market)
  market = market or NS.Market()
  local key = market .. ":" .. tostring(itemID)
  local hit = crossCache[key]
  if hit then return hit end
  local out = {}
  local other = NS.OtherFaction(market)
  if other then
    local row = NS.Price(itemID, other)
    if row and row.median and not NS.TableIsSeed(other) then out.other = { market = other, row = row } end
  end
  local here = NS.Price(itemID, market)
  local best = nil
  for _, m in ipairs(NS.RegionMarkets(market)) do
    local row = NS.Price(itemID, m)
    if row and row.median and (row.qty or 0) > 0 and not NS.TableIsSeed(m) then
      if not best or row.median < best.row.median then best = { market = m, row = row } end
    end
  end
  if best and (not here or not here.median or best.row.median < here.median) then out.cheapest = best end
  crossCache[key] = out
  return out
end
