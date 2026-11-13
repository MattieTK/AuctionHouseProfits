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
    for _, step in ipairs(LADDER_STEPS) do add(reference * step, step == 1 and "market" or nil) end
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
