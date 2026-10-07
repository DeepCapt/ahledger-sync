--[[
  Mailbox summary. When the mailbox opens, one chat line says what the auction house sent:
  "mail: 3 sold for 48g, 2 expired, 1 outbid". The summary stays on the ledger bar's tooltip
  until the next mailbox. Nothing is opened, taken, or deleted; the inbox headers the client
  already has are counted, that is all.
]]
local _, NS = ...

-- The subjects the auction house writes, from the client's own strings so other languages
-- work, with the English as the fallback. "%s" and whatever follows it is the item's name.
local KINDS = {
  { "sold", "AUCTION_SOLD_MAIL_SUBJECT", "Auction successful: %s" },
  { "pending", "AUCTION_INVOICE_MAIL_SUBJECT", "Sale Pending: %s" },
  { "expired", "AUCTION_EXPIRED_MAIL_SUBJECT", "Auction expired: %s" },
  { "outbid", "AUCTION_OUTBID_MAIL_SUBJECT", "Outbid on %s" },
  { "won", "AUCTION_WON_MAIL_SUBJECT", "Auction won: %s" },
  { "cancelled", "AUCTION_REMOVED_MAIL_SUBJECT", "Auction cancelled: %s" },
}

local patterns = nil
local function patternFor(kind)
  if not patterns then
    patterns = {}
    for _, k in ipairs(KINDS) do
      local s = type(_G[k[2]]) == "string" and _G[k[2]] or k[3]
      s = s:gsub("%%s.*$", "")
      s = s:gsub("%p", "%%%0")
      patterns[k[1]] = "^" .. s
    end
  end
  return patterns[kind]
end

-- Counts auction mails by kind. headers = { { subject, money } }. Pure, so the harness can
-- feed it subjects.
function NS.MailSummary(headers)
  local s = { sold = 0, soldMoney = 0, pending = 0, expired = 0, outbid = 0, won = 0, cancelled = 0, auctions = 0, total = #headers }
  for _, h in ipairs(headers) do
    local subject = tostring(h.subject or "")
    for _, k in ipairs(KINDS) do
      if subject:find(patternFor(k[1])) then
        s[k[1]] = s[k[1]] + 1
        s.auctions = s.auctions + 1
        if k[1] == "sold" then s.soldMoney = s.soldMoney + (tonumber(h.money) or 0) end
        break
      end
    end
  end
  return s
end

-- "mail: 3 sold for 48g, 2 expired, 1 outbid", or nil when no auction mail is there.
function NS.MailSummaryText(s)
  if not s or (s.auctions or 0) == 0 then return nil end
  local parts = {}
  local function plural(n, word) return string.format("%d %s", n, word) end
  if s.sold > 0 then parts[#parts + 1] = string.format("%d sold for %s", s.sold, NS.Gold(s.soldMoney)) end
  if s.pending > 0 then parts[#parts + 1] = plural(s.pending, "pending") end
  if s.expired > 0 then parts[#parts + 1] = plural(s.expired, "expired") end
  if s.outbid > 0 then parts[#parts + 1] = plural(s.outbid, "outbid") end
  if s.won > 0 then parts[#parts + 1] = plural(s.won, "won") end
  if s.cancelled > 0 then parts[#parts + 1] = plural(s.cancelled, "cancelled") end
  return "mail: " .. table.concat(parts, ", ")
end

local announced = false

local function summarise()
  if not NS.Setting("mailSummary") or not GetInboxNumItems or not GetInboxHeaderInfo then return end
  local n = GetInboxNumItems() or 0
  if n == 0 then return end
  local headers = {}
  for i = 1, n do
    local _, _, _, subject, money = GetInboxHeaderInfo(i)
    headers[#headers + 1] = { subject = subject, money = money }
  end
  local s = NS.MailSummary(headers)
  NS.LastMail = s
  NS.LastMail.at = NS.Now()
  announced = true
  local text = NS.MailSummaryText(s)
  if text then NS.Print(text) end
  if NS.RefreshBar then NS.RefreshBar() end
end

local frame = CreateFrame("Frame", "AHledgerMailFrame")
for _, e in ipairs({ "MAIL_SHOW", "MAIL_INBOX_UPDATE", "MAIL_CLOSED" }) do pcall(frame.RegisterEvent, frame, e) end
frame:SetScript("OnEvent", function(_, event)
  if event == "MAIL_SHOW" then
    announced = false
  elseif event == "MAIL_INBOX_UPDATE" then
    -- Headers arrive a moment after the box opens; the first update with mail in it is the one.
    if not announced then summarise() end
  elseif event == "MAIL_CLOSED" then
    announced = false
  end
end)
