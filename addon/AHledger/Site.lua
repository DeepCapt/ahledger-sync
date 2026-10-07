--[[
  Links to ahledger.com, kept quiet: shown when a player asks (/ahl link, ctrl+right-click on a
  row), as one muted line at the foot of a window the player opened, once per weekly report after
  a scan, and once after launch. Nothing in tooltips, the bar or the posting panel. The game cannot
  open a web page, so a link is a small box with the address selected, ready for Ctrl+C.
  The siteLinks option turns off everything except what the player asks for.
]]
local _, NS = ...
local UI = NS.UI

NS.SITE = "ahledger.com"

--- "ahledger.com/items/2589"; the site redirects to the page with the item's name in it.
function NS.ItemURL(itemID)
  return string.format("%s/items/%d", NS.SITE, itemID)
end

--- The player's market in the form the site's addresses use: "forever/pvp/horde/us".
local function marketPath()
  local m = NS.Market and NS.Market() or nil
  return (m and m ~= "") and m or nil
end

--- "ahledger.com/deals/forever/pvp/horde/us", or the deal scanner without a market.
function NS.DealsURL()
  local m = marketPath()
  return m and string.format("%s/deals/%s", NS.SITE, m) or (NS.SITE .. "/deals")
end

function NS.CraftingURL()
  local m = marketPath()
  return m and string.format("%s/crafting?market=%s", NS.SITE, m) or (NS.SITE .. "/crafting")
end

function NS.SiteLinksOn()
  return NS.Setting("siteLinks") ~= false
end

--- Opens the copy box for an address.
function NS.ShowLink(title, url)
  if UI.CopyBox then UI.CopyBox(title, url) end
  return url
end

--- The item's page, for /ahl link and ctrl+right-click on a list row.
function NS.ShowItemLink(itemID, name)
  if not itemID then return nil end
  local label = name or (GetItemInfo and GetItemInfo(itemID)) or ("item " .. itemID)
  return NS.ShowLink(label .. " on ahledger.com", NS.ItemURL(itemID))
end

--- /ahl link [item]: a shift-clicked link, an item id, or a name the client has cached.
function NS.LinkCommand(arg)
  arg = arg or ""
  local id = NS.ItemIdFromLink(arg) or tonumber(arg:match("^%s*(%d+)%s*$") or "")
  if not id and arg:match("%S") and GetItemInfo then
    local _, link = GetItemInfo(arg)
    id = link and NS.ItemIdFromLink(link) or nil
  end
  if id then return NS.ShowItemLink(id) end
  if arg:match("%S") then
    NS.Print("no item called " .. arg .. " is in your game cache yet; shift-click its link into /ahl link instead")
    return nil
  end
  return NS.ShowLink("AHledger: prices, deals and history for your auction house", NS.SITE)
end

-- The weekly report goes out on Tuesdays at 15:00 UTC (the site's Ledger job). Epoch arithmetic
-- rather than date(), so it is the same instant on every client clock and time zone.
local FIRST_REPORT = 486000 -- Tuesday 6 January 1970, 15:00 UTC
local WEEK = 604800
local REPORT_WINDOW = 3 * 86400

--- The newest report's publish time at `now`. Pure.
function NS.LatestReportAt(now)
  return FIRST_REPORT + math.floor((now - FIRST_REPORT) / WEEK) * WEEK
end

--- One line after a scan, once per weekly report and only in its first three days. Returns the
--- line (and marks it shown) or nil.
function NS.ReportNudge(db, now)
  if not NS.SiteLinksOn() or not now then return nil end
  local at = NS.LatestReportAt(now)
  if now - at > REPORT_WINDOW or db.reportNudge == at then return nil end
  db.reportNudge = at
  return "This week's market report, the biggest movers on every house: " .. NS.SITE .. "/reports"
end

-- World of Warcraft: Forever launches at 3 pm Pacific on 4 November 2026.
NS.LAUNCH_AT = 1793833200
local LAUNCH_WINDOW = 14 * 86400

--- Once, at the first login in the two weeks after launch. Returns the line (and marks it shown)
--- or nil.
function NS.LaunchNudge(db, now)
  if db.launchNudge or not NS.SiteLinksOn() or not now then return nil end
  if now < NS.LAUNCH_AT or now > NS.LAUNCH_AT + LAUNCH_WINDOW then return nil end
  db.launchNudge = true
  return "Launch week: what to farm, craft and sell, with live prices: " .. NS.SITE .. "/wow-forever/launch-week"
end
