-- Loads the whole addon (SND included) against a WoW boundary mock and drives
-- the main flows: merchant visit, standalone window, AH tab, AH price check.
-- This proves wiring and logic, not native rendering or taint behaviour.
-- Run from addon/: lua5.1 tests/runtime_test.lua
local W = dofile("tests/snd_wow.lua")
local ADDON = "AuctionHouseProfits"

-- Methods this mock doesn't model become recorded no-ops, so the run
-- surfaces every native method the addon relies on for manual review.
local unknown = {}
do
    local probe = CreateFrame("Frame")
    local methods = getmetatable(probe).__index
    -- Capitalised child-region fields (frame.Text etc.) are not methods.
    local fields = { Text = true, Background = true, Arrow = true, Left = true, Middle = true, Right = true,
        TitleText = true, CloseButton = true, NineSlice = true, Tabs = true }
    setmetatable(methods, { __index = function(_, key)
        if type(key) == "string" and key:match("^%u") and not fields[key] then
            unknown[key] = (unknown[key] or 0) + 1
            return function() end
        end
    end })
    function methods:HasFocus() return self.focus == true end
    function methods:SetParent(p) self.parent = p end
    function methods:GetFrameLevel() return self.frameLevel or 1 end
    function methods:SetFrameLevel(v) self.frameLevel = v end
    function methods:IsVisible()
        local f = self
        while f do if not f:IsShown() then return false end; f = f:GetParent() end
        return true
    end
    function methods:SetDataProvider(dp)
        self.rows = {}
        for i, data in ipairs(dp.items) do
            local b = CreateFrame("Button", nil, self)
            self.view.init(b, data)
            self.rows[i] = b
        end
    end
end

-- Globals the addon touches ------------------------------------------------
_G.time = os.time
function GetTime() return W.time end
function GetBuildInfo() return "1.60.1", "70888", "Nov 10 2026", 16001 end
UISpecialFrames = {}
SOUNDKIT = { IG_CHARACTER_INFO_TAB = 1 }
function PlaySound() end
DEFAULT_CHAT_FRAME = { lines = {} }
function DEFAULT_CHAT_FRAME:AddMessage(m) self.lines[#self.lines + 1] = m end
UIErrorsFrame = { lines = {} }
function UIErrorsFrame:AddMessage(m) self.lines[#self.lines + 1] = m end
GameTooltip = CreateFrame("Frame")
AUCTION_DURATION_ONE, AUCTION_DURATION_TWO, AUCTION_DURATION_THREE = "8 Hours", "12 Hours", "24 Hours"
ITEM_QUALITY_COLORS = { [1] = { hex = "|cffffffff" } }
function CreateDataProvider(items) return { items = items } end
function CreateScrollBoxListLinearView()
    local v = {}
    function v:SetElementExtent(h) self.extent = h end
    function v:SetElementInitializer(kind, fn) self.kind, self.init = kind, fn end
    return v
end
ScrollUtil = { InitScrollBoxListWithScrollBar = function(box, bar, view) box.view = view end }
function PanelTemplates_SelectTab(tab) tab.selectedTab = true end
function PanelTemplates_DeselectTab(tab) tab.selectedTab = false end
function PanelTemplates_GetSelectedTab(frame) return frame.selectedTab end

local ITEMS = {
    [14047] = { "Runecloth", "|cffffffff|Hitem:14047::::::::60:::::|h[Runecloth]|h|r", 1, 1, 1, "Trade Goods", "Cloth", 20, "", 132903, 400 },
    [2320] = { "Coarse Thread", "|cffffffff|Hitem:2320::::::::60:::::|h[Coarse Thread]|h|r", 1, 1, 1, "Trade Goods", "Parts", 20, "", 132891, 2 },
    [3371] = { "Crystal Vial", "|cffffffff|Hitem:3371::::::::60:::::|h[Crystal Vial]|h|r", 1, 1, 1, "Trade Goods", "Parts", 20, "", 132793, 5 },
}
local cached = { [14047] = true, [2320] = true } -- 3371 arrives later
C_Item = {
    GetItemInfo = function(id) if cached[id] and ITEMS[id] then return unpack(ITEMS[id]) end end,
    GetItemInfoInstant = function(link) return tonumber(tostring(link):match("item:(%d+)")) end,
}
function C_CurrencyInfo_stub() end
C_CurrencyInfo = { GetCoinTextureString = function(n) return "C" .. n end }

-- An Honored vendor selling at 10% off 4x sell price
local MERCHANT = {
    { id = 2320, info = { name = "Coarse Thread", price = 7, stackCount = 1, numAvailable = -1, hasExtendedCost = false } },
    { id = 3371, info = { name = "Crystal Vial", price = 18, stackCount = 1, numAvailable = -1, hasExtendedCost = false } },
    { id = 14047, info = { name = "Runecloth", price = 1440, stackCount = 1, numAvailable = 5, hasExtendedCost = false } },
}
function GetMerchantNumItems() return #MERCHANT end
C_MerchantFrame = { GetItemInfo = function(i) return MERCHANT[i] and MERCHANT[i].info end }
function GetMerchantItemID(i) return MERCHANT[i] and MERCHANT[i].id end
function GetMerchantItemLink(i) return MERCHANT[i] and ("item:" .. MERCHANT[i].id) end
function UnitReaction() return 6 end
function UnitName(u) if u == "npc" then return "Tamar" end end
function GetRealZoneText() return "Orgrimmar" end

local BAG = { [1] = { itemID = 14047, stackCount = 20 }, [2] = { itemID = 14047, stackCount = 15 } }
C_Container = {
    GetContainerNumSlots = function(bag) return bag == 0 and 4 or 0 end,
    GetContainerItemInfo = function(bag, slot) return bag == 0 and BAG[slot] or nil end,
}
local loaded = {}
C_AddOns = { IsAddOnLoaded = function(name) return loaded[name] == true end }

local cvars = { auctionHouseDurationDropdown = "1" }
function GetCVar(key) return cvars[key] end
local wallet = 100000
function GetMoney() return wallet end
function BuyMerchantItem() end
function IsShiftKeyDown() return false end
StaticPopupDialogs = {}
local popups = {}
function StaticPopup_Show(name) popups[#popups + 1] = "show:" .. name end
function StaticPopup_Hide(name) popups[#popups + 1] = "hide:" .. name end
ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end }
C_Map = { GetBestMapForUnit = function() return 1454 end } -- Orgrimmar: faction AH

local searches, posts, owned = {}, {}, {}
local commodity = { [14047] = {
    { unitPrice = 2100, quantity = 40, numOwnerItems = 0, totalNumberOfOwners = 1, owners = { "Bob" } },
    { unitPrice = 2300, quantity = 10, numOwnerItems = 10, totalNumberOfOwners = 1, owners = {} },
} }
Enum = { AuctionHouseSortOrder = { Price = 0 }, ItemCommodityStatus = { Unknown = 0, Item = 1, Commodity = 2 },
    AuctionStatus = { Active = 0, Sold = 1 } }
C_AuctionHouse = {
    MakeItemKey = function(id) return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end,
    SendSearchQuery = function(key) searches[#searches + 1] = key.itemID end,
    IsThrottledMessageSystemReady = function() return true end,
    GetNumCommoditySearchResults = function(id) return commodity[id] and #commodity[id] or 0 end,
    GetCommoditySearchResultInfo = function(id, i) return commodity[id][i] end,
    GetCommoditySearchResultsQuantity = function(id) return 40 end,
    GetNumItemSearchResults = function() return 0 end,
    CalculateCommodityDeposit = function(id, duration, qty) return 1234 end,
    SupportsCopperValues = function() return true end,
    IsSellItemValid = function() return true end,
    GetItemCommodityStatus = function() return Enum.ItemCommodityStatus.Commodity end,
    PostCommodity = function(loc, duration, qty, price)
        posts[#posts + 1] = { loc = loc, duration = duration, qty = qty, price = price }; return true
    end,
    ConfirmPostCommodity = function(loc, duration, qty, price)
        posts[#posts + 1] = { confirm = true, loc = loc, duration = duration, qty = qty, price = price }
    end,
    GetNumOwnedAuctions = function() return #owned end,
    GetOwnedAuctionInfo = function(i) return owned[i] end,
    GetItemKeyInfo = function() return { isCommodity = true } end,
}

ChatFrameUtil = { InsertLink = function() return false end }

-- Optional third-party price source
Auctionator = { API = { v1 = { GetAuctionPriceByItemID = function(caller, id)
    assert(caller == ADDON); return id == 2320 and 25 or nil end } } }

-- Load in TOC order ----------------------------------------------------------
local ns = {}
for line in io.lines("AuctionHouseProfits/AuctionHouseProfits.toc") do
    if line:match("%.lua$") then
        local path = "AuctionHouseProfits/" .. line:gsub("\\", "/")
        assert(loadfile(path))(ADDON, ns)
    end
end
assert(ns.App, "addon bootstrapped")

local total = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error(name .. ": " .. tostring(err), 0) end
    total = total + 1
    print("PASS " .. name)
end
local function settle() for _ = 1, 5 do W.tick(0.1) end end

-- v0.1 saved "Your price" as a manual market price.
AuctionHouseProfitsData = { version = 1, items = {}, scans = {}, manual = { [3371] = 20 }, plans = {}, calibration = {} }

test("addon becomes ready and migrates v1 data", function()
    W.event("ADDON_LOADED", ADDON)
    settle()
    assert(ns.App:IsReady())
    local db = AuctionHouseProfitsData
    assert(db.version == 2 and type(db.purchases) == "table" and type(db.sales) == "table")
    assert(db.plans[3371].price == 20 and next(db.manual) == nil, "manual price moved to your price")
    assert(#W.errors == 0, W.errors[1])
end)

test("merchant visit records prices, standing and calibration", function()
    W.event("MERCHANT_SHOW")
    settle()
    local data = AuctionHouseProfitsData
    local thread = data.items[2320]
    assert(thread and thread.vendor.price == 7 and thread.vendor.reaction == 6 and thread.vendor.npc == "Tamar")
    assert(data.items[14047].vendor.limited == true)
    -- 3371 wasn't cached: calibration for it waits for item info
    assert(data.items[3371].vendor and not data.items[3371].sellPrice)
    cached[3371] = true
    W.event("GET_ITEM_INFO_RECEIVED", 3371, true)
    settle()
    assert(data.items[3371].sellPrice == 5)
    local pct, n = ns.Data:Calibration(6)
    assert(n == 3, "three samples, got " .. tostring(n))
    assert(pct == 10, "honored discount observed as 10%, got " .. tostring(pct))
    W.event("MERCHANT_SHOW"); settle()
    local _, again = ns.Data:Calibration(6)
    assert(again == 3, "revisiting a merchant doesn't add duplicate samples")
end)

test("buying from a merchant records what you paid, once the money leaves", function()
    BuyMerchantItem(1, 5) -- 5 Coarse Thread at 7c
    wallet = wallet - 35
    W.event("PLAYER_MONEY"); settle()
    assert(ns.Data:PaidUnit(2320) == 7, "paid 7c each")
    BuyMerchantItem(3) -- Runecloth, but the purchase fails: no money moves
    W.event("PLAYER_MONEY"); settle()
    assert(ns.Data:PaidUnit(14047) == nil)
end)

test("targeting or mousing over a vendor refreshes your standing with them", function()
    local name, reaction = UnitName, UnitReaction
    UnitName = function(u) if u == "npc" or u == "mouseover" or u == "target" then return "Tamar" end end
    UnitReaction = function() return 5 end
    W.event("UPDATE_MOUSEOVER_UNIT"); settle()
    local a = ns.Analysis.Item(ns.App, 2320, os.time())
    assert(a.standing == 5 and math.abs(a.unitCost - 7 / 0.9) < 1e-9, "Friendly pays the list price")
    UnitReaction = function() return 6 end
    W.event("PLAYER_TARGET_CHANGED"); settle()
    a = ns.Analysis.Item(ns.App, 2320, os.time())
    assert(a.standing == 6 and math.abs(a.unitCost - 7) < 1e-9, "back to Honored")
    UnitName = function() return "Some Player" end
    W.event("UPDATE_MOUSEOVER_UNIT"); settle()
    assert(ns.Data:Standing("Some Player") == nil, "only vendors you've shopped at")
    UnitName, UnitReaction = name, reaction
end)

test("an item sold by several vendors is costed at the one you stand best with", function()
    local name, reaction = UnitName, UnitReaction
    -- Grub sells Coarse Thread at its 8c list price: you're only Friendly there.
    local saved = MERCHANT
    MERCHANT = { { id = 2320, info = { name = "Coarse Thread", price = 8, stackCount = 1, numAvailable = -1, hasExtendedCost = false } } }
    UnitName = function(u) if u == "npc" or u == "mouseover" then return "Grub" end end
    UnitReaction = function() return 5 end
    W.event("MERCHANT_SHOW"); settle()
    local item = AuctionHouseProfitsData.items[2320]
    assert(item.vendors.Grub and item.vendors.Tamar, "both vendors kept")
    local a = ns.Analysis.Item(ns.App, 2320, os.time())
    assert(a.vendor.npc == "Tamar" and math.abs(a.unitCost - 7) < 1e-9 and #a.offers == 2, "Honored at Tamar: 7c")
    -- Reach Honored with Grub as well: 8c list less 10% beats Tamar's 7c? No: 7.2c.
    UnitReaction = function() return 6 end
    W.event("UPDATE_MOUSEOVER_UNIT"); settle()
    a = ns.Analysis.Item(ns.App, 2320, os.time())
    assert(a.vendor.npc == "Tamar", "still cheaper at Tamar")
    -- Drop to Friendly with Tamar: Grub at Honored (7.2c) is now the better buy.
    UnitName = function(u) if u == "mouseover" then return "Tamar" end end
    UnitReaction = function() return 5 end
    W.event("UPDATE_MOUSEOVER_UNIT"); settle()
    a = ns.Analysis.Item(ns.App, 2320, os.time())
    assert(a.vendor.npc == "Grub" and math.abs(a.unitCost - 7.2) < 1e-9, "switches to Grub")
    local rows = ns.Analysis.List(ns.App, "merchant", "", "Grub", os.time())
    assert(#rows == 1 and rows[1].id == 2320, "last-merchant filter knows every vendor")
    rows = ns.Analysis.List(ns.App, "merchant", "", "Tamar", os.time())
    assert(#rows == 3)
    -- Back to Honored with Tamar for the rest of the run.
    UnitReaction = function() return 6 end
    W.event("UPDATE_MOUSEOVER_UNIT"); settle()
    MERCHANT, UnitName, UnitReaction = saved, name, reaction
    ns.lastMerchant = nil
end)

test("WoW Forever discounts: full price below Honored, 10% from Honored up", function()
    local rules = ns.Rules(ns.App)
    assert(rules.discounts[4] == 0 and rules.discounts[5] == 0)
    assert(rules.discounts[6] == 10 and rules.discounts[7] == 10 and rules.discounts[8] == 10)
end)

test("analysis prices an item from vendor cost and Auctionator", function()
    local a = ns.Analysis.Item(ns.App, 2320, os.time())
    assert(math.abs(a.baseUnit - 7 / 0.9) < 1e-9, "list price recovered from honored price")
    assert(a.standing == 6 and math.abs(a.unitCost - 7) < 1e-9)
    assert(a.market and a.market.source == "auctionator" and a.market.price == 25)
    assert(a.price == 25 and a.priceKind == "market", "no listings seen: price at market")
    assert(a.duration == 1, "duration from the AH Sell page's own setting")
    assert(a.paidUnit == 7)
    assert(a.faction and a.neutral and a.ladder and #a.byStanding == 2, "two price tiers")
    assert(a.byStanding[1].unitCost > a.byStanding[2].unitCost, "below Honored pays more")
    assert(not a.gameDepositVenue, "AH closed: formula deposit")
end)

test("slash command opens the standalone window with a populated list", function()
    SlashCmdList_run = nil
    local handler
    for key, fn in pairs(SlashCmdList) do if key:upper():find("AUCTIONHOUSEPROFITS") then handler = handler or fn end end
    assert(handler, "slash registered")
    handler("")
    settle()
    assert(ns.UI:IsShown() and ns.UI.host == "window")
    local rows = ns.UI.listBox.rows
    assert(rows and #rows == 3, "three vendor items listed, got " .. tostring(rows and #rows))
    -- best profit first: thread (25c market vs 7c cost)
    assert(rows[1].data.id == 2320, "most profitable first")
    rows[1]:GetScript("OnClick")(rows[1])
    settle()
    assert(ns.UI.selected == 2320 and ns.UI.current and ns.UI.current.id == 2320)
    assert(ns.UI.title:GetText():find("Coarse Thread"))
    assert(ns.UI.cards.faction.profit:GetText() ~= "")
    assert(not ns.UI.cards.neutral.frame:IsShown() and ns.UI.activityCard.frame:IsShown(), "neutral AH is opt-in")
    assert(ns.UI.tableHeads[3]:GetText() == "Profit" and not ns.UI.tableHeads[4]:IsShown())
    assert(ns.App:Set("showNeutral", true)); settle()
    assert(ns.UI.cards.neutral.frame:IsShown() and not ns.UI.activityCard.frame:IsShown())
    assert(ns.UI.tableHeads[3]:GetText() == "Faction" and ns.UI.tableHeads[4]:IsShown())
    assert(ns.App:Set("showNeutral", false)); settle()
    assert(#W.errors == 0, W.errors[1])
end)

test("editing the plan and your price republishes", function()
    local box = ns.UI.inputs.stackSize
    box:SetText("10")
    box:GetScript("OnEnterPressed")(box)
    settle()
    assert(ns.UI.current.stackSize == 10)
    local boxes = ns.UI.inputs.price.boxes
    boxes[3]:SetText("30")
    boxes[3]:GetScript("OnEnterPressed")(boxes[3])
    settle()
    local a = ns.UI.current
    assert(a.price == 30 and a.priceKind == "yours")
    assert(a.market.source == "auctionator" and a.market.price == 25, "your price never replaces the market price")
    -- 1g 2s 3c across three boxes
    boxes[1]:SetText("1"); boxes[2]:SetText("2"); boxes[3]:SetText("3")
    boxes[1]:GetScript("OnEnterPressed")(boxes[1]); settle()
    assert(ns.UI.current.price == 10203)
    assert(boxes[1]:GetText() == "1" and boxes[2]:GetText() == "2" and boxes[3]:GetText() == "3")
    boxes[1]:SetText(""); boxes[2]:SetText(""); boxes[3]:SetText("30")
    boxes[3]:GetScript("OnEnterPressed")(boxes[3]); settle()
    -- ladder click sets your price
    local first = ns.UI.ladder[1].button
    local clicked = first.price -- the ladder re-centres on the new price after the click
    first:GetScript("OnClick")(first)
    settle()
    assert(ns.Data:Plan(2320).price == clicked and clicked == 45)
    -- clearing all three boxes goes back to the default price
    for _, b in ipairs(boxes) do b:SetText("") end
    boxes[1]:GetScript("OnEnterPressed")(boxes[1])
    settle()
    assert(ns.Data:Plan(2320).price == nil and ns.UI.current.priceKind == "market")
    assert(boxes[3]:GetText() == "25", "boxes show the default again")
end)

test("closed dropdowns show their value", function()
    assert(ns.UI.inputs.duration.Text:GetText() == "8 Hours")
    assert(ns.UI.sortDropdown.Text:GetText() == "Profit per day")
    assert(ns.UI.inputs.standing == nil, "standing comes from the game, not a menu")
    assert(ns.UI.filterDropdown.Text:GetText() == "Vendor items")
    assert(ns.UI.inputs.duration.Text.font, "caption has a font")
end)

test("filters and search", function()
    ns.UI:SetFilter("bags"); settle()
    assert(#ns.UI.listBox.rows == 1 and ns.UI.listBox.rows[1].data.id == 14047)
    ns.UI:SetFilter("vendor"); ns.UI:SetQuery("vial"); settle()
    assert(#ns.UI.listBox.rows == 1 and ns.UI.listBox.rows[1].data.id == 3371)
    ns.UI:SetQuery("2320"); settle()
    assert(ns.UI.listBox.rows[1].data.id == 2320)
    ns.UI:SetQuery(""); settle()
end)

-- Auction house ---------------------------------------------------------------
local ah
test("auction house tab attaches when Blizzard_AuctionHouseUI loads", function()
    ah = CreateFrame("Frame", "AuctionHouseFrame", UIParent)
    AuctionHouseFrameDisplayMode = { Buy = { "BrowseResultsFrame" }, ItemSell = { "ItemSellFrame" }, Auctions = { "AuctionsFrame" } }
    local order = { AuctionHouseFrameDisplayMode.Buy, AuctionHouseFrameDisplayMode.ItemSell, AuctionHouseFrameDisplayMode.Auctions }
    ah.Tabs = {}
    for i, mode in ipairs(order) do
        local tab = CreateFrame("Button", nil, ah)
        tab:SetScript("OnClick", function() ah:SetDisplayMode(mode) end)
        ah.Tabs[i] = tab
    end
    function ah:SetDisplayMode(mode) -- Blizzard_AuctionHouseFrame.lua semantics
        if self.displayMode == mode then return end
        self.displayMode = mode
        for i, m in ipairs(order) do if m == mode then self.selectedTab = i; PanelTemplates_SelectTab(self.Tabs[i]) end end
    end
    ah:SetScript("OnShow", function(self) self:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy) end)
    function ah:SetTitle(t) self.title = t end
    -- Blizzard's Auctions page: an item header shows when you pick one of your items.
    local af = CreateFrame("Frame", nil, ah)
    af.ItemDisplay = CreateFrame("Button", nil, af)
    function af:GetItemKey() return self.itemKey end
    function af:SetItemKey(key) self.itemKey = key end
    function af:SetDisplayMode(mode) self.mode = mode end
    function af:SetTab(tab) self.tab = tab end
    function af:IsDisplayingBids() return false end
    ah.AuctionsFrame = af
    ah:Hide()
    loaded.Blizzard_AuctionHouseUI = true
    W.event("ADDON_LOADED", "Blizzard_AuctionHouseUI")
    settle()
    assert(ns.AuctionTab.attached and AuctionHouseProfitsAHTab)
    assert(#ah.Tabs == 3, "Blizzard Tabs array untouched")
    assert(AuctionHouseProfitsAHTab:GetParent() ~= ah, "tab lives in our holder")
    assert(ns.AuctionsBar.attached and ns.AuctionsBar.bar, "Auctions tab strip attached")
end)

test("opening the AH and clicking Profits shows the view in the AH", function()
    W.event("AUCTION_HOUSE_SHOW")
    ah:Show()
    settle()
    assert(ns.Prices.ahOpen)
    AuctionHouseProfitsAHTab:GetScript("OnClick")(AuctionHouseProfitsAHTab)
    settle()
    assert(ns.UI.host == "ah" and ns.UI:IsShown() and ns.UI.panel:GetParent() == ah)
    assert(AuctionHouseProfitsAHTab.selectedTab == true and ah.Tabs[1].selectedTab == false)
    assert(type(ah.displayMode) == "table" and #ah.displayMode == 0, "Blizzard subframes hidden via an empty display mode")
    assert(not ns.UI.window:IsShown(), "standalone window closed when docked")
    assert(ah.title == "Auction House Profits")
end)

test("selecting an item auto-scans the AH and uses the game deposit", function()
    ns.UI:Select(14047)
    settle()
    assert(searches[#searches] == 14047, "search query sent")
    W.event("COMMODITY_SEARCH_RESULTS_UPDATED", 14047)
    settle()
    local scan = ns.Data:Scan(14047)
    assert(scan and scan.price == 2100 and scan.qty == 40)
    assert(scan.levels and #scan.levels == 2 and scan.levels[2].mine == 10)
    local a = ns.UI.current
    assert(a.market.source == "scan" and a.market.price == 2100)
    assert(a.gameDepositVenue and a.deposit[a.gameDepositVenue] == 1234)
    assert(ns.UI.scanButton.label:GetText() == "Scan AH")
    assert(a.undercut == 2099 and a.price == 2099 and a.priceKind == "undercut", "defaults to 1c under Bob")
    assert(a.ahead == 0 and a.positions[1].price == 2099 and a.positions[1].ahead == 0)
    assert(#a.positions == 1, "your own 23s listing isn't something to undercut")
    local rows = a.marketRows
    assert(#rows == 3 and rows[1].ghost and rows[1].price == 2099 and rows[1].qty == 20, "your listing first")
    assert(rows[2].price == 2100 and rows[2].qty == 40 and rows[3].price == 2300 and rows[3].mine == 10)
    assert(ns.UI.tableHeads[1]:GetText() == "Price" and ns.UI.tableHeads[2]:GetText() == "Qty",
        "live market table shown once listings are known")
    assert(ns.UI.ladder[2].second:GetText() == "40", "quantity at each price")
    assert(ns.UI.ladder[1].button.price == nil, "the ghost row isn't a price to click")
    ns.UI.ladder[2].button:GetScript("OnClick")(ns.UI.ladder[2].button); settle()
    assert(ns.Data:Plan(14047).price == 2099, "clicking a level lists 1c under it")
    ns.UI:SetPlan("price", nil); settle()
    local boxes = ns.UI.inputs.price.boxes
    assert(boxes[1]:GetText() == "" and boxes[2]:GetText() == "20" and boxes[3]:GetText() == "99")
    -- Clicking into the price and away again doesn't pin the automatic price.
    boxes[2]:SetFocus(); boxes[2]:ClearFocus(); boxes[2]:GetScript("OnEditFocusLost")(boxes[2]); settle()
    assert(ns.Data:Plan(14047).price == nil and ns.UI.current.priceKind == "undercut")
    -- Escape throws away what you typed.
    boxes[3]:SetText("12"); boxes[3]:SetFocus()
    local esc = boxes[3]:GetScript("OnEscapePressed")
    local lost = boxes[3]:GetScript("OnEditFocusLost")
    local clear = boxes[3].ClearFocus
    boxes[3].ClearFocus = function(self) clear(self); lost(self) end -- native ClearFocus fires focus-lost
    esc(boxes[3]); settle()
    boxes[3].ClearFocus = nil
    assert(ns.Data:Plan(14047).price == nil and boxes[3]:GetText() == "99")
end)

test("Scan AH re-analyses only the item scanned, not the whole list", function()
    local U, A = ns.UI, ns.Analysis
    U:SetFilter("all"); settle()
    local rows = #U.rows
    assert(rows >= 3, "a list to not re-analyse: " .. rows)
    local item, seen = A.Item, {}
    A.Item = function(app, id, now) seen[#seen + 1] = id; return item(app, id, now) end
    U.scanButton:GetScript("OnClick")(U.scanButton); settle()
    commodity[14047][1].unitPrice = 2050
    W.event("COMMODITY_SEARCH_RESULTS_UPDATED", 14047); settle()
    W.event("COMMODITY_SEARCH_RESULTS_ADDED", 14047); settle()
    A.Item = item
    commodity[14047][1].unitPrice = 2100
    assert(#seen > 0, "the scanned item is redrawn")
    for _, id in ipairs(seen) do assert(id == 14047, "re-analysed item " .. tostring(id)) end
    local row
    for _, r in ipairs(U.rows) do if r.id == 14047 then row = r end end
    assert(row and row.market == 2049 and #U.rows == rows, "its row shows the new price")
    seen = {}
    A.Item = function(app, id, now) seen[#seen + 1] = id; return item(app, id, now) end
    U:Select(2320); settle()
    A.Item = item
    assert(#seen > 0, "the selected item is drawn")
    for _, id in ipairs(seen) do assert(id == 2320, "selecting an item re-analysed item " .. tostring(id)) end
    U:Select(14047); settle()
    local distinct = {}
    A.Item = function(app, id, now) distinct[id] = true; return item(app, id, now) end
    U:SetFilter("vendor"); settle()
    A.Item = item
    local n = 0
    for _ in pairs(distinct) do n = n + 1 end
    assert(n == #U.rows and n > 1, "changing the filter rebuilds the whole list")
    seen = {}
    A.Item = function(app, id, now) seen[#seen + 1] = id; return item(app, id, now) end
    W.event("BAG_UPDATE_DELAYED"); settle() -- e.g. after a buy
    A.Item = item
    assert(#seen > 0, "the selected item's bag count is redrawn")
    for _, id in ipairs(seen) do assert(id == 14047, "a bag change re-analysed item " .. tostring(id)) end
end)

test("a search that finds nothing clears stale sellers", function()
    commodity[3371] = {}
    ns.Data:RecordScan(3371, 30, 5, os.time(), { { price = 30, qty = 5, mine = 0 } })
    assert(ns.Prices:Scan(3371))
    W.event("COMMODITY_SEARCH_RESULTS_UPDATED", 3371); settle()
    local scan = ns.Data:Scan(3371)
    assert(#scan.levels == 0 and scan.qty == 0 and not ns.Prices:IsScanning(3371))
end)

test("other addons' searches refresh the market depth too", function()
    commodity[14047][1].quantity = 41
    W.event("COMMODITY_SEARCH_RESULTS_UPDATED", 14047) -- nobody asked us
    settle()
    assert(ns.Data:Scan(14047).levels[1].qty == 41)
    commodity[14047][1].quantity = 40
    W.event("COMMODITY_SEARCH_RESULTS_UPDATED", 14047); settle()
end)

test("each search adds to the item's price and volume history", function()
    local D, now = ns.Data, os.time()
    local h = D:History(14047)
    assert(#h >= 1 and h[#h].q == 40 and h[#h].p == 2100 and h[#h].d == "2100:40,2300:10", tostring(h[#h].d))
    D:AddHistory(3371, 30, 5, now - 100); D:AddHistory(3371, 30, 4, now - 97)
    local merged = D:History(3371)
    assert(merged[#merged].q == 4 and merged[#merged].t == now - 97 and (#merged < 2 or merged[#merged - 1].t ~= now - 100),
        "result events from one search merge")
    -- Coarse Thread: the cheap end keeps selling and refilling.
    local books = { "25:100,26:200", "25:40,26:200", "24:60,25:40,26:200", "24:10,25:40,26:200", "23:50,24:10,25:40,26:200" }
    for i, d in ipairs(books) do D:AddHistory(2320, 25, 300, now - (6 - i) * 1200, d) end
    local a = ns.Analysis.Item(ns.App, 2320, now)
    assert(a.activity.key == "busy" and a.activity.bought == 110, tostring(a.activity.key))
    assert(a.perDay == nil or a.perDay < 0, "at 25c the 12s deposit eats the profit")
    ns.Data:SetPlan(2320, "price", 300)
    a = ns.Analysis.Item(ns.App, 2320, now)
    assert(a.perDay and a.perDay > 0, "profit per day for an active market")
    local rows = ns.Analysis.List(ns.App, "vendor", "", nil, now, "day")
    assert(rows[1].id == 2320 and rows[1].perDay)
    ns.UI:Select(2320); settle()
    assert(not ns.UI.chart.empty:IsShown(), "chart drawn")
    local bars = 0
    for _, col in ipairs(ns.UI.chart.columns) do if col.bar:IsShown() then bars = bars + 1 end end
    assert(bars == 5, "one volume bar per scan, got " .. bars)
    local sold = 0
    for _, col in ipairs(ns.UI.chart.columns) do if col.sold:IsShown() then sold = sold + 1 end end
    assert(sold == 2, "bought bars where the cheap end sold, got " .. sold)
    assert(ns.UI.activityCard.profit:GetText():find("Busy"))
    ns.UI:SetPlan("price", nil); ns.UI:Select(14047); settle()
end)

test("Scan list searches every item in the list in turn", function()
    local before = #searches
    ns.UI:RefreshList()
    ns.UI:ToggleScanList()
    assert(ns.Prices:QueueProgress() ~= nil, "queue running")
    for _ = 1, 10 do
        local id = searches[#searches]
        W.event("COMMODITY_SEARCH_RESULTS_UPDATED", id)
        settle()
        if not ns.Prices:QueueProgress() then break end
    end
    assert(not ns.Prices:QueueProgress(), "queue finished")
    local seen = {}
    for i = before + 1, #searches do seen[searches[i]] = true end
    assert(seen[2320] and seen[3371] and seen[14047], "every listed item searched")
    assert(ns.UI.scanAllButton.label:GetText() == "Scan list")
end)

test("Post lists a stack from your bags at your price", function()
    local before = #posts
    ns.UI.postButton:GetScript("OnClick")(ns.UI.postButton)
    settle()
    local p = posts[before + 1]
    assert(p and p.qty == 20 and p.price == 2099 and p.duration == 1 and p.loc.bag == 0 and p.loc.slot == 1)
    assert(ns.Post:IsBusy() and ns.UI.postButton.label:GetText() == "Posting...")
    -- The game asks for confirmation: our popup replaces Blizzard's.
    W.event("AUCTION_HOUSE_POST_WARNING"); settle()
    assert(popups[#popups - 1] == "hide:AUCTION_HOUSE_POST_WARNING" and popups[#popups] == "show:AUCTIONHOUSEPROFITS_POST_WARNING")
    StaticPopupDialogs.AUCTIONHOUSEPROFITS_POST_WARNING.OnAccept()
    local c = posts[before + 2]
    assert(c and c.confirm and c.qty == 20 and c.price == 2099)
    local scans = #searches
    W.event("AUCTION_HOUSE_AUCTION_CREATED"); settle(); settle()
    assert(not ns.Post:IsBusy())
    assert(#searches == scans + 1 and searches[#searches] == 14047, "re-reads listings after posting")
end)

test("clicking a Blizzard tab or changing display mode closes the Profits view", function()
    local buy = ah.Tabs[1]
    buy:GetScript("OnClick")(buy)
    settle()
    assert(not ns.UI:IsShown(), "closed when Blizzard switches back to Buy")
    assert(ah.displayMode == AuctionHouseFrameDisplayMode.Buy)
    assert(ah.Tabs[1].selectedTab == true and AuctionHouseProfitsAHTab.selectedTab == false, "visuals restored")
    AuctionHouseProfitsAHTab:GetScript("OnClick")(AuctionHouseProfitsAHTab); settle()
    assert(ns.UI:IsShown())
    ah:SetDisplayMode(AuctionHouseFrameDisplayMode.Auctions); settle()
    assert(not ns.UI:IsShown(), "closed by SetDisplayMode hook")
end)

test("Auctions tab strip: relist, undercut/match and what your auctions made", function()
    local af, B = ah.AuctionsFrame, ns.AuctionsBar
    ah:SetDisplayMode(AuctionHouseFrameDisplayMode.Auctions); settle()
    af:SetItemKey({ itemID = 14047 }); settle()
    assert(B.bar:IsShown() and B.itemID == 14047)
    assert(B.qtyBox:GetText() == "20")
    assert(B.money.boxes[2]:GetText() == "20" and B.money.boxes[3]:GetText() == "99", "undercut by default")
    assert(B.quote:GetText():find("first in line"))
    B:UsePrice("match"); settle()
    assert(B.money.boxes[3]:GetText() == "0" and B.money.boxes[2]:GetText() == "21")
    assert(B.quote:GetText():find("40 ahead"))
    -- 13 sold for 21s each, 7 still listed
    owned[1] = { auctionID = 501, itemKey = { itemID = 14047 }, status = 1, quantity = 13, buyoutAmount = 13 * 2100 }
    owned[2] = { auctionID = 502, itemKey = { itemID = 14047 }, status = 0, quantity = 7, buyoutAmount = 2100 }
    W.event("OWNED_AUCTIONS_UPDATED"); settle()
    local o = ns.Post:Owned(14047)
    assert(o.sold == 13 and o.listed == 7 and o.prices[1].price == 2100)
    local sale = AuctionHouseProfitsData.sales[501]
    assert(sale and sale.qty == 13 and sale.gross == 27300 and sale.unitCost == 1440 and sale.cutRate == 0.05)
    W.event("OWNED_AUCTIONS_UPDATED"); settle()
    local n = 0; for _ in pairs(AuctionHouseProfitsData.sales) do n = n + 1 end
    assert(n == 1, "each sale recorded once")
    local day = AuctionHouseProfitsData.ledger[ns.Data.DayKey(time())]
    assert(day and day.a.n == 1 and day.a.costed == 1 and day.a.gross == 27300 and day.a.profit == 7215,
        "the sale is in the earnings ledger, once")
    -- 27300 - 1365 cut - 13 x 1440 = 7215
    assert(B.owned:GetText():find("13 sold") and B.owned:GetText():find("7 listed"), B.owned:GetText())
    assert(B.owned:GetText():find("C7215"), "profit on sold auctions: " .. B.owned:GetText())
    -- Relist another 20 at the matched price
    local before = #posts
    B.postButton:GetScript("OnClick")(B.postButton); settle()
    assert(posts[before + 1].qty == 20 and posts[before + 1].price == 2100)
    W.event("AUCTION_HOUSE_AUCTION_CREATED"); settle()
    af:SetItemKey(nil); settle()
    assert(not B.bar:IsShown(), "hidden on All Auctions")
end)

test("/ahp while docked moves the view to the window and gives the AH back", function()
    AuctionHouseProfitsAHTab:GetScript("OnClick")(AuctionHouseProfitsAHTab); settle()
    assert(ns.UI.host == "ah")
    ns.UI:ToggleWindow(); settle()
    assert(ns.UI.host == "window" and ns.UI.window:IsShown())
    assert(ah.displayMode == AuctionHouseFrameDisplayMode.Buy, "AH back on Buy")
    assert(ah.Tabs[1].selectedTab == true and AuctionHouseProfitsAHTab.selectedTab == false)
    ns.UI.window:Hide(); settle()
end)

test("shift-clicking an item while the search box has focus selects it", function()
    ns.UI:ToggleWindow(); settle()
    ns.UI.search:SetFocus()
    ChatFrameUtil.InsertLink("|cffffffff|Hitem:3371::::::::60:::::|h[Crystal Vial]|h|r")
    settle()
    assert(ns.UI.selected == 3371 and ns.UI.search:GetText() == "3371")
    ns.UI.search:ClearFocus()
    ChatFrameUtil.InsertLink("|cffffffff|Hitem:2320::::::::60:::::|h[Coarse Thread]|h|r")
    settle()
    assert(ns.UI.selected == 3371, "ignored without focus")
    ns.UI:SetQuery(""); ns.UI.window:Hide(); settle()
end)

test("closing the AH hides the view and marks the AH closed", function()
    AuctionHouseProfitsAHTab:GetScript("OnClick")(AuctionHouseProfitsAHTab); settle()
    ah:Hide()
    W.event("AUCTION_HOUSE_CLOSED")
    settle()
    assert(not ns.UI:IsShown() and not ns.Prices.ahOpen)
    local ok, why = ns.Prices:Scan(14047)
    assert(not ok and why:find("Open the auction house"))
end)

test("open-on-Profits setting", function()
    assert(ns.App:Set("openOnProfitsTab", true))
    W.event("AUCTION_HOUSE_SHOW"); ah:Show(); settle()
    assert(ns.UI.host == "ah" and ns.UI:IsShown())
    ah:Hide(); W.event("AUCTION_HOUSE_CLOSED"); settle()
    assert(ns.App:Set("openOnProfitsTab", false))
end)

-- Vendor sniper -----------------------------------------------------------------
ITEMS[9999] = { "Rusty Sword", "|cffffffff|Hitem:9999::::::::60:::::|h[Rusty Sword]|h|r", 1, 10, 5, "Weapon", "Swords", 1, "", 135274, 300 }
ITEMS[15000] = { "Quest Thing", "|cffffffff|Hitem:15000::::::::60:::::|h[Quest Thing]|h|r", 1, 1, 1, "Quest", "Quest", 1, "", 134400, 0 }
ITEMS[9998] = { "Old Shield", "|cffffffff|Hitem:9998::::::::60:::::|h[Old Shield]|h|r", 1, 10, 5, "Armor", "Shields", 1, "", 134955, 400 }
-- Reports a sell price, but vendors refuse it.
ITEMS[6947] = { "Instant Poison", "|cffffffff|Hitem:6947::::::::60:::::|h[Instant Poison]|h|r", 1, 20, 20, "Consumable", "Consumable", 20, "", 132273, 500 }
cached[15000], cached[9998], cached[6947] = true, true, true -- 9999 loads after the scan has been read
local replicate = {
    { id = 14047, count = 10, buyout = 2000 },               -- 2s a unit, vendor pays 4s: a deal
    { id = 14047, count = 5, buyout = 2500 },                -- 5s a unit: no
    { id = 14047, count = 3, buyout = 300, owner = "Me" },   -- your own auction: never
    { id = 9999, count = 1, buyout = 150 },                  -- vendor pays 3s: a deal
    { id = 9999, count = 1, buyout = 250 },                  -- 50c: under the 1s minimum
    { id = 15000, count = 1, buyout = 1 },                   -- vendors won't buy it
    { id = 6947, count = 20, buyout = 20 },                  -- shows 5s each, but vendors refuse it
    { id = 2320, count = 20, buyout = 20 },                  -- 1c a unit: under the minimum
    { id = 9998, count = 1, buyout = 100 },                  -- vendor pays 4s: sold before we check it
}
-- Enough other auctions that reading takes more than one frame.
for _ = 1, 600 do replicate[#replicate + 1] = { id = 2320, count = 20, buyout = 400 } end
-- Trade goods are commodities; gear isn't.
C_AuctionHouse.GetItemKeyInfo = function(key) return { isCommodity = key.itemID ~= 9999 and key.itemID ~= 9998 } end
local purchases, bids, itemResults = {}, {}, {}
C_AuctionHouse.ReplicateItems = function() replicate.asked = (replicate.asked or 0) + 1 end
C_AuctionHouse.GetNumReplicateItems = function() return #replicate end
C_AuctionHouse.GetReplicateItemInfo = function(i)
    local r = replicate[i + 1]
    if not r then return end
    return nil, nil, r.count, 1, true, 1, nil, 0, 0, r.buyout, 0, nil, nil, r.owner, nil, 0, r.id, true
end
C_AuctionHouse.StartCommoditiesPurchase = function(id, qty) purchases[#purchases + 1] = { start = id, qty = qty } end
C_AuctionHouse.ConfirmCommoditiesPurchase = function(id, qty) purchases[#purchases + 1] = { confirm = id, qty = qty } end
C_AuctionHouse.CancelCommoditiesPurchase = function() purchases[#purchases + 1] = { cancel = true } end
C_AuctionHouse.PlaceBid = function(auctionID, amount) bids[#bids + 1] = { auctionID = auctionID, amount = amount } end
C_AuctionHouse.GetNumItemSearchResults = function(key) return itemResults[key.itemID] and #itemResults[key.itemID] or 0 end
C_AuctionHouse.GetItemSearchResultInfo = function(key, i) return itemResults[key.itemID][i] end
C_Container.GetContainerNumFreeSlots = function(bag) return bag == 0 and 12 or 0 end
local runecloth = commodity[14047]
local cheapBook = {
    { unitPrice = 200, quantity = 6, numOwnerItems = 0, totalNumberOfOwners = 1, owners = { "Ann" } },
    { unitPrice = 290, quantity = 4, numOwnerItems = 0, totalNumberOfOwners = 1, owners = { "Cy" } },
    { unitPrice = 350, quantity = 3, numOwnerItems = 0, totalNumberOfOwners = 1, owners = { "Di" } }, -- only 50c a unit
    { unitPrice = 2100, quantity = 40, numOwnerItems = 0, totalNumberOfOwners = 1, owners = { "Bob" } },
}
local SN, SV = ns.Snipe, ns.SnipePanel
local function press(mouse) SV.buyButton:GetScript("OnClick")(SV.buyButton, mouse or "LeftButton"); settle() end

test("the sniper sits beside the auction house and shows when it opens", function()
    assert(SV.attached and AuctionHouseProfitsSniper and AuctionHouseProfitsSnipeBuyButton, "built with the AH")
    assert(SV.frame:GetParent() == ah)
    W.event("AUCTION_HOUSE_SHOW"); ah:Show()
    SV.frame:Hide(); SV.frame:Show() -- in game OnShow fires as the AH opens
    settle()
    assert(SV:IsShown() and SV.scope, "background work runs while visible")
    assert(SV.scanButton:GetText() == "Full scan" and SV.buyButton:GetText() == "No deals")
    assert(not SV.buyButton:IsEnabled())
    assert(SV.minimum.boxes[2]:GetText() == "1" and SV.minimum.boxes[3]:GetText() == "0", "1 silver by default")
    assert(SV.bags:GetText():find("12 free slots"))
    assert(type(AuctionHouseProfits_SnipeBuy) == "function" and BINDING_NAME_AUCTIONHOUSEPROFITS_SNIPE_BUY)
    local xml = io.open("AuctionHouseProfits/Bindings.xml"):read("*a")
    assert(xml:find("AUCTIONHOUSEPROFITS_SNIPE_BUY") and xml:find("AuctionHouseProfits_SnipeBuy%(%)"), "key binding declared")
end)

test("a full scan lists deals as it's read, checking the best gear first", function()
    local chat = #DEFAULT_CHAT_FRAME.lines
    SV.scanButton:GetScript("OnClick")(SV.scanButton); settle()
    assert(replicate.asked == 1 and SN.full and SV.scanButton:GetText() == "Scanning...")
    W.event("REPLICATE_ITEM_LIST_UPDATE")
    -- The first 500 auctions are read; the shield is checked before the rest.
    assert(SN.full and SN.full.stage == "reading" and SN.checking == 9998 and searches[#searches] == 9998,
        "gear deals are checked while the scan is still being read")
    itemResults[9998] = {} -- someone bought it
    W.event("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 9998 })
    local said = DEFAULT_CHAT_FRAME.lines[chat + 1]
    assert(said and said:find("Old Shield was gone when checked") and said:find("scan saw C100 each")
        and said:find("none are listed now"), said)
    settle()
    assert(not SN.full and SN.snapshot.total == #replicate, "listed without waiting for vendor prices")
    assert(not SN.byID[9998], "a check during the read outranks the scan")
    local cloth = SN.byID[14047]
    assert(cloth.direct and not cloth.verified and cloth.qty == 10 and cloth.cost == 2000 and cloth.profit == 2000)
    assert(cloth.stack == 20 and cloth.perSlot == 2000, "10 Runecloth fill one slot")
    assert(not SN.byID[9999], "the sword's vendor price hasn't loaded")
    cached[9999] = true
    W.event("GET_ITEM_INFO_RECEIVED", 9999, true); settle()
    local sword = SN.byID[9999]
    assert(sword and sword.qty == 1 and sword.profit == 150 and not sword.direct, "joins when its price loads")
    assert(not SN.byID[15000] and not SN.byID[2320], "unsellable and too-thin skipped")
    assert(not SN.byID[6947] and SN.Item(6947).sell == false, "a sell price vendors refuse isn't a deal")
    assert(#SN:Deals() == 2)
    assert(SV.scanButton:GetText() == "Recheck" and SV.status:GetText():find("full scan in"), SV.status:GetText())
    assert(#SV.listBox.rows == 2 and SV.listBox.rows[1].data.id == 14047, "what one press can buy comes first")
    assert(SV.listBox.rows[1].profit:GetText():find("~"), "scan prices are marked")
end)

test("trade goods are bought straight from the scan; gear is checked first", function()
    assert(SN.checking == 9999 and searches[#searches] == 9999, "gear is searched for its auction IDs")
    local n14047 = 0
    for _, id in ipairs(searches) do if id == 14047 then n14047 = n14047 + 1 end end
    -- The press needs no search: the server quotes the price before we confirm.
    assert(SV.buyButton:GetText() == "Buy 10 for ~C2000", "the button says what one press buys: " .. SV.buyButton:GetText())
    assert(SV.nextName:GetText():find("Next:") and SV.nextName:GetText():find("Runecloth"))
    local detail = SV.nextDetail:GetText()
    assert(detail:find("10 at up to C200 each") and detail:find("vendor pays |rC4000") and detail:find("%+C2000"), detail)
    itemResults[9999] = {
        { auctionID = 71, quantity = 1, buyoutAmount = 150, containsOwnerItem = false },
        { auctionID = 72, quantity = 1, buyoutAmount = 120, containsOwnerItem = false },
        { auctionID = 73, quantity = 1, buyoutAmount = 290, containsOwnerItem = false },
    }
    W.event("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 9999 }); settle()
    local sword = SN.byID[9999]
    assert(sword.verified and sword.kind == "item" and #sword.buy.auctions == 2 and sword.buy.auctions[1].auctionID == 72)
    local m = 0
    for _, id in ipairs(searches) do if id == 14047 then m = m + 1 end end
    assert(m == n14047, "the trade good wasn't searched")
    local lines = {}
    local add = GameTooltip.AddLine
    GameTooltip.AddLine = function(_, text) lines[#lines + 1] = text end
    SV.buyButton:GetScript("OnEnter")(SV.buyButton)
    GameTooltip.AddLine = add
    local said = table.concat(lines, "\n")
    assert(lines[1]:find("^Buy 10 .*Runecloth.* for C2000$"), lines[1])
    assert(said:find("A vendor pays C4000") and said:find("10 cheapest, each C200 or less"), said)
    assert(said:find("over C3000") and said:find("cancelled") and said:find("Straight from the full scan"), said)
    assert(said:find("Nothing else in the list is bought"), said)
    -- Hovering the next deal shows the item's own tooltip, which other
    -- add-ons add their prices to, and this add-on's vendor price.
    local shown, extra = nil, {}
    local setItem = GameTooltip.SetItemByID
    GameTooltip.SetItemByID = function(_, id) shown = id end
    GameTooltip.AddLine = function(_, text) extra[#extra + 1] = text end
    SV.nextItem:GetScript("OnEnter")(SV.nextItem)
    GameTooltip.AddLine, GameTooltip.SetItemByID = add, setItem
    assert(shown == 14047, "the item tooltip")
    assert(#extra == 1 and extra[1]:find("vendor pays C400 each, C4000 for these 10"), extra[1])
end)

test("one press buys every profitable unit of a trade good, confirmed at the server's price", function()
    commodity[14047] = cheapBook -- what's really listed by now
    local chat = #DEFAULT_CHAT_FRAME.lines
    press()
    assert(purchases[#purchases].start == 14047 and purchases[#purchases].qty == 10)
    assert(SN:IsBusy() and SV.buyButton:GetText() == "Buying..." and not SV.buyButton:IsEnabled())
    press() -- a second press while waiting buys nothing
    assert(#purchases == 1)
    W.event("COMMODITY_PRICE_UPDATED", 236, 2360); settle()
    assert(purchases[2].confirm == 14047 and purchases[2].qty == 10, "confirmed without another press")
    commodity[14047] = { cheapBook[3], cheapBook[4] } -- the cheap units are gone
    W.event("COMMODITY_PURCHASE_SUCCEEDED"); settle()
    assert(not SN:IsBusy() and SN.session.units == 10 and SN.session.spent == 2360 and SN.session.value == 4000)
    assert(SV.session:GetText():find("10 bought"))
    assert(not SN.byID[14047] or not (SN.byID[14047].verified or SN.byID[14047].direct), "re-read before buying more")
    if SN.checking ~= 14047 then settle() end
    W.event("COMMODITY_SEARCH_RESULTS_UPDATED", 14047); settle()
    assert(not SN.byID[14047], "nothing left under vendor price")
    assert(#DEFAULT_CHAT_FRAME.lines == chat, "not reported as gone: we bought it")
end)

test("one press buys one auction, the most profitable first", function()
    assert(SN:Head().id == 9999)
    assert(searches[#searches] == 9999, "the top gear deal's search is kept the latest")
    W.event("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 9999 }); settle()
    press()
    assert(bids[1].auctionID == 72 and bids[1].amount == 120)
    W.event("AUCTION_HOUSE_PURCHASE_COMPLETED", 72); settle()
    assert(SN.session.buys == 2 and SN.byID[9999].verified and #SN.byID[9999].buy.auctions == 1)
    press()
    assert(bids[2].auctionID == 71)
    W.event("AUCTION_HOUSE_SHOW_ERROR", 1); settle() -- someone else got it
    assert(not SN:IsBusy() and SN.session.buys == 2, "a failed buy costs nothing")
    assert(not SN.byID[9999].verified, "checks the listings again")
    itemResults[9999] = {}
    W.event("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 9999 }); settle()
    assert(#SN:Deals() == 0 and SV.buyButton:GetText() == "No deals")
end)

test("grouped gear auctions: one press buys one, at the row's price each", function()
    -- Blizzard's buy list groups identical auctions; buyoutAmount is each one's price.
    itemResults[9999] = {
        { auctionID = 81, quantity = 2, buyoutAmount = 280, containsOwnerItem = false }, -- 20c each
        { auctionID = 82, quantity = 32, buyoutAmount = 299, containsOwnerItem = false }, -- 1c each: under 1s
    }
    ns.App:Set("snipeMinProfit", 1); settle()
    W.event("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 9999 }); settle()
    local sword = SN.byID[9999]
    assert(sword.verified and sword.qty == 34 and sword.profit == 2 * 20 + 32 * 1, "at 1c both rows count, per auction")
    ns.App:Set("snipeMinProfit", 100); settle()
    W.event("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 9999 }); settle()
    assert(not SN.byID[9999], "at 1s minimum neither row is a deal")
    ns.App:Set("snipeMinProfit", 20); settle()
    W.event("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 9999 }); settle()
    sword = SN.byID[9999]
    assert(sword.qty == 2 and sword.cost == 560 and sword.profit == 40, "only the 2s 80c row")
    SN:Focus(9999); settle() -- Runecloth at 3s 50c clears 20c too; buy the sword next
    assert(SV.nextDetail:GetText():find("1 auction at C280") and SV.buyButton:GetText() == "Buy 1 for C280", SV.nextDetail:GetText())
    local lines = {}
    local add = GameTooltip.AddLine
    GameTooltip.AddLine = function(_, text) lines[#lines + 1] = text end
    SV.buyButton:GetScript("OnEnter")(SV.buyButton)
    GameTooltip.AddLine = add
    local said = table.concat(lines, "\n")
    assert(said:find("One auction only%. 1 more after this, one per press%."), said)
    local before = #bids
    press()
    assert(bids[before + 1].auctionID == 81 and bids[before + 1].amount == 280, "pays one auction's price")
    W.event("AUCTION_HOUSE_PURCHASE_COMPLETED", 81); settle()
    assert(SN.session.units == 12 and SN.session.spent == 2360 + 120 + 280 and SN.session.value == 4000 + 300 + 300)
    assert(SN.byID[9999].qty == 1, "one left in the row")
    itemResults[9999] = {}
    W.event("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 9999 }); settle()
    ns.App:Set("snipeMinProfit", 100); settle()
end)

test("a trade good whose price rose is cancelled, not bought", function()
    commodity[14047] = cheapBook
    W.event("COMMODITY_SEARCH_RESULTS_UPDATED", 14047); settle() -- e.g. you searched it on the Buy page
    assert(SN.byID[14047] and SN.byID[14047].verified, "any search can turn up a deal")
    local before = #purchases
    press()
    -- The limit is 10 x (4s vendor - 1s minimum) = 30s: exactly that still goes through.
    W.event("COMMODITY_PRICE_UPDATED", 300, 3000); settle()
    assert(purchases[before + 2].confirm == 14047)
    W.event("COMMODITY_PURCHASE_FAILED"); settle()
    assert(not SN:IsBusy() and SN.session.buys == 3)
    W.event("COMMODITY_SEARCH_RESULTS_UPDATED", 14047); settle()
    before = #purchases
    press()
    W.event("COMMODITY_PRICE_UPDATED", 301, 3010); settle()
    assert(purchases[before + 2].cancel and not purchases[before + 3], "over the limit: cancelled")
    assert(not SN:IsBusy())
end)

test("a scan price that's gone is cancelled, and the next press waits for a check", function()
    SN.live[14047], SN.tried[14047] = nil, nil -- as if fresh from a full scan
    SN:Evaluate(14047); settle()
    assert(SN.byID[14047].direct and SV.buyButton:GetText() == "Buy 10 for ~C2000", SV.buyButton:GetText())
    local before = #purchases
    press()
    W.event("COMMODITY_PRICE_UPDATED", 2100, 21000); settle() -- the cheap ones are long gone
    assert(purchases[before + 1].start == 14047 and purchases[before + 2].cancel and not purchases[before + 3])
    local d = SN.byID[14047]
    assert(d and not d.direct and not d.verified and SV.buyButton:GetText() == "Checking listings...")
    if SN.checking ~= 14047 then settle() end
    assert(SN.checking == 14047, "checked straight away")
    W.event("COMMODITY_SEARCH_RESULTS_UPDATED", 14047); settle()
    assert(SN.byID[14047].verified)
end)

test("min profit in gold, silver and copper, per unit or per purchase", function()
    W.event("COMMODITY_SEARCH_RESULTS_UPDATED", 14047); settle()
    local boxes = SV.minimum.boxes
    boxes[2]:SetText("2"); boxes[3]:SetText("")
    boxes[2]:GetScript("OnEnterPressed")(boxes[2]); settle()
    assert(ns.App:Get("snipeMinProfit") == 200)
    assert(SN.byID[14047].buy.qty == 6, "only the 2s units make 2s each")
    boxes[1]:SetText(""); boxes[2]:SetText("15"); boxes[3]:SetText("")
    boxes[2]:GetScript("OnEnterPressed")(boxes[2]); settle()
    assert(not SN.byID[14047], "nothing makes 15s a unit")
    SV.basis:GetScript("OnClick")(SV.basis); settle()
    assert(ns.App:Get("snipeBasis") == "buy" and SV.basis:GetText() == "per buy")
    local cloth = SN.byID[14047]
    assert(cloth and cloth.buy.qty == 13 and cloth.buy.cost == 3410 and cloth.profit == 13 * 400 - 3410,
        "per purchase: every unit under 4s, as long as the whole buy makes 15s")
    SV.basis:GetScript("OnClick")(SV.basis)
    assert(ns.App:Set("snipeMinProfit", 100)); settle()
end)

test("right-click skips a deal until the next full scan", function()
    assert(SN:Head().id == 14047)
    press("RightButton")
    assert(not SN:Head() and #purchases > 0 and SN.skipped[14047])
    W.event("COMMODITY_SEARCH_RESULTS_UPDATED", 14047); settle()
    assert(not SN.byID[14047], "stays skipped")
end)

test("between full scans, Recheck searches items that had deals", function()
    local ok, why = SN:FullScan()
    assert(not ok and why:find("next full scan"), "the game allows one every 15 minutes")
    local before = #searches
    AuctionHouseProfitsData.watch[6947] = time() + 1 -- watched by an older version
    SV.scanButton:GetScript("OnClick")(SV.scanButton); settle()
    for _, id in ipairs(ns.Prices.queue.ids) do assert(id ~= 6947, "items vendors refuse aren't rechecked") end
    assert(ns.Prices:QueueProgress(), "rechecking")
    assert(SV.scanButton:GetText():find("^Stop"))
    SV.scanButton:GetScript("OnClick")(SV.scanButton); settle()
    assert(not ns.Prices:QueueProgress())
    assert(#searches > before and searches[before + 1] ~= 14047, "skipped items aren't rechecked")
    assert(AuctionHouseProfitsData.watch[14047] and AuctionHouseProfitsData.watch[9999], "watch list saved")
    assert(AuctionHouseProfitsData.fullScan, "full-scan time saved: the limit is account-wide")
end)

test("/ahp snipe and the Sniper button show and hide it", function()
    local handler
    for key, fn in pairs(SlashCmdList) do if key:upper():find("AUCTIONHOUSEPROFITS") then handler = handler or fn end end
    handler("snipe"); settle()
    assert(not SV.frame:IsShown() and ns.App:Get("snipeShow") == false and not SV.scope, "hidden, background work stopped")
    ns.UI:ToggleWindow(); settle()
    ns.UI.sniperButton:GetScript("OnClick")(ns.UI.sniperButton); settle()
    assert(SV.frame:IsShown() and ns.App:Get("snipeShow") == true)
    ns.UI:ToggleWindow(); settle()
    commodity[14047] = runecloth
    ah:Hide(); W.event("AUCTION_HOUSE_CLOSED"); settle()
    assert(not SV:IsShown())
    assert(SV.frame:IsShown(), "comes back next time the AH opens")
end)

test("what the addon made you is kept for good, by day", function()
    local D, E = ns.Data, ns.Earnings
    local now = time()
    local today = AuctionHouseProfitsData.ledger[D.DayKey(now)]
    local s = SN.session
    assert(today.s.n == s.buys and today.s.units == s.units and today.s.spent == s.spent and today.s.value == s.value,
        "every sniper buy is recorded")
    local all = E.Periods(now)[4].sum
    assert(all.profit == (s.value - s.spent) + 7215 and all.snipe == s.value - s.spent and all.sales == 7215)
    -- An older day counts in all but not today.
    AuctionHouseProfitsData.ledger[D.DayKey(now - 10 * 86400)] = { s = { n = 1, units = 3, spent = 100, value = 400 } }
    local p = E.Periods(now)
    assert(p[1].sum.profit == all.profit and p[2].sum.profit == all.profit, "today and this week")
    assert(p[3].sum.profit == all.profit + 300 and p[4].sum.profit == all.profit + 300, "30 days and in all")
    -- Shown in the sniper panel and on the Profits tab, with a tooltip.
    ah:Show(); W.event("AUCTION_HOUSE_SHOW"); settle()
    SV:Refresh()
    assert(SV.made.text:GetText():find("Made") and SV.made.text:GetText():find("in all"), SV.made.text:GetText())
    local lines = {}
    local add, add2 = GameTooltip.AddLine, GameTooltip.AddDoubleLine
    GameTooltip.AddLine = function(_, text) lines[#lines + 1] = text end
    GameTooltip.AddDoubleLine = function(_, a, b) lines[#lines + 1] = a .. " = " .. b end
    SV.made:GetScript("OnEnter")(SV.made)
    GameTooltip.AddLine, GameTooltip.AddDoubleLine = add, add2
    local text = table.concat(lines, "\n")
    assert(text:find("Made by Auction House Profits") and text:find("Today = ") and text:find("In all = "))
    assert(text:find("Vendor sniper: " .. (s.buys + 1) .. " buys") and text:find("Auction sales: 1 sale with a known cost"), text)
    assert(text:find("Last 7 days"), text)
    -- /ahp made prints it to chat.
    local handler
    for key, fn in pairs(SlashCmdList) do if key:upper():find("AUCTIONHOUSEPROFITS") then handler = handler or fn end end
    local before = #DEFAULT_CHAT_FRAME.lines
    handler("made")
    assert(DEFAULT_CHAT_FRAME.lines[before + 1]:find("Made today"), DEFAULT_CHAT_FRAME.lines[before + 1])
    assert(#DEFAULT_CHAT_FRAME.lines >= before + 4)
    AuctionHouseProfitsData.ledger[D.DayKey(now - 10 * 86400)] = nil
end)

test("the ledger starts from sales already on record, and survives a reload", function()
    local D, saved = ns.Data, AuctionHouseProfitsData
    local now = time()
    AuctionHouseProfitsData = { version = 2, items = {}, sales = {
        [1] = { id = 2320, qty = 10, gross = 1000, time = now - 3 * 86400, unitCost = 50, cutRate = 0.05 },
        [2] = { id = 2321, qty = 1, gross = 500, time = now - 86400 }, -- no known cost
    } }
    assert(D:Load(now))
    local sum = ns.Earnings.Periods(now)[4].sum
    assert(sum.a.n == 2 and sum.a.costed == 1 and sum.sales == 1000 - 50 - 500, "seeded from the sales on record")
    assert(D:LedgerSince() == now - 3 * 86400)
    AuctionHouseProfitsData.ledger["junk"] = 5
    AuctionHouseProfitsData.ledger[D.DayKey(now)] = { s = { n = "x", units = 1, spent = 10, value = 30 } }
    assert(D:Load(now))
    assert(AuctionHouseProfitsData.ledger.junk == nil, "bad days dropped")
    assert(ns.Earnings.Periods(now)[4].sum.a.n == 2, "not seeded twice")
    assert(ns.Earnings.Periods(now)[1].sum.snipe == 20)
    AuctionHouseProfitsData = saved
    assert(D:Load(now))
end)

test("deals rank by what one item makes, not by the total", function()
    local saved, focus = SN.deals, SN.focus
    SN.focus = nil
    local stack = { id = 1, verified = true, qty = 32, profit = 64, each = 2 }   -- 32 auctions at +2c
    local single = { id = 2, verified = true, qty = 1, profit = 50, each = 50 }  -- one at +50c
    local estimate = { id = 3, verified = false, qty = 1, profit = 900, each = 900 }
    SN.deals = { stack, estimate, single }
    SN:Sort()
    assert(SN.deals[1] == single and SN.deals[2] == stack and SN.deals[3] == estimate,
        "the best single purchase first; estimates after checked deals until checked")
    SN.deals, SN.focus = saved, focus
end)

test("sort by profit per bag slot puts stackable deals first", function()
    local saved, focus = SN.deals, SN.focus
    SN.focus = nil
    -- 20 Runecloth at +5c fill one slot (+1s a slot); a +10c sword fills one slot each.
    local cloth = { id = 1, verified = true, qty = 20, profit = 100, each = 5, stack = 20, perSlot = ns.Model.PerSlot(100, 20, 5, 20) }
    local sword = { id = 2, verified = true, qty = 3, profit = 30, each = 10, stack = 1, perSlot = ns.Model.PerSlot(30, 3, 10, 1) }
    assert(cloth.perSlot == 100 and sword.perSlot == 10)
    SN.deals = { cloth, sword }
    SN:Sort()
    assert(SN.deals[1] == sword, "per item by default")
    SV.sortButton:GetScript("OnClick")(SV.sortButton); settle()
    assert(ns.App:Get("snipeSort") == "slot" and SV.sortButton:GetText() == "Sort: per slot")
    assert(SN:Deals()[1] == cloth, "per bag slot: the stack first")
    SV:Refresh()
    assert(SV.listBox.rows[1].profit:GetText():find("C100") and SV.listBox.rows[1].profit:GetText():find("a slot"),
        SV.listBox.rows[1].profit:GetText())
    SV.sortButton:GetScript("OnClick")(SV.sortButton); settle()
    assert(ns.App:Get("snipeSort") == "item" and SN:Deals()[1] == sword)
    SN.deals, SN.focus = saved, focus
    SN:Sort()
end)

test("Buy under your price: one press buys a share of the units at or under it you can afford", function()
    W.event("AUCTION_HOUSE_SHOW"); ah:Show(); settle()
    AuctionHouseProfitsAHTab:GetScript("OnClick")(AuctionHouseProfitsAHTab); settle()
    local U = ns.UI
    assert(U:IsShown() and U.host == "ah")
    U:Select(9999); settle()
    SN:SetLimit(9999, 200); settle()
    assert(U.buyButton.label:GetText() == "Trade goods only" and not U.buyButton:IsEnabled())
    U:Select(14047); settle()
    assert(U.buyButton.label:GetText() == "Set a price" and not U.buyButton:IsEnabled())
    commodity[14047] = {
        { unitPrice = 300, quantity = 25, numOwnerItems = 0, totalNumberOfOwners = 1, owners = { "Ann" } },
        { unitPrice = 350, quantity = 30, numOwnerItems = 5, totalNumberOfOwners = 2, owners = { "Cy" } }, -- 5 are yours
        { unitPrice = 351, quantity = 50, numOwnerItems = 0, totalNumberOfOwners = 1, owners = { "Bob" } }, -- 1c over
    }
    local boxes = U.limitInput.boxes
    boxes[2]:SetText("3"); boxes[3]:SetText("50")
    boxes[3]:GetScript("OnEnterPressed")(boxes[3]); settle()
    assert(SN:Limit(14047) == 350, "3s 50c each")
    U.scanButton:GetScript("OnClick")(U.scanButton); settle()
    W.event("COMMODITY_SEARCH_RESULTS_UPDATED", 14047); settle()
    local saved, before, units = wallet, #purchases, SN.session.units
    assert(U.buyButton.label:GetText() == "Buy 25 for C7500", "half of the 50 at your price: " .. U.buyButton.label:GetText())
    wallet = 12000 -- 25 at 3s, then 12 more at 3s 50c: 37, so 19
    W.event("PLAYER_MONEY"); settle()
    assert(U.buyButton.label:GetText() == "Buy 19 for C5700" and U.buyButton:IsEnabled(), U.buyButton.label:GetText())
    U.buyButton:GetScript("OnClick")(U.buyButton); settle()
    assert(#purchases == before + 1 and purchases[#purchases].start == 14047 and purchases[#purchases].qty == 19,
        "one press, no quantity to pick")
    assert(U.buyButton.label:GetText() == "Buying..." and not U.buyButton:IsEnabled())
    W.event("COMMODITY_PRICE_UPDATED", 300, 5700); settle()
    assert(purchases[#purchases].confirm == 14047 and purchases[#purchases].qty == 19, "confirmed at the quoted total")
    -- Some went before the confirm reached the server: it quotes again rather than charging more.
    W.event("COMMODITY_PRICE_UPDATED", 310, 5900); settle()
    assert(#purchases == before + 3 and purchases[#purchases].confirm == 14047, "still under 19 x 3s 50c: confirmed again")
    commodity[14047] = { { unitPrice = 360, quantity = 50, numOwnerItems = 0, totalNumberOfOwners = 1, owners = { "Bob" } } }
    local scans = #searches
    W.event("COMMODITY_PURCHASE_SUCCEEDED"); W.tick(0.1)
    assert(not SN:IsBusy() and #searches == scans, "the next press gets the AH first, not a search")
    assert(SN.session.units == units, "not counted as a vendor flip")
    -- Until the search answers, the next press goes from what's left: 6 at 3s and 25 at 3s 50c, so 16.
    assert(U.buyButton.label:GetText() == "Buy 16 for ~C5300" and U.buyButton:IsEnabled(), U.buyButton.label:GetText())
    settle(); settle()
    assert(#searches == scans + 1 and searches[#searches] == 14047, "listings re-read once you pause")
    W.event("COMMODITY_SEARCH_RESULTS_UPDATED", 14047); settle()
    assert(U.buyButton.label:GetText() == "None that cheap" and not U.buyButton:IsEnabled())
    -- Someone bought the cheap units first: the server's total is over your price, so it's cancelled,
    -- and the next press asks for fewer, without waiting for the search.
    wallet = saved
    commodity[14047] = { { unitPrice = 340, quantity = 10, numOwnerItems = 0, totalNumberOfOwners = 1, owners = { "Di" } } }
    U.scanButton:GetScript("OnClick")(U.scanButton); settle()
    W.event("COMMODITY_SEARCH_RESULTS_UPDATED", 14047); settle()
    assert(U.buyButton.label:GetText() == "Buy 5 for C1700", "half of 10: " .. U.buyButton.label:GetText())
    U.buyButton:GetScript("OnClick")(U.buyButton); settle()
    assert(purchases[#purchases].start == 14047 and purchases[#purchases].qty == 5)
    scans = #searches
    W.event("COMMODITY_PRICE_UPDATED", 360, 1800); settle()
    assert(purchases[#purchases].cancel and not SN:IsBusy(), "over 5 x 3s 50c: cancelled")
    assert(UIErrorsFrame.lines[#UIErrorsFrame.lines]:find("^Someone was quicker"), UIErrorsFrame.lines[#UIErrorsFrame.lines])
    assert(U.buyButton.label:GetText() == "Buy 3 for ~C1020" and U.buyButton:IsEnabled(), U.buyButton.label:GetText())
    U.buyButton:GetScript("OnClick")(U.buyButton); settle()
    assert(purchases[#purchases].start == 14047 and purchases[#purchases].qty == 3, "tried again at once, for fewer")
    settle(); settle()
    assert(#searches == scans, "no search mid-purchase")
    W.event("COMMODITY_PRICE_UPDATED", 340, 1020); settle()
    W.event("COMMODITY_PURCHASE_SUCCEEDED"); W.tick(0.1)
    assert((SN.misses[14047] or 0) == 0, "a buy that goes through resets the misses")
    assert(U.buyButton.label:GetText() == "Buy 5 for ~C1700", U.buyButton.label:GetText())
    -- Re-quoted over your price after the confirm: cancelled.
    U.buyButton:GetScript("OnClick")(U.buyButton); settle()
    W.event("COMMODITY_PRICE_UPDATED", 340, 1700); settle()
    W.event("COMMODITY_PRICE_UPDATED", 400, 2000); settle()
    assert(purchases[#purchases].cancel and not SN:IsBusy() and SN.misses[14047] == 1)
    settle(); settle()
    assert(#searches == scans + 1 and searches[#searches] == 14047, "read again once you pause")
    SN:SetLimit(14047, nil); SN:SetLimit(9999, nil)
    W.event("AUCTION_HOUSE_CLOSED"); ah:Hide(); settle()
end)

test("settings changes redraw an open view", function()
    ns.UI:ToggleWindow(); settle()
    ns.UI:Select(2320); settle()
    local before = ns.UI.current.faction.profit
    assert(ns.App:Set("cutFaction", 20)); settle()
    assert(ns.UI.current.faction.profit < before, "higher cut lowers profit")
    assert(ns.App:Set("cutFaction", 5)); settle()
    ns.UI:ToggleWindow(); settle()
    assert(not ns.UI:IsShown())
end)

test("options panel opens", function()
    local ok, err = ns.Options:Open("reputation")
    assert(ok, err and err.message)
    settle()
    ns.Options:Close()
end)

test("no errors were reported", function()
    assert(#W.errors == 0, W.errors[1])
end)

local names = {}
for k in pairs(unknown) do names[#names + 1] = k end
table.sort(names)
print(total .. " runtime tests passed")
print("Native methods not modelled by the mock (verify in game): " .. table.concat(names, ", "))
