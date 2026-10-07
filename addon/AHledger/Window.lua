--[[
  The AHledger window (/ahl): header with market switcher, table age and item lookup; tabs
  registered by the feature modules (Watchlist, Deals, Crafting, Bags) plus Options; footer with
  scan, import and settings. Also the minimap button and the data broker feed.
]]
local _, NS = ...
local UI = NS.UI
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local window = nil
local current = nil
local built = {}

local WIDTH, HEIGHT = 700, 620
local CONTENT_TOP = -104
local CONTENT_BOTTOM = 46

function NS.WindowShowing(key)
  return window ~= nil and window:IsShown() and (key == nil or current == key)
end

-- ---------------------------------------------------------------------------------------------
-- Header pieces
-- ---------------------------------------------------------------------------------------------

local function refreshHeader()
  local market = NS.Market()
  local pinned = (NS.Setting("market") or "") ~= ""
  window.marketButton:SetText(NS.MarketLabel(market) .. (pinned and "  (pinned)" or "") .. "  ▾")
  if NS.TableIsSeed(market) then
    window.age:SetText("Prices: |cffffd23f" .. (NS.TableDate(market) or "release") .. " snapshot|r, sync for live")
  else
    window.age:SetText("Prices " .. UI.AgeColored(NS.TableAge(market)))
  end
end

local function marketMenu()
  local entries = {}
  local override = NS.Setting("market") or ""
  entries[#entries + 1] = {
    text = "Detect from realm and faction",
    checked = override == "",
    onClick = function()
      NS.SetSetting("market", "")
      NS.RefreshWindow()
    end,
  }
  for _, m in ipairs(NS.KnownMarkets()) do
    entries[#entries + 1] = {
      text = NS.MarketLabel(m),
      checked = override == m,
      onClick = function()
        NS.SetSetting("market", m)
        NS.RefreshWindow()
      end,
    }
  end
  UI.Menu(window.marketButton, entries)
end

local function lookup()
  local id, name = NS.ItemFrom(window.lookupBox:GetText())
  if not id then
    window.lookupText:SetText(UI.GREY .. "Type an item name you have seen, or shift-click a link into the box" .. UI.R)
    window.lookupId = nil
    return
  end
  window.lookupId = id
  local _, link = GetItemInfo(id)
  local p = NS.Price(id, NS.Market())
  if p then
    window.lookupText:SetText(string.format("%s  %s median  %s  %s min  %s listed",
      link or name, NS.Gold(p.median), UI.ChangeText(p), NS.Gold(p.min), UI.Comma(p.qty or 0)))
  else
    window.lookupText:SetText((link or name) .. "  " .. UI.GREY .. "not listed on " .. NS.MarketLabel(NS.Market()) .. UI.R)
  end
end

-- ---------------------------------------------------------------------------------------------
-- Options tab
-- ---------------------------------------------------------------------------------------------

local optionsTab = {}
local function buildOptions(parent)
  UI.Muted(parent, "Every switch saves at once. The market override and full descriptions live in the settings panel (Full settings).", 0, -2, 668)
  optionsTab.checks = {}
  local options = NS.OPTIONS or {}
  local perColumn = math.ceil(#options / 2)
  for i, o in ipairs(options) do
    local col = i <= perColumn and 0 or 1
    local rowIndex = col == 0 and (i - 1) or (i - 1 - perColumn)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", -4 + col * 334, -30 - rowIndex * 24)
    local label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    label:SetWidth(300)
    label:SetJustifyH("LEFT")
    label:SetText(o.short or o.label)
    cb.key = o.key
    cb:SetScript("OnClick", function(self) NS.SetSetting(self.key, self:GetChecked() and true or false) end)
    cb:SetScript("OnEnter", function(self)
      if o.tip == "" then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(o.label, 1, 1, 1)
      GameTooltip:AddLine(o.tip, 0.8, 0.8, 0.8, true)
      GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    optionsTab.checks[#optionsTab.checks + 1] = cb
  end
  local y = -30 - perColumn * 24 - 12
  optionsTab.status = UI.Muted(parent, "", 0, y, 668)
  optionsTab.status:SetSpacing(2)
end

local function refreshOptions()
  if not optionsTab.checks then return end
  for _, cb in ipairs(optionsTab.checks) do cb:SetChecked(NS.Setting(cb.key) and true or false) end
  local lines = { NS.PersistStatus and NS.PersistStatus() or "" }
  lines[#lines + 1] = "Version " .. NS.VERSION .. ". Slash commands: /ahl, /ahl scan, /ahl link, /ahl pace, /ahl import, /ahl watch, /ahl bar, /ahl set, /ahl market, /ahl status."
  optionsTab.status:SetText(table.concat(lines, "\n"))
end

-- ---------------------------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------------------------

local function showTab(key)
  current = key
  for _, t in ipairs(NS.Tabs) do
    local body = window.bodies[t.key]
    if t.key == key then
      if not built[t.key] then
        built[t.key] = true
        t.build(body)
      end
      body:Show()
    else
      body:Hide()
    end
    local b = window.tabButtons[t.key]
    if t.key == key then b:Disable() else b:Enable() end
  end
  NS.RefreshWindow()
end

local function ensureWindow()
  if window then return window end
  -- Options is a tab like the others, registered last so it sits at the right.
  NS.RegisterTab({ key = "options", label = "Options", order = 9, build = buildOptions, refresh = refreshOptions })

  window = CreateFrame("Frame", "AHledgerFrame", UIParent, "BackdropTemplate")
  window:SetSize(WIDTH, HEIGHT)
  window:SetPoint("CENTER")
  window:SetMovable(true)
  window:EnableMouse(true)
  window:RegisterForDrag("LeftButton")
  window:SetScript("OnDragStart", window.StartMoving)
  window:SetScript("OnDragStop", window.StopMovingOrSizing)
  window:SetBackdrop({
    bgFile = "Interface/DialogFrame/UI-DialogBox-Background",
    edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 24,
    insets = { left = 8, right = 8, top = 8, bottom = 8 },
  })
  window:SetFrameStrata("DIALOG")
  tinsert(UISpecialFrames, "AHledgerFrame")

  UI.Label(window, UI.ACCENT .. "AHledger" .. UI.R .. "  " .. UI.GREY .. "v" .. NS.VERSION .. UI.R, "GameFontNormal", 16, -14)
  local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)

  window.marketButton = UI.Button(window, "", 230, marketMenu)
  window.marketButton:SetPoint("TOPRIGHT", -36, -10)
  window.age = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  window.age:SetPoint("TOPRIGHT", -40, -36)
  window.age:SetJustifyH("RIGHT")

  UI.Label(window, "Look up", "GameFontNormalSmall", 16, -48, 50)
  window.lookupBox = UI.EditBox(window, 220, 72, -44, lookup)
  local lookupButton = UI.Button(window, "Price", 60, lookup)
  lookupButton:SetPoint("TOPLEFT", 298, -43)
  local watchButton = UI.Button(window, "Watch", 60, function()
    lookup()
    if window.lookupId then
      NS.WatchAdd(window.lookupId, (GetItemInfo(window.lookupId)))
      showTab("watch")
    end
  end)
  watchButton:SetPoint("TOPLEFT", 362, -43)
  window.lookupText = UI.Label(window, "", "GameFontHighlightSmall", 16, -70, 668)
  window.lookupText:SetWordWrap(false)

  -- Shift-clicking an item while a box in the window has focus drops the link into it.
  if ChatEdit_InsertLink and hooksecurefunc then
    hooksecurefunc("ChatEdit_InsertLink", function(link)
      if type(link) ~= "string" then return end
      local boxes = { window.lookupBox, NS.WatchTab and NS.WatchTab.addBox }
      for _, box in ipairs(boxes) do
        if box and box.HasFocus and box:HasFocus() then box:SetText(link) end
      end
    end)
  end

  window.tabButtons = {}
  window.bodies = {}
  local x = 16
  for _, t in ipairs(NS.Tabs) do
    local b = UI.Button(window, t.label, 104, function() showTab(t.key) end)
    b:SetPoint("TOPLEFT", x, -84)
    window.tabButtons[t.key] = b
    x = x + 108
    local body = CreateFrame("Frame", nil, window)
    body:SetPoint("TOPLEFT", 16, CONTENT_TOP - 8)
    body:SetPoint("BOTTOMRIGHT", -16, CONTENT_BOTTOM)
    body:Hide()
    window.bodies[t.key] = body
  end

  local scan = UI.Button(window, "AHledger scan", 170, function() if NS.StartScan then NS.StartScan(true) end end)
  scan:SetPoint("BOTTOMLEFT", 16, 14)
  if NS.RegisterScanButton then NS.RegisterScanButton(scan) end
  local import = UI.Button(window, "Import prices", 110, function() if NS.ShowImport then NS.ShowImport() end end)
  import:SetPoint("LEFT", scan, "RIGHT", 6, 0)
  local settings = UI.Button(window, "Full settings", 110, function() if NS.OpenOptions then NS.OpenOptions() end end)
  settings:SetPoint("BOTTOMRIGHT", -16, 14)
  window.footer = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  window.footer:SetPoint("LEFT", import, "RIGHT", 10, 0)
  window.footer:SetPoint("RIGHT", settings, "LEFT", -10, 0)
  window.footer:SetJustifyH("LEFT")
  window.footer:SetWordWrap(false)
  window.footer:SetTextColor(0.6, 0.6, 0.62)

  window:SetScript("OnShow", function() NS.RefreshWindow() end)
  window:SetScript("OnHide", function() UI.HideMenu() end)
  return window
end

function NS.RefreshWindow()
  if not window or not window:IsShown() then return end
  refreshHeader()
  for _, t in ipairs(NS.Tabs) do
    if t.key == current and built[t.key] then t.refresh() end
  end
  if NS.RefreshScanButton then NS.RefreshScanButton() end
end

-- The footer line alone, which the scanner refreshes every second while it is counting; the
-- tabs above it are not rebuilt for that.
function NS.RefreshScanFooter()
  if not window or not window:IsShown() then return end
  local market = NS.Market()
  local t = NS.TableFor(market)
  local state = NS.ScanState and NS.ScanState() or {}
  local parts = {}
  if t then parts[#parts + 1] = string.format("%s prices for %s items", NS.MarketLabel(market), UI.Comma(t.count or 0)) end
  if state.last then
    parts[#parts + 1] = string.format("your last scan %s", UI.AgeText(NS.Now() - (state.last.ts or NS.Now())) or "")
    if state.unsent then parts[#parts + 1] = UI.DOWN .. "not sent yet: /reload" .. UI.R end
  end
  window.footer:SetText(#parts > 0 and table.concat(parts, "  ·  ") or "No price table yet: run AHledger sync or import one")
end

function NS.ToggleWindow(tabKey)
  local w = ensureWindow()
  if w:IsShown() and (not tabKey or tabKey == current) then
    w:Hide()
    return
  end
  w:Show()
  showTab(tabKey or current or (NS.Tabs[1] and NS.Tabs[1].key))
end

function NS.OpenWindow(tabKey)
  local w = ensureWindow()
  w:Show()
  showTab(tabKey or current or (NS.Tabs[1] and NS.Tabs[1].key))
end

-- ---------------------------------------------------------------------------------------------
-- Minimap button and data broker feed
-- ---------------------------------------------------------------------------------------------

local minimapButton = nil

local function statusLines(tt)
  local market = NS.Market()
  tt:AddLine(UI.ACCENT .. "AHledger" .. UI.R .. " " .. NS.VERSION)
  if NS.TableIsSeed(market) then
    tt:AddLine(NS.SeedNote(market), 1, 0.82, 0.25, true)
  else
    tt:AddLine(NS.MarketLabel(market) .. ": prices " .. UI.AgeColored(NS.TableAge(market)), 1, 1, 1)
  end
  if NS.ScanStatusLines then NS.ScanStatusLines(tt) end
  local n = 0
  for _ in pairs(NS.Db().watch or {}) do n = n + 1 end
  tt:AddLine(string.format("%d watched item%s", n, n == 1 and "" or "s"), 1, 1, 1)
  if NS.DashboardLines then NS.DashboardLines(tt, nil, NS.TableIsSeed(market)) end
  tt:AddLine(UI.GREY .. "Left-click: window. Right-click: scan. Drag to move." .. UI.R)
end

-- How far outside the map's edge the button's centre sits. The button is 31 px across, so at
-- this distance its icon clears the map and only its ring overlaps the minimap's border, which
-- is where the buttons of other addons sit.
local MINIMAP_RIM = 12

-- Which quadrants of a minimap shape are rounded; a square one keeps the button on a rounded
-- square instead of a circle, the way LibDBIcon does. Quadrants: 1 top-right, 2 top-left,
-- 3 bottom-right, 4 bottom-left.
local MINIMAP_SHAPES = {
  ["ROUND"] = { true, true, true, true },
  ["SQUARE"] = { false, false, false, false },
  ["CORNER-TOPLEFT"] = { false, false, false, true },
  ["CORNER-TOPRIGHT"] = { false, false, true, false },
  ["CORNER-BOTTOMLEFT"] = { false, true, false, false },
  ["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
  ["SIDE-LEFT"] = { false, true, false, true },
  ["SIDE-RIGHT"] = { true, false, true, false },
  ["SIDE-TOP"] = { false, false, true, true },
  ["SIDE-BOTTOM"] = { true, true, false, false },
  ["TRICORNER-TOPLEFT"] = { false, true, true, true },
  ["TRICORNER-TOPRIGHT"] = { true, false, true, true },
  ["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
  ["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}

-- The button rides the rim of the minimap, outside the map, at the angle the player dragged it
-- to. The distance follows the minimap's actual size, so a larger or rescaled minimap keeps the
-- button outside the map instead of on top of it.
local function positionMinimap()
  if not minimapButton or not Minimap then return end
  local angle = math.rad(NS.Setting("minimapAngle") or 200)
  local x, y = math.cos(angle), math.sin(angle)
  local quadrant = 1
  if x < 0 then quadrant = quadrant + 1 end
  if y > 0 then quadrant = quadrant + 2 end
  local shape = (GetMinimapShape and GetMinimapShape()) or "ROUND"
  local rounded = (MINIMAP_SHAPES[shape] or MINIMAP_SHAPES["ROUND"])[quadrant]
  local w = (Minimap:GetWidth() or 140) / 2 + MINIMAP_RIM
  local h = (Minimap:GetHeight() or 140) / 2 + MINIMAP_RIM
  if rounded then
    x, y = x * w, y * h
  else
    local dw, dh = math.sqrt(2 * w * w) - 10, math.sqrt(2 * h * h) - 10
    x = math.max(-w, math.min(x * dw, w))
    y = math.max(-h, math.min(y * dh, h))
  end
  minimapButton:ClearAllPoints()
  minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

function NS.RefreshMinimap()
  if not Minimap then return end
  if not NS.Setting("minimap") then
    if minimapButton then minimapButton:Hide() end
    return
  end
  if not minimapButton then
    minimapButton = CreateFrame("Button", "AHledgerMinimapButton", Minimap)
    minimapButton:SetSize(31, 31)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:RegisterForDrag("LeftButton")
    local overlay = minimapButton:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface/Minimap/MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")
    local icon = minimapButton:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetTexture("Interface/Icons/INV_Misc_Coin_02")
    icon:SetPoint("TOPLEFT", 7, -5)
    minimapButton:SetHighlightTexture("Interface/Minimap/UI-Minimap-ZoomButton-Highlight")
    minimapButton:SetScript("OnClick", function(_, button)
      if button == "RightButton" then
        if NS.StartScan then NS.StartScan(true) end
      else
        NS.ToggleWindow()
      end
    end)
    minimapButton:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_LEFT")
      statusLines(GameTooltip)
      GameTooltip:Show()
    end)
    minimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    minimapButton:SetScript("OnDragStart", function(self)
      self:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        cx, cy = cx / scale, cy / scale
        NS.SetSetting("minimapAngle", math.floor(math.deg(math.atan2(cy - my, cx - mx))))
        positionMinimap()
      end)
    end)
    minimapButton:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    -- A minimap that changes size (the player rescales it, or the UI lays it out after login)
    -- takes the button with it.
    if Minimap.HookScript then Minimap:HookScript("OnSizeChanged", positionMinimap) end
  end
  positionMinimap()
  minimapButton:Show()
end

function NS.InitBroker()
  local ok = pcall(function()
    local LDB = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
    if not LDB then return end
    NS.Broker = LDB:NewDataObject("AHledger", {
      type = "launcher",
      label = "AHledger",
      icon = "Interface/Icons/INV_Misc_Coin_02",
      text = "AHledger",
      OnClick = function(_, button)
        if button == "RightButton" then
          if NS.StartScan then NS.StartScan(true) end
        else
          NS.ToggleWindow()
        end
      end,
      OnTooltipShow = function(tt) statusLines(tt) end,
    })
    local function tick()
      if NS.Broker then
        local age = NS.TableAge(NS.Market())
        if NS.TableIsSeed(NS.Market()) then
          NS.Broker.text = "prices " .. (NS.TableDate(NS.Market()) or "") .. " snapshot"
        else
          NS.Broker.text = age and ("prices " .. (UI.AgeText(age) or "")) or "no prices"
        end
      end
      if C_Timer and C_Timer.After then C_Timer.After(60, tick) end
    end
    tick()
  end)
  local _ = ok
end
