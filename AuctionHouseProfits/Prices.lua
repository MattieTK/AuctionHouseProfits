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
    if manual then list[#list + 1] = { source = "manual", label = "Manual", price = manual } end -- v1 data only
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

-- Scan a list of items one after another (the list's Scan button). Each
-- search waits for the last one's results (or 6s) and for the AH throttle.
-- P.after(delay, key, fn) is the timer, set by Core.
local QUEUE_TIMEOUT = 6
function P:StartQueue(ids)
    if not self.ahOpen or #ids == 0 then return false end
    self.queue = { ids = ids, next = 1, total = #ids }
    notify(nil)
    self:Pump()
    return true
end

function P:StopQueue()
    if self.queue then self.queue = nil; notify(nil) end
end

-- Items searched so far and the list's length, while a queue runs.
function P:QueueProgress()
    local q = self.queue
    if q then return q.next - 1, q.total end
end

function P:Pump()
    local q = self.queue
    if not q then return end
    if not self.ahOpen then self:StopQueue(); return end
    local clock = GetTime and GetTime() or 0
    if self.pending and clock - self.pending.time > QUEUE_TIMEOUT then self.pending = nil end
    if not self.pending then
        if q.next > q.total then self:StopQueue(); return end
        if self:CanScan() then
            local id = q.ids[q.next]
            q.next = q.next + 1
            self:Scan(id)
        end
    end
    if self.after then self.after(0.4, "scan-queue", function() P:Pump() end) end
end

-- Any search result for an item, whoever asked for it (us, the Blizzard
-- Buy/Auctions pages, Auctionator), refreshes its recorded market depth.
-- capped: there were more results than we read.
local function record(id, results, total, capped)
    local levels = M.Levels(results, 12)
    local truncated = levels.truncated
    levels.truncated = nil -- saved scans keep only the array
    local unit = levels[1] and levels[1].price or nil
    if P.pending and P.pending.id == id then P.pending = nil end
    if unit then D:RecordScan(id, unit, total, time(), levels, truncated or capped) end
    notify(id)
end

function P:OnCommodityResults(itemID)
    if not readable(itemID) or not M.Number(itemID) then return end
    local n = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
    if not readable(n) then return end
    if n == 0 then
        local full = C_AuctionHouse.HasFullCommoditySearchResults and C_AuctionHouse.HasFullCommoditySearchResults(itemID)
        local asked = self.pending and self.pending.id == itemID
        if asked or full == true then
            if asked then self.pending = nil end
            D:ClearListings(itemID, time()) -- sold out: stale sellers mustn't set your price
            notify(itemID)
        end
        return
    end
    local results, total = {}, 0
    for i = 1, math.min(n, 200) do
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if type(r) == "table" and price(r.unitPrice) and readable(r.quantity) and M.Number(r.quantity) then
            local owners = type(r.owners) == "table" and r.owners or {}
            results[#results + 1] = {
                price = r.unitPrice, qty = r.quantity,
                mine = readable(r.numOwnerItems) and M.Number(r.numOwnerItems) and r.numOwnerItems or 0,
                sellers = readable(r.totalNumberOfOwners) and M.Number(r.totalNumberOfOwners) and r.totalNumberOfOwners or 1,
                seller = readable(owners[1]) and type(owners[1]) == "string" and owners[1] or nil,
            }
            total = total + r.quantity
        end
    end
    local all = C_AuctionHouse.GetCommoditySearchResultsQuantity and C_AuctionHouse.GetCommoditySearchResultsQuantity(itemID)
    -- Results arrive in parts; until they're all in, the dear end is missing.
    local full = C_AuctionHouse.HasFullCommoditySearchResults and C_AuctionHouse.HasFullCommoditySearchResults(itemID)
    record(itemID, results, readable(all) and M.Number(all) and all or total, n > 200 or full == false)
end

function P:OnItemResults(itemKey)
    if type(itemKey) ~= "table" or not readable(itemKey.itemID) or not M.Number(itemKey.itemID) then return end
    local id = itemKey.itemID
    local n = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
    if not readable(n) then return end
    local results, count = {}, 0
    for i = 1, math.min(n, 100) do
        local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if type(r) == "table" and price(r.buyoutAmount) and readable(r.quantity) and M.Number(r.quantity) and r.quantity > 0 then
            local owners = type(r.owners) == "table" and r.owners or {}
            results[#results + 1] = {
                price = r.buyoutAmount / r.quantity, qty = r.quantity,
                mine = r.containsOwnerItem == true and r.quantity or 0, sellers = 1,
                seller = readable(owners[1]) and type(owners[1]) == "string" and owners[1] or nil,
            }
            count = count + r.quantity
        end
    end
    if #results == 0 then
        local full = C_AuctionHouse.HasFullItemSearchResults and C_AuctionHouse.HasFullItemSearchResults(itemKey)
        local asked = self.pending and self.pending.id == id
        if asked or full == true then
            if asked then self.pending = nil end
            D:ClearListings(id, time())
            notify(id)
        end
        return
    end
    local full = C_AuctionHouse.HasFullItemSearchResults and C_AuctionHouse.HasFullItemSearchResults(itemKey)
    record(id, results, count, n > 100 or full == false)
end

-- Which auction house you're standing at. Neutral AHs are in Booty Bay,
-- Gadgetzan and Everlook (classic and modern map IDs). A game-computed
-- deposit, when we have one, overrides this (see Analysis).
local NEUTRAL_MAPS = { [1434] = true, [1446] = true, [1452] = true, [210] = true, [224] = true, [71] = true, [83] = true }
function P:DetectVenue()
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    self.venue = readable(map) and NEUTRAL_MAPS[map] and "neutral" or "faction"
    return self.venue
end

function P:Attach(scope)
    local function on(event, fn)
        local ok, err = scope:Event(event, fn)
        if not ok then error(err.message) end
    end
    on("AUCTION_HOUSE_SHOW", function() P.ahOpen = true; P:DetectVenue(); notify(nil) end)
    on("AUCTION_HOUSE_CLOSED", function() P.ahOpen = false; P.pending = nil; P.venue = nil; P.queue = nil; notify(nil) end)
    on("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID) P:OnCommodityResults(itemID) end)
    on("COMMODITY_SEARCH_RESULTS_ADDED", function(itemID) P:OnCommodityResults(itemID) end)
    on("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey) P:OnItemResults(itemKey) end)
    on("ITEM_SEARCH_RESULTS_ADDED", function(itemKey) P:OnItemResults(itemKey) end)
end
