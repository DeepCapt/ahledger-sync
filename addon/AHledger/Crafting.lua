--[[
  Crafting margins.

  Per recipe: when a recipe is selected in a profession window, a line under the reagents shows
  the total reagent cost at the current market median, the value of what the recipe makes, and
  the margin:

    AHledger  cost 1g 20s  ·  makes 2g 15s  ·  margin +95s (+79%)

  Whole profession: the Crafting tab of the window lists every learned recipe of the open
  profession with cost, value, and margin, sortable, and a shopping list of the reagents missing
  from your bags for N crafts of the selected recipe.

  Reagents with no price are listed as unknown and left out of the cost, so a margin is never
  overstated by a missing number. Works with the modern profession window (the Forever beta)
  and the Classic Era TradeSkill and Craft (Enchanting) frames.
]]
local _, NS = ...
local UI = NS.UI
-- Modern clients (the Forever beta runs the Mainline UI) moved item info under C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local line = nil
local hooked = {}
local tab = { recipes = {}, selected = nil, crafts = 1, profession = nil, computedAt = nil }

local function priceOf(itemID, market)
  local row = NS.Price(itemID, market)
  return row and row.median or nil
end

-- One recipe's economics from its reagent list. reagents = { { itemID, name, qty } }.
-- Returns cost, missingNames, value, margin (value may be nil when the result is unpriced).
local function economics(reagents, resultID, made, market)
  local cost, missing = 0, {}
  for _, r in ipairs(reagents) do
    local price = r.itemID and priceOf(r.itemID, market) or nil
    if price then
      cost = cost + price * (r.qty or 1)
    else
      missing[#missing + 1] = r.name or ("item " .. tostring(r.itemID))
    end
  end
  local value = resultID and priceOf(resultID, market) or nil
  local total = value and value * (made or 1) or nil
  return cost, missing, total, total and (total - cost) or nil
end

local function marginText(cost, total, margin, resultID)
  local parts = { "cost " .. NS.Gold(cost) }
  if total then
    parts[#parts + 1] = "makes " .. NS.Gold(total)
    local sign = margin >= 0 and (UI.UP .. "+") or UI.DOWN
    local pctText = cost > 0 and string.format(" (%s%.0f%%)", margin >= 0 and "+" or "", margin / cost * 100) or ""
    parts[#parts + 1] = string.format("margin %s%s%s|r", sign, (NS.Gold(margin):gsub("^%-", "")), pctText)
  else
    parts[#parts + 1] = UI.GREY .. "result not listed" .. UI.R
  end
  -- How fast the result sells: a margin pays only as fast as that.
  local pace = (resultID and NS.Setting("tooltipPace")) and NS.Pace(NS.Price(resultID, NS.Market())) or nil
  if pace then parts[#parts + 1] = NS.PaceColour(pace.tier) .. NS.PacePhrase(pace.tier) .. UI.R end
  return UI.ACCENT .. "AHledger" .. UI.R .. "  " .. table.concat(parts, "  " .. UI.GREY .. "·" .. UI.R .. "  ")
end

-- ---------------------------------------------------------------------------------------------
-- Recipe readers: one shape for every client
--   { id, index, name, link, resultID, made, reagents = { { itemID, name, qty } } }
-- ---------------------------------------------------------------------------------------------

local TRADESKILL = {
  numReagents = function(i) return GetTradeSkillNumReagents(i) end,
  reagentInfo = function(i, j) return GetTradeSkillReagentInfo(i, j) end,
  reagentLink = function(i, j) return GetTradeSkillReagentItemLink(i, j) end,
  itemLink = function(i) return GetTradeSkillItemLink(i) end,
  numMade = function(i) return GetTradeSkillNumMade(i) end,
  count = function() return GetNumTradeSkills and GetNumTradeSkills() or 0 end,
  info = function(i) return GetTradeSkillInfo(i) end,
  select = function(i) if TradeSkillFrame_SetSelection then TradeSkillFrame_SetSelection(i) end end,
  name = function() return GetTradeSkillLine and GetTradeSkillLine() or "Profession" end,
}

local CRAFT = {
  numReagents = function(i) return GetCraftNumReagents(i) end,
  reagentInfo = function(i, j) return GetCraftReagentInfo(i, j) end,
  reagentLink = function(i, j) return GetCraftReagentItemLink(i, j) end,
  itemLink = function(i) return GetCraftItemLink(i) end,
  numMade = function() return 1, 1 end,
  count = function() return GetNumCrafts and GetNumCrafts() or 0 end,
  info = function(i) return GetCraftInfo(i) end,
  select = function(i) if CraftFrame_SetSelection then CraftFrame_SetSelection(i) end end,
  name = function() return GetCraftDisplaySkillLine and GetCraftDisplaySkillLine() or "Enchanting" end,
}

local function classicRecipe(api, index)
  local reagents = {}
  for j = 1, api.numReagents(index) or 0 do
    local name, _, count = api.reagentInfo(index, j)
    local link = api.reagentLink(index, j)
    reagents[#reagents + 1] = { itemID = NS.ItemIdFromLink(link), name = name, qty = count or 1 }
  end
  local resultLink = api.itemLink(index)
  local minMade, maxMade = api.numMade(index)
  local name = api.info(index)
  return {
    index = index,
    name = name or (resultLink and resultLink:match("%[(.-)%]")) or ("recipe " .. index),
    link = resultLink,
    resultID = NS.ItemIdFromLink(resultLink),
    made = ((minMade or 1) + (maxMade or minMade or 1)) / 2,
    reagents = reagents,
    api = api,
  }
end

local function modernRecipe(recipeID)
  local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
  if not ok or not schematic then return nil end
  local reagents = {}
  for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
    local basic = not slot.reagentType or (Enum.CraftingReagentType and slot.reagentType == Enum.CraftingReagentType.Basic)
    local reagent = slot.reagents and slot.reagents[1]
    if basic and reagent and reagent.itemID then
      reagents[#reagents + 1] = { itemID = reagent.itemID, name = GetItemInfo(reagent.itemID) or ("item " .. reagent.itemID), qty = slot.quantityRequired or 1 }
    end
  end
  local resultID = schematic.outputItemID
  local _, link = resultID and GetItemInfo(resultID) or nil
  return {
    id = recipeID,
    name = schematic.name or (resultID and GetItemInfo(resultID)) or ("recipe " .. recipeID),
    link = link,
    resultID = resultID,
    made = ((schematic.quantityMin or 1) + (schematic.quantityMax or schematic.quantityMin or 1)) / 2,
    reagents = reagents,
  }
end

-- Every learned recipe of the open profession, with economics. Pure enough for the harness.
function NS.CraftingTable()
  local market = NS.Market()
  local recipes, profession = {}, nil
  if C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs and C_TradeSkillUI.GetRecipeInfo then
    local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
    if ok and ids and #ids > 0 then
      for _, id in ipairs(ids) do
        local ok2, info = pcall(C_TradeSkillUI.GetRecipeInfo, id)
        if ok2 and info and info.learned ~= false then
          local r = modernRecipe(id)
          if r and #r.reagents > 0 then recipes[#recipes + 1] = r end
        end
      end
      local ok3, lineInfo = pcall(function() return C_TradeSkillUI.GetBaseProfessionInfo and C_TradeSkillUI.GetBaseProfessionInfo() end)
      profession = ok3 and lineInfo and lineInfo.professionName or nil
    end
  end
  if #recipes == 0 and TradeSkillFrame and TradeSkillFrame:IsShown() and GetNumTradeSkills then
    for i = 1, TRADESKILL.count() do
      local _, kind = TRADESKILL.info(i)
      if kind ~= "header" then
        local r = classicRecipe(TRADESKILL, i)
        if #r.reagents > 0 then recipes[#recipes + 1] = r end
      end
    end
    profession = TRADESKILL.name()
  end
  if #recipes == 0 and CraftFrame and CraftFrame:IsShown() and GetNumCrafts then
    for i = 1, CRAFT.count() do
      local _, _, kind = CRAFT.info(i)
      if kind ~= "header" then
        local r = classicRecipe(CRAFT, i)
        if #r.reagents > 0 then recipes[#recipes + 1] = r end
      end
    end
    profession = CRAFT.name()
  end
  for _, r in ipairs(recipes) do
    local cost, missing, total, margin = economics(r.reagents, r.resultID, r.made, market)
    r.cost, r.missing, r.total, r.margin = cost, missing, total, margin
    r.pct = (total and cost > 0) and (margin / cost * 100) or nil
    r.key = r.id or r.index
    r.resultRow = r.resultID and NS.Price(r.resultID, market) or nil
    r.perDay = r.resultRow and r.resultRow.perDay or nil
    r.profitDay = NS.ProfitPerDay(margin, r.made, r.perDay)
  end
  return recipes, profession
end

-- The margin per item made times the units the market buys a day: the most a crafter supplying
-- all of it could make. nil without a margin or a sales estimate. Pure.
function NS.ProfitPerDay(margin, made, perDay)
  if not margin or not perDay then return nil end
  return margin / ((made and made > 0) and made or 1) * perDay
end

-- Reagents missing from bags for n crafts of a recipe, priced. Pure.
function NS.ShoppingList(recipe, n)
  n = math.max(1, math.floor(tonumber(n) or 1))
  local lines, total, unknown = {}, 0, 0
  for _, r in ipairs(recipe.reagents or {}) do
    local need = (r.qty or 1) * n
    local have = (r.itemID and GetItemCount) and (GetItemCount(r.itemID) or 0) or 0
    local short = need - have
    if short > 0 then
      local price = r.itemID and priceOf(r.itemID, NS.Market()) or nil
      local cost = price and price * short or nil
      if cost then total = total + cost else unknown = unknown + 1 end
      lines[#lines + 1] = { itemID = r.itemID, name = r.name, need = need, have = have, short = short, cost = cost }
    end
  end
  return lines, total, unknown
end

-- ---------------------------------------------------------------------------------------------
-- Per-recipe line under the reagents
-- ---------------------------------------------------------------------------------------------

local function ensureLine(parent, anchor, name)
  if line and line:GetParent() == parent then return line end
  line = parent:CreateFontString(name, "OVERLAY", "GameFontNormalSmall")
  line:SetJustifyH("LEFT")
  line:SetWidth(300)
  line:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)
  return line
end

local function showLine(recipe)
  if not line then return end
  if not NS.Setting("crafting") or not recipe then
    line:SetText("")
    return
  end
  local cost, missing, total, margin = economics(recipe.reagents, recipe.resultID, recipe.made, NS.Market())
  local text = marginText(cost, total, margin, recipe.resultID)
  if #missing > 0 then
    text = text .. "\n" .. UI.GREY .. "no price for " .. table.concat(missing, ", ") .. UI.R
  end
  line:SetText(text)
end

local retailLine = nil
local function describeRetail(form, recipeInfo)
  if not NS.Setting("crafting") or not recipeInfo or not recipeInfo.recipeID then
    if retailLine then retailLine:SetText("") end
    return
  end
  local recipe = modernRecipe(recipeInfo.recipeID)
  if not recipe then return end
  if not retailLine or retailLine:GetParent() ~= form then
    retailLine = form:CreateFontString("AHledgerCraftLineRetail", "OVERLAY", "GameFontNormalSmall")
    retailLine:SetJustifyH("LEFT")
    retailLine:SetWidth(300)
    retailLine:SetPoint("TOPLEFT", form.Reagents or form, "BOTTOMLEFT", 0, -8)
  end
  line = retailLine
  showLine(recipe)
end

function NS.HookCrafting()
  if ProfessionsFrame and ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.SchematicForm and not hooked.retail then
    hooked.retail = true
    hooksecurefunc(ProfessionsFrame.CraftingPage.SchematicForm, "Init", describeRetail)
  end
  if TradeSkillFrame and TradeSkillFrame_SetSelection and not hooked.tradeskill then
    hooked.tradeskill = true
    hooksecurefunc("TradeSkillFrame_SetSelection", function(index)
      if not index or index < 1 or not GetTradeSkillNumReagents then return end
      local parent = TradeSkillDetailScrollChildFrame or TradeSkillFrame
      ensureLine(parent, TradeSkillReagentLabel or parent, "AHledgerCraftLine")
      showLine(classicRecipe(TRADESKILL, index))
    end)
  end
  if CraftFrame and CraftFrame_SetSelection and not hooked.craft then
    hooked.craft = true
    hooksecurefunc("CraftFrame_SetSelection", function(index)
      if not index or index < 1 or not GetCraftNumReagents then return end
      local parent = CraftDetailScrollChildFrame or CraftFrame
      ensureLine(parent, CraftReagentLabel or parent, "AHledgerCraftLine")
      showLine(classicRecipe(CRAFT, index))
    end)
  end
end

-- ---------------------------------------------------------------------------------------------
-- Crafting tab
-- ---------------------------------------------------------------------------------------------

local function refreshShopping()
  local r = nil
  for _, recipe in ipairs(tab.recipes) do
    if recipe.key == tab.selected then r = recipe end
  end
  if not r then
    tab.shopTitle:SetText(UI.GREY .. "Select a recipe for its shopping list" .. UI.R)
    tab.shopText:SetText("")
    return
  end
  local n = tab.crafts
  local lines, total, unknown = NS.ShoppingList(r, n)
  tab.shopTitle:SetText(string.format("Shopping list for %s × %d", r.link or r.name, n))
  if #lines == 0 then
    tab.shopText:SetText(UI.UP .. "You have every reagent." .. UI.R)
    return
  end
  local out = {}
  for _, l in ipairs(lines) do
    out[#out + 1] = string.format("%d × %s  %s", l.short, l.name, l.cost and (UI.GREY .. NS.Gold(l.cost) .. UI.R) or (UI.GREY .. "no price" .. UI.R))
  end
  out[#out + 1] = "Total " .. NS.Gold(total) .. (unknown > 0 and (UI.GREY .. string.format("  (%d reagent%s unpriced)", unknown, unknown == 1 and "" or "s") .. UI.R) or "")
  tab.shopText:SetText(table.concat(out, "\n"))
end

local function refresh()
  if not tab.list then return end
  local recipes, profession = NS.CraftingTable()
  if #recipes > 0 then
    tab.recipes = recipes
    tab.profession = profession
    tab.computedAt = NS.Now()
  end
  tab.craftsBox:SetText(tostring(tab.crafts))
  if #tab.recipes == 0 then
    tab.status:SetText(UI.GREY .. "Open a profession window and the recipes appear here with cost, value, and margin." .. UI.R)
  else
    local stale = #recipes == 0 and tab.computedAt and string.format(" (from %s)", UI.AgeText(NS.Now() - tab.computedAt) or "earlier") or ""
    tab.status:SetText(string.format("%s: %d recipes at %s prices%s. Click a recipe for its shopping list; right-click to show it in the profession window.",
      tab.profession or "Profession", #tab.recipes, NS.MarketLabel(NS.Market()), stale))
  end
  tab.list.selectedKey = tab.selected
  tab.list:SetRows(tab.recipes)
  refreshShopping()
end

local function build(parent)
  tab.status = UI.Label(parent, "", "GameFontHighlightSmall", 0, -2, 560)
  tab.status:SetWordWrap(false)
  UI.Label(parent, "Crafts", "GameFontNormalSmall", 574, -4, 44)
  tab.craftsBox = UI.EditBox(parent, 44, 620, 0, function(self)
    tab.crafts = math.max(1, math.floor(tonumber((self:GetText() or ""):match("%d+")) or 1))
    self:ClearFocus()
    refreshShopping()
  end)
  tab.list = UI.List(parent, {
    x = 0, y = -26, width = 668, rows = 13, rowKey = "key",
    columns = {
      { key = "name", label = "Recipe", width = 180, format = function(v, r) return r.link or v end },
      { key = "cost", label = "Cost", width = 80, numeric = true, format = function(v) return NS.Gold(v) end },
      { key = "total", label = "Makes", width = 80, numeric = true, format = function(v) return v and NS.Gold(v) or (UI.GREY .. "not listed" .. UI.R) end },
      { key = "margin", label = "Margin", width = 90, numeric = true, format = function(v)
        if not v then return "" end
        return (v >= 0 and UI.UP or UI.DOWN) .. (v >= 0 and "+" or "") .. UI.PlainGold(v) .. UI.R
      end },
      { key = "pct", label = "%", width = 45, numeric = true, justify = "RIGHT", format = function(v) return v and string.format("%+.0f%%", v) or "" end },
      { key = "perDay", label = "Sold/day", width = 65, numeric = true, justify = "RIGHT", tip = "Estimated units sold a day on this auction house, from players' scans over the last week. Green sells fast, white steadily, yellow slowly, grey barely. /ahl pace explains it. For the item the recipe makes.", format = function(_, r) return NS.PaceCell(r.resultRow) end },
      { key = "profitDay", label = "Profit/day", width = 85, numeric = true, justify = "RIGHT", tip = "The margin per item made times the units sold a day on this auction house: the most a crafter supplying all of it could make.", format = function(v)
        if not v then return UI.GREY .. "-" .. UI.R end
        return (v >= 0 and UI.UP or UI.DOWN) .. UI.PlainGold(math.floor(v + 0.5)) .. UI.R
      end },
      { key = "missing", label = "Unpriced", width = 40, justify = "RIGHT", format = function(v) return v and #v > 0 and tostring(#v) or "" end },
    },
    empty = "No recipes loaded.",
    siteLink = function()
      return { text = "Every recipe and margin on your house: " .. NS.CraftingURL(), title = "Crafting margins on your auction house", url = NS.CraftingURL() }
    end,
    onClick = function(row, button)
      if button == "RightButton" and IsControlKeyDown and IsControlKeyDown() then NS.ShowItemLink(row.resultID, row.name) return end
      if button == "RightButton" then
        if row.id and C_TradeSkillUI and C_TradeSkillUI.OpenRecipe then
          pcall(C_TradeSkillUI.OpenRecipe, row.id)
        elseif row.api and row.index then
          row.api.select(row.index)
        end
      else
        tab.selected = row.key
        tab.list:Select(row.key)
        refreshShopping()
      end
    end,
    onEnter = function(tt, row)
      if row.resultID then tt:SetItemByID(row.resultID) end
      tt:AddLine(UI.GREY .. "Ctrl+right-click for its ahledger.com page" .. UI.R)
      if row.missing and #row.missing > 0 then tt:AddLine(UI.GREY .. "No price for " .. table.concat(row.missing, ", ") .. UI.R, nil, nil, nil, true) end
      if row.profitDay then
        tt:AddLine(UI.GREY .. "Profit/day: the margin per item times the units the market buys a day, the most a crafter supplying all of it could make." .. UI.R, nil, nil, nil, true)
      end
    end,
  })
  tab.list:SetSort("margin", "desc")
  local y = -26 - (18 + 13 * 18 + 16) - 6
  tab.shopTitle = UI.Label(parent, "", "GameFontNormalSmall", 0, y, 668)
  tab.shopTitle:SetWordWrap(false)
  tab.shopText = UI.Label(parent, "", "GameFontHighlightSmall", 0, y - 18, 668)
  tab.shopText:SetSpacing(2)
end

NS.RegisterTab({ key = "craft", label = "Crafting", order = 3, build = build, refresh = refresh })

local events = CreateFrame("Frame")
for _, e in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_UPDATE", "CRAFT_SHOW", "CRAFT_UPDATE" }) do
  pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function()
  if NS.WindowShowing and NS.WindowShowing("craft") then refresh() end
end)
