--[[
  AHledger. Core: shared helpers, settings, market detection, the auction house scanner,
  and slash commands. Prices.lua, Tooltip.lua, Crafting.lua, Watchlist.lua, and Options.lua add
  to the NS table this file creates.

  What the scanner does: when you open the auction house it asks the server for the full listing
  (C_AuctionHouse.ReplicateItems, the same call Auctionator and TSM use), packs every listing into
  a compact string, and stores it in SavedVariables (WTF/Account/<account>/SavedVariables/AHledger.lua).
  AHledger sync reads that file and, when contribution is on, sends it to ahledger.com.

  What it never does: no network access (addons cannot), no buying, bidding, cancelling, or any
  other gameplay action, no memory reading, and nothing behind a paywall. Blizzard throttles
  ReplicateItems to roughly one full scan every 15 minutes; the addon respects that, and
  the scan button says so while it applies.

  Slash commands: /ahl (window) | scan | upload | status | import | watch | bar | auto on|off | clear
]]

local ADDON_NAME, NS = ...
NS.VERSION = "0.13.4"

local MAX_SCANS_PER_MARKET = 3 -- newest scans kept per realm+faction (about 1 MB each at 50k listings)
local MAX_SCANS_TOTAL = 12 -- hard ceiling on the SavedVariables file across every realm and faction
local AUTO_SCAN_MIN_INTERVAL = 15 * 60 -- seconds; matches the server throttle
local REGION_NAMES = { [1] = "us", [2] = "kr", [3] = "eu", [4] = "tw", [5] = "cn" }

local AHledger = CreateFrame("Frame", "AHledgerFrame")

-- When the game blocks this addon from a protected call it shows a popup naming the addon but
-- not the call. This listener keeps the name, prints it once, and shows it in /ahl status, so
-- a report can say which one. A blocked CVar call also turns the CVar mirror off for the
-- session, since every later mirror write would be blocked the same way.
NS.Forbidden = nil
do
  local guard = CreateFrame("Frame", "AHledgerGuardFrame")
  guard:RegisterEvent("ADDON_ACTION_FORBIDDEN")
  guard:RegisterEvent("ADDON_ACTION_BLOCKED")
  guard:SetScript("OnEvent", function(_, event, addonName, func)
    if addonName ~= ADDON_NAME then return end
    local name = tostring(func or "?")
    if name:find("CVar") then NS.CVarBlocked = true end
    if not NS.Forbidden then
      NS.Forbidden = { fn = name, at = GetServerTime and GetServerTime() or time(), event = event, version = NS.VERSION }
      if AHledgerDB and type(AHledgerDB) == "table" then AHledgerDB.forbidden = NS.Forbidden end
      NS.Print(string.format("the game blocked a call to %s. Nothing is lost; please send that name through ahledger.com/contact so it can be fixed.", name))
    end
  end)
end
local scanning = false
local scanRequestedAt = nil
local scanButton = nil

function NS.Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffff9d2fAHledger|r " .. tostring(msg))
end
local print_ = NS.Print

function NS.Now()
  return GetServerTime and GetServerTime() or time()
end
local now = NS.Now

-- ---------------------------------------------------------------------------------------------
-- Frame slices (0.13.3)
--
-- Long jobs (packing a scan, reading it into the prices, finding its deals) do a slice of work
-- per frame and yield. A slice used to be a row count, 4,000, which on a live house of 150,000
-- listings held the client near 3 frames a second for half a minute after every scan (a player
-- measured it with the client's script profiling). A slice is now time: a job works until its
-- budget is spent, reading the clock every SLICE_CHECK rows.
--
-- The budget adapts to the frame (NS.NextSlice). A frame is measured from one frame's first slice
-- to the next frame's. One longer than SLICE_FRAME_MS cuts the budget to what that frame left
-- (its length less AHledger's work, taken from SLICE_FRAME_MS) and remembers a ceiling just
-- under the budget that overran; one inside it grows the budget by SLICE_GROW_MS, up to the
-- ceiling or SLICE_MAX_MS. Growing slowly and remembering the ceiling matters with vsync: frames
-- come in steps of 16.7 ms, a slice one millisecond too long doubles the frame, and reacting to
-- each frame on its own swung between 60 and 30 frames a second. The ceiling rises again after
-- SLICE_RELAX_FRAMES good frames, in case the game was only busy for a moment. Under a frame cap
-- (or a slow PC) every frame is long and the budget stays at SLICE_MIN_MS.
--
-- The budget is per frame, not per job: after a scan the prices and the deals are read at the
-- same time, and they share it (GetTime is the same all through a frame, which tells the jobs
-- they are in one). Without debugprofilestop (the harness unless it supplies a clock) a slice is
-- the job's fixed row count, as before.
-- ---------------------------------------------------------------------------------------------
local SLICE_FRAME_MS = 25 -- the frame time aimed for while a job runs: 40 frames a second
local SLICE_MIN_MS = 5 -- at 30 frames a second, 5 ms more is barely felt, and a save still ends
local SLICE_MAX_MS = 12
local SLICE_FIRST_MS = 6 -- before there is a frame to measure, or after a pause
local SLICE_GROW_MS = 0.5 -- added per frame inside the target
local SLICE_RELAX_FRAMES = 120 -- good frames before a ceiling rises by a millisecond
local SLICE_GAP_MS = 250 -- a longer gap since the last slice is a pause, not a frame
local SLICE_CHECK = 20 -- rows between clock reads
NS.SLICE_FRAME_MS, NS.SLICE_MIN_MS, NS.SLICE_MAX_MS, NS.SLICE_CHECK = SLICE_FRAME_MS, SLICE_MIN_MS, SLICE_MAX_MS, SLICE_CHECK

-- The next frame's slice from the last one's: `prev` { budget, ceiling, good }, the last frame's
-- length and AHledger's work in it, in ms. Returns a new { budget, ceiling, good }. Pure.
function NS.NextSlice(prev, intervalMs, workedMs)
  local budget = prev and prev.budget or SLICE_FIRST_MS
  local ceiling, good = prev and prev.ceiling or nil, prev and prev.good or 0
  local worked = workedMs or 0
  if intervalMs > SLICE_FRAME_MS then
    if worked > 0 then
      ceiling = math.max(SLICE_MIN_MS, math.min(ceiling or SLICE_MAX_MS, budget - 1))
    end
    budget = math.max(SLICE_MIN_MS, math.min(budget, SLICE_FRAME_MS - (intervalMs - worked)))
    good = 0
  else
    good = good + 1
    if ceiling and good >= SLICE_RELAX_FRAMES then
      ceiling, good = ceiling + 1, 0
      if ceiling >= SLICE_MAX_MS then ceiling = nil end
    end
    budget = math.min(SLICE_MAX_MS, ceiling or SLICE_MAX_MS, budget + SLICE_GROW_MS)
  end
  return { budget = budget, ceiling = ceiling, good = good }
end

-- The clock in milliseconds, or nil. Read at each use so the harness can supply one.
local function sliceClock()
  local f = NS.SliceClock or debugprofilestop
  if not f then return nil end
  local ok, t = pcall(f)
  return ok and tonumber(t) or nil
end

-- The frame the slices are in: when its first slice began, its deadline, what the jobs did, and
-- the controller's state for the next frame.
local sliceFrame = { id = nil, began = nil, deadline = nil, worked = 0, state = nil }

local function frameId()
  local ok, t = pcall(function() return GetTime and GetTime() end)
  return ok and t or nil
end

-- One job's slicer: s:Begin(fallbackRows, every) at the top of a frame's work, s:More() before
-- each row (false once the frame's budget is spent), s:End() when the job stops for the frame.
-- `every` is how many rows go between clock reads (SLICE_CHECK unless a row is heavy).
local Slicer = {}
Slicer.__index = Slicer
function NS.NewSlicer()
  return setmetatable({ rows = 0 }, Slicer)
end
function Slicer:Begin(fallbackRows, every)
  self.rows = 0
  self.fallback = fallbackRows
  self.every = every or SLICE_CHECK
  local t = sliceClock()
  self.began = t
  if not t then
    self.deadline = nil
    return
  end
  local id = frameId()
  local f = sliceFrame
  if not (id and f.id == id and f.deadline) then
    -- A new frame: the last one's length and AHledger's work in it set this one's budget.
    if f.began and t - f.began <= SLICE_GAP_MS then
      f.state = NS.NextSlice(f.state, t - f.began, f.worked)
    else
      f.state = { budget = SLICE_FIRST_MS, ceiling = f.state and f.state.ceiling or nil, good = 0 }
    end
    f.id, f.began, f.worked = id, t, 0
    f.deadline = t + f.state.budget
  end
  self.deadline = f.deadline
end
function Slicer:More()
  local rows = self.rows
  self.rows = rows + 1
  if not self.deadline then return rows < (self.fallback or 4000) end
  if rows == 0 or rows % (self.every or SLICE_CHECK) ~= 0 then return true end
  local t = sliceClock()
  return not t or t < self.deadline
end
function Slicer:End()
  local t = sliceClock()
  if t and self.began then sliceFrame.worked = (sliceFrame.worked or 0) + (t - self.began) end
end

-- Settings, with defaults. Every option lives in AHledgerDB.settings so the sync app can read
-- the contribution switch from the same file it uploads from.
local DEFAULTS = {
  autoScan = true,
  scanButton = true,
  contribute = true,
  observe = true,
  tooltip = true,
  tooltipShift = false,
  tooltipMin = true,
  tooltipChange = true,
  tooltipQuantity = true,
  tooltipVendor = true,
  tooltipDisenchant = true,
  crafting = true,
  market = "", -- empty: detect from realm and faction
  alertSound = true,
  tooltipBags = true,
  postingHelper = true,
  ahColumn = true,
  minimap = true,
  minimapAngle = 200,
  dealsPercent = 30,
  dealsMinValue = 100,
  -- The ledger bar (Bar.lua) and the at-a-glance features added in 0.8.0.
  bar = true,
  barLocked = false,
  barTicker = true,
  barX = 0,
  barY = -4,
  tooltipCompact = false,
  questRewards = true,
  mailSummary = true,
  scanSummary = true,
  vendorFlips = true,
  -- Sell pace (0.9.0): the estimated units sold a day from the price table.
  tooltipPace = true,
  barPace = true,
  dealsSelling = false,
  -- Links to ahledger.com (0.9.2): window footers, the weekly report line, the launch message.
  siteLinks = true,
  -- Profit dots in the profession window's recipe list and the Crafting tab's margin filter (0.9.5).
  craftDots = true,
  craftFilter = false,
  craftFilterPct = 0,
  -- 0.9.10: the Save and upload button after a scan, and the line on opening the auction house
  -- when nobody has scanned this market lately.
  reloadPrompt = true,
  scanNudge = true,
  -- 0.10.0: reload on leaving the auction house after a scan (off until the player says so),
  -- the watchlist kept in step with the account on ahledger.com, craft-or-buy and other-market
  -- lines in tooltips, Shift for the full tooltip block, bag slot dots, the market pulse at
  -- login, and the posting plan.
  autoUpload = false,
  watchSync = true,
  tooltipCraft = true,
  tooltipMarkets = true,
  tooltipShiftMore = true,
  bagDots = true,
  pulse = true,
  postingPlan = true,
  -- 0.11.0: the ledger of posts, sales and purchases, and the undercut check.
  ledger = true,
  undercutCheck = true,
  ledgerDays = 7,
  -- 0.12.0: the players you see, by name, for the PvP ladder on ahledger.com.
  sightings = true,
  -- 0.13.0: a player's PvP rank and kills on their tooltip, and your own Rank Points for the site.
  tooltipPvp = true,
  pvpPoints = true,
}
-- Settings written while something is dragged: not worth a "last change" note each frame.
local SILENT = { minimapAngle = true, barX = true, barY = true }

function NS.Db()
  if type(AHledgerDB) ~= "table" then
    AHledgerDB = {}
    NS.DbCreated = true -- nothing came from disk this session
  end
  AHledgerDB.version = 2
  if type(AHledgerDB.settings) ~= "table" then AHledgerDB.settings = {} end
  for k, v in pairs(DEFAULTS) do
    if AHledgerDB.settings[k] == nil then AHledgerDB.settings[k] = v end
  end
  if type(AHledgerDB.scans) ~= "table" then AHledgerDB.scans = {} end
  if type(AHledgerDB.watch) ~= "table" then AHledgerDB.watch = {} end
  if type(AHledgerDB.tables) ~= "table" then AHledgerDB.tables = {} end
  if type(AHledgerDB.observations) ~= "table" then AHledgerDB.observations = {} end
  -- The client language, so the site keeps names only from English clients (sync 0.2.17 sends it).
  if GetLocale then AHledgerDB.locale = GetLocale() end
  return AHledgerDB
end
local ensureDb = NS.Db

-- Diagnostics: snapshot the settings at load and report any value that drifts from the snapshot
-- without going through NS.SetSetting. Printed at login and by /ahl status.
local snapshot = nil
function NS.Snapshot()
  snapshot = {}
  for k in pairs(DEFAULTS) do snapshot[k] = ensureDb().settings[k] end
end
function NS.Drift(stage)
  if not snapshot then return end
  local db = ensureDb()
  for k in pairs(DEFAULTS) do
    if db.settings[k] ~= snapshot[k] then
      NS.Print(string.format("settings drift at %s: %s was %s, now %s", stage, k, tostring(snapshot[k]), tostring(db.settings[k])))
      snapshot[k] = db.settings[k]
    end
  end
end
function NS.DiagLine()
  return NS.PersistStatus and NS.PersistStatus() or (NS.DbCreated and "saved data: none loaded" or "saved data: loaded from disk")
end

function NS.Setting(key)
  return ensureDb().settings[key]
end

function NS.SetSetting(key, value)
  local db = ensureDb()
  if db.settings[key] ~= value and not SILENT[key] then
    -- Remember the last change and where it came from, for /ahl status and bug reports.
    local from = debugstack and debugstack(2, 1, 0) or ""
    from = (from:match("([^\n]*)") or ""):gsub("^%s+", "")
    db.lastChange = { key = key, value = tostring(value), at = date("%H:%M:%S"), from = from }
  end
  db.settings[key] = value
  if NS.OnSettingChanged then NS.OnSettingChanged(key, value) end
  if NS.PersistSave then NS.PersistSave() end
end

-- Test and PTR clients report a region id outside the retail set; fall back to the login portal.
local function detectRegion()
  local id = GetCurrentRegion and GetCurrentRegion() or nil
  if id and REGION_NAMES[id] then return REGION_NAMES[id] end
  local portal = GetCVar and GetCVar("portal") or nil
  if type(portal) == "string" and #portal > 0 then
    portal = portal:lower()
    if portal == "us" or portal == "eu" or portal == "kr" or portal == "tw" or portal == "cn" then
      return portal
    end
  end
  return "unknown"
end

-- True on the Forever client (1.16 and up; Classic Era is 1.13 to 1.15). The pre-launch realm
-- rule and the US price fallback below only make sense there: Classic Era has realms in every region.
function NS.IsForeverClient()
  local version = GetBuildInfo and GetBuildInfo() or nil
  local minor = tonumber(tostring(version or ""):match("^1%.(%d+)%."))
  return minor ~= nil and minor >= 16
end

-- World of Warcraft: Forever launches at 3 pm Pacific on 4 November 2026 (23:00 UTC); the China
-- servers open an hour earlier by the clock, 6 am China time on 5 November (22:00 UTC).
NS.LAUNCH_AT = 1793833200
NS.LAUNCH_AT_CN = 1793829600
function NS.LaunchAt(region)
  if region == "cn" then return NS.LAUNCH_AT_CN end
  return NS.LAUNCH_AT
end

function NS.ClientInfo()
  local version, build = GetBuildInfo()
  local region = detectRegion()
  local faction = UnitFactionGroup("player") or "unknown"
  local realm = GetRealmName() or "unknown"
  -- Before launch, Forever ran one set of test realms, hosted in the US, and every region's
  -- players were routed to them, but a European account still reported Europe. Scans and prices
  -- for such a realm belong to the US market; up to 0.8.5 they were tagged EU, refused by the
  -- site, and the tooltips looked for an EU price table that does not exist. The English name is
  -- one rule; a Chinese client names those realms in Chinese, so the clock is the other: before
  -- a region's servers open, every Forever realm is a pre-launch realm (0.9.6).
  if NS.IsForeverClient() and (realm:lower():find("^classic beta") or NS.Now() < NS.LaunchAt(region)) then
    region = "us"
  end
  return {
    build = string.format("%s (%s)", tostring(version), tostring(build)),
    region = region,
    faction = faction,
    realm = realm,
  }
end
local clientInfo = NS.ClientInfo

-- Forever is realmless: the realm name carries the ruleset ("... PvE", "... PvP", "... RP",
-- "... RP PvP", "... Hardcore"). Each ruleset is its own megaserver with its own auction house,
-- RP PvP included (0.9.9). European clients use their own words: JcJ (French, Spanish) and JxJ
-- (Portuguese) for PvP, JdR (French), GdR (Italian) and Rol (Spanish) for RP. The site reads
-- realm names the same way.
local function word(r, w) return r:find("%f[%a]" .. w .. "%f[%A]") ~= nil end
local function rulesetFromRealm(realm)
  local r = (realm or ""):lower()
  if r:find("hardcore", 1, true) then return "hardcore" end
  local pvp = r:find("pvp", 1, true) or word(r, "jcj") or word(r, "jxj")
  local rp = word(r, "rp") or word(r, "jdr") or word(r, "gdr") or word(r, "rol")
  if rp and pvp then return "rppvp" end
  if pvp then return "pvp" end
  if rp then return "rp" end
  return "normal"
end
NS.RulesetFromRealm = rulesetFromRealm

-- The market key this character's prices belong to: game/ruleset/faction/region, matching the
-- site's market slugs. The options panel can override it.
function NS.Market()
  local override = NS.Setting("market")
  if type(override) == "string" and override ~= "" then return override end
  return NS.ClientMarket()
end

-- The market of the realm and faction the client is on, whatever the options pin: the one a scan
-- taken here belongs to.
function NS.ClientMarket()
  local info = clientInfo()
  local region = info.region ~= "unknown" and info.region or "us"
  -- Each region is its own economy (Forever opens its EU servers with the US ones), so an EU
  -- character prices on the EU market even before it has prices; showing US prices instead would
  -- be wrong numbers presented as right. Pre-launch realms are US realms (ClientInfo).
  return string.format("forever/%s/%s/%s", rulesetFromRealm(info.realm), (info.faction or "unknown"):lower(), region)
end

-- "forever/pvp/horde/us" -> "PvP Horde (US)", the way the site names markets.
local RULESET_LABEL = { normal = "Normal", pvp = "PvP", rp = "RP", rppvp = "RP PvP", hardcore = "Hardcore" }
function NS.MarketLabel(market)
  market = market or NS.Market()
  local _, ruleset, faction, region = market:match("^([^/]+)/([^/]+)/([^/]+)/([^/]+)$")
  if not ruleset then return market end
  return string.format("%s %s (%s)", RULESET_LABEL[ruleset] or ruleset, faction:gsub("^%l", string.upper), region:upper())
end

-- Gold formatting: 184g 20s 5c, dropping copper above 10g and silver above 1,000g.
function NS.Gold(copper)
  copper = tonumber(copper)
  if not copper then return "-" end
  local neg = copper < 0
  copper = math.abs(math.floor(copper + 0.5))
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  local out
  if g >= 1000 then
    out = string.format("%s|cffffd700g|r", tostring(g):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
  elseif g >= 10 then
    out = s > 0 and string.format("%d|cffffd700g|r %d|cffc7c7cfs|r", g, s) or string.format("%d|cffffd700g|r", g)
  elseif g > 0 then
    local parts = { string.format("%d|cffffd700g|r", g) }
    if s > 0 then parts[#parts + 1] = string.format("%d|cffc7c7cfs|r", s) end
    if c > 0 then parts[#parts + 1] = string.format("%d|cffeda55fc|r", c) end
    out = table.concat(parts, " ")
  elseif s > 0 then
    out = c > 0 and string.format("%d|cffc7c7cfs|r %d|cffeda55fc|r", s, c) or string.format("%d|cffc7c7cfs|r", s)
  else
    out = string.format("%d|cffeda55fc|r", c)
  end
  return (neg and "-" or "") .. out
end

function NS.ItemIdFromLink(link)
  if type(link) ~= "string" then return nil end
  local id = link:match("item:(%d+)")
  return id and tonumber(id) or nil
end

-- ---------------------------------------------------------------------------------------------
-- Scanner
--
-- A scan has three phases, and only one of them can show real progress.
--
-- Waiting: ReplicateItems is one request, and the server says nothing until the whole listing
-- is ready, then fires REPLICATE_ITEM_LIST_UPDATE once. There is no "40% done" to show, so the
-- button shows the one true number, the seconds elapsed, and keeps waiting. There is no cutoff:
-- the old 45 second limit discarded listings that arrived at 46, having already spent the
-- server's once-per-15-minutes allowance. A request the server drops fires
-- AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED, which ends the wait; closing the house ends it too.
--
-- Saving: packing 50,000 rows in one loop froze the client for a moment, so it runs in slices
-- across frames (by time since 0.13.3, see Frame slices), and here the count is real:
-- "Saving 31,000 / 53,074".
--
-- Saved: "saved" means saved in memory. The client writes SavedVariables only at logout and
-- /reload, and AHledger sync reads the disk, so a scan made this session is not sent until one
-- of those happens. The result stays on the button, and everything that reports the scan says
-- to reload until it is.
-- ---------------------------------------------------------------------------------------------

local PACK_CHUNK = 4000 -- listings packed per frame while saving, when there is no clock
local LONG_WAIT_NOTE = 90 -- seconds before chat says once that a wait is long but not dead
local NO_REPLY_S = 180 -- seconds after which the request has almost certainly been dropped
local noReplyNoted = false
local packing = nil -- { index, count, pieces, n, skipped, slicer, all } while a listing is being packed
local ticker = nil
local refusedAt = nil -- when the server last dropped a request
local longWaitNoted = false
  noReplyNoted = false
local finishScan -- defined below packStep, which calls it

-- "53,074". UI.lua has the same, but it loads after this file.
local function comma(n)
  local s = tostring(math.floor(tonumber(n) or 0))
  return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

-- The wall clock when this file loaded. A scan newer than this has not been through a logout
-- or /reload, so it is not on disk yet and sync cannot have uploaded it.
NS.SessionStart = now()

-- The newest scan for this realm and faction. Should the client start a session without its
-- saved variables (the pre-launch client did, after every reload), the time and size of the last
-- scan are mirrored into CVars by Persist.lua and read from there, which keeps the throttle
-- countdown honest across a reload rather than inviting a request the server will refuse.
local function lastScan()
  local db = ensureDb()
  local info = clientInfo()
  for i = #db.scans, 1, -1 do
    local s = db.scans[i]
    if s.realm == info.realm and s.faction == info.faction then return s end
  end
  -- The mirror strips punctuation and spaces from names (Persist.lua), so compare that way.
  local function plain(v) return (tostring(v or ""):gsub("[^%w%./%-]", "")) end
  if db.lastScanAt and plain(db.lastScanRealm) == plain(info.realm) and plain(db.lastScanFaction) == plain(info.faction) then
    return { ts = db.lastScanAt, count = db.lastScanCount or 0, realm = info.realm, faction = info.faction, mirrored = true }
  end
  return nil
end
NS.LastScan = lastScan

-- Seconds until the server is likely to accept another full listing, or 0. The last scan on
-- record explains a refusal while its interval is still running, so the wait counts from it. A
-- refusal after that interval means somebody else spent the allowance (another addon makes the
-- same request), and the full interval from the refusal is the only honest guess.
local function nextScanIn()
  local last = lastScan()
  if last and last.ts then
    local wait = last.ts + AUTO_SCAN_MIN_INTERVAL - now()
    if wait > 0 then return wait end
  end
  if refusedAt then return math.max(0, refusedAt + AUTO_SCAN_MIN_INTERVAL - now()) end
  return 0
end

local function canAutoScan()
  local db = ensureDb()
  if not db.settings.autoScan then return false end
  return nextScanIn() <= 0
end

-- Everything a button or a tooltip needs to describe the scanner, in one place.
--   phase: "idle" | "waiting" | "saving" | "blocked"
function NS.ScanState()
  local state = { phase = "idle" }
  if scanning and packing then
    state.phase = "saving"
    state.packed = packing.index
    state.total = packing.count
  elseif scanning then
    state.phase = "waiting"
    state.elapsed = now() - (scanRequestedAt or now())
  else
    local wait = nextScanIn()
    if wait > 0 then
      state.phase = "blocked"
      state.nextIn = wait
      local last = lastScan()
      state.refused = refusedAt ~= nil and (not last or refusedAt >= (last.ts or 0))
    end
  end
  local last = lastScan()
  if last then
    state.last = last
    state.unsent = (last.ts or 0) >= NS.SessionStart and not last.mirrored
    state.contribute = ensureDb().settings.contribute and true or false
  end
  return state
end

local function minutes(seconds)
  return math.max(1, math.ceil(seconds / 60))
end

-- The text for a scan button in the current state. Pure, so the harness can check it.
function NS.ScanButtonText(state)
  if state.phase == "waiting" then
    -- A listing lands within about ninety seconds. Past three minutes the server has almost
    -- certainly dropped the request without saying so; the wait goes on, since a late listing
    -- is still worth saving, but the button stops pretending it is coming.
    if (state.elapsed or 0) >= NO_REPLY_S then return string.format("No reply %ds", state.elapsed or 0) end
    return string.format("Scanning... %ds", state.elapsed or 0)
  end
  if state.phase == "saving" then return string.format("Saving %s / %s", comma(state.packed or 0), comma(state.total or 0)) end
  if state.phase == "blocked" then
    -- A saved scan reaches the site only after the client writes it to disk, which a reload does.
    -- That matters more than the countdown, which the tooltip and footer still show.
    if state.unsent and state.contribute then return "/reload to send" end
    return string.format("Next scan: %d min", minutes(state.nextIn))
  end
  return "AHledger scan"
end

-- The lines under a scan button or on the minimap tooltip.
function NS.ScanStatusLines(tt, state)
  state = state or NS.ScanState()
  if state.phase == "waiting" then
    if (state.elapsed or 0) >= NO_REPLY_S then
      tt:AddLine("No reply from the server after three minutes: it has probably dropped the request. Close the auction house and open it again to try once the countdown allows.", 1, 1, 1, true)
    else
      tt:AddLine("Waiting for the server's full listing. Large houses take a while; closing the auction house cancels.", 1, 1, 1, true)
    end
  elseif state.phase == "saving" then
    tt:AddLine("Packing the listing.", 1, 1, 1, true)
  elseif state.phase == "blocked" then
    if state.refused then
      tt:AddLine("The server refused the last request. It allows about one full listing every 15 minutes.", 1, 1, 1, true)
    else
      tt:AddLine("The server allows about one full listing every 15 minutes. /ahl scan tries anyway.", 1, 1, 1, true)
    end
  end
  local last = state.last
  if last then
    tt:AddLine(string.format("Last scan: %s listings, %s", comma(last.count or 0), (NS.UI and NS.UI.AgoText(now() - (last.ts or now()))) or ""), 1, 1, 1)
    if state.unsent then
      if ensureDb().settings.contribute then
        tt:AddLine("Not sent yet: type /reload so AHledger sync can upload it.", 1, 0.82, 0.2, true)
      else
        tt:AddLine("Contribution is off; it stays on this machine.", 0.7, 0.7, 0.72, true)
      end
    end
  else
    tt:AddLine("No scan for this realm and faction yet.", 0.7, 0.7, 0.72)
  end
end

-- ---------------------------------------------------------------------------------------------
-- Save and upload (0.9.10)
--
-- The client writes SavedVariables only at logout and /reload, so a scan made this session sits
-- unseen by AHledger sync until one of those happens. ReloadUI() is that write, one click away.
-- It is never called on its own: a player presses the button or types /ahl upload, and never in
-- combat, where the game would refuse it anyway.
-- ---------------------------------------------------------------------------------------------

-- Reloads the interface so the saved file is written. Returns true when it did, false with a
-- chat line when it could not.
function NS.UploadNow()
  if InCombatLockdown and InCombatLockdown() then
    print_("cannot reload in combat; type /reload (or press Save and upload) once the fight is over")
    return false
  end
  if not ReloadUI then
    print_("this client has no ReloadUI; type /reload so AHledger sync can send the scan")
    return false
  end
  print_("saving the scan to disk so AHledger sync can send it...")
  ReloadUI()
  return true
end

-- True while the Save and upload button has a job: a scan from this session is not on disk,
-- contribution is on, and the player has not turned the button off.
function NS.UploadButtonWanted(state)
  state = state or NS.ScanState()
  if not NS.Setting("reloadPrompt") then return false end
  if state.phase ~= "blocked" then return false end
  return state.unsent == true and state.contribute == true
end

-- ---------------------------------------------------------------------------------------------
-- Reload on leaving the house (0.10.0)
--
-- The option autoUpload, off by default: when the auction house closes with a scan from this
-- session still unsent, the interface reloads a moment later, which writes the scan for sync.
-- The player turned it on knowing what it does; it still never runs in combat, and it says so
-- in chat first. Pure apart from the setting, for the harness.
-- ---------------------------------------------------------------------------------------------

local AUTO_UPLOAD_DELAY = 1.5 -- seconds after the house closes, so its frame is gone first

function NS.AutoUploadWanted(state)
  state = state or NS.ScanState()
  if not NS.Setting("autoUpload") then return false end
  if state.phase == "waiting" or state.phase == "saving" then return false end
  return state.unsent == true and state.contribute == true
end

-- Called when the house closes. Returns true when a reload was scheduled.
function NS.AutoUploadOnClose()
  if not NS.AutoUploadWanted() then return false end
  if InCombatLockdown and InCombatLockdown() then
    print_("the scan will be saved for sync when you next reload; not reloading in combat")
    return false
  end
  print_("reloading in a moment to save the scan for AHledger sync (/ahl set autoUpload off stops this)")
  if C_Timer and C_Timer.After then
    C_Timer.After(AUTO_UPLOAD_DELAY, function()
      if NS.AutoUploadWanted() then NS.UploadNow() end
    end)
  else
    NS.UploadNow()
  end
  return true
end

local buttons = {}
local uploadButton = nil
local startTicker -- defined below; the clock runs whenever a button shows something that moves

local function applyButton(b, state)
  b:SetText(NS.ScanButtonText(state))
  if state.phase == "idle" then b:Enable() else b:Disable() end
end

-- The Save and upload button stands where the scan button does, while that one would only say
-- "/reload to send": one slot, no overlap with the house's own search bar.
local function placeUploadButton(state)
  if not uploadButton or not scanButton then return end
  if NS.UploadButtonWanted(state) and NS.Setting("scanButton") then
    scanButton:Hide()
    uploadButton:Show()
  else
    uploadButton:Hide()
  end
end

local function setButtonState()
  local state = NS.ScanState()
  for _, b in ipairs(buttons) do
    if b == scanButton and not NS.Setting("scanButton") then
      b:Hide()
    else
      b:Show()
      applyButton(b, state)
    end
  end
  placeUploadButton(state)
  if NS.RefreshScanFooter then NS.RefreshScanFooter() end
  if state.phase ~= "idle" then startTicker() end
end
NS.RefreshScanButton = setButtonState

-- Any button that starts a scan registers here so every one of them shows the same state.
function NS.RegisterScanButton(b)
  buttons[#buttons + 1] = b
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    NS.ScanStatusLines(GameTooltip)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  applyButton(b, NS.ScanState())
end

-- One clock while anything on the button is counting: seconds up while waiting, minutes down
-- while blocked. Stops on its own when there is nothing to count.
startTicker = function()
  if ticker or not (C_Timer and C_Timer.NewTicker) then return end
  ticker = C_Timer.NewTicker(1, function()
    local state = NS.ScanState()
    if state.phase == "waiting" and state.elapsed >= LONG_WAIT_NOTE and not longWaitNoted then
      longWaitNoted = true
      print_(string.format("still waiting after %ds. The server sends the listing all at once when it is ready; closing the auction house cancels", LONG_WAIT_NOTE))
    end
    if state.phase == "waiting" and state.elapsed >= NO_REPLY_S and not noReplyNoted then
      noReplyNoted = true
      print_("no reply from the server after three minutes; it has probably dropped the request. Close the auction house and open it again to try once the countdown allows")
    end
    setButtonState()
    if state.phase == "idle" then
      ticker:Cancel()
      ticker = nil
    end
  end)
end

local function endScan()
  scanning = false
  packing = nil
  setButtonState()
end

-- Packs one slice of listings, then yields a frame, until the whole list is packed. The
-- replicate list stays readable until the next request or the house closes; once the house
-- closes (`all`) the rest is packed at once rather than lost. Each slice's rows are joined into
-- one piece as it ends, so the save at the end joins one piece per frame instead of every row.
local function packStep()
  local p = packing
  if not p then return end
  local ok, err = pcall(function()
    local getInfo, getTimeLeft = C_AuctionHouse.GetReplicateItemInfo, C_AuctionHouse.GetReplicateItemTimeLeft
    local slicer, all = p.slicer, p.all
    if not all then
      -- Saving now spans many frames. A listing replaced meanwhile (another addon's scan once the
      -- server allows it) would mix two listings in one scan: start again on the new one. One
      -- cleared is a scan lost, and is said so rather than saved short.
      local live = C_AuctionHouse.GetNumReplicateItems and C_AuctionHouse.GetNumReplicateItems()
      if live and live ~= p.count then
        if live <= 0 then
          p.cleared = true
          return
        end
        p.index, p.count, p.pieces, p.n, p.skipped = 0, live, {}, 0, 0
      end
      slicer:Begin(PACK_CHUNK)
    end
    local parts, k = {}, 0
    local index, count = p.index, p.count
    while index < count and (all or slicer:More()) do
      local _, _, stack, _, _, _, _, _, _, buyout, bid, _, _, _, _, _, itemID = getInfo(index)
      if itemID and itemID > 0 and stack and stack > 0 then
        local timeLeft = getTimeLeft(index) or 0
        k = k + 1
        -- Prices are written with %.0f, not %d: the client's %d is a 32-bit integer, and one
        -- listing at 99,999,999,999,999 copper (somebody's joke, or a mistake) threw "integer
        -- overflow" and took the whole scan with it. A number that large is still a number;
        -- what to do with it is decided at upload, where anything past the copper cap is dropped.
        parts[k] = string.format("%d:%d:%.0f:%.0f:%d", itemID, stack, tonumber(buyout) or 0, tonumber(bid) or 0, timeLeft)
      else
        p.skipped = p.skipped + 1
      end
      index = index + 1
    end
    if k > 0 then
      p.pieces[#p.pieces + 1] = table.concat(parts, ";")
      p.n = p.n + k
    end
    p.index = index
    if not all then slicer:End() end
  end)
  if not ok then
    endScan()
    print_("the listing could not be read (" .. tostring(err) .. "); scan discarded")
    return
  end
  if p.cleared then
    endScan()
    print_("the listing was cleared before it was saved; scan discarded. Try /ahl scan again once the countdown allows")
    return
  end
  setButtonState()
  if p.index >= p.count then
    finishScan()
  elseif C_Timer and C_Timer.After then
    C_Timer.After(0, packStep)
  else
    packStep()
  end
end

finishScan = function()
  local p = packing
  local data, n, skipped = table.concat(p.pieces, ";"), p.n, p.skipped
  if n == 0 then
    -- Saving it would record the house as empty and start the countdown for nothing.
    endScan()
    print_("the listing arrived empty; nothing saved. If the house is not actually empty, try /ahl scan again")
    return
  end
  local db = ensureDb()
  local info = clientInfo()
  local scan = {
    realm = info.realm,
    faction = info.faction,
    region = info.region,
    ts = now(),
    build = info.build,
    addon = NS.VERSION,
    full = true,
    count = n,
    data = data,
  }
  table.insert(db.scans, scan)
  local perMarket = 0
  for i = #db.scans, 1, -1 do
    local s = db.scans[i]
    if s.realm == scan.realm and s.faction == scan.faction then
      perMarket = perMarket + 1
      if perMarket > MAX_SCANS_PER_MARKET then table.remove(db.scans, i) end
    end
  end
  while #db.scans > MAX_SCANS_TOTAL do table.remove(db.scans, 1) end
  db.lastScanAt = scan.ts
  db.lastScanCount = n
  db.lastScanRealm = scan.realm
  db.lastScanFaction = scan.faction
  refusedAt = nil
  endScan()
  if NS.PersistSave then NS.PersistSave(true) end
  -- Tooltips take their lowest prices and listed counts from this scan as soon as it is read
  -- (0.13.1), without waiting for the reload that sends it and the table built from it.
  local used = NS.UseOwnScan and NS.UseOwnScan(scan) or false
  local tail = " Contribution is off; it stays on this machine."
  if db.settings.contribute then
    tail = db.settings.reloadPrompt
      and " Type /reload (or press Save and upload) so sync can send it."
      or " Type /reload so AHledger sync can upload it."
  end
  print_(string.format("scan saved: %s listings on %s (%s)%s.%s%s",
    comma(n), info.realm, info.faction, skipped > 0 and string.format(", %d without item ids skipped", skipped) or "",
    used and " Your prices use it now." or "", tail))
  -- What the scan found, right here in chat, so the scan button pays off without opening anything.
  if db.settings.scanSummary and NS.DealSummary and NS.ScanSummaryText then
    local function say()
      local ok, text = pcall(function() return NS.ScanSummaryText(NS.DealSummary()) end)
      if ok and text then print_(text) end
      -- Once per weekly report, the line to read it (Site.lua; off with siteLinks).
      local nudge = NS.ReportNudge and NS.ReportNudge(db, time and time() or nil)
      if nudge then print_(nudge) end
    end
    -- The deals need the scan read through (Deals.lua), which takes a few frames on a full house.
    if NS.WithScanMinima then NS.WithScanMinima(scan, say) else say() end
  end
  if NS.RefreshBar then NS.RefreshBar() end
end

-- The player's own scan has been read into the prices (Prices.lua): redraw what shows them, and
-- let the watchlist see the fresh lowest prices.
function NS.OnPricesChanged()
  if NS.RefreshWindow then NS.RefreshWindow() end
  if NS.RefreshBar then NS.RefreshBar() end
  if NS.RefreshBroker then NS.RefreshBroker() end
  if NS.CheckAlerts then NS.CheckAlerts() end
end

local function beginPacking()
  local count = C_AuctionHouse.GetNumReplicateItems() or 0
  packing = { index = 0, count = count, pieces = {}, n = 0, skipped = 0, slicer = NS.NewSlicer() }
  setButtonState()
  packStep()
end

local function startScan(manual)
  if scanning then
    if manual then print_("a scan is already running") end
    return
  end
  if not C_AuctionHouse or not C_AuctionHouse.ReplicateItems then
    print_("this client does not expose C_AuctionHouse.ReplicateItems; scanning is unavailable")
    return
  end
  if not AuctionHouseFrame and not AuctionFrame then
    print_("open the auction house first")
    return
  end
  local wait = nextScanIn()
  if wait > 0 and manual then
    -- A typed command is a decision; the buttons are disabled while this is true.
    print_(string.format("trying, but the server allows about one full listing every 15 minutes and the last was %d min ago", minutes(AUTO_SCAN_MIN_INTERVAL - wait)))
  end
  scanning = true
  packing = nil
  longWaitNoted = false
  noReplyNoted = false
  scanRequestedAt = now()
  setButtonState()
  startTicker()
  if manual then print_("requesting the full listing from the server...") end
  C_AuctionHouse.ReplicateItems()
end
NS.StartScan = startScan

local function ensureButton()
  if scanButton then
    setButtonState()
    return
  end
  local parent = AuctionHouseFrame or AuctionFrame
  if not parent then return end
  -- On the modern house the button joins the search bar, in the gap between the search box
  -- and the Filter button, as a child of the bar so it is drawn with the bar's own buttons.
  -- Right of Search there is no room: that button already touches the frame's edge. In the
  -- title bar the Forever client drew its border over the button: present and invisible.
  local bar = AuctionHouseFrame and AuctionHouseFrame.SearchBar
  if type(bar) ~= "table" then bar = nil end
  local home = bar or parent
  scanButton = CreateFrame("Button", "AHledgerScanButton", home, "UIPanelButtonTemplate")
  scanButton:SetSize(120, 22)
  if bar then
    local filter = type(bar.FilterButton) == "table" and bar.FilterButton or nil
    local search = type(bar.SearchButton) == "table" and bar.SearchButton or nil
    if filter then
      scanButton:SetPoint("RIGHT", filter, "LEFT", -12, 0)
      -- The search box stretches towards the Filter button, so it would run on under the
      -- scan button. Whatever anchor gives the box its right edge is re-pointed at the scan
      -- button, with the same gap the bar keeps between its own buttons; a box with no
      -- right anchor gets one.
      local box = type(bar.SearchBox) == "table" and bar.SearchBox or nil
      if box and box.GetNumPoints and box.GetPoint and box.ClearAllPoints then
        local points, hasRight = {}, false
        for i = 1, box:GetNumPoints() do
          local point, rel, relPoint, x, y = box:GetPoint(i)
          if point then
            if point:find("RIGHT") then
              hasRight = true
              points[#points + 1] = { point, scanButton, (point:gsub("RIGHT", "LEFT")), -12, 0 }
            else
              points[#points + 1] = { point, rel, relPoint, x, y }
            end
          end
        end
        if #points > 0 then
          box:ClearAllPoints()
          for _, p in ipairs(points) do box:SetPoint(p[1], p[2], p[3], p[4], p[5]) end
          if not hasRight then box:SetPoint("RIGHT", scanButton, "LEFT", -12, 0) end
        end
      end
    elseif search then
      scanButton:SetPoint("RIGHT", search, "LEFT", -8, 0)
    else
      scanButton:SetPoint("RIGHT", bar, "RIGHT", -8, 0)
    end
  else
    scanButton:SetPoint("TOPLEFT", parent, "TOPLEFT", 70, -12)
  end
  local level = home.GetFrameLevel and home:GetFrameLevel()
  if level then scanButton:SetFrameLevel(level + 5) end
  scanButton:SetScript("OnClick", function() startScan(true) end)
  NS.RegisterScanButton(scanButton)
  -- Save and upload: the same slot, shown in place of the scan button while a scan from this
  -- session waits for a reload (UI.lua loads after this file, so its helper is looked up here).
  if NS.UI and NS.UI.Button then
    uploadButton = NS.UI.Button(home, "Save and upload", 120, NS.UploadNow)
  else
    uploadButton = CreateFrame("Button", nil, home, "UIPanelButtonTemplate")
    uploadButton:SetSize(120, 22)
    uploadButton:SetText("Save and upload")
    uploadButton:SetScript("OnClick", NS.UploadNow)
  end
  _G.AHledgerUploadButton = uploadButton
  uploadButton:SetAllPoints(scanButton)
  if level then uploadButton:SetFrameLevel(level + 5) end
  uploadButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Save and upload", 1, 1, 1)
    GameTooltip:AddLine("Reloads the interface, which writes the scan to disk so AHledger sync can send it to ahledger.com. The same as typing /reload.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  uploadButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
  uploadButton:Hide()
  setButtonState()
end

-- ---------------------------------------------------------------------------------------------
-- Nudges (0.9.10): one line when the auction house opens and nobody has scanned this market
-- lately, and one line, ever, inviting a contributor to put a name on their scans.
-- ---------------------------------------------------------------------------------------------

local STALE_TABLE = 6 * 3600 -- seconds; past this the market counts as unscanned
local nudgedMarkets = {} -- markets already nudged this session

-- The line for a market whose prices are missing or old, or nil. Pure, for the harness: `age`
-- is the table's age in seconds, nil when there is no live table (none, or the shipped snapshot).
function NS.ScanNudgeText(market, age)
  local label = NS.MarketLabel(market)
  if age == nil then
    return string.format("%s has no scan since launch yet. Scan now and your prices are the ones everyone sees.", label)
  end
  if age < STALE_TABLE then return nil end
  return string.format("Nobody has scanned %s in %d hours. Scan now and your prices are the ones everyone sees.", label, math.floor(age / 3600))
end

-- Once per session per market, when the house opens. Returns the line printed, or nil.
function NS.ScanNudge(market)
  market = market or NS.Market()
  if not NS.Setting("scanNudge") or nudgedMarkets[market] then return nil end
  if not NS.TableFor then return nil end -- Prices.lua not loaded: nothing to judge
  local t = NS.TableFor(market)
  local age = nil
  if t and not (NS.TableIsSeed and NS.TableIsSeed(market)) then
    age = NS.TableAge and NS.TableAge(market) or nil
    if age == nil then return nil end -- a table with no date is not one to call stale
  end
  local line = NS.ScanNudgeText(market, age)
  if not line then return nil end
  nudgedMarkets[market] = true
  print_(line)
  return line
end

-- The invitation to the contributor leaderboard, once the first contribution with a scan in it
-- is seen (sync writes the numbers into AHledger_Data.lua). Marks db.optInNudge and returns the
-- line, or nil. Pure apart from the flag, for the harness.
function NS.OptInNudge(db, c)
  if db.optInNudge then return nil end
  if type(c) ~= "table" or (tonumber(c.scans) or 0) < 1 then return nil end
  db.optInNudge = true
  local lead = ""
  local rank, total = tonumber(c.rank), tonumber(c.contributors)
  if rank and rank > 0 and total and total > 0 then
    lead = string.format("You rank %d of %d contributors this week. ", rank, total)
  end
  return lead .. "Your scans are on ahledger.com. Put a name on them: choose one under Contributor leaderboard on your account page (ahledger.com/account)."
end

-- Events the scanner answers; the frame's handler below routes them here.
function NS.ScanEvent(event)
  if event == "AUCTION_HOUSE_SHOW" then
    ensureButton()
    -- Why the scan matters, before the auto scan runs: the market is unscanned or going stale.
    pcall(NS.ScanNudge)
    if canAutoScan() then startScan(false) end
    startTicker()
  elseif event == "AUCTION_HOUSE_CLOSED" then
    if scanning and packing then
      -- The listing is already here; finish packing it in one go rather than lose it.
      packing.all = true
      packStep()
      if scanning then
        endScan()
        print_("auction house closed while the listing was being saved; scan discarded")
      end
    elseif scanning then
      endScan()
      print_("auction house closed before the listing arrived; scan discarded")
    end
    -- With autoUpload on, a scan from this session goes to disk now rather than at logout.
    pcall(NS.AutoUploadOnClose)
  elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
    if scanning and not packing then
      beginPacking()
    elseif not scanning and (AuctionHouseFrame or AuctionFrame) then
      -- Nobody here asked, or the wait was ended by a refusal that turned out to be for some
      -- other request. Either way the full listing is on the client now, and another addon's
      -- scan is as good as ours. One saved a moment ago is the same listing; skip that.
      local last = lastScan()
      if not last or (now() - (last.ts or 0)) >= 60 then
        print_("a full listing arrived without being asked for here; saving it")
        scanning = true
        scanRequestedAt = now()
        beginPacking()
      end
    end
  elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
    if scanning and not packing then
      refusedAt = now()
      endScan()
      print_(string.format("the server refused the request; it allows about one full listing every 15 minutes. Next scan in %d min", minutes(nextScanIn())))
      startTicker()
    end
  end
end

-- ---------------------------------------------------------------------------------------------
-- Merchants
-- ---------------------------------------------------------------------------------------------

-- price, stack size, number available and whether it costs something other than money, for one
-- merchant row, from C_MerchantFrame.GetItemInfo where the client has it (a table) and the old
-- GetMerchantItemInfo global otherwise. nil when neither answers. A client without the global
-- raised "attempt to call a nil value" at every vendor up to 0.8.8.
function NS.MerchantItem(index)
  if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
    local ok, info = pcall(C_MerchantFrame.GetItemInfo, index)
    if ok and type(info) == "table" then
      return info.price, info.stackCount, info.numAvailable, info.hasExtendedCost
    end
  end
  if GetMerchantItemInfo then
    local _, _, price, quantity, available, _, _, extendedCost = GetMerchantItemInfo(index)
    return price, quantity, available, extendedCost
  end
  return nil
end

-- The first error a guarded handler caught this session, for /ahl status and support: what
-- failed and the message, never shown as a popup. A note from another version is dropped.
NS.LastError = nil
function NS.NoteError(what, err)
  if NS.LastError then return end
  local msg = tostring(err or "unknown"):gsub("^.-AddOns[\\/]", ""):sub(1, 200)
  NS.LastError = { what = what, msg = msg, at = GetServerTime and GetServerTime() or time(), version = NS.VERSION }
  if type(AHledgerDB) == "table" then AHledgerDB.lastError = NS.LastError end
end

function NS.Status()
  local db = ensureDb()
  local info = clientInfo()
  local last = lastScan()
  local market = NS.Market()
  local blocked = NS.Forbidden or db.forbidden
  if blocked and blocked.fn and blocked.version ~= NS.VERSION then
    -- A block an earlier version ran into is not this version's problem; stop asking for it.
    blocked = nil
    db.forbidden = nil
  end
  if blocked and blocked.fn then
    print_(string.format("blocked call: %s (%s). Send this line through ahledger.com/contact.", blocked.fn, blocked.at and date("%Y-%m-%d %H:%M", blocked.at) or "time unknown"))
  end
  local caught = NS.LastError or db.lastError
  if caught and caught.version ~= NS.VERSION then
    caught = nil
    db.lastError = nil
  end
  if caught and caught.msg then
    print_(string.format("caught error in %s: %s. Send this line through ahledger.com/contact.", caught.what or "?", caught.msg))
  end
  print_(string.format("v%s | %s %s %s | market %s | auto-scan %s | contribute %s | %d scan(s) stored | %d source line(s) | %d quest(s)",
    NS.VERSION, info.realm, info.faction, info.region, market,
    db.settings.autoScan and "on" or "off", db.settings.contribute and "on" or "off", #db.scans,
    NS.ObservationCount and NS.ObservationCount() or 0, NS.QuestCount and NS.QuestCount() or 0))
  local changed = {}
  for k, d in pairs(DEFAULTS) do
    if db.settings[k] ~= d then changed[#changed + 1] = k .. "=" .. tostring(db.settings[k]) end
  end
  table.sort(changed)
  print_("options changed from default: " .. (#changed > 0 and table.concat(changed, ", ") or "none"))
  print_(NS.DiagLine())
  local t = NS.TableFor(market)
  if t then
    if t.seed then
      print_(string.format("price table: %d items, the %s snapshot shipped with the addon; install AHledger sync from ahledger.com/download for live prices", t.count or 0, NS.TableDate(market) or "release"))
    else
      print_(string.format("price table: %d items, newest scan in it %d min ago", t.count or 0, math.floor(math.max(0, now() - (t.updated or now())) / 60)))
    end
  else
    print_("no price table for this market yet: run AHledger sync, or paste one with /ahl import")
  end
  if NS.OwnScanInUse and NS.OwnScanInUse(market) then
    print_(string.format("lowest prices, medians and listed counts come from your scan %s until a newer price table loads", NS.UI.AgoText(NS.TableAge(market) or 0)))
  end
  if last then
    local age = now() - (last.ts or 0)
    print_(string.format("last scan here: %d listings, %d min ago", last.count or 0, math.floor(age / 60)))
  else
    print_(string.format("no scan stored on this PC for %s %s yet%s; open the auction house and /ahl scan", info.realm, info.faction, t and " (the price table above is from other players' scans)" or ""))
  end
  local c = NS.ContributionText and NS.ContributionText(NS.Contribution and NS.Contribution())
  if c then print_(c) end
  if NS.ObserveFullness then
    local f = NS.ObserveFullness()
    if f >= 0.5 then
      print_(string.format("item source table %d%% full; the saved file is written at logout or /reload, which is when sync can send it", math.floor(f * 100)))
    end
  end
end

SLASH_AHLEDGER1 = "/ahledger"
SLASH_AHLEDGER2 = "/ahl"
SlashCmdList["AHLEDGER"] = function(msg)
  local cmd, arg = msg:match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()
  local db = ensureDb()
  if cmd == "scan" then
    startScan(true)
  elseif cmd == "upload" then
    NS.UploadNow()
  elseif cmd == "status" then
    NS.Status()
  elseif cmd == "import" then
    if NS.ShowImport then NS.ShowImport() end
  elseif cmd == "watch" then
    if NS.WatchCommand then NS.WatchCommand(arg) end
  elseif cmd == "bar" then
    if NS.BarCommand then NS.BarCommand(arg) end
  elseif cmd == "set" then
    local key, value = (arg or ""):match("^(%S+)%s*(%S*)$")
    if key and DEFAULTS[key] ~= nil and type(DEFAULTS[key]) == "boolean" then
      value = (value or ""):lower()
      local v = value == "on" or value == "true" or value == "1"
      if value == "" then v = not db.settings[key] end
      NS.SetSetting(key, v)
      print_(key .. ": " .. (v and "on" or "off"))
    else
      local keys = {}
      for k, d in pairs(DEFAULTS) do if type(d) == "boolean" then keys[#keys + 1] = k end end
      table.sort(keys)
      print_("usage: /ahl set <" .. table.concat(keys, "|") .. "> on|off")
    end
  elseif cmd == "market" then
    local v = (arg or ""):lower()
    if v == "" or v == "detect" then NS.SetSetting("market", "") else NS.SetSetting("market", v) end
    print_("market: " .. NS.MarketLabel(NS.Market()) .. (NS.Setting("market") == "" and " (detected)" or " (pinned)"))
  elseif cmd == "auto" then
    arg = (arg or ""):lower()
    if arg == "on" then db.settings.autoScan = true
    elseif arg == "off" then db.settings.autoScan = false end
    print_("auto-scan " .. (db.settings.autoScan and "on" or "off"))
  elseif cmd == "clear" then
    db.scans = {}
    if NS.ForgetOwnScan then NS.ForgetOwnScan() end
    print_("stored scans cleared")
  elseif cmd == "" then
    if NS.ToggleWindow then NS.ToggleWindow() else NS.Status() end
  elseif cmd == "deals" or cmd == "bags" or cmd == "craft" or cmd == "crafting" or cmd == "ledger" then
    if NS.OpenWindow then NS.OpenWindow(cmd == "crafting" and "craft" or cmd) end
  elseif cmd == "options" or cmd == "config" then
    if NS.OpenOptions then NS.OpenOptions() else NS.Status() end
  elseif cmd == "link" then
    if NS.LinkCommand then NS.LinkCommand(arg) end
  elseif cmd == "pace" then
    for _, line in ipairs(NS.PaceHelp and NS.PaceHelp() or {}) do print_(line) end
  elseif cmd == "pulse" then
    if NS.MarketPulse then
      if not NS.MarketPulse(true) then print_("nothing has moved since the last price table, or there is no earlier table to compare with yet") end
    end
  else
    print_("commands: /ahl (window) | deals | bags | craft | ledger | options | scan | upload | status | pace | pulse | link [item] | import | watch add|remove|alert | bar [lock|unlock|reset] | set <option> on|off | market <key|detect> | auto on|off | clear")
  end
end

AHledger:RegisterEvent("ADDON_LOADED")
AHledger:RegisterEvent("PLAYER_LOGIN")
AHledger:RegisterEvent("PLAYER_LOGOUT")
AHledger:RegisterEvent("AUCTION_HOUSE_SHOW")
AHledger:RegisterEvent("AUCTION_HOUSE_CLOSED")
AHledger:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
AHledger:RegisterEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")

AHledger:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 == ADDON_NAME then
      ensureDb()
      -- A call blocked while the files were loading was noted before saved data existed.
      if NS.Forbidden and not AHledgerDB.forbidden then AHledgerDB.forbidden = NS.Forbidden end
      if NS.PersistRestore then NS.PersistRestore() end
      if NS.Init then NS.Init() end
    elseif arg1 == "Blizzard_AuctionUI" or arg1 == "Blizzard_AuctionHouseUI" then
      ensureButton()
    elseif arg1 == "Blizzard_TradeSkillUI" or arg1 == "Blizzard_CraftUI" or arg1 == "Blizzard_Professions" then
      if NS.HookCrafting then NS.HookCrafting() end
    end
  elseif event == "PLAYER_LOGIN" then
    local market = NS.Market()
    if NS.TableIsSeed and NS.TableIsSeed(market) then
      print_(string.format("v%s loaded. %s. /ahl for options.", NS.VERSION, NS.SeedNote(market)))
    elseif NS.TableFor and NS.TableFor(market) then
      -- The scan the prices are about to take up (below) is the one to name, if there is one.
      local mine = NS.LatestLocalScan and NS.LatestLocalScan()
      local t = NS.TableFor(market)
      local text = NS.PricesAgeText(market) or "no scan yet"
      if mine and mine.ts and market == NS.ClientMarket() and (t.seed or (t.updated or 0) < mine.ts) then
        text = "your scan " .. NS.UI.AgoText(math.max(0, now() - mine.ts))
      end
      print_(string.format("v%s loaded. Prices for %s: %s. /ahl for options.", NS.VERSION, NS.MarketLabel(market), text))
    else
      print_(string.format("v%s loaded. No price table for %s yet: run AHledger sync, or paste one with /ahl import. /ahl for options.", NS.VERSION, NS.MarketLabel(market)))
    end
    if NS.DbCreated and NS.PersistState == "restored" then
      print_("your saved options and watchlist were not loaded by the game this time; AHledger restored them from its backup.")
    end
    -- Once ever: the first time sync reports a scan of this player's on the site (Bar.lua reads
    -- the numbers from the data file).
    local invite = NS.OptInNudge(ensureDb(), NS.Contribution and NS.Contribution() or nil)
    if invite then print_(invite) end
    -- The account watchlist sync wrote into the data file, and what moved since the last table.
    if NS.CrossMarketReset then NS.CrossMarketReset() end
    -- A scan of the player's newer than the table that loaded (sent by the last reload, not yet
    -- in a table sync has brought down): the prices use it, read over the next frames.
    if NS.UseOwnScan and NS.LatestLocalScan then pcall(NS.UseOwnScan, NS.LatestLocalScan()) end
    if NS.WatchSyncFromData then pcall(NS.WatchSyncFromData) end
    if NS.MarketPulse then pcall(NS.MarketPulse) end
    -- Safety net: mirror every minute in case a change slipped past the explicit saves.
    if NS.PersistSave and C_Timer and C_Timer.After then
      local function tick()
        NS.PersistSave(true)
        C_Timer.After(60, tick)
      end
      C_Timer.After(60, tick)
    end
    if NS.OnLogin then NS.OnLogin() end
  elseif event == "PLAYER_LOGOUT" then
    -- When this file was last written (logout and /reload both come through here), so sync and
    -- the site know which watchlist changes the saved file already carries (Watchlist.lua).
    ensureDb().savedAt = now()
    if NS.PersistSave then NS.PersistSave(true) end
  else
    NS.ScanEvent(event)
  end
end)
