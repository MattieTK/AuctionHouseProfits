-- Records what merchants charge, and at which reputation standing, so the
-- profit view can show vendor cost for every standing.
local _, ns = ...
local M, D = ns.Model, ns.Data
local R = {}
ns.Merchant = R

local function readable(v) return not (issecretvalue and issecretvalue(v)) end

local function itemInfo(id)
    if not C_Item or not C_Item.GetItemInfo then return nil end
    local name, link, quality, _, _, _, _, maxStack, _, icon, sellPrice = C_Item.GetItemInfo(id)
    if not name then return nil end
    return { name = name, link = link, quality = quality, maxStack = maxStack, icon = icon, sellPrice = sellPrice }
end
R.ItemInfo = itemInfo

local function merchantItem(i)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local info = C_MerchantFrame.GetItemInfo(i)
        if type(info) == "table" then return info end
        return nil
    end
    if GetMerchantItemInfo then -- older clients
        local name, texture, cost, qty, available, purchasable, usable, extended = GetMerchantItemInfo(i)
        if not name then return nil end
        return { name = name, texture = texture, price = cost, stackCount = qty, numAvailable = available,
            isPurchasable = purchasable, isUsable = usable, hasExtendedCost = extended }
    end
end

local function itemIDAt(i)
    local id = GetMerchantItemID and GetMerchantItemID(i)
    if M.Number(id) and id > 0 then return id end
    local link = GetMerchantItemLink and GetMerchantItemLink(i)
    if link and C_Item and C_Item.GetItemInfoInstant then
        id = C_Item.GetItemInfoInstant(link)
        if M.Number(id) and id > 0 then return id end
    end
end

-- Scan the open merchant. Returns how many items were recorded, and the
-- ids whose item info was not cached yet (retry when it arrives).
function R:Scan(now)
    if not GetMerchantNumItems then return 0, {} end
    local reaction = UnitReaction and UnitReaction("npc", "player")
    if not readable(reaction) or not M.STANDING_BY_REACTION[reaction] then reaction = 4 end
    local npc = UnitName and UnitName("npc")
    if not readable(npc) then npc = nil end
    local zone = GetRealZoneText and GetRealZoneText() or nil
    local recorded, missing, ratios = 0, {}, {}
    local count = GetMerchantNumItems() or 0
    for i = 1, count do
        local info = merchantItem(i)
        local id = itemIDAt(i)
        if info and id and readable(info.price) and M.Number(info.price) and info.price > 0 and not info.hasExtendedCost then
            local qty = M.Number(info.stackCount) and info.stackCount > 0 and info.stackCount or 1
            D:RecordVendor(id, {
                price = info.price, qty = qty, reaction = reaction, npc = npc, zone = zone,
                limited = M.Number(info.numAvailable) and info.numAvailable >= 0 or nil, time = now,
            })
            local static = itemInfo(id)
            if static then
                D:RememberInfo(id, static)
                local r = M.SampleRatio(info.price / qty, static.sellPrice)
                if r then ratios[id] = r end
            else
                D:RememberInfo(id, { name = info.name, icon = info.texture })
                missing[#missing + 1] = id
            end
            recorded = recorded + 1
        end
    end
    D:AddRatios(reaction, ratios, now)
    return recorded, missing, reaction
end

---------------------------------------------------------------------------
-- Purchases: what you actually paid, for profit on later sales.
-- BuyMerchantItem is post-hooked; the purchase only counts once your money
-- drops by about the expected amount (so failed buys are never recorded).
---------------------------------------------------------------------------
R.pending = {}

local function money() return GetMoney and GetMoney() or nil end

function R:OnBuy(index, quantity, now)
    local info, id = merchantItem(index), itemIDAt(index)
    if not info or not id or info.hasExtendedCost or not readable(info.price) or not M.Number(info.price) or info.price <= 0 then return end
    local stack = M.Number(info.stackCount) and info.stackCount > 0 and info.stackCount or 1
    local units = M.Number(quantity) and quantity > 0 and quantity or stack
    local unit = info.price / stack
    if #self.pending == 0 then self.money = money() end
    self.pending[#self.pending + 1] = { id = id, units = units, unit = unit, time = GetTime and GetTime() or 0, now = now }
end

function R:OnMoney()
    local current, before = money(), self.money
    self.money = current
    if not current or not before or current >= before or #self.pending == 0 then return end
    local spent, clock = before - current, GetTime and GetTime() or 0
    for i = #self.pending, 1, -1 do
        if clock - self.pending[i].time > 10 then table.remove(self.pending, i) end
    end
    for i, p in ipairs(self.pending) do
        -- Units from the money that left, in case the client counts stacks differently.
        local units = math.floor(spent / p.unit + 0.5)
        if units >= 1 and math.abs(units * p.unit - spent) <= math.max(1, units) then
            D:RecordPurchase(p.id, units, spent, p.now)
            table.remove(self.pending, i)
            return true
        end
    end
end
