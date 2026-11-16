-- The vendor sniper panel, beside the auction house. One Buy button that
-- stays put: each press buys the deal at the top of the list, so you can
-- work through every deal without moving the mouse. Right-click it to skip.
-- The same actions are key bindings (Key Bindings > AddOns).
local ADDON, ns = ...
local M, P, N, U = ns.Model, ns.Prices, ns.Snipe, ns.UI
local V = { attached = false }
ns.SnipePanel = V

local GOOD, BAD, MUTED = "ff4cc24c", "ffee7a7a", "ff9d9a8f"
local WIDTH, ROW_H = 320, 20
local function color(hex, s) return "|c" .. hex .. s .. "|r" end
local function count(n) return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n) end

BINDING_HEADER_AUCTIONHOUSEPROFITS = "Auction House Profits"
BINDING_NAME_AUCTIONHOUSEPROFITS_SNIPE_BUY = "Vendor sniper: buy the next deal"
BINDING_NAME_AUCTIONHOUSEPROFITS_SNIPE_SKIP = "Vendor sniper: skip the next deal"
function AuctionHouseProfits_SnipeBuy() V:Buy() end
function AuctionHouseProfits_SnipeSkip() V:Skip() end

local function tip(frame, fn)
    frame:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        fn(GameTooltip, self)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
end

local function label(parent, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function blizzButton(parent, name, text, w, h)
    local b = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h or 22)
    b:SetText(text)
    return b
end

local function freeSlots()
    if not C_Container or not C_Container.GetContainerNumFreeSlots then return nil end
    local free = 0
    for bag = 0, NUM_BAG_SLOTS or 4 do
        local n = C_Container.GetContainerNumFreeSlots(bag)
        if M.Number(n) then free = free + n end
    end
    return free
end

local function itemName(d)
    local hex = d.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[d.quality] and ITEM_QUALITY_COLORS[d.quality].hex
    local name = d.name or ("item:" .. d.id)
    return hex and (hex .. name .. "|r") or name
end

-- What one press buys from a checked deal: units, cost, profit.
local function press(d)
    if not d or not d.verified or not d.buy then return nil end
    if d.kind == "item" then
        local a = d.buy.auctions[1]
        return 1, a.buyout, a.profit
    end
    return d.buy.qty, d.buy.cost, d.buy.profit
end

---------------------------------------------------------------------------
function V:Build(ah)
    local app = self.app
    local f = CreateFrame("Frame", "AuctionHouseProfitsSniper", ah, "BackdropTemplate")
    f:SetWidth(WIDTH)
    f:SetPoint("TOPLEFT", ah, "TOPRIGHT", 2, 0)
    f:SetPoint("BOTTOMLEFT", ah, "BOTTOMRIGHT", 2, 0)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    local ok, err = app.ui:Style(f, "dialog")
    if not ok and err then app.log:Warn(err.message) end
    self.frame = f

    local title = label(f, "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("Vendor sniper")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() V:Toggle(false) end)

    -- Minimum profit, in gold, silver and copper.
    local minLabel = label(f, "GameFontNormalSmall")
    minLabel:SetPoint("TOPLEFT", 12, -40)
    minLabel:SetText("Min profit")
    local minimum = U.MoneyInput(f, function(parent)
        local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
        box:SetAutoFocus(false)
        return box
    end, function(copper)
        local set, serr = app:Set("snipeMinProfit", copper or 0)
        if not set and serr then app.log:Warn(serr.message) end
        V:Refresh()
    end)
    minimum:SetPoint("LEFT", minLabel, "RIGHT", 10, 0)
    self.minimum = minimum
    local basis = blizzButton(f, nil, "each", 54, 20)
    basis:SetPoint("LEFT", minimum, "RIGHT", 2, 0)
    basis:SetScript("OnClick", function()
        local set, serr = app:Set("snipeBasis", app:Get("snipeBasis") == "unit" and "buy" or "unit")
        if not set and serr then app.log:Warn(serr.message) end
        V:Refresh()
    end)
    tip(basis, function(t)
        t:AddLine("Minimum profit applies to")
        t:AddLine(app:Get("snipeBasis") == "unit" and "Each unit: every unit must make at least this much. Click for each purchase."
            or "Each purchase: one press must make at least this much in all. Click for each unit.", 1, 1, 1, true)
    end)
    self.basis = basis

    -- Scanning
    local scan = blizzButton(f, nil, "Full scan", 100)
    scan:SetPoint("TOPLEFT", 10, -66)
    scan:SetScript("OnClick", function() V:Scan() end)
    tip(scan, function(t)
        t:AddLine("Find auctions below vendor price")
        t:AddLine("A full scan reads every auction at once; the game allows one every 15 minutes per account. "
            .. "In between, Recheck searches the items that had deals before. Searches you run on the Buy page are checked too.", 1, 1, 1, true)
    end)
    self.scanButton = scan
    local status = label(f, "GameFontDisableSmall")
    status:SetPoint("LEFT", scan, "RIGHT", 8, 0)
    status:SetPoint("RIGHT", f, "RIGHT", -10, 0)
    self.status = status

    -- Deals
    local box = CreateFrame("Frame", nil, f, "WowScrollBoxList")
    box:SetPoint("TOPLEFT", 10, -96)
    box:SetPoint("BOTTOMRIGHT", -24, 156)
    local bar = CreateFrame("EventFrame", nil, f, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
    bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_H)
    view:SetElementInitializer("Button", function(row, data) V:InitRow(row, data) end)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
    self.listBox = box
    local empty = label(f, "GameFontDisableSmall")
    empty:SetPoint("TOPLEFT", box, "TOPLEFT", 4, -6)
    empty:SetPoint("RIGHT", box, "RIGHT", -4, 0)
    empty:SetWordWrap(true)
    self.empty = empty

    local totals = label(f, "GameFontDisableSmall")
    totals:SetPoint("BOTTOMLEFT", 12, 138)
    totals:SetPoint("RIGHT", f, "RIGHT", -10, 0)
    self.totals = totals

    -- The next deal, and the button that buys it.
    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(28, 28)
    icon:SetPoint("BOTTOMLEFT", 12, 100)
    self.nextIcon = icon
    local name = label(f, "GameFontHighlight")
    name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, -1)
    name:SetPoint("RIGHT", f, "RIGHT", -10, 0)
    self.nextName = name
    local detail = label(f, "GameFontHighlightSmall")
    detail:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 6, 1)
    detail:SetPoint("RIGHT", f, "RIGHT", -10, 0)
    self.nextDetail = detail
    -- Hover the next deal for the game's item tooltip, with whatever other
    -- add-ons add to it (their vendor and market prices). Shift-click links it.
    local item = CreateFrame("Button", nil, f)
    item:SetPoint("TOPLEFT", icon, "TOPLEFT")
    item:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT")
    item:SetScript("OnEnter", function(self) V:ItemTooltip(self) end)
    item:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    item:SetScript("OnClick", function()
        local d = V.nextDeal
        local link = d and C_Item and C_Item.GetItemInfo and select(2, C_Item.GetItemInfo(d.id))
        if link and HandleModifiedItemClick then HandleModifiedItemClick(link) end
    end)
    self.nextItem = item

    local buy = blizzButton(f, "AuctionHouseProfitsSnipeBuyButton", "Buy", WIDTH - 92, 44)
    buy:SetPoint("BOTTOMLEFT", 10, 50)
    buy:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    buy:SetScript("OnClick", function(_, mouse)
        if mouse == "RightButton" then V:Skip() else V:Buy() end
    end)
    tip(buy, function(t) V:BuyTooltip(t) end)
    self.buyButton = buy
    local skip = blizzButton(f, nil, "Skip", 66, 44)
    skip:SetPoint("LEFT", buy, "RIGHT", 6, 0)
    skip:SetScript("OnClick", function() V:Skip() end)
    self.skipButton = skip

    local session = label(f, "GameFontHighlightSmall")
    session:SetPoint("BOTTOMLEFT", 12, 30)
    session:SetPoint("RIGHT", f, "RIGHT", -10, 0)
    self.session = session
    -- What the addon has made you; hover for today, this week and in all.
    local made = CreateFrame("Button", nil, f)
    made:SetPoint("BOTTOMRIGHT", -10, 10)
    made:SetSize(215, 16)
    local madeText = label(made, "GameFontHighlightSmall")
    madeText:SetAllPoints()
    madeText:SetJustifyH("RIGHT")
    made.text = madeText
    tip(made, function(t) ns.Earnings:Tooltip(t, time()) end)
    self.made = made
    local bags = label(f, "GameFontDisableSmall")
    bags:SetPoint("BOTTOMLEFT", 12, 14)
    bags:SetPoint("RIGHT", made, "LEFT", -6, 0)
    self.bags = bags

    -- Background work only while you can see the panel.
    f:SetScript("OnShow", function() V:Start() end)
    f:SetScript("OnHide", function() V:Stop() end)
end

function V:InitRow(row, d)
    if not row.ahp then
        row.ahp = true
        row:SetHeight(ROW_H)
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(1, .82, 0, .12)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", 2, 0)
        row.profit = label(row)
        row.profit:SetPoint("RIGHT", -4, 0)
        row.profit:SetJustifyH("RIGHT")
        row.name = label(row)
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
        row.name:SetPoint("RIGHT", row.profit, "LEFT", -6, 0)
        row:SetScript("OnClick", function(self) N:Focus(self.data.id) end)
        tip(row, function(t, self)
            local x = self.data
            t:AddLine(x.name or ("item:" .. x.id))
            t:AddLine(string.format("%s for %s, vendor pays %s", count(x.qty), U.Money(x.cost), U.Money(x.cost + x.profit)), 1, 1, 1)
            t:AddLine("Up to " .. U.Money(x.each, true, true) .. " each, " .. U.Money(x.profit, true, true) .. " if you get all "
                .. count(x.qty) .. ". Sorted by the most one item makes.", 1, 1, 1, true)
            if x.verified then
                if x.kind == "item" then t:AddLine(count(x.qty) .. " auctions, one per press.", 1, 1, 1) end
                t:AddLine("Checked against the live listings.", .3, .8, .3)
            else
                t:AddLine("Estimate from the full scan; checking the live listings.", .6, .6, .6, true)
            end
            t:AddLine("Click to buy this one next.", .6, .6, .6)
        end)
    end
    row.data = d
    row.icon:SetTexture(d.icon)
    local hex = d.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[d.quality] and ITEM_QUALITY_COLORS[d.quality].hex
    local name = (d.name or ("item:" .. d.id)) .. color(MUTED, " x" .. count(d.qty))
    row.name:SetText(hex and (hex .. (d.name or ("item:" .. d.id)) .. "|r" .. color(MUTED, " x" .. count(d.qty))) or name)
    row.profit:SetText((d.verified and "" or color(MUTED, "~")) .. U.Money(d.each, true, d.verified) .. color(MUTED, " each"))
    row.sel:SetShown(d == N.deals[1])
end

-- Spell out what pressing Buy will do, and what it won't.
-- The next deal's item tooltip, then what this add-on reads as its vendor price.
function V:ItemTooltip(owner)
    local d, t = self.nextDeal, GameTooltip
    self.tooltipID = nil
    if not d or not t then return end
    t:SetOwner(owner, "ANCHOR_LEFT")
    if t.SetItemByID then t:SetItemByID(d.id) else t:SetHyperlink("item:" .. d.id) end
    local item = N.Item(d.id)
    if item and item.sell then
        local qty = press(d)
        local line = "Auction House Profits: a vendor pays " .. U.Money(item.sell) .. " each"
        if qty and qty > 1 then line = line .. ", " .. U.Money(item.sell * qty) .. " for these " .. count(qty) end
        t:AddLine(line, 1, .82, 0, true)
    end
    t:Show()
    self.tooltipID = d.id
end

function V:BuyTooltip(t)
    local d = self.nextDeal
    local qty, cost, gain = press(d)
    if N:IsBusy() then
        t:AddLine("Buying...")
        t:AddLine("Waiting for the game to confirm the last purchase. Pressing again does nothing until then.", 1, 1, 1, true)
        return
    end
    if not d then
        t:AddLine("No deals")
        t:AddLine("Nothing to buy. Scan the auction house first.", 1, 1, 1, true)
        return
    end
    if not qty then
        t:AddLine("Checking " .. itemName(d))
        t:AddLine("The sniper is reading this item's live listings. Pressing now buys nothing; it checks them sooner.", 1, 1, 1, true)
        return
    end
    t:AddLine("Buy " .. count(qty) .. " " .. itemName(d) .. " for " .. U.Money(cost))
    t:AddLine("A vendor pays " .. U.Money(cost + gain) .. " for " .. (qty == 1 and "it" or "them") .. ": "
        .. U.Money(gain, true, true) .. ".", 1, 1, 1, true)
    if d.kind == "item" then
        local left = d.buy.qty - 1
        t:AddLine("One auction only." .. (left > 0 and (" " .. count(left) .. " more after this, one per press.") or ""), 1, 1, 1, true)
    else
        local minProfit, basis = N:Rules()
        local sell = cost + gain
        t:AddLine("The " .. count(qty) .. " cheapest, each " .. U.Money(d.buy.maxPrice) .. " or less. The game quotes the total before "
            .. "you pay; if it's over " .. U.Money(M.SnipeLimit(qty, sell / qty, minProfit, basis))
            .. " (someone bought the cheap ones first), the purchase is cancelled.", 1, 1, 1, true)
    end
    t:AddLine("Nothing else in the list is bought. Right-click to skip this deal.", .3, .8, .3, true)
    t:AddLine("Bind a key: Key Bindings > AddOns > Auction House Profits.", .6, .6, .6, true)
end

---------------------------------------------------------------------------
function V:Buy()
    local ok, why = N:BuyNext()
    if not ok and why and UIErrorsFrame then UIErrorsFrame:AddMessage(why, 1, .82, 0) end
    self:Refresh()
end

function V:Skip()
    N:Skip()
    self:Refresh()
end

function V:Scan()
    local ok, why
    if P:QueueProgress() then
        P:StopQueue(); ok = true
    elseif N:HasFullScan() and N:FullScanWait() == 0 then
        ok, why = N:FullScan()
    else
        ok, why = N:Recheck()
    end
    if not ok and UIErrorsFrame then UIErrorsFrame:AddMessage(why or "Nothing to scan.", 1, .3, .3) end
    self:Refresh()
end

function V:Start()
    if self.scope then self.scope:Cancel() end
    local scope = self.app:Scope()
    self.scope = scope
    scope:Every(0.3, "pump", function() N:Pump() end)
    scope:Every(1, "clock", function() V:Refresh() end)
    scope:Watch(self.app:SelectSettings(function(v) return tostring(v.snipeMinProfit) .. ":" .. tostring(v.snipeBasis) end),
        function() V:Refresh() end)
    self:Refresh()
end

function V:Stop()
    if self.scope then self.scope:Cancel(); self.scope = nil end
end

function V:IsShown() return self.frame ~= nil and self.frame:IsVisible() end

function V:Toggle(show)
    if not self.frame then
        if UIErrorsFrame then UIErrorsFrame:AddMessage("Open the auction house to use the sniper.", 1, .3, .3) end
        return
    end
    if show == nil then show = not self.frame:IsShown() end
    local ok, err = self.app:Set("snipeShow", show == true)
    if not ok and err then self.app.log:Warn(err.message) end
    self.frame:SetShown(show)
end

function V:RequestRefresh()
    if not self:IsShown() or not self.core then return end
    self.core:After(0, "snipe-refresh", function() V:Refresh() end)
end

function V:Refresh()
    if not self:IsShown() then return end
    local app = self.app
    self.minimum:Set(app:Get("snipeMinProfit"))
    self.basis:SetText(app:Get("snipeBasis") == "unit" and "each" or "per buy")

    -- Scan button and status
    local done, total = P:QueueProgress()
    local wait = N:FullScanWait()
    local canFull = N:HasFullScan() and wait == 0
    if N.full then
        self.scanButton:SetText("Scanning...")
    elseif done then
        self.scanButton:SetText("Stop " .. done .. "/" .. total)
    else
        self.scanButton:SetText(canFull and "Full scan" or "Recheck")
    end
    self.scanButton:SetEnabled(P.ahOpen and not N.full)
    local s = N:Status()
    if not s then
        local parts = {}
        local snap = N.snapshot
        if snap then
            local age = time() - snap.time
            parts[#parts + 1] = count(snap.total) .. " auctions, " .. (age < 90 and "just now" or (math.floor(age / 60 + 0.5) .. "m ago"))
        end
        if N:HasFullScan() then
            parts[#parts + 1] = canFull and color(GOOD, "full scan ready") or ("full scan in " .. N.Clock(wait))
        end
        s = table.concat(parts, " · ")
    end
    self.status:SetText(s)

    -- List
    local deals = N:Deals()
    if self.listBox and CreateDataProvider then
        self.listBox:SetDataProvider(CreateDataProvider(deals), ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition)
    end
    self.empty:SetShown(#deals == 0)
    self.empty:SetText(N.snapshot and "Nothing below vendor price right now. Recheck, or wait for the next full scan."
        or "Press Full scan to find auctions you can sell to a vendor for more than they cost.")
    local n, profit, ready = N:Totals()
    self.totals:SetText(n > 0 and string.format("%d deals, %d checked · up to %s", n, ready, U.Money(profit, true, true)) or "")

    -- Next deal, and a Buy button that says exactly what one press buys.
    local d, why = N:Next()
    local qty, cost, gain = press(d)
    self.nextDeal = d
    -- Keep an open item tooltip on the deal it describes.
    if GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(self.nextItem) and self.tooltipID ~= (d and d.id) then
        if d then self:ItemTooltip(self.nextItem) else GameTooltip:Hide() end
    end
    if d then
        self.nextIcon:SetTexture(d.icon)
        self.nextIcon:Show()
        self.nextName:SetText(color(MUTED, "Next: ") .. itemName(d))
        if qty then
            local each = d.kind == "item" and ("1 auction at " .. U.Money(cost))
                or (count(qty) .. " at up to " .. U.Money(d.buy.maxPrice) .. " each")
            self.nextDetail:SetText(each .. color(MUTED, " · vendor pays ") .. U.Money(cost + gain)
                .. color(MUTED, " · ") .. U.Money(gain, true, true))
        else
            self.nextDetail:SetText(color(MUTED, "About " .. U.Money(d.profit, true) .. " in all. Checking the live listings first."))
        end
    else
        self.nextIcon:Hide()
        self.nextName:SetText("")
        self.nextDetail:SetText(color(MUTED, why or ""))
    end
    local text
    if N:IsBusy() then text = "Buying..."
    elseif not d then text = "No deals"
    elseif not qty then text = "Checking listings..."
    else text = "Buy " .. count(qty) .. " for " .. U.Money(cost) end
    self.buyButton:SetText(text)
    self.buyButton:SetEnabled(P.ahOpen and d ~= nil and not N:IsBusy())
    self.skipButton:SetEnabled(d ~= nil and not N:IsBusy())

    local sess = N.session
    if sess.buys > 0 then
        self.session:SetText(string.format("Since login: %d bought for %s, vendors pay %s", sess.units, U.Money(sess.spent),
            U.Money(sess.value)) .. color(MUTED, " (") .. U.Money(sess.value - sess.spent, true, true) .. color(MUTED, ")"))
    else
        self.session:SetText(color(MUTED, "Each press buys only what the button says. Right-click to skip."))
    end
    local free = freeSlots()
    self.bags:SetText(free and (free == 0 and color(BAD, "Bags full: sell to a vendor first.") or (free .. " free slots")) or "")
    self.made.text:SetText(ns.Earnings.Short(time()))
end

function V:Attach(app, core)
    if self.attached then return true end
    local ah = AuctionHouseFrame
    if type(ah) ~= "table" then return false end
    self.app, self.core = app, core
    self:Build(ah)
    self.attached = true
    self.frame:SetShown(app:Get("snipeShow"))
    return true
end
