-- Posting from your bags, and what your own auctions made.
-- Post() calls the protected C_AuctionHouse.Post* functions, so it must run
-- inside a click handler (a hardware event), exactly like Blizzard's Post.
local ADDON, ns = ...
local M, D, P, A = ns.Model, ns.Data, ns.Prices, ns.Analysis
local S = { pending = nil, owned = {}, listeners = {} }
ns.Post = S

local POPUP = "AUCTIONHOUSEPROFITS_POST_WARNING"
local PENDING_SECONDS = 15

local function readable(v) return not (issecretvalue and issecretvalue(v)) end
local function clock() return GetTime and GetTime() or 0 end

function S:OnChange(fn) self.listeners[#self.listeners + 1] = fn end
local function notify(id) for _, fn in ipairs(S.listeners) do fn(id) end end

---------------------------------------------------------------------------
-- Finding the item
---------------------------------------------------------------------------
local function bags()
    local list = {}
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
    for bag = 0, last do list[#list + 1] = bag end
    local reagent = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag
    if reagent and reagent > last then list[#list + 1] = reagent end
    return list
end

-- First postable stack of an item, and how many you have in all.
function S.Find(id)
    if not C_Container or not C_Container.GetContainerNumSlots or not ItemLocation then return nil, 0 end
    local first, count = nil, 0
    for _, bag in ipairs(bags()) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if type(info) == "table" and readable(info.itemID) and info.itemID == id and not info.isLocked then
                local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
                local valid = not C_AuctionHouse.IsSellItemValid or C_AuctionHouse.IsSellItemValid(loc, false)
                if valid then
                    first = first or loc
                    count = count + (M.Number(info.stackCount) and info.stackCount or 1)
                end
            end
        end
    end
    return first, count
end

-- Whether Post() can work right now: ok, reason, units available.
function S:CanPost(id, quantity, price)
    if not P.ahOpen or not C_AuctionHouse or not C_AuctionHouse.PostCommodity then return false, "Open the auction house to post." end
    if self:IsBusy() then return false, "Waiting for the last post to go through." end
    if not M.Number(price) or price < 1 then return false, "Set a price first." end
    local loc, count = S.Find(id)
    if not loc or count < 1 then return false, "None in your bags.", 0 end
    if not M.Number(quantity) or quantity < 1 then return false, "Set how many to post.", count end
    return true, nil, count
end

-- Some clients only take whole-silver prices (Blizzard rounds the same way).
function S.CopperAllowed()
    return not (C_AuctionHouse and C_AuctionHouse.SupportsCopperValues) or C_AuctionHouse.SupportsCopperValues() ~= false
end

function S:IsBusy()
    return self.pending ~= nil and clock() - self.pending.time < PENDING_SECONDS
end

-- Post up to quantity units at a unit price. Call from OnClick only.
function S:Post(id, quantity, price, duration)
    local ok, why, count = self:CanPost(id, quantity, price)
    if not ok then return false, why end
    quantity = math.min(math.floor(quantity), count)
    price = M.PostablePrice(price, S.CopperAllowed())
    local loc = S.Find(id)
    local status = C_AuctionHouse.GetItemCommodityStatus and C_AuctionHouse.GetItemCommodityStatus(loc)
    local kinds = Enum and Enum.ItemCommodityStatus or {}
    local args, sent
    local args
    if status == kinds.Commodity then
        args = { kind = "commodity", loc, duration, quantity, price }
    elseif status == kinds.Item then
        -- Each unit becomes its own auction at this buyout (Blizzard's multisell).
        args = { kind = "item", loc, duration, quantity, nil, price }
    else
        return false, "Item details are still loading. Try again in a moment."
    end
    -- Pending before the call: a confirmation warning may fire during it.
    self.pending = { args = args, id = id, qty = quantity, price = price, time = clock() }
    local sent
    if args.kind == "commodity" then
        sent = C_AuctionHouse.PostCommodity(loc, duration, quantity, price)
    else
        sent = C_AuctionHouse.PostItem(loc, duration, quantity, nil, price)
    end
    if not sent then self.pending = nil; return false, "The auction house refused the post." end
    notify(id)
    return true
end

-- The game wants confirmation (AUCTION_HOUSE_POST_WARNING). Blizzard's own
-- popup would re-post whatever its Sell page posted last, so swap it for ours.
function S:OnPostWarning()
    if not self:IsBusy() then return end
    local function swap()
        if StaticPopup_Hide then StaticPopup_Hide("AUCTION_HOUSE_POST_WARNING") end
        if StaticPopup_Show then StaticPopup_Show(POPUP) end
    end
    -- Blizzard shows its popup from the same event; let it, then replace it.
    if C_Timer and C_Timer.After then C_Timer.After(0, swap) else swap() end
end

function S:Confirm()
    local p = self.pending
    self.pending = nil
    if not p or clock() - p.time > 120 then return end
    self.confirmed = p.id -- AUCTION_CREATED follows; Done() rescans this item
    local a = p.args
    if a.kind == "commodity" then
        C_AuctionHouse.ConfirmPostCommodity(a[1], a[2], a[3], a[4])
    else
        C_AuctionHouse.ConfirmPostItem(a[1], a[2], a[3], a[4], a[5])
    end
end

function S:Done()
    local id = self.pending and self.pending.id or self.confirmed
    self.pending, self.confirmed = nil, nil
    notify(id)
end

---------------------------------------------------------------------------
-- Your auctions
---------------------------------------------------------------------------
local function isCommodity(itemKey)
    if not C_AuctionHouse.GetItemKeyInfo then return nil end
    local info = C_AuctionHouse.GetItemKeyInfo(itemKey)
    return type(info) == "table" and info.isCommodity or nil
end

-- Read the owned-auctions list Blizzard just refreshed. Sold rows become sale
-- records (once each); live rows are summarised per item for the views.
function S:OnOwnedAuctions(app, now)
    if not C_AuctionHouse.GetNumOwnedAuctions then return end
    local n = C_AuctionHouse.GetNumOwnedAuctions() or 0
    if not readable(n) then return end
    local sold = Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold or 1
    local owned, rules = {}, ns.Rules(app)
    local cutRate = M.CutRate(rules, P.venue or "faction")
    for i = 1, n do
        local a = C_AuctionHouse.GetOwnedAuctionInfo(i)
        local key = type(a) == "table" and a.itemKey
        local id = type(key) == "table" and readable(key.itemID) and key.itemID
        if id and M.Number(a.quantity) and a.quantity > 0 then
            local o = owned[id]
            if not o then o = { listed = 0, sold = 0, soldGross = 0, prices = {} }; owned[id] = o end
            local amount = M.Number(a.buyoutAmount) and a.buyoutAmount or (M.Number(a.bidAmount) and a.bidAmount) or nil
            -- Sold rows show the total sale; live commodity rows a unit price
            -- (in game: "Sold: Fine Thread x3  2s 94c" beside "x7  98c").
            if a.status == sold then
                o.sold, o.soldGross = o.sold + a.quantity, o.soldGross + (amount or 0)
                if amount and M.Number(a.auctionID) then
                    local sale = { id = id, qty = a.quantity, gross = amount, time = now,
                        unitCost = (A.CostBasis(app, id, now)), cutRate = cutRate }
                    if D:RecordSale(a.auctionID, sale) then D:RecordEarning("sale", sale, now) end
                end
            else
                -- Live commodity rows show a unit price; item rows a total.
                local unit = amount
                if amount and isCommodity(key) == false then unit = amount / a.quantity end
                o.listed = o.listed + a.quantity
                if unit then o.prices[#o.prices + 1] = { price = unit, qty = a.quantity } end
            end
        end
    end
    self.owned = owned
    notify(nil)
end

-- Summary of your auctions of one item from the last owned-auctions refresh.
function S:Owned(id) return self.owned[id] end

function S:Attach(app, scope)
    local function on(event, fn)
        local ok, err = scope:Event(event, fn)
        if not ok then error(err.message) end
    end
    on("AUCTION_HOUSE_POST_WARNING", function() S:OnPostWarning() end)
    on("AUCTION_HOUSE_AUCTION_CREATED", function() S:Done() end)
    on("AUCTION_HOUSE_POST_ERROR", function() S:Done() end)
    on("AUCTION_HOUSE_CLOSED", function() S.pending = nil end)
    on("OWNED_AUCTIONS_UPDATED", function() S:OnOwnedAuctions(app, time()) end)
    if type(StaticPopupDialogs) == "table" and not StaticPopupDialogs[POPUP] then
        StaticPopupDialogs[POPUP] = {
            text = type(CONFIRM_AUCTION_POSTING_TEXT) == "string" and CONFIRM_AUCTION_POSTING_TEXT
                or "Post this auction?",
            button1 = ACCEPT or "Accept", button2 = CANCEL or "Cancel",
            OnAccept = function() S:Confirm() end,
            OnCancel = function() S.pending = nil end,
            showAlert = true, hideOnEscape = 1, timeout = 0, whileDead = 1,
        }
    end
end
