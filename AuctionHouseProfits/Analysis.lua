-- Turns recorded data + settings into numbers the views draw.
local _, ns = ...
local M, D, P, R = ns.Model, ns.Data, ns.Prices, ns.Merchant
local A = {}
ns.Analysis = A

local function readable(v) return not (issecretvalue and issecretvalue(v)) end

local function itemIDFromLink(text)
    local id = type(text) == "string" and text:match("item:(%d+)")
    return id and tonumber(id) or nil
end
A.ItemIDFromLink = itemIDFromLink

-- Item info requests we're waiting on, and IDs the client said don't exist.
A.requested, A.failed = {}, {}

-- Static info, preferring the live item cache over what we saved.
function A.Info(id)
    local saved = D:Item(id) or {}
    local live = not A.failed[id] and R.ItemInfo(id) or nil
    if not live and not A.failed[id] then A.requested[id] = true end
    local info = {}
    for k, v in pairs(saved) do info[k] = v end
    if live then for k, v in pairs(live) do info[k] = v end end
    info.id = id
    info.name = info.name or ("item:" .. id)
    info.maxStack = M.Number(info.maxStack) and info.maxStack > 0 and info.maxStack or 1
    info.sellPrice = M.Number(info.sellPrice) and info.sellPrice or 0
    return info
end

-- Game-computed deposit for a stack, when the AH is open. nil otherwise.
local function gameDeposit(id, durationIndex, quantity)
    if not P.ahOpen or not C_AuctionHouse or not C_AuctionHouse.CalculateCommodityDeposit then return nil end
    local ok, v = pcall(C_AuctionHouse.CalculateCommodityDeposit, id, durationIndex, quantity)
    if ok and readable(v) and M.Number(v) and v > 0 then
        if C_AuctionHouse.SupportsCopperValues and not C_AuctionHouse.SupportsCopperValues() then
            v = math.ceil(v / 100) * 100 -- matches the Blizzard sell frame
        end
        return v
    end
end

-- The duration last picked on Blizzard's Sell page (a CVar), if enabled.
local function ahDuration(app)
    if not app:Get("durationFromAH") or not GetCVar then return nil end
    local ok, v = pcall(GetCVar, "auctionHouseDurationDropdown")
    v = ok and tonumber(v)
    return (v == 1 or v == 2 or v == 3) and v or nil
end
A.AHDuration = ahDuration

function A.BagCount(id)
    if C_Item and C_Item.GetItemCount then
        local ok, n = pcall(C_Item.GetItemCount, id, false, false, false)
        if ok and readable(n) and M.Number(n) then return n end
    end
    local n = 0
    if not C_Container or not C_Container.GetContainerNumSlots then return n end
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
    for bag = 0, last do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if type(info) == "table" and info.itemID == id then n = n + (M.Number(info.stackCount) and info.stackCount or 1) end
        end
    end
    return n
end

-- Every vendor seen selling an item, best first: cheapest at your standing
-- with each (as the game last reported it; the price may have been seen
-- before you ranked up), then the one you stand best with, then unlimited
-- stock, then the one seen most recently.
function A.Offers(rules, vendors)
    local list = {}
    for _, v in pairs(vendors or {}) do
        local current, seenAt = D:Standing(v.npc)
        local standing = current or v.reaction or 4
        local base = M.BaseUnitPrice(rules, v.price / v.qty, v.reaction or 4)
        list[#list + 1] = { vendor = v, standing = standing, standingTime = seenAt or v.time, base = base,
            cost = M.UnitCostAt(rules, base, standing) }
    end
    table.sort(list, function(a, b)
        if math.abs(a.cost - b.cost) > 1e-6 then return a.cost < b.cost end
        if a.standing ~= b.standing then return a.standing > b.standing end
        if (a.vendor.limited == true) ~= (b.vendor.limited == true) then return not a.vendor.limited end
        if (a.vendor.time or 0) ~= (b.vendor.time or 0) then return (a.vendor.time or 0) > (b.vendor.time or 0) end
        return (a.vendor.npc or "") < (b.vendor.npc or "")
    end)
    return list
end

-- Full analysis for one item.
function A.Item(app, id, now)
    now = now or time()
    local rules = ns.Rules(app)
    local info = A.Info(id)
    local saved = D:Item(id)
    local plan = D:Plan(id)
    local offers = A.Offers(rules, D:Vendors(id))
    local pick = offers[1]
    local vendor = pick and pick.vendor

    local out = { id = id, info = info, rules = rules, vendor = vendor, offers = offers }
    if pick then
        out.observedUnit = vendor.price / vendor.qty
        out.baseUnit = pick.base
    end
    out.standing = pick and pick.standing or 4
    out.standingTime = pick and pick.standingTime
    out.costOverride = M.Number(plan.cost) and plan.cost or nil
    if out.costOverride then
        out.unitCost = out.costOverride
    elseif out.baseUnit then
        out.unitCost = M.UnitCostAt(rules, out.baseUnit, out.standing)
    end

    out.stackSize = M.Number(plan.stackSize) and plan.stackSize >= 1 and math.floor(plan.stackSize) or info.maxStack
    out.stacks = M.Number(plan.stacks) and plan.stacks >= 1 and math.floor(plan.stacks) or app:Get("defaultStacks")
    out.duration = (plan.duration == 1 or plan.duration == 2 or plan.duration == 3) and plan.duration
        or ahDuration(app) or app:Get("duration")

    out.market = P:Resolve(id, info.link, app:Get("priceSource"), app:Get("scanFreshMinutes") * 60, now)
    out.prices = P:All(id, info.link, now)
    local scan = D:Scan(id)
    out.levels = scan and scan.levels and #scan.levels > 0 and scan.levels or nil
    out.levelsAge = out.levels and now - scan.time or nil
    out.listed = scan and scan.qty

    -- The price everything is evaluated at: yours, else 1c under the
    -- cheapest other seller, else the market price.
    local copper = ns.Post.CopperAllowed()
    out.undercut = M.Undercut(out.levels, copper)
    if M.Number(plan.price) and plan.price > 0 then
        out.price, out.priceKind = plan.price, "yours"
    elseif out.undercut then
        out.price, out.priceKind = out.undercut, "undercut"
    elseif out.market then
        out.price, out.priceKind = out.market.price, "market"
    end
    out.ahead = out.price and out.levels and M.AheadAt(out.levels, out.price) or nil
    out.history = D:History(id)
    out.activity = M.Activity(out.history, now, 7)
    out.listQty = out.stackSize * out.stacks
    out.paidUnit = D:PaidUnit(id)
    out.bagCount = A.BagCount(id)
    local sold, gross, profit, n = D:SalesFor(id, now - 7 * 86400)
    out.sales = n > 0 and { qty = sold, gross = gross, profit = profit, count = n } or nil

    local deposit = {
        faction = M.FormulaDeposit(rules, info.sellPrice, out.stackSize, out.duration, "faction"),
        neutral = M.FormulaDeposit(rules, info.sellPrice, out.stackSize, out.duration, "neutral"),
    }
    if app:Get("useGameDeposit") then
        local g = gameDeposit(id, out.duration, out.stackSize)
        if g then
            -- The game prices the AH you're standing at; match it to the closer formula.
            local venue = math.abs(g - deposit.neutral) < math.abs(g - deposit.faction) and "neutral" or "faction"
            deposit[venue] = g
            out.gameDepositVenue = venue
        end
    end
    out.deposit = deposit
    out.venue = out.gameDepositVenue or P.venue or "faction"
    -- The neutral AH is opt-in, unless that's where you're standing.
    out.showNeutral = app:Get("showNeutral") or (P.ahOpen and out.venue == "neutral")
    out.odds = M.Odds(app:Get("sellChance"), app:Get("maxListings"))

    if not out.unitCost then -- nothing to compare against yet
        out.positions = M.Positions(out.levels, nil, 13, copper)
        out.marketRows = M.MarketRows(out.levels, nil, out.price, out.listQty, 13, copper)
        return out
    end

    local function planFor(unitCost)
        return { stackSize = out.stackSize, stacks = out.stacks, unitCost = unitCost, vendorSellUnit = info.sellPrice,
            unsold = app:Get("unsold"), odds = out.odds, deposit = deposit, rules = rules }
    end
    out.plan = planFor(out.unitCost)
    local price = out.price
    out.positions = M.Positions(out.levels, out.plan, 13, copper)
    out.marketRows = M.MarketRows(out.levels, out.plan, price, out.listQty, 13, copper)
    if price then
        out.faction = M.Evaluate(out.plan, "faction", price, true)
        out.neutral = M.Evaluate(out.plan, "neutral", price, true)
    else
        out.faction = M.Evaluate(out.plan, "faction", 0, true)
        out.neutral = M.Evaluate(out.plan, "neutral", 0, true)
    end
    out.ladder = M.Ladder(out.plan, price)
    out.best = A.BestVenue(out)
    out.perDay = out.best and M.ProfitPerDay(out.best.profitUnit, out.activity, out.listQty) or nil

    -- Same item bought at each standing (only when the cost came from a vendor).
    if out.baseUnit and not out.costOverride then
        out.byStanding = {}
        for _, s in ipairs(M.TIERS) do
            local p = planFor(M.UnitCostAt(rules, out.baseUnit, s.reaction))
            local row = { standing = s, unitCost = p.unitCost }
            if price then
                row.faction = M.Evaluate(p, "faction", price, true)
                row.neutral = M.Evaluate(p, "neutral", price, true)
            end
            out.byStanding[#out.byStanding + 1] = row
        end
    end
    return out
end

-- The venue whose numbers count: the better of the two when the neutral AH
-- is shown, else the faction AH.
function A.BestVenue(a)
    if not a.faction or not a.price then return nil end
    if a.showNeutral and a.neutral.profitUnit > a.faction.profitUnit then return a.neutral end
    return a.faction
end

-- What a unit you're about to list cost you: what you paid, if we saw you
-- buy it, else the vendor/override cost.
function A.CostBasis(app, id, now)
    local paid = D:PaidUnit(id)
    if paid then return paid, "paid" end
    local a = A.Item(app, id, now)
    return a.unitCost, a.costOverride and "override" or (a.unitCost and "vendor" or nil)
end

-- One listing of qty units at price at the AH you're standing at, if it sells.
function A.Quote(app, id, qty, price, now)
    local a = A.Item(app, id, now)
    local unitCost, basis = A.CostBasis(app, id, now)
    local venue = a.venue
    local dep = gameDeposit(id, a.duration, qty)
        or M.FormulaDeposit(a.rules, a.info.sellPrice, qty, a.duration, venue)
    local q = M.Quote(qty, price, unitCost, M.CutRate(a.rules, venue), dep)
    q.venue, q.basis, q.duration = venue, basis, a.duration
    q.ahead = a.levels and M.AheadAt(a.levels, price) or nil
    return q, a
end

-- Light summary for list rows.
function A.Summary(app, id, now)
    local a = A.Item(app, id, now)
    local best = a.best
    return { id = id, name = a.info.name, icon = a.info.icon, quality = a.info.quality, link = a.info.link,
        hasVendor = a.vendor ~= nil, unitCost = a.unitCost, market = a.price,
        profitUnit = best and best.profitUnit, margin = best and best.margin, npc = a.vendor and a.vendor.npc,
        activity = a.activity, perDay = a.perDay }
end

---------------------------------------------------------------------------
-- Item lists
---------------------------------------------------------------------------
local function bagItemIDs()
    local ids = {}
    if not C_Container or not C_Container.GetContainerNumSlots then return ids end
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
    for bag = 0, last do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if type(info) == "table" and readable(info.itemID) and M.Number(info.itemID) then ids[info.itemID] = true end
        end
    end
    return ids
end
A.BagItemIDs = bagItemIDs

-- How lists order. "day": profitable markets that move first, by profit per
-- day (profit/unit x what leaves the market daily); then profitable items we
-- haven't seen enough scans of, by profit/unit; then the rest. "unit": plain
-- profit per unit. "activity": busiest markets first.
local function before(av, bv)
    if av ~= nil and bv ~= nil and av ~= bv then return av > bv end
    if (av ~= nil) ~= (bv ~= nil) then return av ~= nil end
end
local function ranked(tier, value)
    return function(a, b)
        local at, bt = tier(a), tier(b)
        if at ~= bt then return at < bt end
        local r = before(value(a), value(b))
        if r ~= nil then return r end
        r = before(a.profitUnit, b.profitUnit)
        if r ~= nil then return r end
        return (a.name or "") < (b.name or "")
    end
end
local function profitable(r) return r.profitUnit ~= nil and r.profitUnit > 0 end
local SORTS = {
    day = ranked(function(r)
        if r.perDay and r.perDay > 0 then return 1 end
        return profitable(r) and 2 or 3
    end, function(r) return r.perDay and r.perDay > 0 and r.perDay or nil end),
    unit = ranked(function() return 1 end, function(r) return r.profitUnit end),
    activity = ranked(function(r) return r.activity and r.activity.level and 1 or 2 end, function(r)
        local act = r.activity
        return act and act.level and (act.level.rank * 1e9 + (act.demandPerDay or 0)) or nil
    end),
}
function A.Sorter(sort) return SORTS[sort] or SORTS.day end

-- filter: "vendor" | "bags" | "all" | "merchant"; query: name text, id or link.
function A.List(app, filter, query, merchantName, now, sort)
    local candidates = {}
    local db = D.db
    if filter == "bags" or filter == "all" then
        for id in pairs(bagItemIDs()) do candidates[id] = true end
    end
    if filter ~= "bags" and db then
        for id, item in pairs(db.items) do
            local vendors = D:Vendors(id)
            if filter == "all" or (next(vendors) and (filter ~= "merchant" or (merchantName and vendors[merchantName]))) then
                candidates[id] = true
            end
        end
        if filter == "all" then
            for id in pairs(db.scans) do candidates[id] = true end
            for id in pairs(db.manual) do candidates[id] = true end
        end
    end
    local q = type(query) == "string" and query:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
    local wantID = tonumber(q) or itemIDFromLink(query)
    if wantID and not candidates[wantID] then candidates[wantID] = true end
    local rows = {}
    for id in pairs(candidates) do
        local s = A.Summary(app, id, now)
        local keep = q == "" or id == wantID or (s.name and s.name:lower():find(q, 1, true))
        if keep then rows[#rows + 1] = s end
    end
    table.sort(rows, A.Sorter(sort))
    return rows
end
