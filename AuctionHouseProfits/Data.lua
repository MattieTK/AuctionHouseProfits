-- Domain persistence: what vendors charge, what the AH says, and per-item plans.
-- SND owns settings (AuctionHouseProfitsDB); this module alone owns
-- AuctionHouseProfitsData and validates it on load.
local _, ns = ...
local M = ns.Model
local D = { readOnly = false, revision = 0 }
ns.Data = D

local SCHEMA = 2
local SALE_DAYS = 30
local HISTORY_DAYS, HISTORY_MAX, HISTORY_MERGE = 14, 200, 5
local TABLES = { "items", "scans", "manual", "plans", "calibration", "purchases", "sales", "history", "standings" }

local function isID(k) return type(k) == "number" and k > 0 and k == math.floor(k) end

local function fresh()
    local db = { version = SCHEMA }
    for _, key in ipairs(TABLES) do db[key] = {} end
    return db
end

-- v1 wrote "Your price" into the manual market price, which then hid real
-- scan data. v2 keeps your price on the plan and the market price separate.
local function migrate(db)
    if (M.Number(db.version) and db.version or 1) < 2 and type(db.manual) == "table" then
        if type(db.plans) ~= "table" then db.plans = {} end
        for id, price in pairs(db.manual) do
            if isID(id) and M.Number(price) and price > 0 then
                local plan = type(db.plans[id]) == "table" and db.plans[id] or {}
                if plan.price == nil then plan.price = price end
                db.plans[id] = plan
            end
        end
        db.manual = {}
    end
end

local function validLevels(levels)
    if type(levels) ~= "table" then return nil end
    local out = {}
    for _, l in ipairs(levels) do
        if type(l) == "table" and M.Number(l.price) and M.Number(l.qty) then out[#out + 1] = l end
    end
    return out
end

local UNKNOWN_VENDOR = "?"
local function validOffer(v)
    return type(v) == "table" and M.Number(v.price) and M.Number(v.qty) and v.qty > 0
end

-- Drop malformed records instead of erroring later in the UI.
local function sanitize(db, now)
    for _, key in ipairs(TABLES) do
        if type(db[key]) ~= "table" then db[key] = {} end
    end
    for id, item in pairs(db.items) do
        if not isID(id) or type(item) ~= "table" then
            db.items[id] = nil
        else
            if item.vendor ~= nil and not validOffer(item.vendor) then item.vendor = nil end
            if type(item.vendors) ~= "table" then item.vendors = nil end
            for key, v in pairs(item.vendors or {}) do
                if type(key) ~= "string" or not validOffer(v) then item.vendors[key] = nil end
            end
            -- Before 0.3.2 only the last merchant was kept.
            if item.vendor and not (item.vendors and next(item.vendors)) then
                item.vendors = { [item.vendor.npc or UNKNOWN_VENDOR] = item.vendor }
            end
        end
    end
    for id, scan in pairs(db.scans) do
        if not isID(id) or type(scan) ~= "table" or not M.Number(scan.price) or not M.Number(scan.time) then
            db.scans[id] = nil
        else
            scan.levels = validLevels(scan.levels)
        end
    end
    for id, list in pairs(db.history) do
        if not isID(id) or type(list) ~= "table" then
            db.history[id] = nil
        else
            local kept = {}
            for _, h in ipairs(list) do
                if type(h) == "table" and M.Number(h.t) and M.Number(h.q) and h.q >= 0
                    and (h.p == nil or M.Number(h.p)) and (h.d == nil or type(h.d) == "string")
                    and (not now or h.t >= now - HISTORY_DAYS * 86400) then
                    kept[#kept + 1] = h
                end
            end
            db.history[id] = #kept > 0 and kept or nil
        end
    end
    for npc, s in pairs(db.standings) do
        if type(npc) ~= "string" or type(s) ~= "table" or not M.STANDING_BY_REACTION[s.reaction] then db.standings[npc] = nil end
    end
    for id, p in pairs(db.purchases) do
        if not isID(id) or type(p) ~= "table" or not M.Number(p.qty) or p.qty <= 0 or not M.Number(p.spent) then
            db.purchases[id] = nil
        end
    end
    for auctionID, sale in pairs(db.sales) do
        if not isID(auctionID) or type(sale) ~= "table" or not isID(sale.id) or not M.Number(sale.qty)
            or not M.Number(sale.gross) or not M.Number(sale.time) or (now and sale.time < now - SALE_DAYS * 86400) then
            db.sales[auctionID] = nil
        end
    end
    for id, price in pairs(db.manual) do
        if not isID(id) or not M.Number(price) or price < 0 then db.manual[id] = nil end
    end
    for id, plan in pairs(db.plans) do
        if not isID(id) or type(plan) ~= "table" then db.plans[id] = nil end
    end
    for reaction, cal in pairs(db.calibration) do
        if not M.STANDING_BY_REACTION[reaction] or type(cal) ~= "table" or type(cal.items) ~= "table" then
            db.calibration[reaction] = nil
        end
    end
end

function D:Load(now)
    local db = _G.AuctionHouseProfitsData
    if db == nil then
        db = fresh()
        _G.AuctionHouseProfitsData = db
    elseif type(db) ~= "table" then
        db = fresh()
        _G.AuctionHouseProfitsData = db
    elseif M.Number(db.version) and db.version > SCHEMA then
        -- Written by a newer version of the addon: leave it untouched.
        self.readOnly = true
        local copy = fresh()
        self.db = copy
        return false
    else
        migrate(db)
        db.version = SCHEMA
        sanitize(db, now)
    end
    self.db = db
    return true
end

function D:Touch() self.revision = self.revision + 1 end

function D:Item(id) return self.db and self.db.items[id] end

function D:EnsureItem(id)
    local item = self.db.items[id]
    if not item then item = {}; self.db.items[id] = item end
    return item
end

-- Merge static item info (name, icon, sell price, max stack) for display.
function D:RememberInfo(id, info)
    if self.readOnly or not isID(id) then return end
    local item = self:EnsureItem(id)
    for _, key in ipairs({ "name", "icon", "quality", "sellPrice", "maxStack", "link" }) do
        if info[key] ~= nil then item[key] = info[key] end
    end
    self:Touch()
end

-- Every merchant seen selling an item, by name. item.vendor stays the one
-- seen last (what 0.3.1 and earlier read).
function D:RecordVendor(id, offer)
    if self.readOnly or not isID(id) then return end
    local item = self:EnsureItem(id)
    local entry = {
        price = offer.price, qty = offer.qty, reaction = offer.reaction, npc = offer.npc,
        zone = offer.zone, limited = offer.limited or nil, time = offer.time,
    }
    item.vendor = entry
    item.vendors = item.vendors or {}
    item.vendors[offer.npc or UNKNOWN_VENDOR] = entry
    self:Touch()
end

function D:Vendors(id)
    local item = self.db and self.db.items[id]
    if not item then return {} end
    if item.vendors then return item.vendors end
    return item.vendor and { [item.vendor.npc or UNKNOWN_VENDOR] = item.vendor } or {}
end

-- One point per search for the price/volume history, with the order book
-- it saw (depth text from M.EncodeDepth) so demand can be told from supply.
-- The several result events one search fires merge into a single point.
function D:AddHistory(id, price, quantity, now, depth)
    if self.readOnly or not isID(id) or not M.Number(quantity) or not M.Number(now) then return end
    local list = self.db.history[id]
    if not list then list = {}; self.db.history[id] = list end
    local last = list[#list]
    local point = { t = now, p = M.Number(price) and price or nil, q = quantity, d = type(depth) == "string" and depth or nil }
    if last and now - last.t <= HISTORY_MERGE and now >= last.t then
        list[#list] = point
    else
        list[#list + 1] = point
    end
    local cutoff = now - HISTORY_DAYS * 86400
    while #list > HISTORY_MAX or (list[1] and list[1].t < cutoff) do table.remove(list, 1) end
end

function D:History(id) return self.db and self.db.history[id] or {} end

-- levels: market depth from M.Levels (optional); truncated: dearer levels
-- were left out.
function D:RecordScan(id, price, quantity, now, levels, truncated)
    if self.readOnly or not isID(id) then return end
    self.db.scans[id] = { price = price, qty = quantity, time = now, levels = levels }
    self:AddHistory(id, price, quantity, now, levels and M.EncodeDepth(levels, truncated) or nil)
    self:Touch()
end

function D:Scan(id) return self.db and self.db.scans[id] end

-- A search found nothing listed: keep the last price for reference, drop the sellers.
function D:ClearListings(id, now)
    local scan = self.db and self.db.scans[id]
    if self.readOnly or not scan then return end
    scan.levels, scan.qty, scan.time = {}, 0, now
    self:AddHistory(id, nil, 0, now, "") -- an empty book
    self:Touch()
end

function D:SetManual(id, price)
    if self.readOnly or not isID(id) then return end
    self.db.manual[id] = price
    self:Touch()
end

function D:Manual(id) return self.db and self.db.manual[id] end

function D:Plan(id)
    return self.db and self.db.plans[id] or {}
end

function D:SetPlan(id, key, value)
    if self.readOnly or not isID(id) then return end
    local plan = self.db.plans[id]
    if not plan then plan = {}; self.db.plans[id] = plan end
    plan[key] = value
    self:Touch()
end

-- ratios = { [itemID] = observed / list ratio }. One sample per item and
-- standing, so a vendor you visit often doesn't outweigh the rest.
function D:AddRatios(reaction, ratios, now)
    if self.readOnly or not M.STANDING_BY_REACTION[reaction] or next(ratios) == nil then return end
    local cal = self.db.calibration[reaction]
    if not cal then cal = { items = {} }; self.db.calibration[reaction] = cal end
    for id, r in pairs(ratios) do if isID(id) and M.Number(r) then cal.items[id] = r end end
    cal.time = now
    self:Touch()
end

-- Observed discount per standing, from merchant price checks: (pct, items).
function D:Calibration(reaction)
    local cal = self.db and self.db.calibration[reaction]
    if not cal then return nil, 0 end
    local list = {}
    for _, r in pairs(cal.items) do list[#list + 1] = r end
    return M.MedianDiscount(list)
end

-- What you actually paid merchants, for profit on sales.
function D:RecordPurchase(id, units, spent, now)
    if self.readOnly or not isID(id) or not M.Number(units) or units <= 0 or not M.Number(spent) then return end
    local p = self.db.purchases[id]
    if not p then p = { qty = 0, spent = 0 }; self.db.purchases[id] = p end
    p.qty, p.spent, p.time = p.qty + units, p.spent + spent, now
    self:Touch()
end

-- Average price paid per unit, or nil if we never saw you buy it.
function D:PaidUnit(id)
    local p = self.db and self.db.purchases[id]
    return p and p.qty > 0 and p.spent / p.qty or nil
end

-- One record per sold auction; returns true the first time it's seen.
function D:RecordSale(auctionID, sale)
    if self.readOnly or not isID(auctionID) or self.db.sales[auctionID] then return false end
    self.db.sales[auctionID] = sale
    self:Touch()
    return true
end

-- Sales of an item since a time: qty, gross, profit (nil if any cost unknown), count.
function D:SalesFor(id, since)
    local qty, gross, profit, n = 0, 0, 0, 0
    for _, sale in pairs(self.db and self.db.sales or {}) do
        if sale.id == id and sale.time >= (since or 0) then
            local r = M.SaleProfit(sale.gross, sale.qty, sale.unitCost, sale.cutRate)
            qty, gross, n = qty + sale.qty, gross + sale.gross, n + 1
            profit = profit and r.profit and profit + r.profit or nil
        end
    end
    return qty, gross, profit, n
end

-- Your standing with a vendor, as the game last reported it (UnitReaction).
-- Merchant visits set it; targeting or mousing over the vendor refreshes it.
function D:SetStanding(npc, reaction, now)
    if self.readOnly or type(npc) ~= "string" or not M.STANDING_BY_REACTION[reaction] then return false end
    local s = self.db.standings[npc]
    if s and s.reaction == reaction then s.time = now; return false end
    self.db.standings[npc] = { reaction = reaction, time = now }
    self:Touch()
    return true
end

function D:Standing(npc)
    local s = npc and self.db and self.db.standings[npc]
    return s and s.reaction, s and s.time
end

function D:IsVendor(npc) return npc ~= nil and self.db ~= nil and self.db.standings[npc] ~= nil end

function D:ForgetVendor(id)
    local item = self.db and self.db.items[id]
    if item and not self.readOnly then item.vendor, item.vendors = nil, nil; self:Touch() end
end
