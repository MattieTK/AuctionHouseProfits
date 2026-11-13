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

local BAG = { [1] = { itemID = 14047 } }
C_Container = {
    GetContainerNumSlots = function(bag) return bag == 0 and 4 or 0 end,
    GetContainerItemInfo = function(bag, slot) return bag == 0 and BAG[slot] or nil end,
}
local loaded = {}
C_AddOns = { IsAddOnLoaded = function(name) return loaded[name] == true end }

local searches = {}
local commodity = { [14047] = { { unitPrice = 2100, quantity = 40 } } }
Enum = { AuctionHouseSortOrder = { Price = 0 } }
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

test("addon becomes ready and creates its data store", function()
    W.event("ADDON_LOADED", ADDON)
    settle()
    assert(ns.App:IsReady())
    assert(type(AuctionHouseProfitsData) == "table" and AuctionHouseProfitsData.version == 1)
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

test("analysis prices an item from vendor cost and Auctionator", function()
    local a = ns.Analysis.Item(ns.App, 2320, os.time())
    assert(math.abs(a.baseUnit - 7 / 0.9) < 1e-9, "list price recovered from honored price")
    assert(a.standing == 6 and math.abs(a.unitCost - 7) < 1e-9)
    assert(a.market and a.market.source == "auctionator" and a.market.price == 25)
    assert(a.faction and a.neutral and a.ladder and #a.byStanding == 5)
    assert(a.byStanding[1].unitCost > a.byStanding[3].unitCost, "neutral standing pays more")
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
    assert(#W.errors == 0, W.errors[1])
end)

test("editing the plan and manual price republishes", function()
    local box = ns.UI.inputs.stackSize
    box:SetText("10")
    box:GetScript("OnEnterPressed")(box)
    settle()
    assert(ns.UI.current.stackSize == 10)
    local manual = ns.UI.inputs.manual
    manual:SetText("30c")
    manual:GetScript("OnEnterPressed")(manual)
    settle()
    assert(ns.UI.current.market.source == "manual" and ns.UI.current.market.price == 30)
    -- ladder click sets the manual price
    local first = ns.UI.ladder[1].button
    local clicked = first.price -- the ladder re-centres on the new price after the click
    first:GetScript("OnClick")(first)
    settle()
    assert(ns.Data:Manual(2320) == clicked and clicked == 45)
    manual:SetText("")
    manual:GetScript("OnEnterPressed")(manual)
    settle()
    assert(ns.Data:Manual(2320) == nil and ns.UI.current.market.source == "auctionator")
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
    ah:Hide()
    loaded.Blizzard_AuctionHouseUI = true
    W.event("ADDON_LOADED", "Blizzard_AuctionHouseUI")
    settle()
    assert(ns.AuctionTab.attached and AuctionHouseProfitsAHTab)
    assert(#ah.Tabs == 3, "Blizzard Tabs array untouched")
    assert(AuctionHouseProfitsAHTab:GetParent() ~= ah, "tab lives in our holder")
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
end)

test("selecting an item auto-scans the AH and uses the game deposit", function()
    ns.UI:Select(14047)
    settle()
    assert(searches[#searches] == 14047, "search query sent")
    W.event("COMMODITY_SEARCH_RESULTS_UPDATED", 14047)
    settle()
    local scan = ns.Data:Scan(14047)
    assert(scan and scan.price == 2100 and scan.qty == 40)
    local a = ns.UI.current
    assert(a.market.source == "scan" and a.market.price == 2100)
    assert(a.gameDepositVenue and a.deposit[a.gameDepositVenue] == 1234)
    assert(ns.UI.scanButton.label:GetText() == "Scan AH")
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
