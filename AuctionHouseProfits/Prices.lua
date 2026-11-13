-- Market price sources and the on-demand AH price check.
local ADDON, ns = ...
local M, D = ns.Model, ns.Data
local P = { ahOpen = false, pending = nil, listeners = {} }
ns.Prices = P

local function readable(v) return not (issecretvalue and issecretvalue(v)) end
local function price(v)
    return readable(v) and M.Number(v) and v > 0 and math.floor(v + 0.5) or nil
end

-- Each external source is optional and wrapped in pcall: a broken or
-- changed third-party API must never break this addon.
P.SOURCES = {
    auctionator = {
        label = "Auctionator",
        available = function()
            return type(Auctionator) == "table" and type(Auctionator.API) == "table" and type(Auctionator.API.v1) == "table"
                and type(Auctionator.API.v1.GetAuctionPriceByItemID) == "function"
        end,
        get = function(id)
            local ok, v = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, ADDON, id)
            if not ok then return nil end
            local age
            if type(Auctionator.API.v1.GetAuctionAgeByItemID) == "function" then
                local aok, days = pcall(Auctionator.API.v1.GetAuctionAgeByItemID, ADDON, id)
                if aok and M.Number(days) then age = days * 86400 end
            end
            return price(v), age
        end,
    },
    tsm = {
        label = "TSM",
        available = function() return type(TSM_API) == "table" and type(TSM_API.GetCustomPriceValue) == "function" end,
        get = function(id)
            local ok, v = pcall(TSM_API.GetCustomPriceValue, "DBMarket", "i:" .. id)
            if ok and price(v) then return price(v) end
            ok, v = pcall(TSM_API.GetCustomPriceValue, "DBMinBuyout", "i:" .. id)
            return ok and price(v) or nil
        end,
    },
    auctioneer = {
        label = "Auctioneer",
        available = function()
            return type(AucAdvanced) == "table" and type(AucAdvanced.API) == "table" and type(AucAdvanced.API.GetMarketValue) == "function"
        end,
        get = function(id, link)
            if not link then return nil end
            local ok, v = pcall(AucAdvanced.API.GetMarketValue, link)
            return ok and price(v) or nil
        end,
    },
}
P.ORDER = { "auctionator", "tsm", "auctioneer" }

function P:Available()
    local out = {}
    for _, key in ipairs(self.ORDER) do
        if self.SOURCES[key].available() then out[#out + 1] = key end
    end
    return out
end

-- Every known price for an item, for display: { {source, label, price, age} }
function P:All(id, link, now)
    local list = {}
    local manual = D:Manual(id)
    if manual then list[#list + 1] = { source = "manual", label = "Manual", price = manual } end
    local scan = D:Scan(id)
    if scan then list[#list + 1] = { source = "scan", label = "My scan", price = scan.price, age = now - scan.time, qty = scan.qty } end
    for _, key in ipairs(self.ORDER) do
        local src = self.SOURCES[key]
        if src.available() then
            local v, age = src.get(id, link)
            if v then list[#list + 1] = { source = key, label = src.label, price = v, age = age } end
        end
    end
    return list
end

-- The price used for calculations. mode is the priceSource setting.
function P:Resolve(id, link, mode, freshSeconds, now)
    local all = self:All(id, link, now)
    local by = {}
    for _, e in ipairs(all) do by[e.source] = e end
    if mode ~= "auto" then return by[mode] end
    if by.manual then return by.manual end
    if by.scan and by.scan.age <= freshSeconds then return by.scan end
    for _, key in ipairs(self.ORDER) do if by[key] then return by[key] end end
    return by.scan
end

---------------------------------------------------------------------------
-- AH price check (one query per user action; no background scanning)
---------------------------------------------------------------------------
function P:OnChange(fn) self.listeners[#self.listeners + 1] = fn end
local function notify(id) for _, fn in ipairs(P.listeners) do fn(id) end end

function P:CanScan()
    if not self.ahOpen or not C_AuctionHouse or not C_AuctionHouse.SendSearchQuery then return false, "Open the auction house to scan." end
    if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        return false, "The auction house is busy. Try again in a moment."
    end
    return true
end

function P:Scan(id)
    local ok, why = self:CanScan()
    if not ok then return false, why end
    local key = C_AuctionHouse.MakeItemKey(id)
    local sorts = {}
    if Enum and Enum.AuctionHouseSortOrder then
        sorts[1] = { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false }
    end
    local sent, err = pcall(C_AuctionHouse.SendSearchQuery, key, sorts, false)
    if not sent then return false, "Search failed: " .. tostring(err) end
    self.pending = { id = id, time = GetTime and GetTime() or 0 }
    notify(id)
    return true
end

function P:IsScanning(id) return self.pending and self.pending.id == id end

local function finish(id, unit, quantity)
    if P.pending and P.pending.id == id then P.pending = nil end
    if unit then D:RecordScan(id, unit, quantity, time()) end
    notify(id)
end

function P:OnCommodityResults(itemID)
    if not readable(itemID) or not self.pending or self.pending.id ~= itemID then return end
    local n = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
    if n == 0 then return finish(itemID, nil) end
    local first = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
    local total = C_AuctionHouse.GetCommoditySearchResultsQuantity and C_AuctionHouse.GetCommoditySearchResultsQuantity(itemID)
    finish(itemID, first and price(first.unitPrice), readable(total) and total or nil)
end

function P:OnItemResults(itemKey)
    if type(itemKey) ~= "table" or not readable(itemKey.itemID) then return end
    local id = itemKey.itemID
    if not self.pending or self.pending.id ~= id then return end
    local n = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
    local best, count = nil, 0
    for i = 1, math.min(n, 50) do
        local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if r and price(r.buyoutAmount) and M.Number(r.quantity) and r.quantity > 0 then
            local unit = r.buyoutAmount / r.quantity
            if not best or unit < best then best = unit end
            count = count + r.quantity
        end
    end
    finish(id, best and math.floor(best + 0.5), count)
end

function P:Attach(scope)
    local function on(event, fn)
        local ok, err = scope:Event(event, fn)
        if not ok then error(err.message) end
    end
    on("AUCTION_HOUSE_SHOW", function() P.ahOpen = true; notify(nil) end)
    on("AUCTION_HOUSE_CLOSED", function() P.ahOpen = false; P.pending = nil; notify(nil) end)
    on("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID) P:OnCommodityResults(itemID) end)
    on("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey) P:OnItemResults(itemKey) end)
end
