--[[
  Best quest reward. When a quest offers a choice, each option shows what it is worth (the
  market median or the vendor price, whichever is more, times the count) and the best one is
  marked "best value". A quest window with one choice, or with nothing priced, shows nothing.
  The choice stays the player's; this is a label on the buttons Blizzard draws.
]]
local _, NS = ...
local UI = NS.UI
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

-- The index of the single highest value, with the value, or nil on a tie or when nothing is
-- priced. values[i] is copper or false. Pure.
function NS.BestChoice(values)
  local best, bestValue, tie = nil, 0, false
  for i = 1, #values do
    local v = values[i]
    if v and v > bestValue then
      best, bestValue, tie = i, v, false
    elseif v and v > 0 and v == bestValue then
      tie = true
    end
  end
  if tie or not best then return nil end
  return best, bestValue
end

-- Copper per choice: the better of median and vendor, times the count offered.
local function choiceValues()
  local n = GetNumQuestChoices and GetNumQuestChoices() or 0
  local values = {}
  local market = NS.Market()
  for i = 1, n do
    local link = GetQuestItemLink and GetQuestItemLink("choice", i) or nil
    local id = NS.ItemIdFromLink(link)
    local v = false
    if id then
      -- Called on its own line: "f and f()" would keep only the first of its returns.
      local qty = 1
      if GetQuestItemInfo then
        local _, _, n = GetQuestItemInfo("choice", i)
        qty = n
      end
      local row = NS.Price(id, market)
      local vendor = select(11, GetItemInfo(link or id))
      local unit = math.max(row and row.median or 0, tonumber(vendor) or 0)
      if unit > 0 then v = unit * math.max(1, tonumber(qty) or 1) end
    end
    values[i] = v
  end
  return values
end

local function labelFor(button)
  local fs = rawget(button, "AHledgerValue")
  if not fs then
    fs = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("BOTTOMRIGHT", button, "TOPRIGHT", -2, 1)
    fs:SetJustifyH("RIGHT")
    fs:SetWidth(120)
    button.AHledgerValue = fs
  end
  return fs
end

local function choiceButtons()
  local out = {}
  local frame = QuestInfoRewardsFrame
  if not frame or type(frame.RewardButtons) ~= "table" then return out end
  for _, b in ipairs(frame.RewardButtons) do
    if b.type == "choice" and b.GetID and b:IsShown() then out[b:GetID()] = b end
  end
  return out
end

local warned = false
local function mark()
  local ok, err = pcall(function()
    local buttons = choiceButtons()
    if not NS.Setting("questRewards") then
      for _, b in pairs(buttons) do
        local fs = rawget(b, "AHledgerValue")
        if fs then fs:SetText("") end
      end
      return
    end
    local values = choiceValues()
    local best, bestValue = NS.BestChoice(values)
    for i, b in pairs(buttons) do
      local fs = labelFor(b)
      if i == best then
        fs:SetText(UI.UP .. "best value " .. UI.PlainGold(bestValue) .. UI.R)
      elseif values[i] then
        fs:SetText(UI.GREY .. UI.PlainGold(values[i]) .. UI.R)
      else
        fs:SetText("")
      end
    end
  end)
  if not ok and not warned then
    warned = true
    NS.Print("quest reward values are off for this session: " .. tostring(err))
  end
end

local function markSoon()
  if C_Timer and C_Timer.After then C_Timer.After(0.1, mark) else mark() end
end

if hooksecurefunc and QuestInfo_Display then
  hooksecurefunc("QuestInfo_Display", markSoon)
end

local frame = CreateFrame("Frame", "AHledgerQuestRewardFrame")
for _, e in ipairs({ "QUEST_DETAIL", "QUEST_COMPLETE", "QUEST_ITEM_UPDATE" }) do pcall(frame.RegisterEvent, frame, e) end
frame:SetScript("OnEvent", function() markSoon() end)
NS.RefreshQuestRewards = mark
