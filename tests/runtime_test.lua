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

test("reputation defaults step up by standing", function()
    local rules = ns.Rules(ns.App)
    assert(rules.discounts[5] == 5 and rules.discounts[6] == 10 and rules.discounts[7] == 15 and rules.discounts[8] == 20)
end)

test("analysis prices an item from vendor cost and Auctionator", function()
    local a = ns.Analysis.Item(ns.App, 2320, os.time())
    assert(math.abs(a.baseUnit - 7 / 0.9) < 1e-9, "list price recovered from honored price")
    assert(a.standing == 6 and math.abs(a.unitCost - 7) < 1e-9)
    assert(a.market and a.market.source == "auctionator" and a.market.price == 25)
    assert(a.price == 25 and a.priceKind == "market", "no listings seen: price at market")
    assert(a.duration == 1, "duration from the AH Sell page's own setting")
    assert(a.paidUnit == 7)
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
    assert(ns.UI.inputs.standing.Text:GetText() == "Honored")
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
    assert(ns.UI.tableHeads[1]:GetText() == "List at", "live market table shown once listings are known")
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
