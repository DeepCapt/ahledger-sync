--[[
  Small UI kit shared by the window and its tabs: labels, buttons, edit boxes, a scrolling list
  with sortable columns, a popup menu, and the tab registry the window assembles from.

  Every module that owns a tab calls NS.RegisterTab({ key, label, build(parent), refresh() })
  at load; the window (Window.lua, loaded later) builds the tab bodies on first open.
]]
local _, NS = ...

local UI = {}
NS.UI = UI

UI.GREY = "|cff9d9d9d"
UI.WHITE = "|cffededf2"
UI.UP = "|cff3ddc6a"
UI.DOWN = "|cffff4d4d"
UI.ACCENT = "|cffff9d2f"
UI.R = "|r"

function UI.Button(parent, text, width, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, 22)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

function UI.Label(parent, text, font, x, y, width, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
  fs:SetPoint("TOPLEFT", x, y)
  if width then fs:SetWidth(width) end
  fs:SetJustifyH(justify or "LEFT")
  fs:SetText(text or "")
  return fs
end

function UI.Muted(parent, text, x, y, width)
  local fs = UI.Label(parent, text, "GameFontHighlightSmall", x, y, width)
  fs:SetTextColor(0.6, 0.6, 0.62)
  return fs
end

function UI.EditBox(parent, width, x, y, onEnter)
  local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  box:SetSize(width, 20)
  box:SetPoint("TOPLEFT", x, y)
  box:SetAutoFocus(false)
  box:SetMaxLetters(200)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  if onEnter then box:SetScript("OnEnterPressed", function(self) onEnter(self) end) end
  return box
end

function UI.Pct(cur, prev)
  if not cur or not prev or prev == 0 then return nil end
  return (cur - prev) / prev * 100
end

-- "+12%" in green or "-4%" in red, from a price row's median against its 7 day median. A sign,
-- not a triangle: the game's fonts have no glyph for the triangle and drew a box in its place.
function UI.ChangeText(row)
  local pct = row and UI.Pct(row.median, row.m7)
  if not pct then return "" end
  local tone = pct >= 0 and UI.UP or UI.DOWN
  return string.format("%s%s%.0f%%%s", tone, pct >= 0 and "+" or "-", math.abs(pct), UI.R)
end

function UI.AgeText(seconds)
  if not seconds then return nil end
  if seconds < 60 then return "just now" end
  if seconds < 3600 then return string.format("%d min old", math.floor(seconds / 60)) end
  if seconds < 86400 then return string.format("%d h old", math.floor(seconds / 3600)) end
  return string.format("%d d old", math.floor(seconds / 86400))
end

-- Age colored by freshness: green under an hour, amber under six, red beyond or missing.
function UI.AgeColored(seconds)
  if not seconds then return UI.DOWN .. "no price table" .. UI.R end
  local color = seconds < 3600 and UI.UP or seconds < 6 * 3600 and "|cffffd23f" or UI.DOWN
  return color .. UI.AgeText(seconds) .. UI.R
end

-- Gold text without color codes, for edit boxes.
function UI.PlainGold(copper)
  return (NS.Gold(copper):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- "12g 50s", "1250s", "125000" -> copper, or nil.
function UI.ParsePrice(text)
  if not text or text == "" then return nil end
  local total, matched = 0, false
  for num, unit in text:gmatch("(%d+)%s*([gsc]?)") do
    matched = true
    num = tonumber(num)
    if unit == "g" then total = total + num * 10000
    elseif unit == "s" then total = total + num * 100
    else total = total + num end
  end
  return matched and total or nil
end

function UI.Comma(n)
  local s = tostring(math.floor(tonumber(n) or 0))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

-- ---------------------------------------------------------------------------------------------
-- List: fixed rows, mouse-wheel scrolling, click-to-sort headers, item tooltips on hover.
--   UI.List(parent, {
--     x, y, width, rows = 12, rowHeight = 18,
--     columns = { { key, label, width, justify = "LEFT", numeric = false, format = fn(value, row), tip = "hover text" } },
--     onClick = fn(row, button), onEnter = fn(tooltip, row), sortable = true,
--     empty = "text shown when there are no rows",
--   })
--   list:SetRows(rows)  list:Refresh()  list:SetSort(key, dir)
-- ---------------------------------------------------------------------------------------------

local ListMixin = {}

function ListMixin:SetRows(rows)
  self.rows = rows or {}
  -- Keep the scroll position across refreshes; Refresh clamps it to the new length.
  self:Refresh()
end

function ListMixin:SetSort(key, dir)
  self.sortKey = key
  self.sortDir = dir or "desc"
  self:Refresh()
end

function ListMixin:Sorted()
  local rows = self.rows
  if not self.sortKey then return rows end
  local key, dir = self.sortKey, self.sortDir
  local out = {}
  for i, r in ipairs(rows) do out[i] = r end
  table.sort(out, function(a, b)
    local x, y = a[key], b[key]
    if x == nil and y == nil then return false end
    if x == nil then return false end
    if y == nil then return true end
    if type(x) == "number" and type(y) == "number" then
      if dir == "asc" then return x < y else return x > y end
    end
    x, y = tostring(x):lower(), tostring(y):lower()
    if dir == "asc" then return x < y else return x > y end
  end)
  return out
end

function ListMixin:Refresh()
  local rows = self:Sorted()
  local n = #rows
  local visible = self.opts.rows
  local maxOffset = math.max(0, n - visible)
  if self.offset > maxOffset then self.offset = maxOffset end
  for i = 1, visible do
    local r = self.lines[i]
    local row = rows[self.offset + i]
    if row then
      r.row = row
      for _, col in ipairs(self.opts.columns) do
        local v = row[col.key]
        local text = col.format and col.format(v, row) or (v == nil and "" or tostring(v))
        r.cells[col.key]:SetText(text)
      end
      if self.selectedKey and self.opts.rowKey and row[self.opts.rowKey] == self.selectedKey then
        r.bg:Show()
      else
        r.bg:Hide()
      end
      r:Show()
    else
      r.row = nil
      r.bg:Hide()
      r:Hide()
    end
  end
  for _, col in ipairs(self.opts.columns) do
    local h = self.headers[col.key]
    local arrow = self.sortKey == col.key and (self.sortDir == "asc" and " ▲" or " ▼") or ""
    h.text:SetText(col.label .. arrow)
  end
  if self.siteLink then
    local link = NS.SiteLinksOn and NS.SiteLinksOn() and self.opts.siteLink() or nil
    if link then
      self.siteLink.text:SetText(link.text)
      self.siteLink:Show()
    else
      self.siteLink:Hide()
    end
  end
  if n == 0 then
    self.footer:SetText(self.opts.empty or "")
  else
    self.footer:SetText(string.format("%d to %d of %s", self.offset + 1, math.min(n, self.offset + visible), UI.Comma(n)))
  end
end

function ListMixin:Select(key)
  self.selectedKey = key
  self:Refresh()
end

function UI.List(parent, opts)
  opts.rows = opts.rows or 12
  opts.rowHeight = opts.rowHeight or 18
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetPoint("TOPLEFT", opts.x or 0, opts.y or 0)
  frame:SetSize(opts.width, 18 + opts.rows * opts.rowHeight + 16)
  for k, v in pairs(ListMixin) do frame[k] = v end
  frame.opts = opts
  frame.rows = {}
  frame.offset = 0
  frame.headers = {}
  frame.lines = {}

  local x = 0
  for _, col in ipairs(opts.columns) do
    local h = CreateFrame("Button", nil, frame)
    h:SetSize(col.width, 18)
    h:SetPoint("TOPLEFT", x, 0)
    h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h.text:SetAllPoints()
    h.text:SetJustifyH(col.justify or "LEFT")
    h.text:SetTextColor(0.6, 0.6, 0.62)
    h.text:SetText(col.label)
    if col.tip then
      h:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(col.label, 1, 1, 1)
        GameTooltip:AddLine(col.tip, 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
      end)
      h:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    if opts.sortable ~= false and col.sortable ~= false then
      h:SetScript("OnClick", function()
        if frame.sortKey == col.key then
          frame.sortDir = frame.sortDir == "asc" and "desc" or "asc"
        else
          frame.sortKey = col.key
          frame.sortDir = col.numeric and "desc" or "asc"
        end
        frame:Refresh()
      end)
    end
    frame.headers[col.key] = h
    x = x + col.width + 6
  end

  for i = 1, opts.rows do
    local r = CreateFrame("Button", nil, frame)
    r:SetSize(opts.width, opts.rowHeight)
    r:SetPoint("TOPLEFT", 0, -18 - (i - 1) * opts.rowHeight)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    r.bg:SetColorTexture(1, 0.62, 0.18, 0.18)
    r.bg:Hide()
    r:SetHighlightTexture("Interface/QuestFrame/UI-QuestTitleHighlight", "ADD")
    r.cells = {}
    local cx = 0
    for _, col in ipairs(opts.columns) do
      local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetPoint("LEFT", cx, 0)
      fs:SetWidth(col.width)
      fs:SetJustifyH(col.justify or "LEFT")
      fs:SetWordWrap(false)
      r.cells[col.key] = fs
      cx = cx + col.width + 6
    end
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function(self, button)
      if self.row and opts.onClick then opts.onClick(self.row, button) end
    end)
    r:SetScript("OnEnter", function(self)
      if not self.row then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if self.row.itemID then
        GameTooltip:SetItemByID(self.row.itemID)
      elseif self.row.name then
        GameTooltip:SetText(self.row.name, 1, 1, 1)
      end
      if opts.onEnter then opts.onEnter(GameTooltip, self.row) end
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame.lines[i] = r
  end

  -- One muted line at the right of the footer: the full page on ahledger.com (Site.lua).
  if opts.siteLink then
    local b = CreateFrame("Button", nil, frame)
    b:SetSize(math.floor(opts.width * 0.6), 14)
    b:SetPoint("BOTTOMRIGHT", 0, 0)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetAllPoints()
    b.text:SetJustifyH("RIGHT")
    b.text:SetTextColor(0.6, 0.6, 0.62)
    b:SetScript("OnClick", function()
      local link = opts.siteLink()
      if link and NS.ShowLink then NS.ShowLink(link.title, link.url) end
    end)
    b:SetScript("OnEnter", function(self) self.text:SetTextColor(1, 0.82, 0.25) end)
    b:SetScript("OnLeave", function(self) self.text:SetTextColor(0.6, 0.6, 0.62) end)
    frame.siteLink = b
  end

  frame.footer = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.footer:SetPoint("BOTTOMLEFT", 0, 0)
  frame.footer:SetWidth(opts.width)
  frame.footer:SetJustifyH("LEFT")
  frame.footer:SetTextColor(0.6, 0.6, 0.62)

  frame:EnableMouseWheel(true)
  frame:SetScript("OnMouseWheel", function(self, delta)
    local step = math.max(1, math.floor(opts.rows / 3))
    self.offset = math.max(0, self.offset - delta * step)
    self:Refresh()
  end)
  frame:Refresh()
  return frame
end

-- ---------------------------------------------------------------------------------------------
-- Popup menu: a plain list of buttons under an anchor. entries = { { text, onClick, checked } }
-- ---------------------------------------------------------------------------------------------

local menu = nil

function UI.Menu(anchor, entries)
  if not menu then
    menu = CreateFrame("Frame", "AHledgerMenu", UIParent, "BackdropTemplate")
    menu:SetBackdrop({
      bgFile = "Interface/DialogFrame/UI-DialogBox-Background-Dark",
      edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    menu:SetFrameStrata("TOOLTIP")
    menu:EnableMouse(true)
    menu.buttons = {}
    menu:SetScript("OnLeave", function(self)
      if not self:IsMouseOver() then self:Hide() end
    end)
  end
  for _, b in ipairs(menu.buttons) do b:Hide() end
  local width = 200
  for i, e in ipairs(entries) do
    local b = menu.buttons[i]
    if not b then
      b = CreateFrame("Button", nil, menu)
      b:SetHeight(18)
      b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      b.text:SetPoint("LEFT", 10, 0)
      b.text:SetJustifyH("LEFT")
      b:SetHighlightTexture("Interface/QuestFrame/UI-QuestTitleHighlight", "ADD")
      menu.buttons[i] = b
    end
    b:SetPoint("TOPLEFT", 4, -6 - (i - 1) * 18)
    b:SetWidth(width - 8)
    b.text:SetText((e.checked and (UI.ACCENT .. "• " .. UI.R) or "   ") .. e.text)
    b:SetScript("OnClick", function()
      menu:Hide()
      if e.onClick then e.onClick() end
    end)
    b:Show()
  end
  menu:SetSize(width, 12 + #entries * 18)
  menu:ClearAllPoints()
  menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
  menu:Show()
end

function UI.HideMenu()
  if menu then menu:Hide() end
end

-- ---------------------------------------------------------------------------------------------
-- Copy box: an address the player can copy, since the game cannot open a web page
-- ---------------------------------------------------------------------------------------------

local copy = nil

function UI.CopyBox(title, text)
  if not copy then
    copy = CreateFrame("Frame", "AHledgerCopyBox", UIParent, "BackdropTemplate")
    copy:SetBackdrop({
      bgFile = "Interface/DialogFrame/UI-DialogBox-Background-Dark",
      edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    copy:SetSize(400, 96)
    copy:SetPoint("CENTER", 0, 120)
    copy:SetFrameStrata("DIALOG")
    copy:EnableMouse(true)
    copy.title = copy:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    copy.title:SetPoint("TOPLEFT", 16, -14)
    copy.title:SetWidth(340)
    copy.title:SetJustifyH("LEFT")
    copy.title:SetWordWrap(false)
    copy.edit = CreateFrame("EditBox", nil, copy, "InputBoxTemplate")
    copy.edit:SetSize(360, 20)
    copy.edit:SetPoint("TOPLEFT", 20, -36)
    copy.edit:SetAutoFocus(true)
    copy.edit:SetScript("OnEscapePressed", function() copy:Hide() end)
    copy.edit:SetScript("OnEnterPressed", function() copy:Hide() end)
    -- Read only: typing puts the address back, still selected.
    copy.edit:SetScript("OnTextChanged", function(self, userInput)
      if userInput then
        self:SetText(copy.value or "")
        self:HighlightText()
      end
    end)
    copy.hint = copy:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    copy.hint:SetPoint("TOPLEFT", 16, -66)
    copy.hint:SetTextColor(0.6, 0.6, 0.62)
    copy.hint:SetText("Press Ctrl+C to copy, then Esc to close.")
    local close = CreateFrame("Button", nil, copy, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    if UISpecialFrames then table.insert(UISpecialFrames, "AHledgerCopyBox") end
  end
  copy.value = text
  copy.title:SetText(title or "")
  copy.edit:SetText(text or "")
  copy:Show()
  copy.edit:SetFocus()
  copy.edit:HighlightText()
  return copy
end

-- ---------------------------------------------------------------------------------------------
-- Tab registry
-- ---------------------------------------------------------------------------------------------

NS.Tabs = {}

function NS.RegisterTab(tab)
  NS.Tabs[#NS.Tabs + 1] = tab
  table.sort(NS.Tabs, function(a, b) return (a.order or 50) < (b.order or 50) end)
end
