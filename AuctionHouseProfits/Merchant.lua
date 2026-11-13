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
