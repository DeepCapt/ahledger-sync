--[[
  Market pulse (0.10.0). When a newer price table for your market loads, one chat line says what
  moved since the last one you saw: the three biggest risers and the three biggest fallers, by
  percent, among items with a few listed both times and worth at least 50 silver. The previous
  table's medians are kept as one compact string per market in AHledgerDB.pulse, so nothing is
  computed until a newer table arrives, which happens at login or /reload after sync writes one.
  /ahl pulse prints the line again; the pulse option turns the login line off.
]]
local _, NS = ...
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local UP = "|cff3ddc6a"
local DOWN = "|cffff4d4d"
local R = "|r"

NS.PULSE_MIN_VALUE = 5000 -- copper; under 50s a move is noise
NS.PULSE_MIN_QTY = 3 -- listed both times, so one odd listing does not make a trend
NS.PULSE_MIN_PCT = 15
NS.PULSE_TOP = 3
local KEEP_MIN_VALUE = 1000 -- rows worth keeping for the next comparison
local MAX_ROWS = 20000

-- "id:median:qty;..." for the rows worth comparing later, sorted so the string is stable. Pure.
function NS.PulsePack(items)
  local parts, n = {}, 0
  for id, r in pairs(items or {}) do
    if r.median and r.median >= KEEP_MIN_VALUE and (r.qty or 0) >= 1 then
      n = n + 1
      if n > MAX_ROWS then break end
      parts[n] = string.format("%d:%d:%d", id, math.floor(r.median), math.floor(r.qty or 0))
    end
  end
  table.sort(parts)
  return table.concat(parts, ";")
end

function NS.PulseUnpack(s)
  local out = {}
  for id, median, qty in tostring(s or ""):gmatch("(%d+):(%d+):(%d+)") do
    out[tonumber(id)] = { median = tonumber(median), qty = tonumber(qty) }
  end
  return out
end

-- Risers and fallers between two tables: { risers = { { id, from, to, pct } }, fallers = ...,
-- moves = n }. Risers lead with the largest rise, fallers with the largest fall. Pure.
function NS.PulseDiff(prev, cur)
  local moves = {}
  for id, now in pairs(cur or {}) do
    local before = prev and prev[id]
    if before and before.median and now.median and before.median > 0
      and (before.qty or 0) >= NS.PULSE_MIN_QTY and (now.qty or 0) >= NS.PULSE_MIN_QTY
      and math.max(before.median, now.median) >= NS.PULSE_MIN_VALUE then
      local pct = (now.median - before.median) / before.median * 100
      if math.abs(pct) >= NS.PULSE_MIN_PCT then
        moves[#moves + 1] = { id = id, from = before.median, to = now.median, pct = pct }
      end
    end
  end
  table.sort(moves, function(a, b)
    if a.pct ~= b.pct then return a.pct > b.pct end
    return a.id < b.id
  end)
  local risers, fallers = {}, {}
  for i = 1, math.min(NS.PULSE_TOP, #moves) do
    if moves[i].pct > 0 then risers[#risers + 1] = moves[i] end
  end
  for i = #moves, math.max(1, #moves - NS.PULSE_TOP + 1), -1 do
    if moves[i].pct < 0 then fallers[#fallers + 1] = moves[i] end
  end
  return { risers = risers, fallers = fallers, moves = #moves }
end

-- "PvP Horde (US), 2 h since the last table: up Linen Cloth +40% (2g), ...; down ...".
-- nameOf(id) names an item. nil when nothing moved. Pure.
function NS.PulseText(diff, label, since, nameOf)
  if type(diff) ~= "table" or (#diff.risers == 0 and #diff.fallers == 0) then return nil end
  local function list(rows)
    local parts = {}
    for _, m in ipairs(rows) do
      parts[#parts + 1] = string.format("%s %s%+.0f%%%s (%s)", nameOf(m.id), m.pct >= 0 and UP or DOWN, m.pct, R, NS.Gold(m.to))
    end
    return table.concat(parts, ", ")
  end
  local head = since and string.format("%s, %s since the last table:", label, since) or string.format("%s, since the last table:", label)
  local parts = {}
  if #diff.risers > 0 then parts[#parts + 1] = "up " .. list(diff.risers) end
  if #diff.fallers > 0 then parts[#parts + 1] = "down " .. list(diff.fallers) end
  return head .. " " .. table.concat(parts, "; ")
end

-- "2 h" for the gap between two tables. Pure.
function NS.PulseSince(seconds)
  seconds = tonumber(seconds) or 0
  if seconds < 3600 then return string.format("%d min", math.max(1, math.floor(seconds / 60))) end
  if seconds < 86400 then return string.format("%d h", math.floor(seconds / 3600)) end
  return string.format("%d d", math.floor(seconds / 86400))
end
local sinceText = NS.PulseSince

local function nameOf(id)
  local name, link = GetItemInfo(id)
  return link or name or ("item " .. id)
end

-- Compares this market's table with the one last seen, prints what moved, and keeps the new
-- table as the next baseline. `force` prints even with the option off (/ahl pulse) and repeats
-- the last line when nothing newer has arrived. Returns the line, or nil.
function NS.MarketPulse(force)
  local db = NS.Db()
  local market = NS.Market()
  local t = NS.TableFor(market)
  if not t or t.seed or not t.updated or t.updated == 0 then return nil end
  db.pulse = db.pulse or {}
  local prev = db.pulse[market]
  local line = nil
  if prev and prev.updated and prev.updated < t.updated then
    local diff = NS.PulseDiff(NS.PulseUnpack(prev.data), t.items)
    local label, since = NS.MarketLabel(market), sinceText(t.updated - prev.updated)
    line = NS.PulseText(diff, label, since, nameOf)
    if line and (force or NS.Setting("pulse")) then
      -- Item names arrive from the server a moment after they are asked for; ask first, print
      -- once they are likely here, so the line reads as links rather than item numbers.
      local wait = false
      if C_Item and C_Item.RequestLoadItemDataByID and C_Timer and C_Timer.After then
        for _, rows in ipairs({ diff.risers, diff.fallers }) do
          for _, m in ipairs(rows) do
            if not GetItemInfo(m.id) then
              pcall(C_Item.RequestLoadItemDataByID, m.id)
              wait = true
            end
          end
        end
      end
      if wait then
        C_Timer.After(2, function() NS.Print(NS.PulseText(diff, label, since, nameOf)) end)
      else
        NS.Print(line)
      end
    end
  elseif force and prev and prev.lastLine then
    line = prev.lastLine
    NS.Print(line)
  end
  if not prev or (prev.updated or 0) < t.updated then
    db.pulse[market] = { updated = t.updated, data = NS.PulsePack(t.items), lastLine = line }
  end
  return line
end
