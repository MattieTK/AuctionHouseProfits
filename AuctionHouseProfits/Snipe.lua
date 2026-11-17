-- Vendor sniper: auctions a vendor would pay more for than they cost, bought
-- one press at a time.
--
-- Finding deals needs no clicks. A full scan (C_AuctionHouse.ReplicateItems,
-- once every 15 minutes per account) lists every auction for an estimate.
-- Any search result for an item (ours, Blizzard's Buy page, other add-ons')
-- is checked against its live listings, and Pump() searches each estimated
-- deal in turn so the top of the list is usually checked before you press Buy.
--
-- Buying needs a hardware event: PlaceBid and StartCommoditiesPurchase only
-- work from a click or key press, so BuyNext() must run from one. One press
-- buys one auction, or every profitable unit of a commodity.
-- ConfirmCommoditiesPurchase has no such restriction: a commodity purchase is
-- confirmed from the price the server quotes, and only if it's still a deal.
local ADDON, ns = ...
local M, D, P, R = ns.Model, ns.Data, ns.Prices, ns.Merchant
local N = {
    deals = {}, byID = {}, live = {}, items = {}, skipped = {}, listeners = {}, seq = 0,
    kinds = {},  -- [itemID] = "commodity" / "item", once known
    tried = {},  -- commodities bought (or tried) straight from the scan: check before the next
    session = { buys = 0, units = 0, spent = 0, value = 0 },
}
ns.Snipe = N

local FULL_SCAN_COOLDOWN = 15 * 60
local FULL_SCAN_WAIT = 30      -- seconds to wait for the game to send a full scan
local READ_BATCH = 500         -- auctions read per frame; reading too fast can disconnect
local SEARCH_TIMEOUT = 6
local PURCHASE_TIMEOUT = 10
local RECHECK_LIMIT = 60

local function readable(v) return not (issecretvalue and issecretvalue(v)) end
local function num(v) return readable(v) and M.Number(v) and v or nil end
local function clock() return GetTime and GetTime() or 0 end
local function money() return GetMoney and num(GetMoney()) or 0 end

function N:OnChange(fn) self.listeners[#self.listeners + 1] = fn end
local function notify() for _, fn in ipairs(N.listeners) do fn() end end

function N:Rules()
    return self.app:Get("snipeMinProfit"), self.app:Get("snipeBasis")
end

---------------------------------------------------------------------------
-- Item info
---------------------------------------------------------------------------
-- { sell, name, icon, quality } once the client has the item. sell is false
-- when vendors won't buy it. nil while the item is still loading.
function N.Item(id)
    local known = N.items[id]
    if known then return known end
    local info = R.ItemInfo(id)
    local saved = not info and D:Item(id)
    if not info and not (saved and num(saved.sellPrice) and saved.name) then return nil end
    local src = info or saved
    local sell = num(src.sellPrice)
    known = { sell = sell and sell > 0 and sell or false, name = src.name, icon = src.icon, quality = src.quality,
        maxStack = num(src.maxStack) }
    N.items[id] = known
    return known
end

local function sellPrice(id)
    local item = N.Item(id)
    if not item then return nil end
    return item.sell
end

-- Commodity (bought by item and quantity) or item (bought by auction ID).
-- nil while the game hasn't said.
function N:KindOf(id)
    local known = self.kinds[id]
    if known then return known end
    if C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.MakeItemKey then
        local ok, info = pcall(C_AuctionHouse.GetItemKeyInfo, C_AuctionHouse.MakeItemKey(id))
        if ok and type(info) == "table" and type(info.isCommodity) == "boolean" then
            known = info.isCommodity and "commodity" or "item"
            self.kinds[id] = known
        end
    end
    return known
end

-- The random-suffix ID in an item link (item:id:enchant:gem1:gem2:gem3:gem4:suffix).
local function suffixOf(link)
    if type(link) ~= "string" then return nil end
    local s = link:match("item:%-?%d+:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:(%-?%d+)")
    s = tonumber(s)
    return s and s ~= 0 and s or nil
end

---------------------------------------------------------------------------
-- Deals: estimates from the last full scan, replaced by live listings
---------------------------------------------------------------------------
-- deal = { id, kind ("commodity"/"item"/nil until checked), verified,
--          direct, scan, qty, cost, profit, each, buy (what one press buys),
--          name, icon }
-- each: what the best single item makes. perSlot: what one press makes per
-- bag slot it fills (stackable items fill fewer).
-- verified: from live listings. direct: a commodity from the full scan that
-- one press can buy as it is, because the server quotes the price before
-- we confirm. scan: the deal came from the full scan.
-- each is what the best single item makes. Deals rank by it, not by the
-- total: you may not win every auction or unit, so the most valuable single
-- purchases come first.
local function better(a, b)
    if a.id == N.focus then return true end
    if b.id == N.focus then return false end
    local ra, rb = a.verified or a.direct or false, b.verified or b.direct or false
    if ra ~= rb then return ra end -- deals one press can buy come first
    if N.sortBy == "slot" and a.perSlot ~= b.perSlot then return a.perSlot > b.perSlot end
    if a.each ~= b.each then return a.each > b.each end
    if a.profit ~= b.profit then return a.profit > b.profit end
    return a.id < b.id
end

function N:Sort()
    self.sortBy = self.app and self.app:Get("snipeSort") or "item"
    table.sort(self.deals, better)
end

-- Work out one item's deal from what we know, without re-sorting.
function N:Compute(id)
    local minProfit, basis = self:Rules()
    local old = self.byID[id]
    local deal
    local sell = sellPrice(id)
    local live = self.live[id]
    local snap = self.snapshot and self.snapshot.items[id]
    if sell and not self.skipped[id] then
        if live and (not snap or live.seq > self.snapshot.seq) then
            local buy
            if live.kind == "commodity" then
                buy = M.CommodityBuy(live.levels, sell, minProfit, basis, money())
            else
                buy = M.ItemBuys(live.auctions, sell, minProfit, basis, money())
            end
            if buy then
                deal = { kind = live.kind, verified = not live.stale, qty = buy.qty, cost = buy.cost,
                    profit = buy.profit, each = buy.best, buy = buy, checked = live.time }
            end
        elseif snap and self:KindOf(id) == "commodity" and not self.tried[id] then
            -- No need to search first: StartCommoditiesPurchase is by item and
            -- quantity, and we only confirm if the server's total is a deal.
            local buy = M.CommodityBuy(M.FlatLevels(snap), sell, minProfit, basis, money())
            if buy then
                deal = { kind = "commodity", verified = false, direct = true, scan = true, qty = buy.qty,
                    cost = buy.cost, profit = buy.profit, each = buy.best, buy = buy }
            end
        elseif snap then
            local e = M.EstimateDeal(snap, sell, minProfit, basis)
            if e then deal = { verified = false, scan = true, qty = e.qty, cost = e.cost, profit = e.profit, each = e.best } end
        end
    end
    if old then
        for i, d in ipairs(self.deals) do if d == old then table.remove(self.deals, i); break end end
    end
    self.byID[id] = deal
    if deal then
        local item = N.Item(id) or {}
        deal.id, deal.name, deal.icon, deal.quality = id, item.name, item.icon, item.quality
        deal.stack = item.maxStack or 1
        deal.perSlot = M.PerSlot(deal.profit, deal.qty, deal.each, deal.stack)
        deal.suffixes = self.snapshot and self.snapshot.suffixes[id]
        self.deals[#self.deals + 1] = deal
        D:Watch(id, time())
    elseif self.focus == id then
        self.focus = nil
    end
    return deal
end

function N:Evaluate(id)
    local deal = self:Compute(id)
    self:Sort()
    notify()
    return deal
end

-- Recompute everything (new full scan, or the minimum profit changed).
function N:Rebuild()
    local ids = {}
    for id in pairs(self.live) do ids[id] = true end
    if self.snapshot then for id in pairs(self.snapshot.items) do ids[id] = true end end
    for id in pairs(self.byID) do ids[id] = true end
    for id in pairs(ids) do self:Compute(id) end
    self.rulesKey = table.concat({ self:Rules() }, ":")
    self:Sort()
    notify()
end

-- Only live listings depend on your gold.
function N:RefreshLive()
    for id in pairs(self.live) do self:Compute(id) end
    self:Sort()
    notify()
end

-- Deals, best first; rebuilt if the settings changed since.
function N:Deals()
    if self.rulesKey ~= table.concat({ self:Rules() }, ":") then self:Rebuild() end
    if self.app and self.sortBy ~= self.app:Get("snipeSort") then self:Sort() end
    return self.deals
end

function N:Head() return self:Deals()[1] end

-- Put an item at the top of the list (click a row).
function N:Focus(id)
    self.focus = self.byID[id] and id or nil
    self:Sort()
    notify()
end

-- Drop the top deal (or one item) until the next full scan.
function N:Skip(id)
    local d = id and self.byID[id] or self:Head()
    if not d then return false end
    self.skipped[d.id] = true
    self:Evaluate(d.id)
    return true
end

function N:Totals()
    local n, profit, ready = 0, 0, 0
    for _, d in ipairs(self:Deals()) do
        n, profit = n + 1, profit + d.profit
        if d.verified then ready = ready + 1 end
    end
    return n, profit, ready
end

---------------------------------------------------------------------------
-- Live listings (any search result, whoever asked)
---------------------------------------------------------------------------
-- A search answered: check the next deal straight away, not on the timer.
function N:Answered(id)
    if self.checking == id then self.checking = nil end
    if self.after then self.after(0, "snipe-next-check", function() N:Pump() end) end
end

function N:OnCommodityResults(itemID)
    local id = num(itemID)
    if not id or not C_AuctionHouse.GetNumCommoditySearchResults then return end
    self.lastSearch = id
    local n = num(C_AuctionHouse.GetNumCommoditySearchResults(id)) or 0
    if n == 0 then
        local full = C_AuctionHouse.HasFullCommoditySearchResults and C_AuctionHouse.HasFullCommoditySearchResults(id)
        if self.checking ~= id and full ~= true then return end
    end
    local levels = {}
    for i = 1, math.min(n, 100) do
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(id, i)
        if type(r) == "table" and num(r.unitPrice) and num(r.quantity) then
            levels[#levels + 1] = { price = r.unitPrice, qty = r.quantity, mine = num(r.numOwnerItems) or 0 }
        end
    end
    -- Results arrive cheapest first: a partial answer still has the cheap end.
    local expected = self:Expected(id)
    self.kinds[id] = "commodity"
    self.seq = self.seq + 1
    self.live[id] = { kind = "commodity", levels = levels, time = time(), seq = self.seq }
    self:Answered(id)
    self:Evaluate(id)
    self:ReportGone(id, expected, levels[1] and levels[1].price)
end

function N:OnItemResults(itemKey)
    if type(itemKey) ~= "table" or not C_AuctionHouse.GetNumItemSearchResults then return end
    local id = num(itemKey.itemID)
    if not id then return end
    self.lastSearch = id
    local n = num(C_AuctionHouse.GetNumItemSearchResults(itemKey)) or 0
    if n == 0 then
        local full = C_AuctionHouse.HasFullItemSearchResults and C_AuctionHouse.HasFullItemSearchResults(itemKey)
        if self.checking ~= id and full ~= true then return end
        -- The plain item key found nothing; the scan may have seen a suffix
        -- ("of the Bear") variant that only its own key finds.
        if self.checking == id and self:TryVariant(id) then return end
    end
    local auctions = {}
    for i = 1, math.min(n, 100) do
        local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if type(r) == "table" and num(r.auctionID) and num(r.buyoutAmount) and num(r.quantity) and r.quantity > 0 then
            auctions[#auctions + 1] = { auctionID = r.auctionID, qty = r.quantity, buyout = r.buyoutAmount,
                mine = r.containsOwnerItem == true }
        end
    end
    local expected = self:Expected(id)
    self.kinds[id] = "item"
    self.seq = self.seq + 1
    self.live[id] = { kind = "item", auctions = auctions, time = time(), seq = self.seq }
    self:Answered(id)
    self:Evaluate(id)
    local cheapest
    for _, a in ipairs(auctions) do
        if not a.mine and (not cheapest or a.buyout < cheapest) then cheapest = a.buyout end
    end
    self:ReportGone(id, expected, cheapest)
end

-- The price per item the full scan saw for a deal not yet checked, or nil.
function N:Expected(id)
    local d, sell = self.byID[id], sellPrice(id)
    if not sell then return nil end
    if d and d.scan and d.each then return sell - d.each end
    local f = self.full
    local each = f and f.candidates and f.candidates[id]
    return each and sell - each or nil
end

-- A deal from the scan that a check found gone: say so, with what's there
-- now, so you can tell a sniped deal from a misread one.
function N:ReportGone(id, expected, cheapest)
    -- tried: we just bought (or tried to buy) it from the scan ourselves.
    if not expected or self.byID[id] or self.tried[id] then return end
    self.gone = (self.gone or 0) + 1
    local item = N.Item(id)
    local name = item and item.name or ("item " .. id)
    local Money = ns.UI and ns.UI.Money or M.MoneyText
    local now = cheapest and ("the cheapest is now " .. Money(cheapest) .. " each") or "none are listed now"
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffe8bd55Auction House Profits:|r " .. name .. " was gone when checked. The scan saw "
            .. Money(math.floor(expected + 0.5)) .. " each; " .. now .. ".")
    end
end

function N:Search(id, key)
    if not P:CanScan() then return false end
    local ok = P:Scan(id, key)
    if ok then self.checking, self.checkStarted, self.lastSearch = id, clock(), id end
    return ok
end

function N:TryVariant(id)
    local d = self.byID[id]
    local list = d and d.suffixes
    if not list or not C_AuctionHouse.MakeItemKey then return false end
    d.tried = (d.tried or 0) + 1
    local suffix = list[d.tried]
    return suffix ~= nil and self:Search(id, C_AuctionHouse.MakeItemKey(id, 0, suffix)) or false
end

-- Background work while the sniper is open: time out stuck requests and
-- check the next unchecked deal. Never buys anything.
function N:Pump()
    if not P.ahOpen then return end
    local now = clock()
    if self.purchase and now - self.purchase.time > PURCHASE_TIMEOUT then
        self.purchase = nil
        notify()
    end
    if self.checking and now - self.checkStarted > SEARCH_TIMEOUT then
        local id = self.checking
        self.checking = nil
        -- No answer twice: stop waiting on it.
        local d = self.byID[id]
        if d then
            d.misses = (d.misses or 0) + 1
            if d.misses >= 2 then self.skipped[id] = true; self:Evaluate(id) end
        end
        notify()
    end
    if self.checking or self.purchase or P.queue then return end
    if self.full and self.full.stage == "waiting" then return end
    if P.pending and now - P.pending.time < 3 then return end
    local id = self:NextCheck()
    if id then self:Search(id); return end
    if self.full then return end
    -- Gear is bought by auction ID, as Blizzard's Buy page does from the
    -- item's latest search; keep the top deal's search the latest one.
    local head = self:Deals()[1]
    if head and head.kind == "item" and self.lastSearch ~= head.id then self:Search(head.id) end
end

-- What to search next. A deal you pressed Buy on comes first. While a full
-- scan is read, its best-looking gear starts being checked before the read
-- ends. Commodities from the scan need no check (see Compute).
function N:NextCheck()
    local want = self.priority
    self.priority = nil
    if want and self.byID[want] and not self.byID[want].verified and not self.byID[want].direct then return want end
    local f = self.full
    if f then
        local best, bestEach
        for id, each in pairs(f.candidates or {}) do
            if not f.checked[id] and not self.skipped[id] and self:KindOf(id) ~= "commodity"
                and (not bestEach or each > bestEach or (each == bestEach and id < best)) then
                best, bestEach = id, each
            end
        end
        if best then f.checked[best] = true end
        return best
    end
    for _, d in ipairs(self:Deals()) do
        if not d.verified and not d.direct then return d.id end
    end
end

---------------------------------------------------------------------------
-- Buying (call from a click or key binding only)
---------------------------------------------------------------------------
function N:IsBusy() return self.purchase ~= nil end

-- What the next press would do: deal, and a reason if it can't.
function N:Next()
    if not P.ahOpen then return nil, "Open the auction house." end
    if self.purchase then return self.byID[self.purchase.id], "Waiting for the last purchase." end
    local d = self:Head()
    if not d then return nil, "No deals. Scan the auction house." end
    if not d.verified and not d.direct then return d, "Checking the listings." end
    return d
end

function N:BuyNext()
    if self.purchase and clock() - self.purchase.time > PURCHASE_TIMEOUT then self.purchase = nil end
    local d, why = self:Next()
    if not d or why then
        -- Pressing on a deal still being checked moves it to the front.
        if d and not d.verified and not d.direct then
            self.priority = d.id
            if not self.checking then self:Pump() end
        end
        return false, why
    end
    d = self:Evaluate(d.id) -- your gold may have changed
    if not d or not (d.verified or d.direct) then return false, "No longer a deal." end
    local minProfit, basis = self:Rules()
    local sell = sellPrice(d.id)
    if d.kind == "commodity" then
        local b = d.buy
        -- One go straight from the scan; after it, check the live listings.
        if d.direct then self.tried[d.id] = true end
        self.purchase = { kind = "commodity", id = d.id, qty = b.qty, quoted = b.cost, value = sell * b.qty,
            limit = M.SnipeLimit(b.qty, sell, minProfit, basis), stage = "price", time = clock() }
        C_AuctionHouse.StartCommoditiesPurchase(d.id, b.qty)
    else
        -- One purchase buys one of the auctions grouped in the row.
        local a = d.buy.auctions[1]
        self.purchase = { kind = "item", id = d.id, auctionID = a.auctionID, qty = 1, cost = a.buyout,
            value = sell, time = clock() }
        C_AuctionHouse.PlaceBid(a.auctionID, a.buyout)
    end
    notify()
    return true
end

local function confirm(p)
    p.stage = "confirm"
    C_AuctionHouse.ConfirmCommoditiesPurchase(p.id, p.qty)
end

-- The server's price for the commodity purchase we started.
function N:OnPrice(unitPrice, totalPrice)
    local p = self.purchase
    if not p or p.kind ~= "commodity" or p.stage ~= "price" then return end
    local total = num(totalPrice)
    if total and total <= p.limit and total <= money() then
        p.cost = total
        local ready = not C_AuctionHouse.IsThrottledMessageSystemReady or C_AuctionHouse.IsThrottledMessageSystemReady()
        if ready then confirm(p) else p.stage = "ready" end
    else
        if C_AuctionHouse.CancelCommoditiesPurchase then C_AuctionHouse.CancelCommoditiesPurchase() end
        self:Failed(total and ("The price went up to " .. M.MoneyText(total) .. ". Checking again.") or nil)
    end
    notify()
end

function N:OnThrottleReady()
    local p = self.purchase
    if p and p.stage == "ready" then confirm(p); return end
    if self.after then self.after(0, "snipe-next-check", function() N:Pump() end) end
end

-- An item's name and vendor price loaded after the scan was read.
function N:OnItemInfo(itemID)
    local id = num(itemID)
    if not id or N.items[id] or self.byID[id] then return end
    if not ((self.snapshot and self.snapshot.items[id]) or self.live[id]) then return end
    if N.Item(id) then self:Evaluate(id) end
end

-- A purchase went through.
function N:Bought()
    local p = self.purchase
    if not p then return end
    self.purchase = nil
    local s = self.session
    s.buys, s.units = s.buys + 1, s.units + p.qty
    s.spent, s.value = s.spent + (p.cost or p.quoted or 0), s.value + p.value
    D:RecordEarning("snipe", { units = p.qty, spent = p.cost or p.quoted or 0, value = p.value }, time())
    local live = self.live[p.id]
    if p.kind == "item" and live and live.auctions then
        -- The game re-sends the row (with a new auction ID) after a purchase.
        for i, a in ipairs(live.auctions) do
            if a.auctionID == p.auctionID then
                a.qty = a.qty - 1
                if a.qty <= 0 then table.remove(live.auctions, i) end
                break
            end
        end
    elseif live then
        live.stale = true -- re-read the book before buying more
    end
    self:Evaluate(p.id)
end

-- A purchase didn't go through. The game shows its own error.
function N:Failed(message)
    local p = self.purchase
    if not p then return end
    self.purchase = nil
    local live = self.live[p.id]
    if live then live.stale = true end
    if message and UIErrorsFrame then UIErrorsFrame:AddMessage(message, 1, .82, 0) end
    self:Evaluate(p.id)
end

function N:OnItemPurchased(auctionID)
    local p = self.purchase
    if p and p.kind == "item" and p.auctionID == num(auctionID) then self:Bought() end
end

---------------------------------------------------------------------------
-- Full scan
---------------------------------------------------------------------------
function N.Clock(seconds)
    seconds = math.max(0, math.floor(seconds + 0.5))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Seconds until the game allows another full scan (0 = now).
function N:FullScanWait()
    local last = D:FullScanTime()
    return last and math.max(0, last + FULL_SCAN_COOLDOWN - time()) or 0
end

function N:HasFullScan() return C_AuctionHouse ~= nil and C_AuctionHouse.ReplicateItems ~= nil end

function N:FullScan()
    if not P.ahOpen then return false, "Open the auction house." end
    if not self:HasFullScan() then return false, "This game client has no full scan." end
    if self.full then return false, "Already scanning." end
    local wait = self:FullScanWait()
    if wait > 0 then return false, "The next full scan is allowed in " .. N.Clock(wait) .. "." end
    self.full = { stage = "waiting", started = clock() }
    D:SetFullScanTime(time())
    C_AuctionHouse.ReplicateItems()
    notify()
    self.after(FULL_SCAN_WAIT, "snipe-full-wait", function()
        if N.full and N.full.stage == "waiting" then
            N.full = nil
            if UIErrorsFrame then
                UIErrorsFrame:AddMessage("The game didn't send a full scan. It allows one every 15 minutes per account.", 1, .3, .3)
            end
            notify()
        end
    end)
    return true
end

function N:OnReplicate()
    local f = self.full
    if not f or f.stage ~= "waiting" then return end -- later events are item info arriving
    local total = num(C_AuctionHouse.GetNumReplicateItems()) or 0
    self.seq = self.seq + 1 -- the scan's place among live results: later ones win
    self.skipped = {}
    self.full = { stage = "reading", total = total, index = 0, items = {}, suffixes = {}, asked = {}, started = f.started,
        seq = self.seq, candidates = {}, checked = {} }
    self:ReadBatch()
end

function N:ReadBatch()
    local f = self.full
    if not f or f.stage ~= "reading" then return end
    if not P.ahOpen then self.full = nil; notify(); return end
    local last = math.min(f.total, f.index + READ_BATCH) - 1
    local get, link = C_AuctionHouse.GetReplicateItemInfo, C_AuctionHouse.GetReplicateItemLink
    local minProfit, basis = self:Rules()
    for i = f.index, last do
        local _, _, count, _, _, _, _, _, _, buyout, _, _, _, owner, _, _, itemID = get(i)
        count, buyout, itemID = num(count), num(buyout), num(itemID)
        -- owner is only ever set on your own auctions.
        local yours = owner ~= nil and readable(owner) and owner ~= ""
        if count and count > 0 and buyout and buyout > 0 and itemID and not yours then
            local flat = f.items[itemID]
            if not flat then
                flat = {}
                f.items[itemID] = flat
                if not N.items[itemID] then N.Item(itemID) end -- starts loading its price
            end
            flat[#flat + 1], flat[#flat + 2] = count, buyout
            -- Suffix variants need their own key to search; note any that look like deals.
            local sell = N.items[itemID] and N.items[itemID].sell
            -- Worth checking before the read ends: profit per item.
            local p = sell and M.VendorDeal(buyout, count, sell, minProfit, basis)
            if p and p / count > (f.candidates[itemID] or -math.huge) then f.candidates[itemID] = p / count end
            if link and sell and buyout < sell * count then
                local ok, l = pcall(link, i)
                local s = ok and suffixOf(l)
                if s then
                    local list = f.suffixes[itemID] or {}
                    local seen = false
                    for _, v in ipairs(list) do if v == s then seen = true end end
                    if not seen then list[#list + 1] = s end
                    f.suffixes[itemID] = list
                end
            end
        end
    end
    f.index = last + 1
    notify()
    if not self.checking then self:Pump() end -- start on the best gear found so far
    if f.index >= f.total then
        self:Publish()
    else
        self.after(0, "snipe-read", function() N:ReadBatch() end)
    end
end

-- The scan is read: list its deals now. Items whose vendor price hasn't
-- loaded yet join as it arrives (OnItemInfo).
function N:Publish()
    local f = self.full
    self.snapshot = { time = time(), seq = f.seq, total = f.total, items = f.items, suffixes = f.suffixes }
    self.full = nil
    -- Live listings from before the scan are superseded by it; ones checked
    -- while it was read are newer and stay.
    for id, live in pairs(self.live) do if live.seq < f.seq then self.live[id] = nil end end
    self.tried = {}
    self:Rebuild()
    self:Pump()
end

-- Search items that had deals before, to catch new ones between full scans.
function N:Recheck()
    local ids = {}
    for _, id in ipairs(D:Watched(RECHECK_LIMIT)) do
        if not self.skipped[id] then ids[#ids + 1] = id end
    end
    if #ids == 0 then return false, "Nothing to recheck yet. Run a full scan first." end
    return P:StartQueue(ids)
end

function N:Status()
    local f = self.full
    if f and f.stage == "waiting" then return "Asking for a full scan..." end
    if f and f.stage == "reading" then
        return string.format("Reading auctions %d / %d", f.index, f.total)
    end
    return nil
end

---------------------------------------------------------------------------
function N:Attach(app, scope)
    self.app = app
    local function on(event, fn)
        local ok, err = scope:Event(event, fn)
        if not ok then app.log:Info("Sniper: " .. event .. " unavailable (" .. (err and err.message or "?") .. ")") end
    end
    on("COMMODITY_SEARCH_RESULTS_UPDATED", function(id) N:OnCommodityResults(id) end)
    on("COMMODITY_SEARCH_RESULTS_ADDED", function(id) N:OnCommodityResults(id) end)
    on("ITEM_SEARCH_RESULTS_UPDATED", function(key) N:OnItemResults(key) end)
    on("ITEM_SEARCH_RESULTS_ADDED", function(key) N:OnItemResults(key) end)
    on("REPLICATE_ITEM_LIST_UPDATE", function() N:OnReplicate() end)
    on("COMMODITY_PRICE_UPDATED", function(unit, total) N:OnPrice(unit, total) end)
    on("COMMODITY_PRICE_UNAVAILABLE", function() N:Failed("No longer available. Checking again.") end)
    on("COMMODITY_PURCHASE_SUCCEEDED", function()
        if N.purchase and N.purchase.kind == "commodity" then N:Bought() end
    end)
    on("COMMODITY_PURCHASE_FAILED", function()
        if N.purchase and N.purchase.kind == "commodity" then N:Failed() end
    end)
    on("AUCTION_HOUSE_PURCHASE_COMPLETED", function(auctionID) N:OnItemPurchased(auctionID) end)
    on("AUCTION_HOUSE_SHOW_ERROR", function() if N.purchase then N:Failed() end end)
    on("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function() N:OnThrottleReady() end)
    on("GET_ITEM_INFO_RECEIVED", function(id, ok) if ok then N:OnItemInfo(id) end end)
    -- Whether an item is a commodity can load late too; one may now be buyable
    -- straight from the scan.
    on("ITEM_KEY_ITEM_INFO_RECEIVED", function(itemID)
        local id = num(itemID)
        local d = id and N.byID[id]
        if d and d.scan and not d.direct and not N.kinds[id] and N:KindOf(id) == "commodity" then N:Evaluate(id) end
    end)
    on("AUCTION_HOUSE_CLOSED", function()
        N.purchase, N.full, N.checking = nil, nil, nil
        -- Commodity books move while you're away; check again on return.
        for _, live in pairs(N.live) do if live.kind == "commodity" then live.stale = true end end
        N:RefreshLive()
    end)
    on("PLAYER_MONEY", function() if next(N.live) then N:RefreshLive() end end)
end
