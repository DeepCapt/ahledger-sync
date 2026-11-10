--[[
  Item search for the lookup box, the watchlist box, /ahl link and /ahl watch add (0.14.0).
  Before it, a typed name only worked when it was the item's whole name and the game client had
  that item loaded, so most typing ended in "type an item name you have seen".

  Names come from two places:
  - AHledger_Names.lua, which ships with each release (addon/package.py): every item a Forever
    market has priced, in English, whether or not the client has loaded it.
  - The game's own item cache, read only for items it has already loaded
    (C_Item.IsItemDataCachedByID). Those names are in the client's language and cover items newer
    than the release. Asking the game for an item it has not loaded queues a request to the
    server, so the search never does that across the price table.

  A query matches a name that holds it, or, with several words, a name that holds every word.
  Matches rank as: the whole name, the start of the name, the start of a word in it, anywhere,
  every word somewhere. Within a rank, items with a price here come first, then shorter names.
]]
local _, NS = ...

local MIN_QUERY = 2

-- ASCII only, whatever the C library's locale: under a Windows code page, string.lower, %s and
-- %w treat the bytes of a UTF-8 letter as Latin-1 letters and spaces and break the character.
local LOWER = {}
for c = 65, 90 do LOWER[string.char(c)] = string.char(c + 32) end
local function lower(s) return (s:gsub("[A-Z]", LOWER)) end
local SPACE = "[ \t\r\n]"
local DEFAULT_LIMIT = 12

-- Looked up when called, not at load: the client's C_Item may replace the global in a patch.
local function itemInfo(id)
  local f = GetItemInfo or (C_Item and C_Item.GetItemInfo)
  if not f then return nil end
  return f(id)
end

local function isCached(id)
  return C_Item and C_Item.IsItemDataCachedByID and C_Item.IsItemDataCachedByID(id) and true or false
end

--- Item from a shift-clicked link, an item id, or the whole name of an item the client has
--- loaded. Returns id, name or nil. (Moved here from Watchlist.lua in 0.14.0.)
function NS.ItemFrom(arg)
  arg = (arg or ""):gsub("^" .. SPACE .. "+", ""):gsub(SPACE .. "+$", "")
  if arg == "" then return nil end
  local id = NS.ItemIdFromLink(arg)
  if not id and arg:match("^%d+$") then id = tonumber(arg) end
  if not id then
    local _, link = itemInfo(arg)
    id = link and NS.ItemIdFromLink(link) or nil
  end
  if id then
    local name = itemInfo(id)
    -- A bare id names nothing; the caller falls back to "item <id>".
    return id, name or arg:match("%[(.-)%]") or (not arg:match("^%d+$") and arg or nil)
  end
  return nil
end

-- Names the client has given us, kept for the session: a loaded item's name never changes, so a
-- later search only asks about items that had not loaded yet.
local clientNames = {}

local function clientName(id)
  local n = clientNames[id]
  if n then return n end
  if not isCached(id) then return nil end
  if C_Item and C_Item.GetItemNameByID then n = C_Item.GetItemNameByID(id) end
  if type(n) ~= "string" or n == "" then n = itemInfo(id) end
  if type(n) == "string" and n ~= "" then
    clientNames[id] = n
    return n
  end
  return nil
end

local shipped = nil -- { n, ids = {}, names = {}, lower = {}, byId = {} }

--- The names that ship with the release, parsed on first use. Empty in a source checkout.
function NS.ShippedNames()
  if shipped then return shipped end
  shipped = { n = 0, ids = {}, names = {}, lower = {}, byId = {} }
  local t = AHledgerNames
  local text = type(t) == "table" and type(t.text) == "string" and t.text or ""
  for line in text:gmatch("[^\n]+") do
    local id, name = line:match("^(%d+):(.-)%s*$")
    id = tonumber(id)
    if id and id > 0 and name and name ~= "" and not shipped.byId[id] then
      local n = shipped.n + 1
      shipped.n = n
      shipped.ids[n], shipped.names[n], shipped.lower[n] = id, name, lower(name)
      shipped.byId[id] = name
    end
  end
  return shipped
end

--- Forgets the parsed and remembered names, for the harness after it swaps them.
function NS.ResetShippedNames() shipped = nil; clientNames = {} end

--- The query as the search reads it: lower case, spaces trimmed and squeezed. Pure.
function NS.SearchQuery(text)
  local q = lower(tostring(text or ""))
  q = q:gsub("^" .. SPACE .. "+", ""):gsub(SPACE .. "+$", ""):gsub(SPACE .. "+", " ")
  return q
end

--- How well a lower-case name matches a query: 1 the whole name, 2 the start of the name, 3 the
--- start of a word, 4 anywhere in it, 5 every word somewhere; nil when it does not. Pure.
function NS.MatchScore(lname, q, words)
  if lname == q then return 1 end
  local at = lname:find(q, 1, true)
  if at == 1 then return 2 end
  if at then
    while at do
      if not lname:sub(at - 1, at - 1):match("[0-9a-z]") then return 3 end
      at = lname:find(q, at + 1, true)
    end
    return 4
  end
  if words and #words > 1 then
    for _, w in ipairs(words) do
      if not lname:find(w, 1, true) then return nil end
    end
    return 5
  end
  return nil
end

local function better(a, b)
  if a.score ~= b.score then return a.score < b.score end
  if a.priced ~= b.priced then return a.priced end
  if #a.name ~= #b.name then return #a.name < #b.name end
  if a.name ~= b.name then return a.name < b.name end
  return a.id < b.id
end

--- Items whose names match the text, best first: { { id, name, score, priced } }, at most
--- `limit` of them, and how many matched in all. Fewer than two letters match nothing.
function NS.SearchItems(text, market, limit)
  local q = NS.SearchQuery(text)
  if #q < MIN_QUERY then return {}, 0 end
  market = market or (NS.Market and NS.Market())
  limit = limit or DEFAULT_LIMIT
  local words = {}
  for w in q:gmatch("[^ ]+") do words[#words + 1] = w end
  local t = NS.TableFor and market and NS.TableFor(market) or nil
  local items = t and t.items or {}
  local found, byId, shownName = {}, {}, {}
  local function consider(id, name, lname)
    local score = NS.MatchScore(lname, q, words)
    local f = byId[id]
    if f then
      if score and score < f.score then f.score = score end
      return
    end
    if not score then return end
    f = { id = id, name = shownName[id] or name, score = score, priced = (NS.Price and NS.Price(id, market)) ~= nil }
    byId[id] = f
    found[#found + 1] = f
  end
  -- The client's names first, so a match shows in the player's language. Under pcall: a client
  -- whose cache calls misbehave still gets the shipped names rather than an error.
  if C_Item and C_Item.IsItemDataCachedByID then
    pcall(function()
      for id in pairs(items) do
        local name = clientName(id)
        if name then
          shownName[id] = name
          consider(id, name, lower(name))
        end
      end
    end)
  end
  local s = NS.ShippedNames()
  for i = 1, s.n do consider(s.ids[i], s.names[i], s.lower[i]) end
  table.sort(found, better)
  local out = {}
  for i = 1, math.min(limit, #found) do out[i] = found[i] end
  return out, #found
end

--- The item the player meant: a shift-clicked link, an id, a whole name the client knows, or the
--- one item a search finds (or the one whose whole name it is). Returns id, name; or, when the
--- text fits several items or none, nil, the best matches and how many matched.
function NS.FindItem(text, market, limit)
  local id, name = NS.ItemFrom(text)
  if id then return id, name end
  local matches, total = NS.SearchItems(text, market, limit)
  local first, second = matches[1], matches[2]
  if total == 1 or (first and first.score == 1 and not (second and second.score == 1)) then
    return first.id, first.name
  end
  return nil, matches, total
end

local function shown(text)
  local s = NS.SearchQuery(text)
  if #s > 40 then
    local cut = 40
    -- Back to the start of a UTF-8 character: continuation bytes are 0x80 to 0xBF.
    while cut > 1 and s:byte(cut + 1) and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) < 0xC0 do cut = cut - 1 end
    s = s:sub(1, cut)
    -- The client doubles a typed pipe; a lone one left by the cut would start an escape code.
    local pipes = #(s:match("|*$"))
    if pipes % 2 == 1 then s = s:sub(1, -2) end
    s = s .. "..."
  end
  return s
end

--- What to say when nothing was found; `chat` for a slash command, which has no box. Pure.
function NS.NoMatchText(text, chat)
  local q = NS.SearchQuery(text)
  local where = chat and "shift-click its link after the command" or "shift-click a link into the box"
  if q == "" then return "Type part of an item name, or " .. where end
  if #q < MIN_QUERY then return "Type at least two letters of the item's name" end
  return string.format('No priced item has "%s" in its name. Try fewer letters, or %s', shown(text), where)
end

--- The line over a list of matches; `verb` says what picking does ("watch"), pricing by default.
function NS.ManyMatchText(text, shownCount, total, verb)
  local pick = verb and ("pick one to " .. verb) or "pick one"
  if total > shownCount then
    return string.format('%d items match "%s". The closest %d are listed: %s, or type more of the name', total, shown(text), shownCount, pick)
  end
  return string.format('%d items match "%s": %s from the list', total, shown(text), pick)
end

--- Menu entries for a list of matches, each with its price on the market; picking one calls
--- onPick(id, name).
function NS.MatchEntries(matches, market, onPick)
  local UI = NS.UI
  local entries, seen = {}, {}
  for _, m in ipairs(matches) do seen[m.name] = (seen[m.name] or 0) + 1 end
  for _, m in ipairs(matches) do
    local p = NS.Price and NS.Price(m.id, market) or nil
    local price = (p and p.median) and NS.Gold(p.median) or (UI.GREY .. "not listed" .. UI.R)
    entries[#entries + 1] = {
      -- Two items of one name are told apart by id.
      text = seen[m.name] > 1 and (m.name .. UI.GREY .. "  item " .. m.id .. UI.R) or m.name,
      right = price,
      onClick = function() onPick(m.id, m.name) end,
    }
  end
  return entries
end

--- For chat: the item, or a line naming the closest matches.
function NS.FindItemForChat(text, usage)
  local id, a, total = NS.FindItem(text, nil, 5)
  if id then return id, a end
  if (total or 0) == 0 then
    NS.Print(NS.SearchQuery(text) == "" and usage or (NS.NoMatchText(text, true) .. "."))
    return nil
  end
  local names = {}
  for _, m in ipairs(a) do names[#names + 1] = m.name end
  NS.Print(string.format("%d items match: %s%s. Type more of the name, or shift-click a link.",
    total, table.concat(names, ", "), total > #names and ", ..." or ""))
  return nil
end
