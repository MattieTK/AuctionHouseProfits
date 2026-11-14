-- Pure auction math. No WoW API calls: everything here is unit-tested offline.
local _, ns = ...
local M = {}
ns.Model = M

local floor, max, min, huge = math.floor, math.max, math.min, math.huge

M.DURATION_HOURS = { 8, 12, 24 }
M.VENUES = { "faction", "neutral" }
-- UnitReaction() values for faction standings that can buy from a vendor.
M.STANDINGS = {
    { reaction = 4, key = "neutral",  label = "Neutral" },
    { reaction = 5, key = "friendly", label = "Friendly" },
    { reaction = 6, key = "honored",  label = "Honored" },
    { reaction = 7, key = "revered",  label = "Revered" },
    { reaction = 8, key = "exalted",  label = "Exalted" },
}
M.STANDING_BY_REACTION = {}
for _, s in ipairs(M.STANDINGS) do M.STANDING_BY_REACTION[s.reaction] = s end

-- WoW Forever has two vendor price tiers: full price below Honored, one
-- discount from Honored up. reaction is the tier's representative standing.
M.TIERS = {
    { reaction = 4, key = "full", label = "Below Honored" },
    { reaction = 6, key = "honored", label = "Honored+" },
}
function M.Tier(reaction)
    return (reaction or 4) >= 6 and M.TIERS[2] or M.TIERS[1]
end

-- Vendors in this era typically sell at 4x the price they pay you.
M.VENDOR_MARKUP = 4

function M.Number(v)
    return type(v) == "number" and v == v and v ~= huge and v ~= -huge
end

local function clamp(v, lo, hi) return max(lo, min(hi, v)) end

---------------------------------------------------------------------------
-- Money text
---------------------------------------------------------------------------
function M.Split(copper)
    copper = floor(math.abs(copper) + 0.5)
    return floor(copper / 10000), floor(copper % 10000 / 100), copper % 100
end

function M.MoneyText(copper, plus)
    if not M.Number(copper) then return "-" end
    local g, s, c = M.Split(copper)
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
    local sign = ""
    if copper <= -0.5 then sign = "-" elseif plus and copper >= 0.5 then sign = "+" end
    return sign .. table.concat(parts, " ")
end

-- Accepts "1g 20s 5c", "20s", "1.25" (gold), "1.25g", "350c", "1g20s".
-- Returns copper (integer) or nil.
function M.ParseMoney(text)
    if type(text) ~= "string" then return nil end
    local s = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    local plain = s:match("^(%d+%.?%d*)$") or s:match("^(%.%d+)$")
    if plain then return floor(tonumber(plain) * 10000 + 0.5) end
    local total, matched = 0, false
    local rest = s:gsub("(%d+%.?%d*)%s*([gsc])", function(num, unit)
        local value = tonumber(num)
        if not value then return end
        matched = true
        total = total + value * (unit == "g" and 10000 or unit == "s" and 100 or 1)
        return ""
    end)
    if not matched or rest:gsub("[%s,]", "") ~= "" then return nil end
    return floor(total + 0.5)
end

-- Gold, silver and copper boxes to copper. Blank boxes count as zero; all
-- blank (or non-numeric) returns nil.
function M.Coins(g, s, c)
    local total, any, parts = 0, false, { g, s, c }
    for i = 1, 3 do
        local v = parts[i] -- not ipairs: a nil box would end the loop early
        local text = type(v) == "string" and v:gsub("^%s+", ""):gsub("%s+$", "") or v
        if text ~= nil and text ~= "" then
            local n = tonumber(text)
            if not n or n < 0 or n ~= floor(n) then return nil end
            any = true
            total = total + n * (i == 1 and 10000 or i == 2 and 100 or 1)
        end
    end
    return any and total or nil
end

---------------------------------------------------------------------------
-- Rules
---------------------------------------------------------------------------
-- rules = { cutFaction, cutNeutral (percent), depositPerHour (percent of vendor
-- sell price per hour), neutralMultiplier, minDeposit (copper),
-- discounts = { [reaction] = percent } }

function M.Discount(rules, reaction)
    local d = rules.discounts and rules.discounts[reaction]
    return M.Number(d) and clamp(d, 0, 100) or 0
end

-- Price the vendor charges per unit at a standing, from a recorded observation.
-- observedUnit was charged at observedReaction; base = undiscounted price.
function M.BaseUnitPrice(rules, observedUnit, observedReaction)
    local d = M.Discount(rules, observedReaction)
    if d >= 100 then return observedUnit end
    return observedUnit / (1 - d / 100)
end

function M.UnitCostAt(rules, baseUnit, reaction)
    return baseUnit * (1 - M.Discount(rules, reaction) / 100)
end

function M.CutRate(rules, venue)
    local pct = venue == "neutral" and rules.cutNeutral or rules.cutFaction
    return clamp(M.Number(pct) and pct or 0, 0, 99) / 100
end

-- Deposit for one listing from the formula (used when the game can't tell us).
function M.FormulaDeposit(rules, vendorSellUnit, quantity, durationIndex, venue)
    local hours = M.DURATION_HOURS[durationIndex] or M.DURATION_HOURS[#M.DURATION_HOURS]
    local rate = (rules.depositPerHour or 0) / 100 * hours
    if venue == "neutral" then rate = rate * (rules.neutralMultiplier or 1) end
    local raw = floor((vendorSellUnit or 0) * quantity * rate)
    return max(rules.minDeposit or 0, raw)
end

---------------------------------------------------------------------------
-- Probability of selling and expected forfeited deposits
---------------------------------------------------------------------------
function M.Odds(sellChancePct, maxListings)
    local p = clamp((sellChancePct or 100) / 100, 0.01, 1)
    local m = floor(max(0, maxListings or 0))
    local q = 1 - p
    local sold, listings
    if m > 0 then
        sold = 1 - q ^ m
        listings = sold / p
    else
        sold, listings = 1, 1 / p
    end
    return { p = p, maxListings = m, pSold = sold, expListings = listings, expFailed = max(0, listings - sold) }
end

---------------------------------------------------------------------------
-- Evaluation
---------------------------------------------------------------------------
-- plan = { stackSize, stacks, unitCost, vendorSellUnit, unsold = "vendor"|"keep"|"zero",
--          odds = M.Odds(...), deposit = { faction = c, neutral = c }, rules = rules }
function M.Evaluate(plan, venue, priceUnit, exact)
    local n = max(1, floor(plan.stackSize or 1))
    local stacks = max(1, floor(plan.stacks or 1))
    local cr = M.CutRate(plan.rules, venue)
    local B = exact and floor(priceUnit * n + 0.5) or priceUnit * n
    local cut = exact and floor(B * cr) or B * cr
    local dep = plan.deposit[venue] or 0
    local o = plan.odds
    local lost = o.expFailed * dep
    local cost = (plan.unitCost or 0) * n
    local left = 0
    if plan.unsold == "vendor" then left = (plan.vendorSellUnit or 0) * n
    elseif plan.unsold == "keep" then left = cost end
    local saleNet = B - cut
    local revenue = o.pSold * saleNet + (1 - o.pSold) * left
    local profit = revenue - lost - cost
    local breakEvenStack = huge
    if o.pSold > 0 then
        breakEvenStack = (cost + lost - (1 - o.pSold) * left) / (o.pSold * (1 - cr))
    end
    return {
        venue = venue, priceUnit = priceUnit, buyout = B, cut = cut, deposit = dep, lost = lost,
        cost = cost, leftover = left, saleNet = saleNet, revenue = revenue,
        profit = profit, profitUnit = profit / n, profitTotal = profit * stacks,
        margin = B > 0 and profit / (o.pSold * B) or nil,
        roi = cost > 0 and profit / cost or nil,
        breakEvenUnit = max(0, breakEvenStack / n), pSold = o.pSold, expFailed = o.expFailed,
        depositUpfront = dep * stacks,
    }
end

-- Round a candidate price the way players type it: whole silver above 1g.
function M.NicePrice(copper)
    if copper >= 10000 then return floor(copper / 100 + 0.5) * 100 end
    return floor(copper + 0.5)
end

local LADDER_STEPS = { 1.5, 1.3, 1.2, 1.1, 1.05, 1, 0.95, 0.9, 0.8, 0.7, 0.5 }

-- Price points around a reference price, including both break-evens.
-- Returns rows sorted from highest to lowest price.
function M.Ladder(plan, reference)
    local f0 = M.Evaluate(plan, "faction", reference or 0)
    local n0 = M.Evaluate(plan, "neutral", reference or 0)
    if not M.Number(reference) or reference <= 0 then
        reference = max(M.Number(f0.breakEvenUnit) and f0.breakEvenUnit or 0, 1) * 1.25
    end
    local seen, rows = {}, {}
    local function add(price, tag, up)
        if not M.Number(price) or price < 0 then return end
        -- Break-evens round up, so the tagged row never shows a loss.
        if up then
            price = price >= 10000 and math.ceil(price / 100) * 100 or math.ceil(price)
        else
            price = M.NicePrice(price)
        end
        local row = seen[price]
        if not row then
            row = { price = price, tags = {} }
            seen[price] = row
            rows[#rows + 1] = row
        end
        if tag then row.tags[#row.tags + 1] = tag end
    end
    for _, step in ipairs(LADDER_STEPS) do add(reference * step, step == 1 and "yours" or nil) end
    if f0.breakEvenUnit < huge then add(f0.breakEvenUnit, "faction b/e", true) end
    if n0.breakEvenUnit < huge then add(n0.breakEvenUnit, "neutral b/e", true) end
    table.sort(rows, function(a, b) return a.price > b.price end)
    for _, row in ipairs(rows) do
        row.faction = M.Evaluate(plan, "faction", row.price, true)
        row.neutral = M.Evaluate(plan, "neutral", row.price, true)
    end
    return rows
end

---------------------------------------------------------------------------
-- Live market depth
---------------------------------------------------------------------------
-- results = { { price = unit copper, qty = n, mine = your units, sellers = n, seller = name } }
-- Returns price levels, cheapest first, with your units split out.
function M.Levels(results, limit)
    local by, levels = {}, {}
    for _, r in ipairs(results or {}) do
        if M.Number(r.price) and r.price > 0 and M.Number(r.qty) and r.qty > 0 then
            local price = floor(r.price + 0.5)
            local level = by[price]
            if not level then
                level = { price = price, qty = 0, mine = 0, sellers = 0 }
                by[price] = level
                levels[#levels + 1] = level
            end
            level.qty = level.qty + r.qty
            level.mine = level.mine + min(r.qty, M.Number(r.mine) and max(0, r.mine) or 0)
            level.sellers = level.sellers + (M.Number(r.sellers) and r.sellers or 1)
            if r.seller and not level.seller then level.seller = r.seller end
        end
    end
    table.sort(levels, function(a, b) return a.price < b.price end)
    for i = #levels, (limit or 12) + 1, -1 do levels[i] = nil end
    return levels
end

-- Other sellers' units that sell before a new listing at this price: every
-- cheaper unit, plus units already listed at the same price (they're older).
function M.AheadAt(levels, price)
    local ahead = 0
    for _, l in ipairs(levels or {}) do
        if l.price <= price then ahead = ahead + l.qty - (l.mine or 0) end
    end
    return ahead
end

-- The cheapest price someone else is asking, and the level it's at.
function M.LowestOther(levels)
    for _, l in ipairs(levels or {}) do
        if l.qty - (l.mine or 0) > 0 then return l.price, l end
    end
end

-- A price the AH accepts: whole copper, or whole silver (rounded down, never
-- below 1s) when the client doesn't take copper.
function M.PostablePrice(price, copperAllowed)
    price = floor(price)
    if copperAllowed == false then return max(100, floor(price / 100) * 100) end
    return max(1, price)
end

-- Default listing price: one step (1c, or 1s without copper) under the
-- cheapest other seller.
function M.Undercut(levels, copperAllowed)
    local lowest = M.LowestOther(levels)
    if lowest then return M.PostablePrice(lowest - 1, copperAllowed) end
end

-- Prices worth listing at: 1c under each level, so you sell before that
-- level and everything above it. Matching a level is never better than
-- undercutting the next one. plan (optional) adds faction/neutral profit.
function M.Positions(levels, plan, limit, copperAllowed)
    local rows, seen = {}, {}
    for _, l in ipairs(levels or {}) do
        if l.qty - (l.mine or 0) > 0 then
            local price = M.PostablePrice(l.price - 1, copperAllowed)
            if not seen[price] then
                seen[price] = true
                local row = { price = price, ahead = M.AheadAt(levels, price), undercuts = l }
                if plan then
                    row.faction = M.Evaluate(plan, "faction", price, true)
                    row.neutral = M.Evaluate(plan, "neutral", price, true)
                end
                rows[#rows + 1] = row
                if limit and #rows >= limit then break end
            end
        end
    end
    return rows
end

-- The live market as a table: one row per price level with how many are
-- listed there, and profit if you list 1c under it. A ghost row shows where
-- your own price would sit (after any units already at that price).
-- plan (optional) adds faction/neutral profit; qty = units you'd list.
function M.MarketRows(levels, plan, price, qty, limit, copperAllowed)
    local rows, ghost = {}, nil
    local function evaluate(row, at)
        if plan then
            row.faction = M.Evaluate(plan, "faction", at, true)
            row.neutral = M.Evaluate(plan, "neutral", at, true)
        end
    end
    if M.Number(price) and price > 0 then
        ghost = { ghost = true, price = price, qty = qty, ahead = M.AheadAt(levels, price) }
        evaluate(ghost, price)
    end
    for _, l in ipairs(levels or {}) do
        if ghost and not ghost.index and price < l.price then
            rows[#rows + 1] = ghost; ghost.index = #rows
        end
        local listAt = M.PostablePrice(l.price - 1, copperAllowed)
        local row = { price = l.price, qty = l.qty, mine = l.mine or 0, level = l, listAt = listAt,
            ahead = M.AheadAt(levels, listAt) }
        evaluate(row, listAt)
        rows[#rows + 1] = row
    end
    if ghost and not ghost.index then rows[#rows + 1] = ghost; ghost.index = #rows end
    limit = limit or #rows
    if #rows > limit then
        -- Keep the ghost visible: drop the dearest levels after it first.
        local keep = {}
        for i, row in ipairs(rows) do
            if i <= limit - ((ghost and ghost.index > limit) and 1 or 0) then keep[#keep + 1] = row end
        end
        if ghost and ghost.index > limit then keep[#keep + 1] = ghost end
        rows = keep
    end
    return rows
end

---------------------------------------------------------------------------
-- Market activity, from your scan history
---------------------------------------------------------------------------
-- history = { { t = time, p = lowest unit price or nil, q = units listed } },
-- oldest first. A market where the listed count moves between scans is one
-- people buy from; one that sits still is one you'd wait in.
M.ACTIVITY = {
    busy = { label = "Busy", rank = 4 },
    active = { label = "Active", rank = 3 },
    slow = { label = "Slow", rank = 2 },
    stagnant = { label = "Stagnant", rank = 1 },
}
local GAP_CAP = 86400 -- one long gap shouldn't dilute the rate

function M.Activity(history, now, days)
    local since = (now or 0) - (days or 7) * 86400
    local pts = {}
    for _, h in ipairs(history or {}) do
        if M.Number(h.t) and M.Number(h.q) and h.t >= since then pts[#pts + 1] = h end
    end
    local out = { points = #pts, last = pts[#pts], first = pts[1] }
    if #pts < 2 then return out end
    local changes, drops, adds, span, pairsSeen = 0, 0, 0, 0, 0
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        local dt = b.t - a.t
        if dt > 0 then
            pairsSeen = pairsSeen + 1
            span = span + min(dt, GAP_CAP)
            local d = b.q - a.q
            if d ~= 0 then changes = changes + 1 end
            if d < 0 then drops = drops - d else adds = adds + d end
        end
    end
    out.rescans, out.changes, out.drops, out.adds, out.span = pairsSeen, changes, drops, adds, span
    if pairsSeen == 0 then return out end
    out.changeRate = changes / pairsSeen
    -- Units that left (bought, cancelled or expired) per day: an upper bound on sales.
    if span >= 600 then out.soldPerDay = drops / span * 86400 end
    local r = out.changeRate
    local key
    if r >= 0.6 then key = "busy" elseif r >= 0.3 then key = "active" elseif r > 0 then key = "slow" else key = "stagnant" end
    -- A quiet hour says little; only call a market stagnant over real time.
    if key == "stagnant" and span < 3 * 3600 then key = "slow" end
    out.key = key
    out.level = M.ACTIVITY[key]
    out.confident = pairsSeen >= 3
    return out
end

-- Profit per day if you list at the front of the queue: what leaves the
-- market each day, capped at what you'd list.
function M.ProfitPerDay(profitUnit, activity, listing)
    if not M.Number(profitUnit) or not activity or not M.Number(activity.soldPerDay) then return nil end
    local units = activity.soldPerDay
    if M.Number(listing) and listing > 0 then units = min(units, listing) end
    return profitUnit * units
end

-- Group history into n equal time buckets between from and to, for a chart.
-- Each bucket keeps the last listed count and the lowest price seen in it.
function M.Buckets(history, from, to, n)
    local buckets = {}
    for i = 1, n do buckets[i] = { from = from + (to - from) * (i - 1) / n, to = from + (to - from) * i / n } end
    if to <= from then return buckets end
    for _, h in ipairs(history or {}) do
        if M.Number(h.t) and h.t >= from and h.t <= to then
            local i = min(n, floor((h.t - from) / (to - from) * n) + 1)
            local b = buckets[i]
            b.q, b.t = h.q, h.t
            if M.Number(h.p) and (not b.p or h.p < b.p) then b.p = h.p end
            b.n = (b.n or 0) + 1
        end
    end
    return buckets
end

-- What one sale actually made: gross buyout less the cut, less what the
-- units cost. The deposit comes back on a sale, so it isn't counted.
function M.SaleProfit(gross, qty, unitCost, cutRate)
    local cut = floor(gross * (cutRate or 0))
    local net = gross - cut
    local cost = M.Number(unitCost) and unitCost * qty or nil
    return { gross = gross, cut = cut, net = net, cost = cost, profit = cost and net - cost or nil }
end

-- A single listing of qty units at price, if it sells.
function M.Quote(qty, priceUnit, unitCost, cutRate, deposit)
    local gross = floor(priceUnit * qty + 0.5)
    local sale = M.SaleProfit(gross, qty, unitCost, cutRate)
    sale.deposit = deposit
    sale.profitUnit = sale.profit and sale.profit / qty or nil
    return sale
end

---------------------------------------------------------------------------
-- Vendor discount calibration
---------------------------------------------------------------------------
-- ratio = observed unit price / (vendor sell price * markup). A ratio of 0.9
-- across many items means this vendor gives you 10% off at that standing.
function M.SampleRatio(observedUnit, vendorSellUnit)
    if not M.Number(observedUnit) or not M.Number(vendorSellUnit) or vendorSellUnit <= 0 then return nil end
    local r = observedUnit / (vendorSellUnit * M.VENDOR_MARKUP)
    if r < 0.6 or r > 1.05 then return nil end -- recipes and specials don't follow the markup
    return r
end

function M.MedianDiscount(ratios)
    local list = {}
    for _, r in ipairs(ratios or {}) do if M.Number(r) then list[#list + 1] = r end end
    if #list == 0 then return nil, 0 end
    table.sort(list)
    local mid = #list / 2
    local median = (#list % 2 == 1) and list[floor(mid) + 1] or (list[mid] + list[mid + 1]) / 2
    local pct = (1 - median) * 100
    return max(0, floor(pct * 2 + 0.5) / 2), #list
end
