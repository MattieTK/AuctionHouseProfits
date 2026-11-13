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

-- Full analysis for one item.
function A.Item(app, id, now)
    now = now or time()
    local rules = ns.Rules(app)
    local info = A.Info(id)
    local saved = D:Item(id)
    local plan = D:Plan(id)
    local vendor = saved and saved.vendor

    local out = { id = id, info = info, rules = rules, vendor = vendor }
    if vendor then
        out.observedUnit = vendor.price / vendor.qty
        out.baseUnit = M.BaseUnitPrice(rules, out.observedUnit, vendor.reaction or 4)
    end
    out.standing = M.STANDING_BY_REACTION[plan.standing] and plan.standing or (vendor and vendor.reaction) or 4
    out.costOverride = M.Number(plan.cost) and plan.cost or nil
    if out.costOverride then
        out.unitCost = out.costOverride
    elseif out.baseUnit then
        out.unitCost = M.UnitCostAt(rules, out.baseUnit, out.standing)
    end

    out.stackSize = M.Number(plan.stackSize) and plan.stackSize >= 1 and math.floor(plan.stackSize) or info.maxStack
    out.stacks = M.Number(plan.stacks) and plan.stacks >= 1 and math.floor(plan.stacks) or app:Get("defaultStacks")
    out.duration = (plan.duration == 1 or plan.duration == 2 or plan.duration == 3) and plan.duration or app:Get("duration")

    out.market = P:Resolve(id, info.link, app:Get("priceSource"), app:Get("scanFreshMinutes") * 60, now)
    out.prices = P:All(id, info.link, now)

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
    out.odds = M.Odds(app:Get("sellChance"), app:Get("maxListings"))

    if not out.unitCost then return out end -- nothing to compare against yet

    local function planFor(unitCost)
        return { stackSize = out.stackSize, stacks = out.stacks, unitCost = unitCost, vendorSellUnit = info.sellPrice,
            unsold = app:Get("unsold"), odds = out.odds, deposit = deposit, rules = rules }
    end
    out.plan = planFor(out.unitCost)
    local price = out.market and out.market.price
    if price then
        out.faction = M.Evaluate(out.plan, "faction", price, true)
        out.neutral = M.Evaluate(out.plan, "neutral", price, true)
    else
        out.faction = M.Evaluate(out.plan, "faction", 0, true)
        out.neutral = M.Evaluate(out.plan, "neutral", 0, true)
    end
    out.ladder = M.Ladder(out.plan, price)

    -- Same item bought at each standing (only when the cost came from a vendor).
    if out.baseUnit and not out.costOverride then
        out.byStanding = {}
        for _, s in ipairs(M.STANDINGS) do
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

-- Light summary for list rows.
function A.Summary(app, id, now)
    local a = A.Item(app, id, now)
    local best
    if a.faction and a.market then
        best = a.faction.profitUnit >= a.neutral.profitUnit and a.faction or a.neutral
    end
    return { id = id, name = a.info.name, icon = a.info.icon, quality = a.info.quality, link = a.info.link,
        hasVendor = a.vendor ~= nil, unitCost = a.unitCost, market = a.market and a.market.price,
        profitUnit = best and best.profitUnit, margin = best and best.margin, npc = a.vendor and a.vendor.npc }
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

-- filter: "vendor" | "bags" | "all" | "merchant"; query: name text, id or link.
function A.List(app, filter, query, merchantName, now)
    local candidates = {}
    local db = D.db
    if filter == "bags" or filter == "all" then
        for id in pairs(bagItemIDs()) do candidates[id] = true end
    end
    if filter ~= "bags" and db then
        for id, item in pairs(db.items) do
            if filter == "all" or (item.vendor and (filter ~= "merchant" or item.vendor.npc == merchantName)) then
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
    table.sort(rows, function(a, b)
        local am, bm = a.profitUnit, b.profitUnit
        if am and bm and am ~= bm then return am > bm end
        if (am ~= nil) ~= (bm ~= nil) then return am ~= nil end
        return (a.name or "") < (b.name or "")
    end)
    return rows
end
