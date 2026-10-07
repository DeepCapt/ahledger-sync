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

function NS.Price(itemID, market)
  market = market or NS.Market()
  local t = NS.TableFor(market)
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
function NS.AlertsPaused(market)
  return NS.TableIsSeed(market)
end

-- Age of the table in use, in seconds, or nil when there is none.
function NS.TableAge(market)
  local t = NS.TableFor(market or NS.Market())
  if not t or not t.updated or t.updated == 0 then return nil end
  return math.max(0, NS.Now() - t.updated)
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
