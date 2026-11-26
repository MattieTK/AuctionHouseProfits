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

-- Items the game reports a sell price for that vendors won't buy ("The
-- merchant doesn't want that item"). Everything that counts on selling to a
-- vendor treats them as worth nothing there: the sniper never lists them, and
-- unsold stacks of them aren't counted as vendored. Add each one with where
-- the report came from.
M.VENDOR_REFUSES = {
    [6947] = true, -- Instant Poison (Rank 1): Blizzard bug report, 2026-11-13
}

-- What a vendor pays for one, from the sell price the game reports.
function M.VendorPays(id, sellPrice)
    if M.VENDOR_REFUSES[id] or not M.Number(sellPrice) or sellPrice <= 0 then return 0 end
    return sellPrice
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
-- levels.truncated is set when dearer levels were cut off by the limit.
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
    local truncated = #levels > (limit or 12)
    for i = #levels, (limit or 12) + 1, -1 do levels[i] = nil end
    levels.truncated = truncated or nil
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
-- Market demand, from your scan history
---------------------------------------------------------------------------
-- Each history point keeps the order book it saw: units at each price.
-- Stored as text, "288:35,289:1", with a trailing "+" when dearer levels
-- were cut off.
function M.EncodeDepth(levels, truncated)
    local parts = {}
    for _, l in ipairs(levels or {}) do parts[#parts + 1] = floor(l.price) .. ":" .. floor(l.qty) end
    return table.concat(parts, ",") .. (truncated and "+" or "")
end

function M.DecodeDepth(text)
    if type(text) ~= "string" then return nil end
    local levels = {}
    for price, qty in text:gmatch("(%d+):(%d+)") do
        levels[#levels + 1] = { price = tonumber(price), qty = tonumber(qty) }
    end
    table.sort(levels, function(a, b) return a.price < b.price end)
    return levels, text:sub(-1) == "+"
end

-- What happened between two order books. Buyers take the cheapest units
-- first, so units gone from the cheap end were bought: every level that
-- emptied, up to and including the first one with units still left. Units
-- gone from dearer levels while cheaper ones sat untouched were cancelled
-- or expired, not bought. Units that weren't there before are new supply.
-- New listings at a price that was also bought from hide some purchases,
-- so "bought" is a floor. Prices past a cut-off book are left out.
function M.CompareDepth(a, aCut, b, bCut)
    local aTop = aCut and a[#a] and a[#a].price or huge
    local bTop = bCut and b[#b] and b[#b].price or huge
    local inA, inB = {}, {}
    for _, l in ipairs(a) do inA[l.price] = (inA[l.price] or 0) + l.qty end
    for _, l in ipairs(b) do inB[l.price] = (inB[l.price] or 0) + l.qty end
    local bought, removed, buying = 0, 0, true
    for _, l in ipairs(a) do
        if l.price > bTop then break end
        local left = inB[l.price] or 0
        local gone = max(0, l.qty - left)
        if buying then
            bought = bought + gone
            if left > 0 then buying = false end
        else
            removed = removed + gone
        end
    end
    local added = 0
    for _, l in ipairs(b) do
        if l.price <= aTop then added = added + max(0, l.qty - (inA[l.price] or 0)) end
    end
    return { bought = bought, added = added, removed = removed }
end

M.ACTIVITY = {
    busy = { label = "Busy", rank = 4 },
    active = { label = "Active", rank = 3 },
    slow = { label = "Slow", rank = 2 },
    stagnant = { label = "Stagnant", rank = 1 },
}
-- Over a long gap listings expire and get relisted, which looks like buying;
-- only compare scans this close together.
M.PAIR_MAX = 8 * 3600
local MIN_SPAN = 1800        -- under half an hour of scans says little
local STAGNANT_SPAN = 3 * 3600 -- nothing bought over this long is stagnant

-- history = { { t = time, p = lowest price, q = units listed, d = depth text } },
-- oldest first. Demand is measured from what was bought between scans,
-- relative to how much is on the market:
--   busy      the whole market sells about once a day or faster
--   active    a fifth of it a day (a tenth, if bought from in most rescans)
--   slow      some buying
--   stagnant  nothing bought in 3h+ of scans, however much was listed
-- Supply that grows while little is bought is flagged as piling up.
function M.Activity(history, now, days)
    local since = (now or 0) - (days or 7) * 86400
    local pts = {}
    for _, h in ipairs(history or {}) do
        if M.Number(h.t) and M.Number(h.q) and h.t >= since then pts[#pts + 1] = h end
    end
    local out = { points = #pts, last = pts[#pts], first = pts[1], boughtAt = {} }
    local span, bought, added, removed, compared, timed, buys, qtyTime = 0, 0, 0, 0, 0, 0, 0, 0
    local prev, prevCut
    for i, h in ipairs(pts) do
        local depth, cut = M.DecodeDepth(h.d)
        if depth and prev then
            local a = pts[i - 1]
            local dt = h.t - a.t
            if dt > 0 and dt <= M.PAIR_MAX then
                local c = M.CompareDepth(prev, prevCut, depth, cut)
                compared, span = compared + 1, span + dt
                bought, added, removed = bought + c.bought, added + c.added, removed + c.removed
                qtyTime = qtyTime + a.q * dt
                out.boughtAt[h] = c.bought
                if dt >= 120 then
                    timed = timed + 1
                    if c.bought > 0 then buys = buys + 1 end
                end
            end
        end
        if depth then prev, prevCut = depth, cut else prev = nil end
    end
    out.compared, out.span, out.bought, out.added, out.removed = compared, span, bought, added, removed
    if compared == 0 then return out end
    out.avgQty = qtyTime / span
    out.buyRate = timed > 0 and buys / timed or nil
    out.rescans, out.buys = timed, buys
    out.flooding = added > 0 and added >= 2 * bought
    if span < MIN_SPAN then return out end
    out.demandPerDay = bought / span * 86400
    out.supplyPerDay = added / span * 86400
    out.turnover = out.demandPerDay / max(1, out.avgQty)
    local key
    if bought == 0 then
        key = span >= STAGNANT_SPAN and "stagnant" or nil
    elseif out.turnover >= 1 or (out.turnover >= 0.3 and (out.buyRate or 0) >= 0.6) then
        key = "busy"
    elseif out.turnover >= 0.2 or (out.turnover >= 0.1 and (out.buyRate or 0) >= 0.5) then
        key = "active"
    else
        key = "slow"
    end
    out.key, out.level = key, key and M.ACTIVITY[key]
    out.confident = timed >= 3
    return out
end

-- Profit per day if you list at the front of the queue: what buyers take
-- each day, capped at what you'd list.
function M.ProfitPerDay(profitUnit, activity, listing)
    if not M.Number(profitUnit) or not activity or not M.Number(activity.demandPerDay) then return nil end
    local units = activity.demandPerDay
    if M.Number(listing) and listing > 0 then units = min(units, listing) end
    return profitUnit * units
end

-- Group history into n equal time buckets between from and to, for a chart.
-- Each bucket keeps the last listed count, the lowest price seen in it and
-- (with boughtAt from M.Activity) the units bought since the scan before.
function M.Buckets(history, from, to, n, boughtAt)
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
            local sold = boughtAt and boughtAt[h]
            if sold then b.bought = (b.bought or 0) + sold end
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

---------------------------------------------------------------------------
-- Vendor sniping: auctions a vendor would pay more for than they cost
---------------------------------------------------------------------------
-- basis "unit": every unit must make minProfit. "buy": what one purchase
-- makes in all must reach minProfit. Either way at least 1c.
local function snipeNeed(minProfit, basis, qty)
    local m = max(1, M.Number(minProfit) and minProfit or 0)
    if basis == "unit" then return m * qty end
    return m
end

-- Profit selling qty units bought for total to a vendor at sell each, or
-- nil when it doesn't clear the minimum.
function M.VendorDeal(total, qty, sell, minProfit, basis)
    if not M.Number(total) or not M.Number(qty) or qty <= 0 or not M.Number(sell) or sell <= 0 then return nil end
    local profit = sell * qty - total
    if profit < snipeNeed(minProfit, basis, qty) then return nil end
    return profit
end

-- The most a commodity purchase of qty units may cost once the server quotes
-- it. Above this it is no longer a deal.
function M.SnipeLimit(qty, sell, minProfit, basis)
    return sell * qty - snipeNeed(minProfit, basis, qty)
end

-- What to buy of a commodity. levels: cheapest first, { price, qty, mine }.
-- A purchase takes the cheapest units, so take units while each one is
-- profitable (by minProfit, for "unit") and you can pay. nil if nothing.
function M.CommodityBuy(levels, sell, minProfit, basis, money)
    if not M.Number(sell) or sell <= 0 or type(levels) ~= "table" then return nil end
    local unitNeed = basis == "unit" and max(1, M.Number(minProfit) and minProfit or 0) or 1
    local qty, cost, top, first = 0, 0, nil, nil
    for _, l in ipairs(levels) do
        if not M.Number(l.price) or sell - l.price < unitNeed then break end
        local take = (l.qty or 0) - (l.mine or 0)
        if M.Number(money) and l.price > 0 then take = min(take, floor((money - cost) / l.price)) end
        if take > 0 then
            qty, cost, top = qty + take, cost + take * l.price, l.price
            first = first or l.price
        end
        if M.Number(money) and money - cost < l.price then break end
    end
    if qty == 0 then return nil end
    local profit = M.VendorDeal(cost, qty, sell, minProfit, basis)
    if not profit then return nil end
    -- best: what the cheapest unit makes, the most any one item makes.
    return { qty = qty, cost = cost, profit = profit, maxPrice = top, best = sell - first }
end

-- Every unit of a commodity at or under limit each, cheapest first, as many
-- as money pays for, and no more than most. levels as for CommodityBuy. nil
-- if none.
function M.BuyUnder(levels, limit, money, most)
    if not M.Number(limit) or limit <= 0 or type(levels) ~= "table" then return nil end
    local qty, cost, top = 0, 0, nil
    for _, l in ipairs(levels) do
        if not M.Number(l.price) or l.price > limit then break end
        local take = (l.qty or 0) - (l.mine or 0)
        if M.Number(money) and l.price > 0 then take = min(take, floor((money - cost) / l.price)) end
        if M.Number(most) then take = min(take, most - qty) end
        if take > 0 then qty, cost, top = qty + take, cost + take * l.price, l.price end
        if M.Number(money) and money - cost < l.price then break end
        if M.Number(most) and qty >= most then break end
    end
    if qty == 0 then return nil end
    return { qty = qty, cost = cost, maxPrice = top }
end

-- How many of n cheap units to ask for in one purchase. Others are after the
-- same units, and the server fills a purchase from the cheapest left: ask for
-- all of them and if anyone beats you to some, the rest come from dearer
-- listings and the whole purchase is cancelled. So up to BUY_ALL_UPTO, all of
-- them; past that, half (never fewer than BUY_ALL_UPTO). Each miss in a row
-- halves it again, down to one.
M.BUY_ALL_UPTO = 5
function M.BuyShare(n, misses)
    n = M.Number(n) and floor(n) or 0
    if n <= 0 then return 0 end
    local q = n <= M.BUY_ALL_UPTO and n or max(M.BUY_ALL_UPTO, math.ceil(n / 2))
    for _ = 1, M.Number(misses) and misses or 0 do q = math.ceil(q / 2) end
    return max(1, min(n, q))
end

-- levels with the qty cheapest units (not your own) taken out: the book
-- after you bought them.
function M.TakeCheapest(levels, qty)
    local out, left = {}, M.Number(qty) and qty or 0
    for _, l in ipairs(type(levels) == "table" and levels or {}) do
        local take = min(left, max(0, (l.qty or 0) - (l.mine or 0)))
        left = left - take
        if (l.qty or 0) - take > 0 then
            out[#out + 1] = { price = l.price, qty = l.qty - take, mine = l.mine }
        end
    end
    return out
end

-- Which item (non-commodity) auctions to buy, best first. The AH groups
-- identical auctions into one row: qty is how many, buyout is the price of
-- each, and one purchase buys one of them. auctions: { auctionID, qty,
-- buyout (each), mine }. Each row's profit is per purchase. nil if none.
function M.ItemBuys(auctions, sell, minProfit, basis, money)
    if type(auctions) ~= "table" then return nil end
    local list, qty, cost, profit = {}, 0, 0, 0
    for _, a in ipairs(auctions) do
        local n = M.Number(a.qty) and a.qty or 0
        local p = n > 0 and not a.mine and (not M.Number(money) or (M.Number(a.buyout) and a.buyout <= money))
            and M.VendorDeal(a.buyout, 1, sell, minProfit, basis)
        if p then
            list[#list + 1] = { auctionID = a.auctionID, qty = n, buyout = a.buyout, profit = p }
            qty, cost, profit = qty + n, cost + a.buyout * n, profit + p * n
        end
    end
    if #list == 0 then return nil end
    table.sort(list, function(a, b)
        if a.profit ~= b.profit then return a.profit > b.profit end
        if a.buyout ~= b.buyout then return a.buyout < b.buyout end
        return (a.auctionID or 0) < (b.auctionID or 0)
    end)
    return { auctions = list, qty = qty, cost = cost, profit = profit, best = list[1].profit }
end

-- Profit per bag slot for what one press buys: qty units making profit in
-- all, stacking stack to a slot. Unstackable items take a slot each, so it's
-- the profit of the best one (each).
function M.PerSlot(profit, qty, each, stack)
    stack = M.Number(stack) and stack >= 1 and floor(stack) or 1
    if stack == 1 or not M.Number(qty) or qty <= 0 then return each end
    return profit / math.ceil(qty / stack)
end

-- A full-scan snapshot's auctions of one commodity as an order book, cheapest
-- first, for M.CommodityBuy. flat = { count1, buyout1, ... }, buyout per auction.
function M.FlatLevels(flat)
    local levels = {}
    if type(flat) ~= "table" then return levels end
    for i = 1, #flat - 1, 2 do
        local n, total = flat[i], flat[i + 1]
        if M.Number(n) and n > 0 and M.Number(total) then levels[#levels + 1] = { price = total / n, qty = n } end
    end
    table.sort(levels, function(a, b) return a.price < b.price end)
    return levels
end

-- An estimate from a full-scan snapshot. flat = { count1, buyout1, count2,
-- buyout2, ... } for every auction of one item.
function M.EstimateDeal(flat, sell, minProfit, basis)
    if type(flat) ~= "table" then return nil end
    local qty, cost, profit, best = 0, 0, 0, nil
    for i = 1, #flat - 1, 2 do
        local p = M.VendorDeal(flat[i + 1], flat[i], sell, minProfit, basis)
        if p then
            qty, cost, profit = qty + flat[i], cost + flat[i + 1], profit + p
            best = math.max(best or p / flat[i], p / flat[i])
        end
    end
    if qty == 0 then return nil end
    return { qty = qty, cost = cost, profit = profit, best = best }
end

---------------------------------------------------------------------------
-- Earnings ledger
---------------------------------------------------------------------------
-- One record per day ("YYYY-MM-DD"), split by where the money came from:
--   s: vendor sniper buys { n, units, spent, value }, value = what vendors pay
--   a: your auction sales { n, units, gross, net, profit, costed }, profit and
--      costed cover only sales whose cost is known
M.LEDGER_FIELDS = {
    s = { "n", "units", "spent", "value" },
    a = { "n", "units", "gross", "net", "profit", "costed" },
}

function M.IsDayKey(key)
    return type(key) == "string" and key:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

function M.LedgerAdd(day, source, add)
    local fields = M.LEDGER_FIELDS[source]
    if type(day) ~= "table" or not fields or type(add) ~= "table" then return end
    local rec = day[source]
    if type(rec) ~= "table" then rec = {}; day[source] = rec end
    for _, k in ipairs(fields) do
        rec[k] = (M.Number(rec[k]) and rec[k] or 0) + (M.Number(add[k]) and add[k] or 0)
    end
end

-- Profit in one day's (or a summed) record.
function M.LedgerProfit(rec)
    local s, a = rec and rec.s, rec and rec.a
    local snipe = s and (s.value or 0) - (s.spent or 0) or 0
    local sales = a and a.profit or 0
    return snipe + sales, snipe, sales
end

-- Totals of every day from `from` to `to` (inclusive keys; either may be nil).
function M.LedgerSum(days, from, to)
    local out, n = { s = {}, a = {} }, 0
    for source, fields in pairs(M.LEDGER_FIELDS) do
        for _, k in ipairs(fields) do out[source][k] = 0 end
    end
    for key, day in pairs(type(days) == "table" and days or {}) do
        if M.IsDayKey(key) and (not from or key >= from) and (not to or key <= to) then
            n = n + 1
            for source in pairs(M.LEDGER_FIELDS) do
                if type(day[source]) == "table" then M.LedgerAdd(out, source, day[source]) end
            end
        end
    end
    out.days = n
    out.profit, out.snipe, out.sales = M.LedgerProfit(out)
    return out
end
