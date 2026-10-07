--[[
  Tooltip lines. Every item tooltip (bags, bank, auction house, chat links, quest rewards,
  crafting windows) gains AHledger lines from the price table for the current market:

    AHledger        12g 34s median  ·  min 11g 20s
    7d ▲ 4.2%  ·  123 listed  ·  table 35 min old
    Vendor 5s 20c  ·  Disenchant ~1g 10s

  Uses TooltipDataProcessor where the client has it (Classic Era 1.15+ and Forever), and the
  OnTooltipSetItem script on older clients.
]]
local _, NS = ...
-- Modern clients (the Forever beta runs the Mainline UI) moved item info under C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local GREY = "|cff9d9d9d"
local WHITE = "|cffededf2"
local UP = "|cff3ddc6a"
local DOWN = "|cffff4d4d"
local R = "|r"

local function pct(cur, prev)
  if not cur or not prev or prev == 0 then return nil end
  return (cur - prev) / prev * 100
end

local function ageText(seconds)
  if not seconds then return "" end
  if seconds < 3600 then return string.format("%d min old", math.floor(seconds / 60)) end
  if seconds < 86400 then return string.format("%d h old", math.floor(seconds / 3600)) end
  return string.format("%d d old", math.floor(seconds / 86400))
end

-- The compact block (option tooltipCompact): the market and the numbers on one line, then the
-- verdict, "Auction it" or "Vendor it", from the same rule the bag appraisal uses. Pure.
--
--   AHledger · PvP Horde          4g   +81%   3 listed
--   Auction it   vendor pays 55s 68c
local function compactBlock(ctx)
  local out = {}
  local label = ctx.marketLabel and ("AHledger · " .. ctx.marketLabel) or "AHledger"
  local row = ctx.row
  if row then
    local parts = { WHITE .. NS.Gold(row.median) .. R }
    if ctx.setting("tooltipChange") then
      local change = pct(row.median, row.m7)
      if change and math.abs(change) >= 0.5 then
        parts[#parts + 1] = string.format("%s%s%.0f%%%s", change >= 0 and UP or DOWN, change >= 0 and "+" or "-", math.abs(change), R)
      end
    end
    if ctx.setting("tooltipQuantity") and row.qty and row.qty > 0 then
      parts[#parts + 1] = string.format("%s%d listed%s", GREY, row.qty, R)
    end
    out[#out + 1] = { "double", "|cffff9d2f" .. label .. "|r", table.concat(parts, "   ") }
  elseif ctx.hasTable then
    out[#out + 1] = { "double", "|cffff9d2f" .. label .. "|r", GREY .. "not listed" .. R }
  else
    out[#out + 1] = { "double", "|cffff9d2fAHledger|r", GREY .. "no price table (/ahl import)" .. R }
  end
  local vendor = ctx.vendor and ctx.vendor > 0 and ctx.vendor or nil
  local verdict = NS.SellVerdict and NS.SellVerdict(row and row.median, vendor) or nil
  -- The sell pace rides on the verdict line: "Auction it · sells fast".
  local pace = ctx.setting("tooltipPace") and NS.Pace(row) or nil
  local paced = pace and (GREY .. " · " .. R .. NS.PaceColour(pace.tier) .. NS.PacePhrase(pace.tier) .. R) or ""
  if verdict == "auction" then
    out[#out + 1] = { "line", UP .. "Auction it" .. R .. paced .. (vendor and (GREY .. "   vendor pays " .. NS.Gold(vendor) .. R) or "") }
  elseif verdict == "vendor" then
    out[#out + 1] = { "line", "|cffffd23fVendor it|r" .. paced .. GREY .. "   pays " .. NS.Gold(vendor) .. R }
  elseif verdict == "either" then
    out[#out + 1] = { "line", GREY .. "Either: the vendor pays " .. NS.Gold(vendor) .. ", about the median" .. R .. paced }
  elseif pace then
    out[#out + 1] = { "line", NS.PaceColour(pace.tier) .. NS.PaceText(pace) .. R }
  end
  if ctx.setting("tooltipBags") and ctx.owned then out[#out + 1] = { "line", GREY .. ctx.owned .. R } end
  return out
end

-- The lines of the block, as {kind, left, right}: kind "double" for the header, "line" for the
-- rest. Pure, so the harness can read the words. Every optional part keeps its own switch.
--
--   AHledger · PvP Horde                    2 h old
--   Median 4g   3 listed   lowest 3g 97s
--   7 days: up 81% from 2g 21s
--   Steady: ~2 a day, 2 days of stock
--   Vendor pays 55s 68c   Disenchant ~70s 83c
function NS.TooltipBlock(ctx)
  if ctx.seedDate then
    -- A seed table says what it is instead of how old it is: "Oct 1 snapshot".
    ctx.age = nil
    ctx.ageText = ctx.seedDate .. " snapshot"
  end
  if ctx.compact then return compactBlock(ctx) end
  local out = {}
  local label = ctx.marketLabel and ("AHledger · " .. ctx.marketLabel) or "AHledger"
  local row = ctx.row
  if row then
    out[#out + 1] = { "double", "|cffff9d2f" .. label .. "|r", (ctx.ageText and (GREY .. ctx.ageText .. R)) or (ctx.age and (GREY .. ageText(ctx.age) .. R)) or "" }
    local price = { string.format("%sMedian %s%s", WHITE, NS.Gold(row.median), R) }
    if ctx.setting("tooltipQuantity") and row.qty and row.qty > 0 then
      price[#price + 1] = string.format("%s%d listed%s", GREY, row.qty, R)
    end
    if ctx.setting("tooltipMin") and row.min and row.min ~= row.median then
      price[#price + 1] = string.format("%slowest %s%s", GREY, NS.Gold(row.min), R)
    end
    out[#out + 1] = { "line", table.concat(price, "   ") }
    if ctx.setting("tooltipChange") then
      local change = pct(row.median, row.m7)
      if change and math.abs(change) >= 0.5 then
        local tone = change >= 0 and UP or DOWN
        out[#out + 1] = { "line", string.format("%s7 days: %s %.0f%% from %s%s", tone, change >= 0 and "up" or "down", math.abs(change), NS.Gold(row.m7), R) }
      elseif change then
        out[#out + 1] = { "line", GREY .. "7 days: unchanged" .. R }
      end
    end
    -- Sell pace: "Sells fast: ~36,000 a day, under a day of stock".
    local pace = ctx.setting("tooltipPace") and NS.Pace(row) or nil
    if pace then out[#out + 1] = { "line", NS.PaceColour(pace.tier) .. NS.PaceText(pace) .. R } end
  elseif ctx.hasTable then
    out[#out + 1] = { "double", "|cffff9d2f" .. label .. "|r", (ctx.ageText and (GREY .. ctx.ageText .. R)) or (ctx.age and (GREY .. ageText(ctx.age) .. R)) or "" }
    out[#out + 1] = { "line", GREY .. "Not listed on " .. (ctx.marketLabel or "this market") .. R }
  else
    out[#out + 1] = { "double", "|cffff9d2fAHledger|r", GREY .. "no price table (/ahl import)" .. R }
  end
  local tail = {}
  if ctx.setting("tooltipVendor") and ctx.vendor and ctx.vendor > 0 then
    tail[#tail + 1] = "Vendor pays " .. NS.Gold(ctx.vendor)
  end
  if ctx.setting("tooltipDisenchant") and ctx.disenchant then
    tail[#tail + 1] = "Disenchant ~" .. NS.Gold(ctx.disenchant)
  end
  if ctx.setting("tooltipBags") and ctx.owned then tail[#tail + 1] = ctx.owned end
  if #tail > 0 then out[#out + 1] = { "line", GREY .. table.concat(tail, "   ") .. R } end
  return out
end

local function addLines(tooltip, itemID, link)
  if not itemID or not NS.Setting("tooltip") then return end
  -- One block per tooltip: the retail-style processor can fire twice for the same item.
  if tooltip.AHledgerItem == itemID and tooltip.AHledgerStamp == GetTime() then return end
  tooltip.AHledgerItem = itemID
  tooltip.AHledgerStamp = GetTime()

  local market = NS.Market()
  local row, t = NS.Price(itemID, market)
  local vendor = select(11, GetItemInfo(link or itemID))
  local de = (NS.Setting("tooltipDisenchant") and NS.DisenchantValue) and NS.DisenchantValue(link or itemID, market) or nil
  local owned = (NS.Setting("tooltipBags") and NS.BagLine) and NS.BagLine(itemID, row) or nil

  tooltip:AddLine(" ")
  for _, l in ipairs(NS.TooltipBlock({
    row = row, hasTable = t ~= nil, marketLabel = NS.MarketLabel(market), age = t and NS.TableAge(market) or nil,
    vendor = vendor, disenchant = de, owned = owned, setting = NS.Setting,
    compact = NS.Setting("tooltipCompact") and true or false,
    seedDate = (t and t.seed) and NS.TableDate(market) or nil,
  })) do
    if l[1] == "double" then tooltip:AddDoubleLine(l[2], l[3]) else tooltip:AddLine(l[2]) end
  end
  tooltip:Show()
end

local function onTooltipSetItem(tooltip)
  if tooltip:IsForbidden() or not tooltip.GetItem then return end
  local _, link = tooltip:GetItem()
  local itemID = NS.ItemIdFromLink(link)
  if itemID then addLines(tooltip, itemID, link) end
end

function NS.InitTooltip()
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
      if tooltip:IsForbidden() then return end
      if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip and tooltip ~= ShoppingTooltip1 and tooltip ~= ShoppingTooltip2 then
        return
      end
      -- Comparison tooltips on modern clients have no GetItem; the data block carries the id,
      -- and the link comes from the item guid when the tooltip cannot say.
      local itemID = data and data.id
      local link = nil
      if tooltip.GetItem then
        local _, l = tooltip:GetItem()
        link = l
      end
      if not link and data and data.guid and C_Item and C_Item.GetItemLinkByGUID then
        link = C_Item.GetItemLinkByGUID(data.guid)
      end
      if not itemID then itemID = NS.ItemIdFromLink(link) end
      if itemID then addLines(tooltip, itemID, link) end
    end)
    return
  end
  for _, name in ipairs({ "GameTooltip", "ItemRefTooltip", "ShoppingTooltip1", "ShoppingTooltip2" }) do
    local tip = _G[name]
    if tip and tip.HookScript then tip:HookScript("OnTooltipSetItem", onTooltipSetItem) end
  end
end
