--[[
  Options panel (/ahl) and the disenchant estimate.

  The panel uses the Settings API where the client has it (Classic Era 1.15+ and Forever) and
  falls back to an Interface Options page elsewhere. Every switch is a key in AHledgerDB.settings.
]]
local _, NS = ...
-- Modern clients (the Forever beta runs the Mainline UI) moved item info under C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local OPTIONS = {
  { key = "tooltip", short = "Prices in item tooltips", label = "Show prices in item tooltips", tip = "The AHledger line on every item tooltip." },
  { key = "tooltipMin", short = "Tooltip: minimum buyout", label = "Tooltip: show minimum buyout", tip = "Beside the median." },
  { key = "tooltipChange", short = "Tooltip: 7-day change", label = "Tooltip: show 7-day change", tip = "Median now against the 7-day median." },
  { key = "tooltipQuantity", short = "Tooltip: units listed", label = "Tooltip: show units listed", tip = "How many are on the auction house right now." },
  { key = "tooltipPace", short = "Tooltip: AH sales speed", label = "Tooltip: show how fast it sells on the auction house", tip = "Sells fast, steadily, slowly or barely, with the estimated units sold a day and how soon the current listings would clear. ahledger.com estimates it from players' scans; it leans low. /ahl pace explains it." },
  { key = "tooltipVendor", short = "Tooltip: vendor sell price", label = "Tooltip: show vendor sell price", tip = "" },
  { key = "tooltipDisenchant", short = "Tooltip: disenchant value", label = "Tooltip: show disenchant value", tip = "Expected value of the materials at current prices, for uncommon and better gear." },
  { key = "crafting", short = "Crafting margins", label = "Crafting margins in profession windows", tip = "Reagent cost, result value, and margin under the recipe." },
  { key = "autoScan", short = "Scan the auction house automatically", label = "Scan the auction house automatically", tip = "One full scan when you open the auction house, at most every 15 minutes." },
  { key = "scanButton", short = "Scan button on the auction house", label = "Show the scan button on the auction house", tip = "" },
  { key = "contribute", short = "Contribute scans to ahledger.com", label = "Contribute scans to ahledger.com", tip = "Lets AHledger sync upload your scans. A scan contains listings only: no character, account, or chat data. Turn off to keep scans on this machine." },
  { key = "observe", short = "Contribute item sources", label = "Contribute item sources (drops, vendors, quests, fishing)", tip = "Notes which creature, chest, vendor or quest gave which item, and the zone, so item pages on ahledger.com can say where things come from. Source ids, names, zones, items and vendor prices only: nothing about your character. Needs Contribute scans on." },
  { key = "alertSound", short = "Sound for watchlist alerts", label = "Play a sound for watchlist alerts", tip = "" },
  { key = "tooltipBags", short = "Tooltip: bag count and value", label = "Tooltip: show how many you have and their value", tip = "Count across bags and bank, valued at the market median." },
  { key = "postingHelper", short = "Auction house: posting helper", label = "Auction house: price panel when selling", tip = "Median, minimum, range and buttons that fill the price field. Posting stays your click." },
  { key = "ahColumn", short = "Auction house: price column in results", label = "Auction house: median and percent in browse results", tip = "Each result row shows the median and how far the listing sits from it." },
  { key = "minimap", short = "Minimap button", label = "Show the minimap button", tip = "Left-click opens the window, right-click scans. Drag it around the minimap's edge." },
  { key = "bar", short = "Ledger bar", label = "Show the ledger bar", tip = "A strip with your bags at median, gold this session, watchlist alerts, deals in your latest scan, and a watchlist ticker. Drag it anywhere; each number opens its tab. /ahl bar toggles it." },
  { key = "barLocked", short = "Lock the ledger bar", label = "Lock the ledger bar in place", tip = "Stops drags from moving it. /ahl bar unlock or the right-click menu on the AH mark undoes this." },
  { key = "barPace", short = "Ledger bar: AH sales speed", label = "Ledger bar: show auction house sales speed", tip = "How much of your bags sells fast on the auction house, how many deals sell, and how fast each watchlist item sells." },
  { key = "barTicker", short = "Ledger bar: watchlist ticker", label = "Ledger bar: walk the watchlist", tip = "The last segment shows one watched item at a time with its median and 7-day change, changing every few seconds." },
  { key = "tooltipCompact", short = "Tooltip: compact, one line and a verdict", label = "Tooltip: compact block", tip = "Replaces the full block with one line (median, 7-day change, units listed) and a verdict: Auction it or Vendor it. The other tooltip switches still apply." },
  { key = "questRewards", short = "Quest rewards: mark the best value", label = "Quest rewards: mark the best value", tip = "When a quest offers a choice, each option shows its worth (median or vendor, whichever is more) and the best one is marked." },
  { key = "mailSummary", short = "Mailbox: auction summary in chat", label = "Mailbox: one line on what the auction house sent", tip = "On opening the mailbox: how many sold and for how much, how many expired, outbid, won or cancelled. Nothing is opened or taken." },
  { key = "scanSummary", short = "Scan: deals in chat when it finishes", label = "Scan: say what deals it found", tip = "After a scan saves, one line with the number of deals and the best three." },
  { key = "siteLinks", short = "Links to ahledger.com", label = "Show links to ahledger.com pages", tip = "One muted line at the foot of the Deals, Crafting and Watchlist tabs, the weekly market report once after a scan, and one launch message. /ahl link and ctrl+right-click on a row work either way." },
  { key = "vendorFlips", short = "Vendors: mark items worth flipping", label = "Vendors: mark items that sell for more at auction", tip = "At a merchant, an item whose median is well above its vendor price shows the profit per purchase and the stock left when limited." },
}

NS.OPTIONS = OPTIONS

local category = nil

local function registerWithSettingsApi()
  local cat, layout = Settings.RegisterVerticalLayoutCategory("AHledger")
  category = cat
  for _, o in ipairs(OPTIONS) do
    local variable = "AHLEDGER_" .. o.key:upper()
    local function apply(v)
      v = v and true or false
      if NS.Setting(o.key) ~= v then
        NS.SetSetting(o.key, v)
        NS.Print(string.format("%s: %s", o.label, v and "on" or "off"))
      end
    end
    local setting = Settings.RegisterProxySetting(cat, variable, Settings.VarType.Boolean, o.label, NS.Setting(o.key) and true or false,
      function() return NS.Setting(o.key) and true or false end,
      apply)
    -- Some client builds only notify through the value-changed callback, so listen there too.
    if Settings.SetOnValueChangedCallback then
      Settings.SetOnValueChangedCallback(variable, function(_, _, v) apply(v) end)
    end
    local createCheckbox = Settings.CreateCheckbox or Settings.CreateCheckBox
    createCheckbox(cat, setting, o.tip ~= "" and o.tip or nil)
  end
  -- Market override: a dropdown of every market with a table loaded, plus "detect".
  local function options()
    local container = Settings.CreateControlTextContainer()
    container:Add("", "Detect from realm and faction")
    for _, m in ipairs(NS.KnownMarkets()) do container:Add(m, m) end
    return container:GetData()
  end
  local function applyMarket(v)
    v = type(v) == "string" and v or ""
    if (NS.Setting("market") or "") ~= v then
      NS.SetSetting("market", v)
      NS.Print("market: " .. (v == "" and "detected from realm and faction" or NS.MarketLabel(v)))
    end
  end
  local marketSetting = Settings.RegisterProxySetting(cat, "AHLEDGER_MARKET", Settings.VarType.String, "Market for prices", "",
    function() return NS.Setting("market") or "" end,
    applyMarket)
  if Settings.SetOnValueChangedCallback then
    Settings.SetOnValueChangedCallback("AHLEDGER_MARKET", function(_, _, v) applyMarket(v) end)
  end
  local createDropdown = Settings.CreateDropdown or Settings.CreateDropDown
  createDropdown(cat, marketSetting, options, "Which market's price table the tooltips and margins use. Detected from your realm name and faction unless set here.")
  local _ = layout
  Settings.RegisterAddOnCategory(cat)
end

local function registerLegacyPanel()
  local frame = CreateFrame("Frame", "AHledgerOptionsPanel", UIParent)
  frame.name = "AHledger"
  local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("AHledger")
  local y = -48
  for _, o in ipairs(OPTIONS) do
    local cb = CreateFrame("CheckButton", "AHledgerOption_" .. o.key, frame, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 16, y)
    local label = cb.Text or _G[cb:GetName() .. "Text"]
    if label and label.SetText then label:SetText(o.label) end
    cb.tooltipText = o.tip ~= "" and o.tip or nil
    cb:SetChecked(NS.Setting(o.key) and true or false)
    cb:SetScript("OnClick", function(self) NS.SetSetting(o.key, self:GetChecked() and true or false) end)
    y = y - 26
  end
  local note = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  note:SetPoint("TOPLEFT", 16, y - 8)
  note:SetWidth(560)
  note:SetJustifyH("LEFT")
  note:SetText("Market: " .. NS.Market() .. "   ·   /ahl watch for the watchlist, /ahl import to paste a price table")
  if InterfaceOptions_AddCategory then InterfaceOptions_AddCategory(frame) end
  category = frame
end

function NS.OpenOptions()
  if Settings and Settings.OpenToCategory and category and category.GetID then
    Settings.OpenToCategory(category:GetID())
  elseif InterfaceOptionsFrame_OpenToCategory and category then
    InterfaceOptionsFrame_OpenToCategory(category)
    InterfaceOptionsFrame_OpenToCategory(category)
  else
    NS.Status()
  end
end

function NS.OnSettingChanged(key)
  if key == "scanButton" and NS.RefreshScanButton then NS.RefreshScanButton() end
  if key == "minimap" and NS.RefreshMinimap then NS.RefreshMinimap() end
  if (key == "observe" or key == "contribute") and NS.ObserveRefresh then NS.ObserveRefresh() end
  if key == "ahColumn" and NS.RefreshMedianColumn then NS.RefreshMedianColumn() end
  if (key == "bar" or key == "barLocked" or key == "barTicker" or key == "dealsPercent" or key == "dealsMinValue") and NS.RefreshBar then NS.RefreshBar() end
  if key == "vendorFlips" and NS.RefreshVendorFlips then NS.RefreshVendorFlips() end
  if key == "questRewards" and NS.RefreshQuestRewards then NS.RefreshQuestRewards() end
  if key ~= "minimapAngle" and key ~= "barX" and key ~= "barY" and NS.RefreshWindow then NS.RefreshWindow() end
end

-- ---------------------------------------------------------------------------------------------
-- Disenchant estimate: expected material value by quality and item level, from the vanilla
-- tables. Mirrors the disenchant table on ahledger.com, bracket for bracket, so the
-- tooltip and the item page agree. Each yield: item id, min count, max count, chance.
-- ---------------------------------------------------------------------------------------------

-- One row per five-level bracket: from, dust, essence, shard (nil below 16), upper half.
local BRACKETS = {
  { 5, 10940, 10938, nil, false },
  { 16, 10940, 10939, 10978, true },
  { 21, 11083, 10998, 10978, false },
  { 26, 11083, 11082, 11084, true },
  { 31, 11137, 11134, 11138, false },
  { 36, 11137, 11135, 11139, true },
  { 41, 11176, 11174, 11177, false },
  { 46, 11176, 11175, 11178, true },
  { 51, 16204, 16202, 14343, false },
  { 56, 16204, 16203, 14344, true },
}
local NEXUS = 20725
-- The large shard of each ten-level tier, for epics under 51: 5-30, 31-40, 41-50.
local LARGE_BY_TIER = { 11084, 11084, 11139, 11178 }

local function bracketFor(ilvl)
  local b = BRACKETS[1]
  for _, row in ipairs(BRACKETS) do
    if ilvl >= row[1] then b = row end
  end
  return b
end

-- quality: 2 uncommon, 3 rare, 4 epic. Returns a list of { id, min, max, chance } or nil.
function NS.DisenchantYield(quality, ilvl)
  if not ilvl or ilvl < 5 then return nil end
  local b = bracketFor(ilvl)
  if quality == 2 then
    local dust = b[5] and { b[2], 2, 5, 0.75 } or { b[2], 1, 2, b[4] and 0.75 or 0.80 }
    local essence = { b[3], 1, 2, 0.20 }
    if b[4] then return { dust, essence, { b[4], 1, 1, 0.05 } } end
    return { dust, essence }
  elseif quality == 3 then
    return { { b[4] or 10978, 1, 1, 1 } }
  elseif quality == 4 then
    if ilvl >= 51 then return { { NEXUS, 1, 1, 1 } } end
    local t = math.max(0, math.min(3, math.ceil((ilvl - 20) / 10)))
    return { { LARGE_BY_TIER[t + 1], 1, 1, 1 } }
  end
  return nil
end

function NS.DisenchantValue(link, market)
  local _, _, quality, ilvl, _, _, _, _, _, _, _, classID = GetItemInfo(link)
  if not quality or not ilvl or ilvl < 5 then return nil end
  if classID ~= (Enum and Enum.ItemClass and Enum.ItemClass.Armor or 4) and classID ~= (Enum and Enum.ItemClass and Enum.ItemClass.Weapon or 2) then
    return nil
  end
  local yield = NS.DisenchantYield(quality, ilvl)
  if not yield then return nil end
  local total, known = 0, false
  for _, y in ipairs(yield) do
    local id, minCount, maxCount, chance = y[1], y[2], y[3], y[4]
    local p = id and NS.Price(id, market)
    if p and p.median then
      total = total + p.median * ((minCount + maxCount) / 2) * chance
      known = true
    end
  end
  return known and math.floor(total) or nil
end

-- ---------------------------------------------------------------------------------------------

function NS.Init()
  if Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterProxySetting and (Settings.CreateCheckbox or Settings.CreateCheckBox) then
    local ok, e = pcall(registerWithSettingsApi)
    if not ok then
      NS.Print("options panel unavailable: " .. tostring(e))
      registerLegacyPanel()
    end
  else
    registerLegacyPanel()
  end
  if NS.InitTooltip then NS.InitTooltip() end
end

function NS.OnLogin()
  if NS.HookCrafting then NS.HookCrafting() end
  if NS.HookAuctionHouse then NS.HookAuctionHouse() end
  if NS.RefreshMinimap then NS.RefreshMinimap() end
  if NS.InitBroker then NS.InitBroker() end
  if NS.InitBar then NS.InitBar() end
  if C_Timer and C_Timer.After then
    C_Timer.After(5, function() if NS.CheckAlerts then NS.CheckAlerts() end end)
  end
  -- Once, after updating to 0.9.0: what the new tooltip line is, and where to read more.
  local db = NS.Db()
  if not db.paceIntro then
    db.paceIntro = true
    NS.Print("0.9.0: tooltips now show how fast an item sells on your auction house, estimated from players' scans. /ahl pace explains it.")
  end
  -- Once, in the two weeks after launch (Site.lua; off with siteLinks).
  local launch = NS.LaunchNudge and NS.LaunchNudge(db, time and time() or nil)
  if launch then NS.Print(launch) end
end
