--[[
  AHledgerAPI: AHledger's prices for other addons.

  A leveling guide, a profession helper or a bag addon can show what an item sells for on the
  player's own auction house without scanning it: AHledger already carries a price table for the
  player's market, refreshed every 30 minutes by AHledger sync from the scans players send to
  ahledger.com. Add AHledger to your toc's OptionalDeps and check the global exists:

    ## OptionalDeps: AHledger

    if AHledgerAPI then
      local median = AHledgerAPI.GetMedian(2589)          -- copper, or nil
      local p = AHledgerAPI.GetPrice("|Hitem:2589::...|h") -- item id, numeric string or link
      if p then print(p.median, p.minBuyout, p.soldPerDay, p.snapshot) end
    end

  Terms, the same as the web API's: free to use, and show the credit (AHledgerAPI.CREDIT) where
  the prices appear, for example as the last line of your tooltip block or in your options panel.
  Full wording at ahledger.com/developers#addons.

  Every function is safe to call at any time: a bad argument, a market with no table or anything
  that fails inside returns nil rather than raising an error into the caller's code. Prices are
  copper. Call after PLAYER_LOGIN, when the realm and faction that pick the market are known.

  API.VERSION changes only when something here changes incompatibly; new functions and new
  fields are added without changing it.

  Scanner only (0.14.3). An addon that shows AHledger's prices in its own interface can ask the
  player to run AHledger as a scanner only: AHledger keeps scanning, AHledger sync keeps sending
  the scans, and AHledger's tooltip lines, ledger bar, crafting margins and recipe dots, auction
  house panels, bag dots, vendor and quest reward marks, watchlist alerts, links to ahledger.com
  and chat summaries turn off. Nothing changes until the player says yes in AHledger's own
  dialog, which opens about four seconds after the loading screen (later if a cinematic plays or
  the player is in combat). With AHledger in your OptionalDeps (above), it has loaded before
  your code runs:

    if AHledgerAPI and AHledgerAPI.RequestScannerOnly then
      local state = AHledgerAPI.RequestScannerOnly("Haggler", function(accepted, answer)
        -- answer: "yes", "no", "later" (dialog closed with the X) or "on" (the player turned
        -- it on another way while the question waited); accepted is true for yes and on
      end)
      -- state: "on", "asked", "declined", "later" or "invalid". The callback runs only for
      -- "asked"; the other answers are final for this call.
    end

  Pass your own addon's folder name; the dialog names your addon by its toc Title. Ask once a
  session (at PLAYER_LOGIN is fine). "declined" is kept: the player said no, or said yes and
  later turned scanner only off themselves, so do not ask again; point them to /ahl scanner on
  if they want it after all. "later" lasts until their next login. The player can turn it on or
  off at any time (/ahl scanner on|off, or the first switch in /ahl options) and nothing tells
  you, so read AHledgerAPI.IsScannerOnly() when you need to know. A player in scanner only may
  still turn AHledger's own tooltip back on: AHledgerAPI.IsTooltipOn() says whether it draws its
  price block, if you want to avoid showing the same prices twice.
]]
local _, NS = ...

local API = {}

API.VERSION = 1
API.CREDIT = "Prices from AHledger (ahledger.com)"

-- 2589, "2589", or any string holding an item link or "item:2589". nil for anything else.
local function itemID(x)
  if type(x) == "number" then
    if x > 0 and x < 2 ^ 31 and x == math.floor(x) then return x end
    return nil
  end
  if type(x) ~= "string" then return nil end
  local id = x:match("^%s*(%d+)%s*$") or x:match("item:(%d+)")
  id = tonumber(id)
  if id and id > 0 and id < 2 ^ 31 then return id end
  return nil
end

-- A market key as the site writes it ("forever/pvp/horde/us"), else the player's own market.
local function marketOf(market)
  if type(market) == "string" and market:match("^[%w%-]+/[%w%-]+/[%w%-]+/[%w%-]+$") then
    return market
  end
  return NS.Market()
end

-- Runs f and returns its one result, or nil if it raised: a caller's tooltip must never break
-- on us. Exactly one value, so print(AHledgerAPI.GetMedian(id)) prints one thing.
local function safe(f, ...)
  local ok, a = pcall(f, ...)
  if ok then return a end
  return nil
end

--- The player's market key, e.g. "forever/pvp/horde/us".
function API.GetMarket()
  return safe(NS.Market)
end

--- "PvP Horde (US)" for a market key, or for the player's market without one.
function API.GetMarketLabel(market)
  return safe(function() return NS.MarketLabel(marketOf(market)) end)
end

--- The price table in use for a market: { market, updated (unix seconds), count (items priced),
--- snapshot }.
--- snapshot is true while the market is priced from the copy that ships with the addon, which
--- is older than sync's: say so if you show a price from it.
function API.GetTableInfo(market)
  return safe(function()
    local m = marketOf(market)
    local t = NS.TableFor(m)
    if not t then return nil end
    return { market = m, updated = t.updated, count = t.count, snapshot = t.seed == true }
  end)
end

--- One item's prices on a market (the player's, without one), as a fresh table the caller may
--- keep or change:
---   median, minBuyout, quantity, median7d, median30d, low30d, high30d (copper; nil = unknown),
---   soldPerDay (estimated units sold a day; nil without an estimate),
---   market, updated (unix seconds: the table's newest scan, or the player's own scan while it
---   prices the market), snapshot (see GetTableInfo), url.
--- nil when the item has no price there.
function API.GetPrice(item, market)
  return safe(function()
    local id = itemID(item)
    if not id then return nil end
    local m = marketOf(market)
    local row, t = NS.Price(id, m)
    if not row then return nil end
    -- When these numbers were seen: the player's own scan while it prices the market (0.13.1).
    local seen = NS.PricesSeen and NS.PricesSeen(m) or (t and t.updated)
    return {
      itemID = id,
      median = row.median,
      minBuyout = row.min,
      quantity = row.qty,
      median7d = row.m7,
      median30d = row.m30,
      low30d = row.lo,
      high30d = row.hi,
      soldPerDay = row.perDay,
      market = m,
      updated = seen,
      snapshot = (t and t.seed == true and not (NS.OwnScanInUse and NS.OwnScanInUse(m))) or false,
      url = NS.ItemURL(id),
    }
  end)
end

--- The latest median in copper, or nil. The cheapest call, for a tooltip line.
function API.GetMedian(item, market)
  return safe(function()
    local id = itemID(item)
    if not id then return nil end
    local row = NS.Price(id, marketOf(market))
    return row and row.median or nil
  end)
end

--- "ahledger.com/items/2589": the item's page, for a copy box or a credit line.
function API.GetItemURL(item)
  local id = itemID(item)
  return id and NS.ItemURL(id) or nil
end

--- AHledger's own version, e.g. "0.9.8".
function API.GetAddonVersion()
  return NS.VERSION
end

--- True while AHledger runs as a scanner only (0.14.3).
function API.IsScannerOnly()
  return safe(NS.IsScannerOnly) or false
end

--- True while AHledger draws its own price block in item tooltips (0.14.3): false in scanner
--- only, unless the player turned that switch back on.
function API.IsTooltipOn()
  return safe(function() return NS.Setting("tooltip") and true or false end) or false
end

--- Asks the player to run AHledger as a scanner only (0.14.3). addonName is the caller's folder
--- name, as loaded. Returns:
---   "on"       already on
---   "asked"    the player will see AHledger's dialog, now or once loading, a cinematic or
---              combat is over; callback(accepted, answer) runs once: answer "yes", "no",
---              "later" (closed with the X, accepted false) or "on" (turned on another way
---              meanwhile, accepted true)
---   "declined" the player said no to this addon, or turned scanner only off after saying yes
---   "later"    the player closed the dialog; ask again after their next login
---   "invalid"  addonName is not a loaded addon, or callback is not a function
--- The callback runs only for "asked". An error in it goes to the game's error handler.
function API.RequestScannerOnly(addonName, callback)
  return safe(NS.RequestScannerOnly, addonName, callback) or "invalid"
end

-- Read-only: another addon cannot replace a function here and break every addon after it.
AHledgerAPI = setmetatable({}, {
  __index = API,
  __newindex = function() error("AHledgerAPI is read-only", 2) end,
  __metatable = false,
})
NS.API = API
