-- Domain persistence: what vendors charge, what the AH says, and per-item plans.
-- SND owns settings (AuctionHouseProfitsDB); this module alone owns
-- AuctionHouseProfitsData and validates it on load.
local _, ns = ...
local M = ns.Model
local D = { readOnly = false, revision = 0 }
ns.Data = D

local SCHEMA = 1

local function isID(k) return type(k) == "number" and k > 0 and k == math.floor(k) end

local function fresh()
    return { version = SCHEMA, items = {}, scans = {}, manual = {}, plans = {}, calibration = {} }
end

-- Drop malformed records instead of erroring later in the UI.
local function sanitize(db)
    for _, key in ipairs({ "items", "scans", "manual", "plans", "calibration" }) do
        if type(db[key]) ~= "table" then db[key] = {} end
    end
    for id, item in pairs(db.items) do
        if not isID(id) or type(item) ~= "table" then db.items[id] = nil
        elseif item.vendor ~= nil and (type(item.vendor) ~= "table" or not M.Number(item.vendor.price)
            or not M.Number(item.vendor.qty) or item.vendor.qty <= 0) then
            item.vendor = nil
        end
    end
    for id, scan in pairs(db.scans) do
        if not isID(id) or type(scan) ~= "table" or not M.Number(scan.price) or not M.Number(scan.time) then db.scans[id] = nil end
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

function D:Load()
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
        db.version = SCHEMA
        sanitize(db)
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

function D:RecordVendor(id, offer)
    if self.readOnly or not isID(id) then return end
    local item = self:EnsureItem(id)
    item.vendor = {
        price = offer.price, qty = offer.qty, reaction = offer.reaction, npc = offer.npc,
        zone = offer.zone, limited = offer.limited or nil, time = offer.time,
    }
    self:Touch()
end

function D:RecordScan(id, price, quantity, now)
    if self.readOnly or not isID(id) then return end
    self.db.scans[id] = { price = price, qty = quantity, time = now }
    self:Touch()
end

function D:Scan(id) return self.db and self.db.scans[id] end

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

function D:ForgetVendor(id)
    local item = self.db and self.db.items[id]
    if item and not self.readOnly then item.vendor = nil; self:Touch() end
end
