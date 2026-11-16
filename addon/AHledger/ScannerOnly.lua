--[[
  Scanner only (0.14.3): for players who see AHledger's prices through another addon, which
  reads them with AHledgerAPI. AHledger keeps scanning the auction house and AHledger sync keeps
  sending the scans, as the scanning and contribution switches are set, and AHledger turns its
  own interface off (NS.SCANNER_ONLY_WHAT, Options.lua). What stays is NS.SCANNER_ONLY_KEPT: the
  scan button with Save and upload, the minimap button and the stale-market line, so a scan can
  always be seen and the way back found.

  It is a preset over the ordinary switches, not a second layer: turning it on notes which
  interface switches the player already had off and turns the rest off; turning it off turns
  back on every one not in that note. A switch the player turned back on meanwhile stays on. The
  note is a setting (scannerKeptOff), so the CVar backup in Persist.lua carries it too.

  Another addon can ask for it with AHledgerAPI.RequestScannerOnly(addonName, callback). Nothing
  changes until the player answers in AHledger's own dialog (not StaticPopupDialogs: no list of
  ours goes to Blizzard). The dialog waits until the loading screen and any cinematic are over,
  and never opens in combat. Answers are kept per addon in AHledgerDB.scannerAsks:
    "accepted"  said yes
    "declined"  said no: not asked again
    "off"       said yes, then turned scanner only off by hand: not asked again
    "later"     closed with the X: not asked again until the next login (a /reload, such as
                Save and upload, does not count), and never for more than 20 hours
]]
local _, NS = ...
local UI = NS.UI

-- The switches scanner only turns off. Everything not listed (scanning, contribution, the scan
-- button, Save and upload, the stale-market line, the minimap button, the ledger's silent
-- record of posts and sales) stays as the player set it.
local INTERFACE = {
  "tooltip", "tooltipPvp", "crafting", "craftDots", "postingHelper", "postingPlan", "ahColumn",
  "bar", "bagDots", "pulse", "questRewards", "mailSummary", "scanSummary", "siteLinks",
  "vendorFlips", "undercutCheck",
}
NS.SCANNER_ONLY_OFF = INTERFACE
local WHAT = NS.SCANNER_ONLY_WHAT or "tooltip lines, ledger bar, crafting margins, auction house panels and chat summaries"
local KEPT = NS.SCANNER_ONLY_KEPT or "The scan button and the minimap button stay as you have them."
local LATER_HOURS = 20

local IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata

function NS.IsScannerOnly()
  return NS.Setting("scannerOnly") and true or false
end

-- How many interface switches the player turned back on while scanner only is on.
local function turnedBackOn()
  local n = 0
  for _, k in ipairs(INTERFACE) do if NS.Setting(k) then n = n + 1 end end
  return n
end

local function keptOff()
  local set = {}
  for k in tostring(NS.Setting("scannerKeptOff") or ""):gmatch("[^.]+") do set[k] = true end
  return set
end

local function asks()
  local db = NS.Db()
  if type(db.scannerAsks) ~= "table" then db.scannerAsks = {} end
  return db.scannerAsks
end

local function laterAt()
  local db = NS.Db()
  if type(db.scannerLaterAt) ~= "table" then db.scannerLaterAt = {} end
  return db.scannerLaterAt
end

-- The answer on record for an addon, with a "later" that has run out forgotten.
local function answerOf(name)
  local a = asks()[name]
  if a == "later" then
    local at = laterAt()[name]
    if not at or NS.Now() - at > LATER_HOURS * 3600 then
      asks()[name], laterAt()[name] = nil, nil
      return nil
    end
  end
  return a
end

local function loaded(name)
  if not IsAddOnLoaded then return true end
  local ok, yes = pcall(IsAddOnLoaded, name)
  return ok and yes and true or false
end

-- The sentences about scanning and sending, true to the switches and to whether sync has run.
local function scanText()
  return NS.Setting("autoScan") and "AHledger keeps scanning the auction house when you open it."
    or "AHledger keeps its scan button for scanning the auction house."
end

local function sendText()
  if not NS.Setting("contribute") then return "Contribute scans is off, so your scans stay on this PC." end
  local market = NS.Market()
  if NS.TableIsSeed and NS.TableIsSeed(market) and not (NS.Contribution and NS.Contribution()) then
    return "AHledger sync has not run on this PC yet, so your scans stay here until it does (ahledger.com/download)."
  end
  return "AHledger sync sends your scans as before."
end

-- Tooltips already open keep the block they were drawn with; the one a chat link opened stays up
-- until closed, so it is drawn again, and a mouseover tooltip is let go.
local function refreshOpenTooltips()
  local ref = rawget(_G, "ItemRefTooltip")
  if type(ref) == "table" and ref.IsShown and ref:IsShown() and not (ref.IsForbidden and ref:IsForbidden()) and ref.GetItem then
    local ok, _, link = pcall(ref.GetItem, ref)
    if ok and link then pcall(ref.SetHyperlink, ref, link) end
  end
  local tip = rawget(_G, "GameTooltip")
  if type(tip) == "table" and tip.IsShown and tip:IsShown() and not (tip.IsForbidden and tip:IsForbidden()) and tip.GetItem then
    local ok, _, link = pcall(tip.GetItem, tip)
    if ok and link then tip:Hide() end
  end
end

local resolveOpen -- defined with the dialog below

local function applyBatch(on)
  local failed = nil
  local function write(k, v)
    local ok, err = pcall(NS.WriteSetting, k, v)
    if not ok and not failed then failed = err end
  end
  if on then
    local off = {}
    for _, k in ipairs(INTERFACE) do if not NS.Setting(k) then off[#off + 1] = k end end
    write("scannerKeptOff", table.concat(off, "."))
    -- The flag before the switches, so every refresh below already sees scanner only.
    write("scannerOnly", true)
    for _, k in ipairs(INTERFACE) do
      if NS.Setting(k) then write(k, false) end
    end
    NS.Print("scanner only: on. " .. scanText() .. " " .. sendText() .. " AHledger's " .. WHAT .. " are off. /ahl scanner off puts them back.")
  else
    local off = keptOff()
    write("scannerOnly", false)
    for _, k in ipairs(INTERFACE) do
      if not off[k] and not NS.Setting(k) then write(k, true) end
    end
    write("scannerKeptOff", "")
    -- An addon the player said yes to is not asked again once they have turned it off themselves.
    local a = asks()
    for name, v in pairs(a) do if v == "accepted" then a[name] = "off" end end
    NS.Print("scanner only: off. AHledger's own interface is back as it was.")
  end
  return failed
end

-- Turns scanner only on or off. Returns true when something changed. One switch failing to
-- refresh never stops the others: every switch is written, and the error is named once.
function NS.ApplyScannerOnly(on)
  on = on and true or false
  if NS.IsScannerOnly() == on then return false end
  NS.SettingsBatch = true
  local ok, failed = pcall(applyBatch, on)
  NS.SettingsBatch = false
  if not ok then failed = failed or "unknown" end
  -- The bar and the window once for the whole batch (Options.lua skips them meanwhile).
  if NS.RefreshBar then pcall(NS.RefreshBar) end
  if NS.RefreshWindow then pcall(NS.RefreshWindow) end
  if NS.SyncOptionsPanel then pcall(NS.SyncOptionsPanel) end
  if NS.PersistSave then pcall(NS.PersistSave, true) end
  pcall(refreshOpenTooltips)
  if failed then
    NS.Print("scanner only: a part of the interface did not refresh (" .. tostring(failed) .. "). A /reload settles it; send this line through ahledger.com/contact.")
  end
  -- Turned on some other way while an addon's request was on screen: that request is answered.
  if on and resolveOpen then resolveOpen("on") end
  return true
end

-- /ahl scanner on|off. Bare, it says where things stand rather than flipping the interface.
function NS.ScannerOnlyCommand(arg)
  arg = (arg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if arg == "on" then
    if not NS.ApplyScannerOnly(true) then NS.Print("scanner only is already on. /ahl scanner off turns it off.") end
  elseif arg == "off" then
    if not NS.ApplyScannerOnly(false) then NS.Print("scanner only is already off. /ahl scanner on turns it on.") end
  elseif arg == "" then
    if NS.IsScannerOnly() then
      NS.Print("scanner only is on. /ahl scanner off brings AHledger's own interface back.")
    else
      NS.Print("scanner only is off. /ahl scanner on keeps scanning and uploading and turns AHledger's own interface off, for when another addon shows its prices.")
    end
  else
    NS.Print("usage: /ahl scanner on|off (on: keep scanning and uploading, turn AHledger's own interface off)")
  end
end

-- One line for the minimap button's tooltip and for login, so missing tooltips are never a
-- mystery, and true to what the player turned back on meanwhile.
function NS.ScannerOnlyStatusText()
  local n = turnedBackOn()
  local text
  if n > 0 then
    text = string.format("Scanner only is on, and you turned %d of the switches it turned off back on. /ahl scanner off turns on the others you had on.", n)
  else
    text = "Scanner only is on: AHledger scans and its own interface is off. /ahl scanner off brings it back."
  end
  if not NS.Setting("contribute") then text = text .. " Contribute scans is off, so scans stay on this PC." end
  return text
end

function NS.ScannerOnlyLoginLine()
  if not NS.IsScannerOnly() then return nil end
  local text = NS.ScannerOnlyStatusText()
  text = text:sub(1, 1):lower() .. text:sub(2)
  -- The addon that asked for it is gone: nothing shows prices now.
  local gone = {}
  for name, v in pairs(asks()) do
    if v == "accepted" and not loaded(name) then gone[#gone + 1] = name end
  end
  if #gone > 0 then
    table.sort(gone)
    text = text .. string.format(" %s, which asked for scanner only, is not loaded; /ahl scanner off brings AHledger's interface back.", table.concat(gone, ", "))
  end
  return text
end

-- ---------------------------------------------------------------------------------------------
-- Requests from other addons
-- ---------------------------------------------------------------------------------------------

local queue = {}      -- { name, title, callbacks = {} }, oldest first
local entered = false -- past the first loading screen, plus a few seconds
local waiting = false -- those few seconds are running
local dialog = nil
local showing = nil   -- the request on screen

-- An addon's title as the player knows it, without colour codes, textures, atlases or line
-- breaks.
local function plainTitle(name)
  local title = nil
  if GetAddOnMetadata then
    local ok, t = pcall(GetAddOnMetadata, name, "Title")
    if ok and type(t) == "string" then title = t end
  end
  title = title or name
  title = title:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:]-:", ""):gsub("|r", "")
    :gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|n", " "):gsub("|", "")
  title = title:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if title == "" then title = name end
  if #title > 40 then
    -- Cut on a character boundary: a trailing lead byte and its partial tail go.
    title = title:sub(1, 39):gsub("[\192-\255][\128-\191]*$", "") .. "..."
  end
  return title
end

-- answer: "yes", "no", "later" (closed without an answer) or "on" (turned on another way).
-- A caller's error goes to the game's error handler (BugSack shows it), never into AHledger.
local function call(callbacks, answer)
  local accepted = answer == "yes" or answer == "on"
  for _, cb in ipairs(callbacks) do
    local ok, err = pcall(cb, accepted, answer)
    if not ok and geterrorhandler then pcall(geterrorhandler(), err) end
  end
end

local showNext

local function buildDialog()
  local f = CreateFrame("Frame", "AHledgerScannerOnlyDialog", UIParent, "BackdropTemplate")
  f:SetBackdrop({
    bgFile = "Interface/DialogFrame/UI-DialogBox-Background-Dark",
    edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  f:SetSize(440, 200)
  f:SetPoint("CENTER", 0, 120)
  -- Above the AHledger window and copy box, which sit in DIALOG.
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetToplevel(true)
  f:EnableMouse(true)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  f:Hide()
  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOPLEFT", 18, -16)
  f.title:SetWidth(380)
  f.title:SetJustifyH("LEFT")
  f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.body:SetPoint("TOPLEFT", 18, -40)
  f.body:SetWidth(404)
  f.body:SetJustifyH("LEFT")
  f.body:SetSpacing(2)
  -- Under the body, so a second line of it pushes the buttons down instead of running into them.
  f.note = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.note:SetPoint("TOPLEFT", f.body, "BOTTOMLEFT", 0, -12)
  f.note:SetWidth(404)
  f.note:SetJustifyH("LEFT")
  f.note:SetTextColor(0.6, 0.6, 0.62)
  f.note:SetText("Undo any time: /ahl scanner off, or the Scanner only switch in /ahl options. The X asks again at your next login.")
  -- The pair centred under the text.
  f.yes = UI.Button(f, "Turn on scanner only", 170, function() if resolveOpen then resolveOpen("yes") end end)
  f.yes:SetPoint("BOTTOM", f, "BOTTOM", -89, 16)
  f.no = UI.Button(f, "Keep AHledger as it is", 170, function() if resolveOpen then resolveOpen("no") end end)
  f.no:SetPoint("BOTTOM", f, "BOTTOM", 89, 16)
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)
  -- The X closes it without an answer. Not in UISpecialFrames: an Esc meant for the auction
  -- house, the bags or another window must not answer this. Hiding the whole interface (Alt+Z,
  -- a cinematic) also fires OnHide, but leaves the dialog shown, so it is not an answer either.
  f:SetScript("OnHide", function(self)
    if self:IsShown() then return end
    if resolveOpen then resolveOpen("later") end
  end)
  return f
end

resolveOpen = function(answer)
  local r = showing
  if not r then return end
  showing = nil
  if answer == "yes" then
    asks()[r.name] = "accepted"
    pcall(NS.ApplyScannerOnly, true)
  elseif answer == "no" then
    asks()[r.name] = "declined"
    NS.Print(string.format("scanner only: no. AHledger stays as it is and %s will not ask again; /ahl scanner on turns it on any time.", r.title))
  elseif answer == "later" then
    asks()[r.name] = "later"
    laterAt()[r.name] = NS.Now()
    NS.Print(string.format("scanner only: not answered. %s can ask again at your next login; /ahl scanner on turns it on any time.", r.title))
  end
  if dialog and dialog:IsShown() then dialog:Hide() end
  -- The answer is kept in the CVar backup too (Persist.lua).
  if NS.PersistSave then pcall(NS.PersistSave, true) end
  call(r.callbacks, answer)
  if C_Timer and C_Timer.After then C_Timer.After(0.5, function() showNext() end) end
end

local function busy()
  if InCombatLockdown and InCombatLockdown() then return true end
  -- A cinematic or a movie playing (a new character's intro): wait for it to end.
  local cine = rawget(_G, "CinematicFrame")
  if type(cine) == "table" and cine.IsShown and cine:IsShown() then return true end
  local movie = rawget(_G, "MovieFrame")
  if type(movie) == "table" and movie.IsShown and movie:IsShown() then return true end
  return false
end

showNext = function()
  if showing or not entered or busy() then return end
  while #queue > 0 do
    local r = table.remove(queue, 1)
    local said = answerOf(r.name)
    if NS.IsScannerOnly() then
      call(r.callbacks, "on")
    elseif said == "declined" or said == "off" then
      call(r.callbacks, "no")
    elseif said == "later" then
      call(r.callbacks, "later")
    else
      dialog = dialog or buildDialog()
      showing = r
      dialog.title:SetText("AHledger: scanner only for " .. r.title .. "?")
      dialog.body:SetText(string.format(
        "%s shows AHledger's prices in its own interface, and asks you to run AHledger as a scanner only.\n\n%s %s %s\n\nThese turn off: AHledger's %s.",
        r.title, scanText(), sendText(), KEPT, WHAT))
      dialog:Show()
      dialog:Raise()
      -- Measured once shown, when the font strings have laid out their lines.
      local function height(fs) return tonumber(fs.GetStringHeight and fs:GetStringHeight()) or 0 end
      dialog:SetHeight(math.max(190, 40 + height(dialog.body) + 12 + height(dialog.note) + 16 + 22 + 16))
      return
    end
  end
end

-- Returns "on" (already on), "asked" (the player will be asked, now or once loading, a
-- cinematic or combat is over), "declined" (this addon was told no, or the player turned scanner
-- only off after saying yes), "later" (the player closed the dialog; ask again next login) or
-- "invalid". callback(accepted, answer) runs once the player answers, only for "asked": answer is
-- "yes", "no", "later" or "on" (turned on another way); accepted is true for yes and on.
function NS.RequestScannerOnly(name, callback)
  if type(name) ~= "string" or #name > 64 or not name:match("^[%w_%-%.!]+$") then return "invalid" end
  if callback ~= nil and type(callback) ~= "function" then return "invalid" end
  if not loaded(name) then return "invalid" end
  if NS.IsScannerOnly() then return "on" end
  local said = answerOf(name)
  if said == "declined" or said == "off" then return "declined" end
  if said == "later" then return "later" end
  local r = showing and showing.name == name and showing or nil
  if not r then
    for _, q in ipairs(queue) do if q.name == name then r = q end end
  end
  if not r then
    r = { name = name, title = plainTitle(name), callbacks = {} }
    queue[#queue + 1] = r
  end
  if callback then r.callbacks[#r.callbacks + 1] = callback end
  showNext()
  return "asked"
end

local events = CreateFrame("Frame")
-- The first loading screen's end is the moment. LOADING_SCREEN_DISABLED is missing on some
-- clients, so PLAYER_ENTERING_WORLD stands in there, and also starts a longer fallback in case
-- the loading event never comes.
local okLoading, regResult = pcall(events.RegisterEvent, events, "LOADING_SCREEN_DISABLED")
local haveLoadingEvent = okLoading and regResult ~= false
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
for _, e in ipairs({ "CINEMATIC_STOP", "STOP_MOVIE" }) do pcall(events.RegisterEvent, events, e) end

local function startWait(seconds)
  if entered then return end
  if C_Timer and C_Timer.After then
    C_Timer.After(seconds, function()
      if entered then return end
      entered = true
      showNext()
    end)
  else
    entered = true
  end
end

local seenWorld = false
events:SetScript("OnEvent", function(_, event, isInitialLogin)
  if event == "PLAYER_ENTERING_WORLD" then
    if seenWorld then return end
    seenWorld = true
    -- A real login (not a /reload) ends every "not now".
    if isInitialLogin == true then
      local a = asks()
      for name, v in pairs(a) do if v == "later" then a[name] = nil end end
      NS.Db().scannerLaterAt = nil
    end
    if haveLoadingEvent then startWait(15) else waiting = true; startWait(4) end
  elseif event == "LOADING_SCREEN_DISABLED" then
    if entered or waiting then return end
    waiting = true
    -- A few seconds after the login lines, so the question is not lost among them.
    startWait(4)
  elseif event == "CINEMATIC_STOP" or event == "STOP_MOVIE" then
    if C_Timer and C_Timer.After then C_Timer.After(1, function() showNext() end) end
  elseif event == "PLAYER_REGEN_ENABLED" then
    showNext()
  end
end)

-- For the harness.
function NS.ScannerOnlyState()
  return { queued = #queue, showing = showing and showing.name or nil, entered = entered, dialog = dialog }
end
