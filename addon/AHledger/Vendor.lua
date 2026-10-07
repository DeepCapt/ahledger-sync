--[[
  Vendor flips. At a merchant, an item that sells on the auction house for well over its
  vendor price gets a green "flip +2g 10s" on its row, with the stock left when the vendor
  carries a limited number. Limited-stock recipes are the classic case. The tooltip still
  shows the median; this is the at-a-glance version. Buying stays the player's click.
]]
local _, NS = ...
local UI = NS.UI

local MIN_RATIO = 1.5 -- the median must beat the vendor price by this much
local MIN_PROFIT = 100 -- copper per unit; under a silver is not a flip

-- Profit per unit when an item is worth flipping, else nil. Pure.
function NS.VendorFlip(price, median)
  price, median = tonumber(price), tonumber(median)
  if not price or price <= 0 or not median then return nil end
  local profit = median - price
  if median < price * MIN_RATIO or profit < MIN_PROFIT then return nil end
  return math.floor(profit)
end

local warned = false
local function decorate()
  if not MerchantFrame or not MerchantFrame.IsShown or not MerchantFrame:IsShown() then return end
  local ok, err = pcall(function()
    local per = MERCHANT_ITEMS_PER_PAGE or 10
    local page = MerchantFrame.page or 1
    local onMerchantTab = (MerchantFrame.selectedTab or 1) == 1
    local count = GetMerchantNumItems and GetMerchantNumItems() or 0
    for i = 1, per do
      local row = _G["MerchantItem" .. i]
      if row then
        local fs = rawget(row, "AHledgerFlip")
        if not fs then
          fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
          fs:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, 10)
          fs:SetJustifyH("RIGHT")
          row.AHledgerFlip = fs
        end
        local text = ""
        local index = (page - 1) * per + i
        if NS.Setting("vendorFlips") and onMerchantTab and index <= count then
          local link = GetMerchantItemLink and GetMerchantItemLink(index) or nil
          local id = NS.ItemIdFromLink(link)
          local price, qty, available, extendedCost = NS.MerchantItem(index)
          if id and not extendedCost and price and price > 0 then
            local p = NS.Price(id, NS.Market())
            local unit = price / math.max(1, tonumber(qty) or 1)
            local profit = NS.VendorFlip(unit, p and p.median)
            if profit then
              text = UI.UP .. "flip +" .. UI.PlainGold(profit * math.max(1, tonumber(qty) or 1)) .. UI.R
              if available and available > 0 then text = text .. UI.GREY .. "  " .. available .. " left" .. UI.R end
            end
          end
        end
        fs:SetText(text)
      end
    end
  end)
  if not ok and not warned then
    warned = true
    NS.Print("vendor flips are off for this session: " .. tostring(err))
  end
end

if hooksecurefunc and MerchantFrame_UpdateMerchantInfo then
  hooksecurefunc("MerchantFrame_UpdateMerchantInfo", decorate)
end

local frame = CreateFrame("Frame", "AHledgerVendorFrame")
for _, e in ipairs({ "MERCHANT_SHOW", "MERCHANT_UPDATE" }) do pcall(frame.RegisterEvent, frame, e) end
frame:SetScript("OnEvent", function()
  if C_Timer and C_Timer.After then C_Timer.After(0, decorate) else decorate() end
end)
NS.RefreshVendorFlips = decorate
