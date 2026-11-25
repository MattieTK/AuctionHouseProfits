local ADDON, ns = ...
local M, D, P, R, U, T = ns.Model, ns.Data, ns.Prices, ns.Merchant, ns.UI, ns.AuctionTab
local S, B, N, SP = ns.Post, ns.AuctionsBar, ns.Snipe, ns.SnipePanel
local VERSION = "0.4.8"

-- WoW Forever only (interface 16001). Other clients have different AH rules.
local interface = select(4, GetBuildInfo())
if not M.Number(interface) or interface < 16000 or interface >= 20000 then return end

local SND = ns.SomethingNeedDoing
local app = SND:NewAddon(ADDON, { version = VERSION })
ns.App = app
ns.version = VERSION
ns.ConfigureSettings(app)
app:Appearance({ defaultTheme = "forever", themes = { forever = SND.Themes.forever, modern = SND.Themes.modern } })
ns.Options = ns.ConfigureOptions(app, SND)
U:Init(app)

local core = app:Scope("core")
local function readable(v) return not (issecretvalue and issecretvalue(v)) end
local function required(ok, result)
    if not ok then error(ADDON .. ": " .. result.message) end
    return result
end

-- Small UI projection: views redraw when this revision changes.
local view
local state = app:State({ revision = 0 })
-- id: only that item changed (its search results came in), so the list
-- re-analyses one row instead of every item in it.
local function publish(id)
    U:Invalidate(id)
    -- The Auctions-tab strip isn't a state watcher; refresh it directly.
    if B.bar and B.bar:IsShown() then core:After(0, "auctions-bar", function() B:Refresh() end) end
    local ok, err = state:Update(function(draft) draft.revision = draft.revision + 1 end)
    if not ok and err.code == "reentrant" then
        core:After(0, "publish", function() publish() end)
    elseif not ok then
        app.log:Warn(err.message)
    end
end

U.onChanged = publish
U.onListRequested = function()
    local owner = view or core
    owner:After(0.05, "list", function() U:RefreshList() end)
end
U.onScanStarted = function()
    core:After(8, "scan-timeout", function()
        if P.pending then P.pending = nil; publish() end
    end)
end
U.onShown = function()
    if view then view:Cancel() end
    view = app:Scope()
    U:Invalidate() -- anything may have changed while it was hidden
    view:Watch(state:Select(function(s) return s.revision end), function() U:Refresh() end)
    view:Watch(app:SelectSettings(function(values) return values end), function() U:Invalidate(); U:Refresh() end)
end
U.onHidden = function()
    if view then view:Cancel(); view = nil end
end

-- Item info arrives asynchronously; fill in names, icons and calibration.
local waiting = {}
local function onItemInfo(itemID, success)
    if not readable(itemID) then return end
    if waiting[itemID] then
        waiting[itemID] = nil
        local info = success and R.ItemInfo(itemID)
        if info then
            D:RememberInfo(itemID, info)
            local item = D:Item(itemID)
            if item and item.vendor then
                local r = M.SampleRatio(item.vendor.price / item.vendor.qty, info.sellPrice)
                if r then D:AddRatios(item.vendor.reaction or 4, { [itemID] = r }, time()) end
            end
        end
    end
    if not success then ns.Analysis.failed[itemID] = true end
    if ns.Analysis.requested[itemID] then
        ns.Analysis.requested[itemID] = nil
        if U:IsShown() then (view or core):After(0.2, "item-info", function() publish() end) end
    end
end

local function onMerchantShow()
    if not app:Get("recordMerchants") then return end
    local count, missing, reaction = R:Scan(time())
    local npc = UnitName and UnitName("npc")
    ns.lastMerchant = { npc = readable(npc) and npc or nil, reaction = reaction, count = count }
    for _, id in ipairs(missing) do waiting[id] = true end
    if count > 0 then publish() end
end

local function attachAH()
    T:Attach(app, core)
    B:Attach(app, core)
    SP:Attach(app, core)
end

app:OnReady(function()
    D:Load(time())
    P:Attach(core)
    P.after = function(delay, key, fn) core:After(delay, key, fn) end
    P:OnChange(function(id) publish(id) end)
    N.after = function(delay, key, fn) core:After(delay, key, fn) end
    N:Attach(app, core)
    N:OnChange(function() SP:RequestRefresh(); U:RefreshBuy() end)
    P:OnChange(function() SP:RequestRefresh() end)
    S:Attach(app, core)
    S:OnChange(function(id)
        publish()
        -- After a post, re-read the item's listings so "ahead" counts are current.
        if id and not S:IsBusy() and P.ahOpen then core:After(0.5, "rescan", function() P:Scan(id) end) end
    end)
    required(core:Event("MERCHANT_SHOW", onMerchantShow))
    required(core:Event("GET_ITEM_INFO_RECEIVED", onItemInfo))
    required(core:Event("BAG_UPDATE_DELAYED", function()
        if not (U:IsShown() or (B.bar and B.bar:IsShown())) then return end
        -- Bags decide which items the Bags and All lists show; the vendor
        -- lists only need the selected item's bag count redrawn.
        local only = (U.filter == "vendor" or U.filter == "merchant") and U.selected or nil
        publish(only)
    end))
    for _, pair in ipairs({ { "PLAYER_TARGET_CHANGED", "target" }, { "UPDATE_MOUSEOVER_UNIT", "mouseover" } }) do
        required(core:Event(pair[1], function()
            if R:CheckUnit(pair[2], time()) then publish() end
        end))
    end
    required(core:Event("PLAYER_MONEY", function()
        if R:OnMoney() then publish() end
    end))
    if type(BuyMerchantItem) == "function" then
        local ok = core:PostHook("BuyMerchantItem", function(index, quantity) R:OnBuy(index, quantity, time()) end)
        if not ok then app.log:Info("Purchase tracking unavailable") end
    end
    required(core:Event("ADDON_LOADED", function(name)
        if name == "Blizzard_AuctionHouseUI" then attachAH() end
    end))
    -- Shift-clicking an item while our search box has focus selects it.
    local linked
    if type(ChatFrameUtil) == "table" and type(ChatFrameUtil.InsertLink) == "function" then
        linked = core:PostHook(ChatFrameUtil, "InsertLink", function(link) U:InsertLink(link) end)
    elseif type(ChatEdit_InsertLink) == "function" then
        linked = core:PostHook("ChatEdit_InsertLink", function(link) U:InsertLink(link) end)
    end
    if not linked then app.log:Info("Shift-click item search unavailable") end
    if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_AuctionHouseUI") then
        attachAH()
    end
    if D.readOnly then
        app.log:Warn("Saved data is from a newer version of " .. ADDON .. "; changes won't be saved.")
    end
end)

local function say(message)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffe8bd55Auction House Profits:|r " .. message) end
end

local function slash(args)
    local cmd = (args or ""):lower():match("^%s*(%S*)")
    if cmd == "snipe" or cmd == "sniper" then
        SP:Toggle()
    elseif cmd == "made" or cmd == "earnings" or cmd == "earned" then
        for _, line in ipairs(ns.Earnings:Report(time())) do say(line) end
    elseif cmd == "options" or cmd == "config" then
        local ok, err = ns.Options:Toggle()
        if not ok then say(err.message) end
    elseif cmd == "help" then
        say("/ahp opens the calculator, /ahp snipe shows or hides the vendor sniper, /ahp made shows what the addon has made you, /ahp options opens settings. At the auction house, use the Profits tab.")
    else
        U:ToggleWindow()
    end
end
for _, command in ipairs({ "/ahp", "/ahprofits" }) do
    local ok, err = app:Slash(command, slash)
    if not ok then app.log:Warn(err.message) end
end

-- Addon compartment (the addons button by the minimap).
function AuctionHouseProfits_OnAddonCompartmentClick()
    if app:IsReady() then U:ToggleWindow() end
end
