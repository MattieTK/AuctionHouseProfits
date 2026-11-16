-- What the addon has made you, from the earnings ledger (Data.lua): the
-- sniper's buys at what vendors pay for them, and your auction sales of
-- items whose cost is known. Shown in the sniper panel, on the Profits tab
-- and by /ahp made.
local _, ns = ...
local M, D, U = ns.Model, ns.Data, ns.UI
local E = {}
ns.Earnings = E

local DAY = 86400
local MUTED = "ff9d9a8f"
local dateFn = date or (os and os.date)
local function color(hex, s) return "|c" .. hex .. s .. "|r" end
local function count(n) return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n) end
local function plural(n, one, many) return count(n) .. " " .. (n == 1 and one or many) end
local function made(copper) return U.Money(copper, true, true) end

local function since(now, back) return D.DayKey(now - back * DAY) end

-- { label, sum } for today, the last 7 and 30 days, and everything.
function E.Periods(now)
    local days = D:Ledger()
    return {
        { label = "Today", sum = M.LedgerSum(days, since(now, 0)) },
        { label = "Last 7 days", sum = M.LedgerSum(days, since(now, 6)) },
        { label = "Last 30 days", sum = M.LedgerSum(days, since(now, 29)) },
        { label = "In all", sum = M.LedgerSum(days) },
    }
end

-- The last n days, oldest first: { label, profit }.
function E.Days(now, n)
    local days, out = D:Ledger(), {}
    for back = n - 1, 0, -1 do
        local t = now - back * DAY
        local day = days[D.DayKey(t)]
        out[#out + 1] = { label = back == 0 and "Today" or dateFn("%a %d %b", t), profit = (M.LedgerProfit(day)) }
    end
    return out
end

function E.Short(now)
    local p = E.Periods(now)
    return "Made " .. made(p[1].sum.profit) .. " today · " .. made(p[4].sum.profit) .. " in all"
end

-- Where the all-time total came from, as lines of text.
local function breakdown(sum)
    local lines = {}
    local s, a = sum.s, sum.a
    if s.n > 0 then
        lines[#lines + 1] = string.format("Vendor sniper: %s, %s, paid %s, vendors pay %s: %s",
            plural(s.n, "buy", "buys"), plural(s.units, "item", "items"), U.Money(s.spent), U.Money(s.value), made(sum.snipe))
    else
        lines[#lines + 1] = "Vendor sniper: nothing bought yet."
    end
    if a.costed > 0 then
        lines[#lines + 1] = string.format("Auction sales: %s with a known cost: %s",
            plural(a.costed, "sale", "sales"), made(sum.sales))
    else
        lines[#lines + 1] = "Auction sales: none with a known cost yet."
    end
    if a.n > a.costed then
        lines[#lines + 1] = color(MUTED, plural(a.n - a.costed, "sale", "sales")
            .. " of items with no known cost aren't counted.")
    end
    return lines
end

local function started()
    local t = D:LedgerSince()
    return t and ("Counting since " .. dateFn("%d %b %Y", t) .. ".") or nil
end

function E:Tooltip(t, now)
    local periods = self.Periods(now)
    t:AddLine("Made by Auction House Profits")
    for _, p in ipairs(periods) do t:AddDoubleLine(p.label, made(p.sum.profit), 1, 1, 1) end
    t:AddLine(" ")
    for _, line in ipairs(breakdown(periods[4].sum)) do t:AddLine(line, 1, 1, 1, true) end
    t:AddLine(" ")
    t:AddLine("Last 7 days")
    for _, d in ipairs(self.Days(now, 7)) do
        t:AddDoubleLine(d.label, d.profit ~= 0 and made(d.profit) or color(MUTED, "-"), 1, 1, 1)
    end
    t:AddLine(" ")
    t:AddLine("Sniper buys count what a vendor pays for them, so sell them to one to collect it.", .62, .6, .56, true)
    local from = started()
    if from then t:AddLine(from, .62, .6, .56, true) end
end

-- For /ahp made: one line per period, the breakdown, then the last 7 days.
function E:Report(now)
    local periods = self.Periods(now)
    local out, parts = {}, {}
    for _, p in ipairs(periods) do parts[#parts + 1] = p.label:lower() .. " " .. made(p.sum.profit) end
    out[1] = "Made " .. table.concat(parts, ", ") .. "."
    for _, line in ipairs(breakdown(periods[4].sum)) do out[#out + 1] = line end
    local days = {}
    for _, d in ipairs(self.Days(now, 7)) do days[#days + 1] = d.label .. " " .. made(d.profit) end
    out[#out + 1] = "Last 7 days: " .. table.concat(days, ", ")
    out[#out + 1] = started()
    return out
end
