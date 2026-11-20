-- Run from the repository root with Lua 5.1:
--   lua5.1 addon/tests/scanner_readiness.lua
-- Loads the actual core in an isolated environment for each case; no game or network needed.
local source = arg and arg[1] or "addon/AHledger/AHledger.lua"
local cases = 0

local function client()
  local e = setmetatable({}, { __index = _G })
  e._G = e
  e.clock, e.ready, e.requests, e.visible = 100000, false, 0, true
  e.timers, e.messages, e.ns = {}, {}, {}
  e.GetServerTime = function() return e.clock end
  e.GetTime, e.time = e.GetServerTime, e.GetServerTime
  e.GetBuildInfo = function() return "1.60.1", "70862" end
  e.GetCurrentRegion = function() return 3 end
  e.GetRealmName = function() return "Test PvP" end
  e.UnitFactionGroup = function() return "Alliance" end
  e.GetLocale = function() return "ruRU" end
  e.CreateFrame = function() return { RegisterEvent = function() end, SetScript = function() end } end
  e.DEFAULT_CHAT_FRAME = { AddMessage = function(_, s) e.messages[#e.messages + 1] = s end }
  e.SlashCmdList = {}
  e.AuctionHouseFrame = { IsShown = function() return e.visible end }
  e.C_Timer = {
    After = function(delay, callback)
      e.timers[#e.timers + 1] = { at = e.clock + delay, callback = callback }
    end,
    NewTicker = function() return { Cancel = function() end } end,
  }
  e.C_AuctionHouse = {
    IsThrottledMessageSystemReady = function() return e.ready end,
    ReplicateItems = function()
      assert(e.ready, "request sent on a busy channel")
      e.requests = e.requests + 1
    end,
    GetNumReplicateItems = function() return 1 end,
    GetReplicateItemTimeLeft = function() return 3 end,
    GetReplicateItemInfo = function()
      return unpack({ [3] = 2, [10] = 400, [11] = 100, [17] = 2589 }, 1, 17)
    end,
  }
  local chunk = assert(loadfile(source))
  setfenv(chunk, e)
  chunk("AHledger", e.ns)
  function e.advance(seconds)
    e.clock = e.clock + seconds
    local timers = e.timers
    e.timers = {}
    for _, timer in ipairs(timers) do
      if timer.at <= e.clock then timer.callback() else e.timers[#e.timers + 1] = timer end
    end
  end
  return e, e.ns
end

local function test(name, run)
  local ok, err = pcall(run)
  assert(ok, name .. ": " .. tostring(err))
  cases = cases + 1
end

test("busy opening waits, ready event sends once, and payload/cooldown are preserved", function()
  local e, ns = client()
  ns.StartScan(false)
  assert(e.requests == 0 and ns.ScanState().phase == "queued")
  assert(ns.ScanButtonText(ns.ScanState()) == "Queued... 0s")
  ns.ScanEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
  assert(ns.ScanState().phase == "queued", "another query's drop cancelled the queued scan")
  e.clock = e.clock + 0.315
  e.ready = true
  ns.ScanEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
  assert(e.requests == 1 and ns.ScanState().phase == "waiting")
  assert(ns.ScanState().elapsed == 0, "server-wait timer includes time in the queue")
  e.advance(1)
  ns.ScanEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
  assert(e.requests == 1, "poll/event race sent duplicate requests")
  ns.ScanEvent("REPLICATE_ITEM_LIST_UPDATE")
  local db = ns.Db()
  assert(#db.scans == 1 and db.scans[1].count == 1)
  assert(db.scans[1].data == "2589:2:400:100:3")
  assert(ns.ScanState().phase == "blocked")
end)

test("readiness poll works without a ready event and never retries a sent request", function()
  local e, ns = client()
  ns.StartScan(false)
  e.advance(0.1)
  assert(e.requests == 0)
  e.ready = true
  e.advance(0.1)
  assert(e.requests == 1)
  e.advance(300)
  assert(e.requests == 1 and ns.ScanState().phase == "waiting")
end)

test("closing the house cancels pending callbacks", function()
  local e, ns = client()
  ns.StartScan(true)
  e.visible = false
  ns.ScanEvent("AUCTION_HOUSE_CLOSED")
  e.ready, e.visible = true, true
  e.advance(1)
  ns.ScanEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
  assert(e.requests == 0 and ns.ScanState().phase == "idle")
  ns.StartScan(true)
  assert(e.requests == 1, "ready manual scan should send immediately")
end)

test("hidden house is checked even without a close event", function()
  local e, ns = client()
  ns.StartScan(false)
  e.ready, e.visible = true, false
  e.advance(1)
  assert(e.requests == 0 and ns.ScanState().phase == "idle")
end)

test("unsent request times out without starting the full-scan cooldown", function()
  local e, ns = client()
  ns.StartScan(false)
  e.advance(31)
  assert(e.requests == 0 and ns.ScanState().phase == "idle")
  e.ready = true
  ns.StartScan(true)
  assert(e.requests == 1)
  ns.ScanEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
  assert(ns.ScanState().phase == "blocked", "actual sent-request refusal lost its cooldown")
end)

test("cancelled generation cannot send a replacement scan", function()
  local e, ns = client()
  ns.StartScan(false)
  local stale = e.timers
  e.timers = {}
  ns.ScanEvent("AUCTION_HOUSE_CLOSED")
  ns.StartScan(false)
  e.ready = true
  for _, timer in ipairs(stale) do timer.callback() end
  assert(e.requests == 0)
  ns.ScanEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
  assert(e.requests == 1)
end)

test("a listing from another addon cancels the unsent request before packing yields", function()
  local e, ns = client()
  ns.StartScan(false)
  -- Force more than one packing slice so the next ready event occurs while saving.
  e.C_AuctionHouse.GetNumReplicateItems = function() return 5000 end
  ns.ScanEvent("REPLICATE_ITEM_LIST_UPDATE")
  assert(ns.ScanState().phase == "saving")
  e.ready = true
  ns.ScanEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
  e.advance(1)
  assert(e.requests == 0 and #ns.Db().scans == 1)
end)

test("clients without the readiness API keep the original immediate request", function()
  local e, ns = client()
  e.C_AuctionHouse.IsThrottledMessageSystemReady = nil
  e.ready = true
  ns.StartScan(false)
  assert(e.requests == 1 and ns.ScanState().phase == "waiting")
end)

test("a synchronous ready event during the native call cannot send twice", function()
  local e, ns = client()
  e.ready = true
  local send = e.C_AuctionHouse.ReplicateItems
  e.C_AuctionHouse.ReplicateItems = function()
    send()
    ns.ScanEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
  end
  ns.StartScan(false)
  assert(e.requests == 1)
end)

test("a queued scan cannot trigger auto-upload", function()
  local _, ns = client()
  ns.Db().settings.autoUpload = true
  assert(not ns.AutoUploadWanted({ phase = "queued", unsent = true, contribute = true }))
end)

print(string.format("PASS: %d scanner readiness regression cases", cases))
