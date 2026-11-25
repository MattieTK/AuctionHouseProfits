-- The Profits view: item list on the left, analysis on the right.
-- One view instance; it is re-parented into the AH tab or the standalone window.
local ADDON, ns = ...
local M, D, P, A = ns.Model, ns.Data, ns.Prices, ns.Analysis
local U = { filter = "vendor", query = "", selected = nil }
ns.UI = U

local GOOD, BAD, MUTED, ACCENT = "ff4cc24c", "ffee7a7a", "ff9d9a8f", "ffe8bd55"
local FACTION_COLOR, NEUTRAL_COLOR = { .23, .53, .90 }, { .85, .35, .15 }
local LADDER_ROWS, ROW_H = 13, 14
local LIST_W, TOP_H = 236, 34

local function color(hex, text) return "|c" .. hex .. text .. "|r" end

-- Money with coin icons. plus = show "+" on gains; tint = green/red by sign.
function U.Money(copper, plus, tint)
    if not M.Number(copper) then return color(MUTED, "-") end
    local rounded = math.floor(math.abs(copper) + 0.5)
    local coins
    if GetMoneyString then
        -- Blizzard's formatter: coin icons, or symbols in colorblind mode.
        coins = GetMoneyString(rounded, true, false, rounded == 0)
    elseif C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
        coins = C_CurrencyInfo.GetCoinTextureString(rounded, 0)
    end
    if type(coins) ~= "string" or coins == "" then coins = M.MoneyText(rounded) end
    local sign = ""
    if copper <= -0.5 then sign = "-" elseif plus and copper >= 0.5 then sign = "+" end
    local text = sign .. coins
    if tint and copper >= 0.5 then return color(GOOD, text) end
    if tint and copper <= -0.5 then return color(BAD, text) end
    return text
end
local Money = U.Money

local function pct(x)
    if not M.Number(x) then return "-" end
    return string.format("%d%%", math.floor(x * 100 + (x >= 0 and 0.5 or -0.5)))
end

local function count(n)
    if not M.Number(n) then return "?" end
    return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)
end

local function ago(seconds)
    if not M.Number(seconds) then return "" end
    if seconds < 90 then return "just now" end
    if seconds < 5400 then return math.floor(seconds / 60 + 0.5) .. "m ago" end
    if seconds < 172800 then return math.floor(seconds / 3600 + 0.5) .. "h ago" end
    return math.floor(seconds / 86400 + 0.5) .. "d ago"
end

local function warn(app, ok, err) if not ok and err then app.log:Warn(err.message or "ui error") end end

local function text(parent, template, role)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if role then
        local ok, err = U.app.fonts:Apply(fs, role)
        warn(U.app, ok, err)
    end
    return fs
end

local function section(parent)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    local ok, err = U.app.ui:Style(f, "section")
    warn(U.app, ok, err)
    return f
end

local function control(parent, id, kind)
    local ok, frame = U.app.ui:Control(parent, id, kind)
    if not ok then error(ADDON .. ": " .. frame.message) end
    if kind == "input" then
        warn(U.app, U.app.fonts:Apply(frame, "control"))
        warn(U.app, U.app.ui:Color(frame, "text"))
    elseif kind == "dropdown" and frame.Text then
        -- Without a font the closed dropdown shows no caption at all.
        warn(U.app, U.app.fonts:Apply(frame.Text, "control"))
        warn(U.app, U.app.ui:Color(frame.Text, "text"))
    end
    return frame
end

function U.DurationLabel(i)
    local labels = { _G.AUCTION_DURATION_ONE, _G.AUCTION_DURATION_TWO, _G.AUCTION_DURATION_THREE }
    return type(labels[i]) == "string" and labels[i] or ((M.DURATION_HOURS[i] or "?") .. " hours")
end

-- Show the selected value on a closed dropdown.
function U:Caption(dd, label)
    if dd.IsMenuOpen and dd:IsMenuOpen() then return end
    if dd.GenerateMenu then dd:GenerateMenu() end
    if dd.OverrideText then dd:OverrideText(label) end
    if dd.Text then dd.Text:SetText(label) end
end

-- Three boxes for gold, silver and copper. makeBox(parent, index) returns an
-- EditBox; onCommit(copper or nil) runs on Enter, Tab-out or focus loss.
-- Set(copper) updates the boxes unless you're typing in one of them.
function U.MoneyInput(parent, makeBox, onCommit)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(158, 22)
    local widths = { 46, 30, 30 }
    local icons = { "Interface\\MoneyFrame\\UI-GoldIcon", "Interface\\MoneyFrame\\UI-SilverIcon", "Interface\\MoneyFrame\\UI-CopperIcon" }
    local boxes, x = {}, 0
    local function editing()
        for _, b in ipairs(boxes) do if b:HasFocus() then return true end end
        return false
    end
    -- Only a changed value is a commit: clicking in and out of a box showing
    -- the automatic price must not save it as yours.
    local function commit()
        if f.cancelling then return end
        local value = M.Coins(boxes[1]:GetText(), boxes[2]:GetText(), boxes[3]:GetText())
        if value ~= f.value then onCommit(value) end
    end
    for i = 1, 3 do
        local b = makeBox(f, i)
        b:SetSize(widths[i], 22)
        -- The default 8px insets leave a 30px box no room for "89".
        if b.SetTextInsets then b:SetTextInsets(3, 5, 0, 0) end
        b:SetPoint("LEFT", f, "LEFT", x, 0)
        b:SetNumeric(true)
        b:SetMaxLetters(i == 1 and 6 or 2)
        b:SetJustifyH("RIGHT")
        local icon = f:CreateTexture(nil, "ARTWORK")
        icon:SetSize(12, 12)
        icon:SetTexture(icons[i])
        icon:SetPoint("LEFT", b, "RIGHT", 2, 0)
        x = x + widths[i] + 16
        boxes[i] = b
    end
    for i, b in ipairs(boxes) do
        b:SetScript("OnEnterPressed", function(self) self:ClearFocus(); commit() end)
        b:SetScript("OnTabPressed", function()
            local shift = IsShiftKeyDown and IsShiftKeyDown()
            local nextBox = boxes[shift and (i == 1 and 3 or i - 1) or (i % 3 + 1)]
            nextBox:SetFocus()
            if nextBox.HighlightText then nextBox:HighlightText() end
        end)
        b:SetScript("OnEditFocusLost", function()
            -- Tabbing between the three boxes isn't leaving the input.
            if not editing() then commit() end
        end)
        b:SetScript("OnEscapePressed", function(self)
            f.cancelling = true -- ClearFocus fires OnEditFocusLost
            self:ClearFocus()
            f.cancelling = nil
            f:Set(f.value, true)
        end)
    end
    function f:Set(copper, force)
        self.value = copper
        if editing() and not force then return end
        if not M.Number(copper) then
            for _, b in ipairs(boxes) do b:SetText("") end
            return
        end
        local g, s, c = M.Split(copper)
        boxes[1]:SetText(g > 0 and tostring(g) or "")
        boxes[2]:SetText((g > 0 or s > 0) and tostring(s) or "")
        boxes[3]:SetText(tostring(c))
    end
    f.boxes = boxes
    return f
end

-- SND buttons are bare backdrop buttons; give them a themed label.
local function button(parent, id, label, width)
    local b = control(parent, id, "button")
    b:SetSize(width, 22)
    local fs = b:CreateFontString(nil, "OVERLAY")
    fs:SetPoint("CENTER")
    warn(U.app, U.app.fonts:Apply(fs, "control"))
    warn(U.app, U.app.ui:Color(fs, "text"))
    fs:SetText(label)
    b.label = fs
    return b
end

-- Label above an input, returns the input.
local function labeled(parent, id, kind, label, x, y, w)
    local l = text(parent, "GameFontNormalSmall")
    l:SetPoint("TOPLEFT", x, y)
    l:SetText(label)
    local c = control(parent, id, kind)
    c:SetSize(w, 22)
    c:SetPoint("TOPLEFT", x, y - 13)
    return c, l
end

-- Commit-on-enter edit box behaviour.
local function bindInput(box, commit, current)
    box:SetScript("OnEnterPressed", function(self) commit(self:GetText()); self:ClearFocus() end)
    box:SetScript("OnEditFocusLost", function(self) commit(self:GetText()) end)
    box:SetScript("OnEscapePressed", function(self) self:SetText(current() or ""); self:ClearFocus() end)
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------
function U:Build()
    if self.panel then return self.panel end
    local app = self.app
    local panel = CreateFrame("Frame", "AuctionHouseProfitsPanel", UIParent)
    panel:Hide()
    panel:EnableMouse(true)
    self.panel = panel

    -- Top strip: search and filter (sits beside the AH portrait when docked).
    local top = section(panel)
    top:SetHeight(TOP_H)
    self.top = top
    local search = control(top, "search", "input")
    search:SetSize(LIST_W - 36, 22)
    search:SetPoint("LEFT", 8, 0)
    local hint = text(search, "GameFontDisableSmall")
    hint:SetPoint("LEFT", 8, 0)
    hint:SetText("Name, item ID, or shift-click an item")
    search:SetScript("OnTextChanged", function(box, user)
        hint:SetShown(box:GetText() == "")
        if user then U:SetQuery(box:GetText()) end
    end)
    search:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
    search:SetScript("OnEnterPressed", function(box) box:ClearFocus() end)
    self.search = search

    local filter = control(top, "filter", "dropdown")
    filter:SetSize(130, 22)
    filter:SetPoint("LEFT", search, "RIGHT", 8, 0)
    self.filterDropdown = filter
    local filters = {
        { value = "vendor", label = "Vendor items" },
        { value = "merchant", label = "Last merchant" },
        { value = "bags", label = "My bags" },
        { value = "all", label = "Everything known" },
    }
    filter:SetupMenu(function(_, root)
        for _, f in ipairs(filters) do
            root:CreateRadio(f.label, function() return U.filter == f.value end, function() U:SetFilter(f.value) end, f.value)
        end
    end)
    self.filters = filters

    local sort = control(top, "sort", "dropdown")
    sort:SetSize(130, 22)
    sort:SetPoint("LEFT", filter, "RIGHT", 6, 0)
    local sorts = {
        { value = "day", label = "Profit per day" },
        { value = "unit", label = "Profit per unit" },
        { value = "activity", label = "Busiest markets" },
    }
    sort:SetupMenu(function(_, root)
        for _, o in ipairs(sorts) do
            root:CreateRadio(o.label, function() return app:Get("listSort") == o.value end, function() U:SetSort(o.value) end, o.value)
        end
    end)
    self.sortDropdown, self.sorts = sort, sorts

    local gear = button(top, "options", "Options", 70)
    gear:SetPoint("RIGHT", -8, 0)
    gear:SetScript("OnClick", function()
        local ok, err = ns.Options:Toggle()
        warn(app, ok, err)
    end)
    local sniper = button(top, "sniper", "Sniper", 64)
    sniper:SetPoint("RIGHT", gear, "LEFT", -6, 0)
    sniper:SetScript("OnClick", function() if ns.SnipePanel then ns.SnipePanel:Toggle() end end)
    sniper:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Vendor sniper")
        GameTooltip:AddLine("Find auctions a vendor pays more for than they cost, and buy them one press at a time.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    sniper:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    self.sniperButton = sniper
    local status = text(top, "GameFontDisableSmall")
    status:SetPoint("RIGHT", sniper, "LEFT", -10, 0)
    status:SetPoint("LEFT", sort, "RIGHT", 8, 0)
    status:SetJustifyH("RIGHT")
    self.status = status
    local statusHover = CreateFrame("Frame", nil, top)
    statusHover:SetAllPoints(status)
    statusHover:SetScript("OnEnter", function(self)
        if not GameTooltip or not ns.Earnings then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        ns.Earnings:Tooltip(GameTooltip, time())
        GameTooltip:Show()
    end)
    statusHover:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    -- Body
    local body = section(panel)
    body:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -(TOP_H + 2))
    body:SetPoint("BOTTOMRIGHT")
    self.body = body
    self:BuildList(body)
    self:BuildDetail(body)
    return panel
end

function U:BuildList(body)
    local box = CreateFrame("Frame", nil, body, "WowScrollBoxList")
    box:SetPoint("TOPLEFT", 6, -6)
    box:SetPoint("BOTTOMLEFT", 6, 22)
    box:SetWidth(LIST_W - 12)
    local bar = CreateFrame("EventFrame", nil, body, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 2, 0)
    bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 2, 0)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(22)
    view:SetElementInitializer("Button", function(row, data) U:InitRow(row, data) end)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
    self.listBox = box

    local count = text(body, "GameFontDisableSmall")
    count:SetPoint("BOTTOMLEFT", 10, 6)
    count:SetWidth(LIST_W - 94)
    self.count = count

    local scanAll = button(body, "scan-list", "Scan list", 80)
    scanAll:SetHeight(18)
    scanAll:SetPoint("BOTTOMLEFT", LIST_W - 84, 2)
    scanAll:SetScript("OnClick", function() U:ToggleScanList() end)
    scanAll:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Scan every item in this list")
        GameTooltip:AddLine("Searches the AH for each item in turn. Scanning now and again builds the price and volume history that shows which markets are busy.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    scanAll:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    self.scanAllButton = scanAll

    local divider = body:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 1, 1, .08)
    divider:SetPoint("TOPLEFT", LIST_W + 4, -6)
    divider:SetPoint("BOTTOMLEFT", LIST_W + 4, 6)
    divider:SetWidth(1)
end

function U:InitRow(row, data)
    if not row.ahp then
        row.ahp = true
        row:SetHeight(22)
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(.91, .74, .33, .18)
        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(1, 1, 1, .07)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(18, 18)
        row.icon:SetPoint("LEFT", 3, 0)
        row.value = text(row)
        row.value:SetPoint("RIGHT", -4, 0)
        row.value:SetJustifyH("RIGHT")
        -- Four bars: how busy this item's market looked in your scans.
        row.meter = {}
        for i = 1, 4 do
            local bar = row:CreateTexture(nil, "ARTWORK")
            bar:SetSize(2, 2 + i * 2)
            bar:SetPoint("BOTTOMRIGHT", row.value, "BOTTOMLEFT", -5 - (4 - i) * 3, 1)
            row.meter[i] = bar
        end
        row.name = text(row)
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
        row.name:SetPoint("RIGHT", row.value, "LEFT", -20, 0)
        row:SetScript("OnClick", function(self) U:Select(self.data.id) end)
        row:SetScript("OnEnter", function(self)
            if not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.data.link then GameTooltip:SetHyperlink(self.data.link) else GameTooltip:AddLine(self.data.name or "") end
            U:ActivityLines(GameTooltip, self.data.activity, self.data.profitUnit, self.data.perDay)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    end
    row.data = data
    row.icon:SetTexture(data.icon or 134400)
    local name = data.name or ("item:" .. data.id)
    if data.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[data.quality] then
        name = ITEM_QUALITY_COLORS[data.quality].hex .. name .. "|r"
    end
    row.name:SetText(name)
    if data.profitUnit then
        row.value:SetText(Money(data.profitUnit, true, true))
    elseif data.unitCost and not data.market then
        row.value:SetText(color(MUTED, "no price"))
    else
        row.value:SetText(color(MUTED, data.unitCost and "" or "no cost"))
    end
    row.sel:SetShown(data.id == U.selected)
    U.Meter(row.meter, data.activity)
end

local METER = { { .85, .40, .35 }, { .90, .75, .30 }, { .55, .80, .30 }, { .30, .76, .30 } }
function U.Meter(bars, activity)
    local rank = activity and activity.level and activity.level.rank or 0
    for i, bar in ipairs(bars) do
        if i <= rank then
            local c = METER[rank]
            bar:SetColorTexture(c[1], c[2], c[3], 1)
        else
            bar:SetColorTexture(1, 1, 1, .14)
        end
    end
end

local function units(n) return count(math.floor(n + 0.5)) end

-- "2h 10m", "45m", "3d 4h" for spans of scan history.
local function span(seconds)
    seconds = math.floor((seconds or 0) / 60 + 0.5)
    if seconds < 60 then return seconds .. "m" end
    if seconds < 1440 then
        local m = seconds % 60
        return math.floor(seconds / 60) .. "h" .. (m > 0 and (" " .. m .. "m") or "")
    end
    local h = math.floor(seconds / 60) % 24
    return math.floor(seconds / 1440) .. "d" .. (h > 0 and (" " .. h .. "h") or "")
end
U.Span = span

-- Why there's no rating yet, as (headline, detail).
function U.ActivityPending(act)
    if not act or act.points == 0 then return "Not scanned yet", "Scan it now and again: what gets bought between scans shows demand." end
    if (act.compared or 0) == 0 then return "One scan so far", "Scan again later: what gets bought between scans shows demand." end
    if (act.bought or 0) == 0 then
        return "No sales seen yet", "Nothing bought in " .. span(act.span) .. " of scans. Stagnant after 3h."
    end
    return "Too early to tell", units(act.bought) .. " bought in " .. span(act.span) .. " of scans. Give it half an hour."
end

-- Demand summary lines for tooltips.
function U:ActivityLines(tip, act, profitUnit, perDay)
    if not act or not act.level then
        local head, detail = U.ActivityPending(act)
        tip:AddLine("Market: " .. head, .6, .6, .6)
        tip:AddLine(detail, .6, .6, .6, true)
        return
    end
    tip:AddLine("Market: " .. act.level.label, 1, 1, 1)
    tip:AddLine(string.format("%s bought, %s newly listed in %s of scans", units(act.bought), units(act.added), span(act.span)), .8, .8, .8)
    if act.demandPerDay then tip:AddLine("About " .. units(act.demandPerDay) .. " bought a day", .8, .8, .8) end
    if act.flooding then tip:AddLine("Supply is piling up faster than it sells.", .93, .48, .48, true) end
    if perDay then tip:AddLine("If you list first: " .. Money(perDay, true, true) .. " a day", 1, 1, 1) end
end

-- Small "label / value" stat block.
local function stat(parent, x, y, w, label)
    local l = text(parent, "GameFontDisableSmall")
    l:SetPoint("TOPLEFT", x, y)
    l:SetWidth(w)
    l:SetText(label)
    local v = text(parent, "GameFontHighlight")
    v:SetPoint("TOPLEFT", x, y - 13)
    v:SetWidth(w)
    local s = text(parent, "GameFontDisableSmall")
    s:SetPoint("TOPLEFT", x, y - 28)
    s:SetWidth(w)
    return { label = l, value = v, sub = s }
end


-- Clickable text tab (for the market/ladder switch).
local function textTab(parent, label, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(80, 14)
    local fs = text(b, "GameFontNormalSmall")
    fs:SetPoint("LEFT", 0, 0)
    fs:SetText(label)
    b.label = fs
    local line = b:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(.91, .74, .33, .9)
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT", 0, -1)
    line:SetPoint("BOTTOMRIGHT", fs, "BOTTOMRIGHT", 0, -1)
    b.line = line
    b:SetScript("OnClick", onClick)
    return b
end

function U:BuildDetail(body)
    local d = CreateFrame("Frame", nil, body)
    d:SetPoint("TOPLEFT", LIST_W + 12, -6)
    d:SetPoint("BOTTOMRIGHT", -8, 6)
    self.detail = d

    local empty = text(d, "GameFontNormal")
    empty:SetPoint("CENTER")
    empty:SetWidth(380)
    empty:SetWordWrap(true)
    empty:SetJustifyH("CENTER")
    empty:SetText("Pick an item on the left.\n\nVendor items appear once you've opened a merchant. Search by name or item ID, or shift-click an item link.")
    self.empty = empty

    local content = CreateFrame("Frame", nil, d)
    content:SetAllPoints()
    self.content = content

    -- Header
    local iconButton = CreateFrame("Button", nil, content)
    iconButton:SetSize(34, 34)
    iconButton:SetPoint("TOPLEFT", 0, 0)
    local icon = iconButton:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    iconButton:SetScript("OnEnter", function(self)
        if U.current and U.current.info.link and GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(U.current.info.link)
            GameTooltip:Show()
        end
    end)
    iconButton:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    self.icon = icon
    local scan = button(content, "scan", "Scan AH", 76)
    scan:SetPoint("TOPRIGHT", 0, -4)
    scan:SetScript("OnClick", function() U:ScanSelected() end)
    self.scanButton = scan
    -- Buy under your price, beside Scan AH so scanning and buying are one
    -- short move apart: the most you'll pay each, then Buy.
    local buy = button(content, "buy-under", "Buy", 112)
    buy:SetPoint("RIGHT", scan, "LEFT", -6, 0)
    buy:SetScript("OnClick", function() U:BuyUnder() end)
    buy:SetScript("OnEnter", function(self) U:BuyTooltip(self) end)
    buy:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    self.buyButton = buy
    local limit = U.MoneyInput(content, function(parent, i) return control(parent, "limit" .. i, "input") end,
        function(copper) if U.selected then ns.Snipe:SetLimit(U.selected, copper) end end)
    limit:SetPoint("RIGHT", buy, "LEFT", -6, 0)
    for _, b in ipairs(limit.boxes) do
        b:SetScript("OnEnter", function(self) U:LimitTooltip(self) end)
        b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    end
    self.limitInput = limit
    local post = button(content, "post", "Post", 86)
    post:SetScript("OnClick", function() U:PostSelected() end)
    post:SetScript("OnEnter", function(self)
        if not GameTooltip or not U.current then return end
        local ok, why = U:CanPostSelected()
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(ok and "Post from your bags" or (why or "Can't post"))
        local a = U.current
        GameTooltip:AddLine(string.format("%s at %s each, %dh. %s in your bags.", count(U:PostQuantity()),
            Money(a.price), M.DURATION_HOURS[a.duration] or 0, count(a.bagCount)), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    post:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    self.postButton = post
    local title = text(content, "GameFontNormalLarge", "heading")
    title:SetPoint("TOPLEFT", iconButton, "TOPRIGHT", 8, -1)
    title:SetPoint("RIGHT", limit, "LEFT", -8, 0)
    self.title = title
    local sub = text(content, "GameFontDisableSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    sub:SetPoint("RIGHT", limit, "LEFT", -8, 0)
    self.sub = sub

    -- Price stats, with your listing price as gold/silver/copper boxes.
    local y = -42
    self.stats = {
        vendor = stat(content, 0, y, 118, "Vendor price"),
        cost = stat(content, 124, y, 118, "Your cost / unit"),
        market = stat(content, 248, y, 126, "Lowest on AH"),
    }
    local priceLabel = text(content, "GameFontNormalSmall")
    priceLabel:SetPoint("TOPLEFT", 380, y)
    priceLabel:SetText("Your price / unit")
    local price = U.MoneyInput(content, function(parent, i) return control(parent, "price" .. i, "input") end,
        function(copper) U:SetPlan("price", copper) end)
    price:SetPoint("TOPLEFT", 380, y - 13)
    local priceSub = text(content, "GameFontDisableSmall")
    priceSub:SetPoint("TOPLEFT", 380, y - 37)
    priceSub:SetWidth(152)
    self.priceSub = priceSub

    -- Plan inputs. Your standing with the vendor comes from the game, so
    -- there's no standing menu.
    y = -92
    local stackBox = labeled(content, "stackSize", "input", "Stack size", 0, y, 50)
    bindInput(stackBox, function(v) U:SetPlan("stackSize", tonumber(v) and math.max(1, math.floor(tonumber(v))) or nil) end,
        function() return U.current and tostring(U.current.stackSize) end)
    local stacksBox = labeled(content, "stacks", "input", "Stacks", 58, y, 42)
    bindInput(stacksBox, function(v) U:SetPlan("stacks", tonumber(v) and math.max(1, math.floor(tonumber(v))) or nil) end,
        function() return U.current and tostring(U.current.stacks) end)
    local duration = labeled(content, "duration", "dropdown", "Duration", 108, y, 90)
    duration:SetupMenu(function(_, root)
        for i, hours in ipairs(M.DURATION_HOURS) do
            root:CreateRadio(U.DurationLabel(i), function() return U.current and U.current.duration == i end,
                function() U:SetPlan("duration", i) end, i)
        end
    end)
    local costLabel = text(content, "GameFontNormalSmall")
    costLabel:SetPoint("TOPLEFT", 206, y)
    costLabel:SetText("Cost override / unit")
    local cost = U.MoneyInput(content, function(parent, i) return control(parent, "cost" .. i, "input") end,
        function(copper) U:SetPlan("cost", copper) end)
    cost:SetPoint("TOPLEFT", 206, y - 13)
    -- Post sits under your price, the price it lists at.
    post:SetPoint("TOPLEFT", 380, y - 13)
    local reset = button(content, "reset-price", "Reset", 62)
    reset:SetPoint("LEFT", post, "RIGHT", 6, 0)
    reset:SetScript("OnClick", function() U:SetPlan("price", nil) end)
    reset:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Reset your price")
        GameTooltip:AddLine("Go back to 1c under the cheapest other seller from your last scan.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    reset:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    self.inputs = { stackSize = stackBox, stacks = stacksBox, duration = duration, price = price, cost = cost }

    -- Hovering the cost explains the standing it assumes.
    local costHover = CreateFrame("Frame", nil, content)
    costHover:SetPoint("TOPLEFT", 124, -42)
    costHover:SetSize(118, 40)
    costHover:EnableMouse(true)
    costHover:SetScript("OnEnter", function(self) U:CostTooltip(self) end)
    costHover:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    -- Cards: faction AH, then the neutral AH (opt-in) or how busy the market is.
    y = -138
    self.cards = {}
    local function card(x, rgb)
        local f = section(content)
        f:SetPoint("TOPLEFT", x, y)
        f:SetSize(262, 80)
        local strip = f:CreateTexture(nil, "ARTWORK")
        strip:SetPoint("TOPLEFT", 3, -3)
        strip:SetPoint("BOTTOMLEFT", 3, 3)
        strip:SetWidth(3)
        strip:SetColorTexture(rgb[1], rgb[2], rgb[3], 1)
        local c = { frame = f, strip = strip }
        c.head = text(f, "GameFontNormalSmall"); c.head:SetPoint("TOPLEFT", 12, -7); c.head:SetPoint("RIGHT", -8, 0)
        c.profit = text(f, "GameFontHighlightLarge"); c.profit:SetPoint("TOPLEFT", 12, -21); c.profit:SetPoint("RIGHT", -8, 0)
        c.line1 = text(f, "GameFontHighlightSmall"); c.line1:SetPoint("TOPLEFT", 12, -41); c.line1:SetPoint("RIGHT", -8, 0)
        c.line2 = text(f, "GameFontDisableSmall"); c.line2:SetPoint("TOPLEFT", 12, -54); c.line2:SetPoint("RIGHT", -8, 0)
        c.line3 = text(f, "GameFontDisableSmall"); c.line3:SetPoint("TOPLEFT", 12, -66); c.line3:SetPoint("RIGHT", -8, 0)
        return c
    end
    self.cards.faction = card(0, FACTION_COLOR)
    self.cards.neutral = card(270, NEUTRAL_COLOR)
    self.activityCard = card(270, { .91, .74, .33 })
    -- Its explanations run to two lines (line2 is empty when they do).
    self.activityCard.line1:SetWordWrap(true)
    self.activityCard.line1:SetJustifyV("TOP")

    -- Bottom left: lowest price and units listed over time.
    y = -226
    self:BuildChart(content, 0, y)

    -- Right table: live market depth, or the price ladder.
    local lx = 270
    self.tableTabs = {
        market = textTab(content, "Live market", function() U.tableMode = "market"; U:RefreshDetail() end),
        ladder = textTab(content, "Price ladder", function() U.tableMode = "ladder"; U:RefreshDetail() end),
    }
    self.tableTabs.market:SetPoint("TOPLEFT", lx, y)
    self.tableTabs.ladder:SetPoint("TOPLEFT", lx + 78, y)
    local per = text(content, "GameFontDisableSmall")
    per:SetPoint("TOPRIGHT", content, "TOPLEFT", lx + 260, y)
    per:SetJustifyH("RIGHT")
    self.tablePer = per
    local h1 = text(content, "GameFontDisableSmall")
    h1:SetPoint("TOPLEFT", lx, y - 16); h1:SetWidth(76)
    local h2 = text(content, "GameFontDisableSmall")
    h2:SetPoint("TOPLEFT", lx + 76, y - 16); h2:SetWidth(42); h2:SetJustifyH("RIGHT")
    local hf = text(content, "GameFontDisableSmall")
    hf:SetPoint("TOPLEFT", lx + 120, y - 16); hf:SetWidth(68); hf:SetJustifyH("RIGHT")
    local hn = text(content, "GameFontDisableSmall")
    hn:SetPoint("TOPLEFT", lx + 190, y - 16); hn:SetWidth(68); hn:SetJustifyH("RIGHT"); hn:SetText("Neutral")
    self.tableHeads = { h1, h2, hf, hn }
    local note = text(content, "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", lx, y - 34)
    note:SetWidth(260)
    note:SetWordWrap(true)
    note:SetJustifyV("TOP")
    self.tableNote = note
    self.ladder = {}
    for i = 1, LADDER_ROWS do
        local rowY = y - 16 - i * ROW_H
        local b = CreateFrame("Button", nil, content)
        b:SetPoint("TOPLEFT", lx - 2, rowY + 1)
        b:SetSize(262, ROW_H)
        local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, .07)
        local mark = b:CreateTexture(nil, "BACKGROUND"); mark:SetAllPoints(); mark:SetColorTexture(.91, .74, .33, .14)
        local bar = b:CreateTexture(nil, "BORDER"); bar:SetPoint("LEFT", 122, 0); bar:SetHeight(ROW_H - 4)
        local price = text(b, "GameFontHighlightSmall"); price:SetPoint("LEFT", 2, 0); price:SetWidth(76)
        local second = text(b, "GameFontHighlightSmall"); second:SetPoint("LEFT", 78, 0); second:SetWidth(42); second:SetJustifyH("RIGHT")
        local f = text(b, "GameFontHighlightSmall"); f:SetPoint("LEFT", 122, 0); f:SetWidth(68); f:SetJustifyH("RIGHT")
        local n = text(b, "GameFontHighlightSmall"); n:SetPoint("LEFT", 192, 0); n:SetWidth(68); n:SetJustifyH("RIGHT")
        b:SetScript("OnClick", function(self) if self.price then U:SetPlan("price", self.price) end end)
        b:SetScript("OnEnter", function(self) U:RowTooltip(self) end)
        b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        self.ladder[i] = { button = b, mark = mark, bar = bar, price = price, second = second, faction = f, neutral = n }
    end
end

---------------------------------------------------------------------------
-- Price and volume chart
---------------------------------------------------------------------------
local CHART_W, CHART_H, CHART_BUCKETS = 262, 132, 44

-- A line between two points, or a dot at the end point where the client
-- has no Line regions.
local function segment(parent, pool, i)
    local seg = pool[i]
    if not seg then
        local ok, line = false, nil
        if parent.CreateLine then ok, line = pcall(parent.CreateLine, parent, nil, "OVERLAY") end
        if ok and type(line) == "table" and line.SetStartPoint then
            seg = line
            seg:SetThickness(1.5)
        else
            seg = parent:CreateTexture(nil, "OVERLAY")
            seg:SetSize(3, 3)
        end
        seg:SetColorTexture(.91, .74, .33, 1)
        pool[i] = seg
    end
    return seg
end

function U:BuildChart(content, x, y)
    local title = text(content, "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", x, y)
    title:SetText("Price & volume")
    local range = text(content, "GameFontDisableSmall")
    range:SetPoint("TOPRIGHT", content, "TOPLEFT", x + CHART_W, y)
    range:SetJustifyH("RIGHT")
    local area = CreateFrame("Frame", nil, content)
    area:SetPoint("TOPLEFT", x, y - 16)
    area:SetSize(CHART_W, CHART_H)
    local bg = area:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, .03)
    local base = area:CreateTexture(nil, "BORDER")
    base:SetPoint("BOTTOMLEFT"); base:SetPoint("BOTTOMRIGHT"); base:SetHeight(1)
    base:SetColorTexture(1, 1, 1, .12)
    local qtyMax = text(area, "GameFontDisableSmall"); qtyMax:SetPoint("TOPLEFT", 3, -2)
    local priceTop = text(area, "GameFontDisableSmall"); priceTop:SetPoint("TOPRIGHT", -3, -2); priceTop:SetJustifyH("RIGHT")
    local priceBottom = text(area, "GameFontDisableSmall"); priceBottom:SetPoint("BOTTOMRIGHT", -3, 3); priceBottom:SetJustifyH("RIGHT")
    local empty = text(area, "GameFontDisableSmall")
    empty:SetPoint("CENTER")
    empty:SetWidth(CHART_W - 30)
    empty:SetWordWrap(true)
    empty:SetJustifyH("CENTER")
    local legend = text(content, "GameFontDisableSmall")
    legend:SetPoint("TOPLEFT", x, y - 16 - CHART_H - 4)
    legend:SetWidth(CHART_W)
    local slot = CHART_W / CHART_BUCKETS
    local columns = {}
    for i = 1, CHART_BUCKETS do
        local col = CreateFrame("Frame", nil, area)
        col:SetPoint("BOTTOMLEFT", (i - 1) * slot, 0)
        col:SetSize(slot, CHART_H)
        col:EnableMouse(true)
        col:SetScript("OnEnter", function(self) U:ChartTooltip(self) end)
        col:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        local bar = area:CreateTexture(nil, "ARTWORK")
        bar:SetPoint("BOTTOMLEFT", (i - 1) * slot + 1, 1)
        bar:SetWidth(math.max(1, slot - 2))
        bar:SetColorTexture(.40, .62, .85, .55)
        local sold = area:CreateTexture(nil, "ARTWORK", nil, 1)
        sold:SetPoint("BOTTOMLEFT", (i - 1) * slot + 1, 1)
        sold:SetWidth(math.max(1, slot - 2))
        sold:SetColorTexture(.30, .76, .30, .9)
        sold:Hide()
        columns[i] = { frame = col, bar = bar, sold = sold }
    end
    self.chart = { area = area, range = range, qtyMax = qtyMax, priceTop = priceTop, priceBottom = priceBottom,
        empty = empty, legend = legend, columns = columns, lines = {}, slot = slot }
end

function U:ChartTooltip(col)
    local b = col.bucket
    if not b or not b.n or not GameTooltip then return end
    GameTooltip:SetOwner(col, "ANCHOR_TOP")
    GameTooltip:AddLine(ago(time() - b.t))
    GameTooltip:AddDoubleLine("Listed", count(b.q), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Lowest price", b.p and Money(b.p) or "none listed", 1, 1, 1, 1, 1, 1)
    if b.bought then GameTooltip:AddDoubleLine("Bought since the scan before", count(b.bought), 1, 1, 1, .3, .76, .3) end
    if b.n > 1 then GameTooltip:AddLine(b.n .. " scans", .6, .6, .6) end
    GameTooltip:Show()
end

-- Span to draw: from the oldest point (at most 7 days back) to now, and at
-- least an hour so a few quick scans don't fill the whole width.
local function chartSpan(history, now)
    local first = history[1] and history[1].t or now
    local from = math.max(first, now - 7 * 86400)
    if now - from < 3600 then from = now - 3600 end
    return from, now
end

function U:RefreshChart(a)
    local c, now = self.chart, time()
    local history = a.history or {}
    local from, to = chartSpan(history, now)
    local buckets = M.Buckets(history, from, to, CHART_BUCKETS, a.activity and a.activity.boughtAt)
    local maxQ, minP, maxP, points = 0, nil, nil, 0
    for _, b in ipairs(buckets) do
        if b.n then
            points = points + 1
            maxQ = math.max(maxQ, b.q)
            if b.p then minP = math.min(minP or b.p, b.p); maxP = math.max(maxP or b.p, b.p) end
        end
    end
    c.range:SetText(#history > 0 and ("since " .. ago(now - from)) or "")
    c.empty:SetShown(#history < 2)
    c.empty:SetText(#history == 0 and "No scans of this item yet. Scan it on the AH to start its history."
        or "One scan so far. Scan again later to see the price and volume move.")
    c.qtyMax:SetText(maxQ > 0 and (count(maxQ) .. " listed") or "")
    c.priceTop:SetText(maxP and Money(maxP) or "")
    c.priceBottom:SetText(minP and minP ~= maxP and Money(minP) or "")
    local plotH = CHART_H - 18 -- room for the labels at the top
    local lo, hi = minP or 0, maxP or 0
    if hi - lo < 1 then lo, hi = lo - 1, hi + 1 end
    local prev, used = nil, 0
    for i, b in ipairs(buckets) do
        local col = c.columns[i]
        col.frame.bucket = b
        if b.n and b.q > 0 and maxQ > 0 then
            col.bar:SetHeight(math.max(1, math.floor(plotH * b.q / maxQ)))
            col.bar:Show()
        else
            col.bar:Hide()
        end
        -- Units bought since the scan before, on the same scale, in front.
        if b.bought and b.bought > 0 and maxQ > 0 then
            col.sold:SetHeight(math.max(2, math.floor(plotH * math.min(b.bought, maxQ) / maxQ)))
            col.sold:Show()
        else
            col.sold:Hide()
        end
        if b.n and b.p then
            local px = (i - 0.5) * c.slot
            local py = 4 + (plotH - 8) * (b.p - lo) / (hi - lo)
            used = used + 1
            local seg = segment(c.area, c.lines, used)
            if seg.SetStartPoint then
                -- The first point gets a short tick so a lone price still shows.
                local sx, sy = prev and prev[1] or px - 2, prev and prev[2] or py
                seg:SetStartPoint("BOTTOMLEFT", c.area, sx, sy)
                seg:SetEndPoint("BOTTOMLEFT", c.area, prev and px or px + 2, py)
            else
                seg:ClearAllPoints()
                seg:SetPoint("CENTER", c.area, "BOTTOMLEFT", px, py)
            end
            seg:Show()
            prev = { px, py }
        end
    end
    for i = used + 1, #c.lines do c.lines[i]:Hide() end
    c.legend:SetText(color("ff66a0d9", "Listed") .. color(MUTED, "  ") .. color(GOOD, "Bought") ..
        color(MUTED, "  ") .. color(ACCENT, "Lowest price") .. color(MUTED, "  · " .. #history .. " scans"))
end

---------------------------------------------------------------------------
-- Tooltips
---------------------------------------------------------------------------
function U:CostTooltip(owner)
    local a = self.current
    if not a or not GameTooltip then return end
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    GameTooltip:AddLine("Your cost per unit")
    if a.costOverride then
        GameTooltip:AddLine("Your cost override. Clear it to use the vendor price.", 1, 1, 1, true)
    elseif a.vendor then
        local s = M.STANDING_BY_REACTION[a.standing]
        GameTooltip:AddLine(string.format("%s with %s%s.", s and s.label or "Neutral", a.vendor.npc or "the vendor",
            a.standingTime and (", seen " .. ago(time() - a.standingTime)) or ""), 1, 1, 1, true)
        local d = M.Discount(a.rules, a.standing)
        GameTooltip:AddLine(d > 0 and (d .. "% off the list price of " .. Money(a.baseUnit) .. ".")
            or ("Full list price. Honored and above get " .. M.Discount(a.rules, 6) .. "% off."), .8, .8, .8, true)
        local up = a.byStanding and a.byStanding[2]
        if up and M.Tier(a.standing) ~= M.TIERS[2] then
            GameTooltip:AddDoubleLine("At Honored you'd pay", Money(up.unitCost), .8, .8, .8, 1, 1, 1)
        end
        if #a.offers > 1 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Vendors you've seen selling it (cheapest at your standing first):", .8, .8, .8, true)
            for i, o in ipairs(a.offers) do
                if i > 6 then GameTooltip:AddLine("and " .. (#a.offers - 6) .. " more", .6, .6, .6); break end
                local st = M.STANDING_BY_REACTION[o.standing]
                local name = (o.vendor.npc or "Unknown vendor") .. (o.vendor.zone and (", " .. o.vendor.zone) or "")
                GameTooltip:AddDoubleLine((i == 1 and "> " or "") .. name .. " (" .. (st and st.label or "Neutral") .. ")",
                    Money(o.cost), i == 1 and 1 or .8, i == 1 and .82 or .8, i == 1 and 0 or .8, 1, 1, 1)
            end
        end
        GameTooltip:AddLine("Standing updates when you visit, target or mouse over a vendor.", .6, .6, .6, true)
    else
        GameTooltip:AddLine("Open this item's vendor to record its price.", 1, 1, 1, true)
    end
    if a.paidUnit then GameTooltip:AddDoubleLine("You last paid", Money(a.paidUnit), .8, .8, .8, 1, 1, 1) end
    GameTooltip:Show()
end

function U:RowTooltip(b)
    local row, a = b.row, self.current
    if not row or not GameTooltip or not a then return end
    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
    local venues = a.showNeutral and M.VENUES or { "faction" }
    local function profits(r)
        if not r.faction then return end
        for _, venue in ipairs(venues) do
            local name = venue == "faction" and "Faction" or "Neutral"
            GameTooltip:AddDoubleLine(name .. " profit per unit", Money(r[venue].profitUnit, true, true), 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine(name .. " profit, all stacks", Money(r[venue].profitTotal, true, true), 1, 1, 1, 1, 1, 1)
        end
    end
    if row.ghost then
        GameTooltip:AddLine("Your listing: " .. count(row.qty) .. " at " .. Money(row.price))
        GameTooltip:AddLine(row.ahead == 0 and "Nothing cheaper: yours sell first." or (count(row.ahead) .. " other units sell before yours."), 1, 1, 1)
        profits(row)
    elseif row.level then
        local l = row.level
        local who = l.seller and (" by " .. l.seller) or (l.sellers and l.sellers > 1 and (" by " .. l.sellers .. " sellers") or "")
        GameTooltip:AddLine(count(l.qty) .. " listed at " .. Money(l.price) .. who)
        if (l.mine or 0) > 0 then GameTooltip:AddLine(count(l.mine) .. " of them are yours", .8, .8, .8) end
        GameTooltip:AddLine("Undercut at " .. Money(row.listAt) .. ": " ..
            (row.ahead == 0 and "yours sell first." or (count(row.ahead) .. " units sell before yours.")), 1, 1, 1)
        profits(row)
        GameTooltip:AddLine("Click to list 1c under this price.", .6, .6, .6)
    else
        GameTooltip:AddLine(Money(row.price) .. " per unit")
        profits(row)
        GameTooltip:AddLine("Click to use this as your price.", .6, .6, .6)
    end
    GameTooltip:Show()
end

---------------------------------------------------------------------------
-- Commands from the view (write through Data, then republish)
---------------------------------------------------------------------------
function U:Changed() if self.onChanged then self.onChanged() end end

function U:SetQuery(q) self.query = q or ""; self:RequestList() end

-- Called after Blizzard inserts a shift-clicked link somewhere.
function U:InsertLink(link)
    if not self.search or not self.search:HasFocus() or type(link) ~= "string" then return end
    local id = A.ItemIDFromLink(link)
    if not id then return end
    self.search:SetText(tostring(id))
    self:SetQuery(tostring(id))
    self:Select(id)
end
function U:SetFilter(f) self.filter = f; self:RequestList() end

function U:SetSort(value)
    local ok, err = self.app:Set("listSort", value)
    warn(self.app, ok, err)
    self:RequestList()
end

-- Scan every item in the list, or stop a scan that's running.
function U:ToggleScanList()
    if P:QueueProgress() then P:StopQueue(); return end
    local ids = {}
    for _, row in ipairs(self.rows or {}) do ids[#ids + 1] = row.id end
    if not P:StartQueue(ids) and UIErrorsFrame then
        UIErrorsFrame:AddMessage(P.ahOpen and "Nothing to scan." or "Open the auction house to scan.", 1, .3, .3)
    end
end

function U:Select(id)
    self.selected = id
    self:RefreshDetail()
    self:RequestList()
    if id and P.ahOpen and self.app:Get("autoScan") then
        local scan = D:Scan(id)
        local stale = not scan or (time() - scan.time) > self.app:Get("scanFreshMinutes") * 60
        if stale then self:ScanSelected(true) end
    end
end

function U:SetPlan(key, value)
    if not self.selected then return end
    D:SetPlan(self.selected, key, value)
    self:Changed()
end

function U:ScanSelected(quiet)
    if not self.selected then return end
    local ok, why = P:Scan(self.selected)
    if ok and self.onScanStarted then self.onScanStarted() end
    if not ok and not quiet and UIErrorsFrame and why then UIErrorsFrame:AddMessage(why, 1, .3, .3) end
    self:RefreshDetail()
end

-- Buy every unit at or under your price that you can afford (a click only).
function U:BuyUnder()
    if not self.selected then return end
    local ok, why = ns.Snipe:BuyUnder(self.selected)
    if not ok and UIErrorsFrame and why then UIErrorsFrame:AddMessage(why, 1, .3, .3) end
    self:RefreshBuy()
end

-- The Buy button and your price for the selected item. Cheap: it redraws on
-- every search result and purchase step.
function U:RefreshBuy()
    if not self.buyButton or not self.panel or not self.panel:IsShown() then return end
    local id, N = self.selected, ns.Snipe
    if not id then return end
    local limit = N:Limit(id)
    self.limitInput:Set(limit)
    local p = N.purchase
    local label
    if p and p.under and p.id == id then
        label = "Buying..."
        self.buyButton.ready = false
    else
        local b, why = N:UnderLimit(id)
        if b then
            label = "Buy " .. count(b.qty) .. " for " .. Money(b.cost)
        elseif not limit then
            label = "Set a price"
        elseif why and why:find("^Only") then
            label = "Trade goods only"
        elseif why and why:find("^Not enough") then
            label = "Not enough gold"
        else
            label = "None that cheap"
        end
        self.buyButton.ready = b ~= nil
    end
    self.buyButton.label:SetText(label)
    self.buyButton:SetEnabled(P.ahOpen and self.buyButton.ready == true and not N:IsBusy())
end

function U:BuyTooltip(owner)
    if not GameTooltip or not self.selected then return end
    local N, id = ns.Snipe, self.selected
    local limit = N:Limit(id)
    local b, why = N:UnderLimit(id)
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    GameTooltip:AddLine("Buy under your price")
    if b then
        GameTooltip:AddLine(string.format("%s at %s or less, %s in all (up to %s each).", count(b.qty),
            Money(limit), Money(b.cost), Money(b.maxPrice)), 1, 1, 1, true)
        GameTooltip:AddLine("The game quotes the total before anything is paid. If cheaper units have gone and it comes to more than "
            .. Money(b.qty * limit) .. ", it's cancelled.", 1, 1, 1, true)
    else
        GameTooltip:AddLine(why or "Nothing to buy.", 1, 1, 1, true)
    end
    GameTooltip:AddLine("One press buys every unit at or under your price that you can afford, cheapest first. "
        .. "Scan AH to look again; the listings are read again after each buy.", .62, .6, .56, true)
    GameTooltip:Show()
end

function U:LimitTooltip(owner)
    if not GameTooltip then return end
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    GameTooltip:AddLine("The most you'll pay each")
    GameTooltip:AddLine("Buy takes every unit listed at this price or less. Kept until you log out or reload.", 1, 1, 1, true)
    GameTooltip:Show()
end

-- Units the Post button lists: your stacks x stack size, capped to your bags.
function U:PostQuantity()
    local a = self.current
    if not a then return 0 end
    return math.max(1, math.min(a.stackSize * a.stacks, a.bagCount > 0 and a.bagCount or a.stackSize * a.stacks))
end

function U:CanPostSelected()
    local a = self.current
    if not a then return false, "Pick an item." end
    return ns.Post:CanPost(a.id, self:PostQuantity(), a.price)
end

function U:PostSelected()
    local a = self.current
    if not a then return end
    local ok, why = ns.Post:Post(a.id, self:PostQuantity(), a.price, a.duration)
    if not ok and UIErrorsFrame and why then UIErrorsFrame:AddMessage(why, 1, .3, .3) end
    self:RefreshDetail()
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------
function U:RequestList() if self.onListRequested then self.onListRequested() else self:RefreshList() end end

function U:RefreshList()
    if not self.panel or not self.panel:IsShown() then return end
    local sort = self.app:Get("listSort")
    local rows = A.List(self.app, self.filter, self.query, ns.lastMerchant and ns.lastMerchant.npc, time(), sort)
    self.rows = rows
    if self.listBox and CreateDataProvider then
        self.listBox:SetDataProvider(CreateDataProvider(rows), ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition)
    end
    local where = ({ vendor = "vendor items", merchant = "from the last merchant", bags = "in your bags", all = "known items" })[self.filter]
    self.count:SetText(#rows .. " " .. (where or "items") .. " · profit/unit")
    local done, total = P:QueueProgress()
    self.scanAllButton.label:SetText(done and ("Stop " .. done .. "/" .. total) or "Scan list")
    self.scanAllButton:SetEnabled(P.ahOpen and (done ~= nil or #rows > 0))
    local sources = P:Available()
    local labels = {}
    for _, key in ipairs(sources) do labels[#labels + 1] = P.SOURCES[key].label end
    local all = ns.Earnings and ns.Earnings.Periods(time())[4].sum.profit
    self.status:SetText((P.ahOpen and color(GOOD, "AH open") or color(MUTED, "AH closed")) ..
        (#labels > 0 and color(MUTED, " · " .. table.concat(labels, ", ")) or "") ..
        (all and (color(MUTED, " · made ") .. Money(all, true, true)) or ""))
    self:CaptionFilter()
    for _, o in ipairs(self.sorts or {}) do
        if o.value == sort then self:Caption(self.sortDropdown, o.label) end
    end
end

local function sourceLabel(entry)
    if not entry then return "" end
    local label = entry.label
    if entry.age then label = label .. ", " .. ago(entry.age) end
    return label
end

function U:RefreshDetail()
    if not self.panel or not self.panel:IsShown() then return end
    local id = self.selected
    self.content:SetShown(id ~= nil)
    self.empty:SetShown(id == nil)
    if not id then self.current = nil; return end
    local a = A.Item(self.app, id, time())
    self.current = a
    local info = a.info

    self.icon:SetTexture(info.icon or 134400)
    local name = info.name
    if info.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[info.quality] then
        name = ITEM_QUALITY_COLORS[info.quality].hex .. name .. "|r"
    end
    self.title:SetText(name)
    local subParts = {}
    if a.vendor then
        local who = a.vendor.npc or "a vendor"
        if a.vendor.zone then who = who .. ", " .. a.vendor.zone end
        subParts[#subParts + 1] = "Sold by " .. who
        if a.vendor.limited then subParts[#subParts + 1] = "limited supply" end
        local others = #a.offers - 1
        if others > 0 then subParts[#subParts + 1] = others .. (others == 1 and " other vendor" or " other vendors") end
    else
        subParts[#subParts + 1] = "Item " .. id .. ", no vendor recorded"
    end
    subParts[#subParts + 1] = count(a.bagCount) .. " in bags"
    if a.sales then
        subParts[#subParts + 1] = "sold " .. count(a.sales.qty) .. " this week" ..
            (a.sales.profit and (", " .. Money(a.sales.profit, true, true)) or "")
    end
    self.sub:SetText(table.concat(subParts, " · "))

    local scanning = P:IsScanning(id)
    self.scanButton.label:SetText(scanning and "Scanning..." or "Scan AH")
    self.scanButton:SetEnabled(P.ahOpen and not scanning)
    local busy = ns.Post:IsBusy()
    self.postButton.label:SetText(busy and "Posting..." or ("Post " .. count(self:PostQuantity())))
    self.postButton:SetEnabled(self:CanPostSelected() == true)
    self:RefreshBuy()

    -- Stats
    local s = self.stats
    local buysAt = info.vendorPays > 0 and ("buys back at " .. Money(info.vendorPays)) or "can't sell to vendors"
    if a.baseUnit then
        s.vendor.value:SetText(Money(a.baseUnit) .. (a.vendor.qty > 1 and color(MUTED, " /" .. a.vendor.qty) or ""))
        s.vendor.sub:SetText(buysAt)
    else
        s.vendor.value:SetText(color(MUTED, "unknown"))
        s.vendor.sub:SetText(buysAt)
    end
    if a.unitCost then
        s.cost.value:SetText(Money(a.unitCost))
        local d = M.Discount(a.rules, a.standing)
        local sd = M.STANDING_BY_REACTION[a.standing]
        local basis = a.costOverride and "your override" or ((sd and sd.label or "Neutral") .. (d > 0 and (", " .. d .. "% off") or ", full price"))
        s.cost.sub:SetText(basis)
    else
        s.cost.value:SetText(color(MUTED, "unknown"))
        s.cost.sub:SetText(a.paidUnit and ("you paid " .. Money(a.paidUnit)) or "set a cost override")
    end
    local lowest = a.levels and a.levels[1]
    if lowest then
        s.market.value:SetText(Money(lowest.price) .. color(MUTED, " x" .. count(lowest.qty)))
        s.market.sub:SetText(count(a.listed) .. " listed, " .. ago(a.levelsAge))
    elseif a.market then
        s.market.value:SetText(Money(a.market.price))
        s.market.sub:SetText(sourceLabel(a.market))
    else
        s.market.value:SetText(color(MUTED, "no data"))
        s.market.sub:SetText(P.ahOpen and "press Scan AH" or "open the AH to scan")
    end

    -- Inputs
    local inputs = self.inputs
    if not inputs.stackSize:HasFocus() then inputs.stackSize:SetText(tostring(a.stackSize)) end
    if not inputs.stacks:HasFocus() then inputs.stacks:SetText(tostring(a.stacks)) end
    inputs.price:Set(a.price)
    inputs.cost:Set(a.costOverride)
    local kind = ({ yours = "your price", undercut = "1c under the cheapest", market = "market price (" .. sourceLabel(a.market) .. ")" })[a.priceKind]
    local priceNote = kind or "type a price"
    if a.ahead then priceNote = priceNote .. " · " .. (a.ahead == 0 and "sells first" or (count(a.ahead) .. " ahead")) end
    self.priceSub:SetText(priceNote)
    self:Caption(inputs.duration, U.DurationLabel(a.duration))

    -- Cards
    local hours = M.DURATION_HOURS[a.duration]
    local stackText = a.stacks == 1 and ("1 stack of " .. a.stackSize) or (a.stacks .. " stacks of " .. a.stackSize)
    for _, venue in ipairs(M.VENUES) do
        local card, r = self.cards[venue], a[venue]
        local cut = M.CutRate(a.rules, venue) * 100
        local here = P.ahOpen and a.venue == venue and color(GOOD, "  you're here") or ""
        card.head:SetText(string.format("%s AH · %s%% cut · %dh", venue == "faction" and "Faction" or "Neutral", cut, hours) .. here)
        if r and a.price then
            card.profit:SetText(Money(r.profitTotal, true, true) .. color(MUTED, "  for " .. stackText))
            card.line1:SetText("Per unit " .. Money(r.profitUnit, true, true) .. "   Margin " .. pct(r.margin) .. "   ROI " .. pct(r.roi))
            card.line2:SetText("Break-even " .. Money(math.ceil(r.breakEvenUnit)) .. " / unit")
            local depNote = a.gameDepositVenue == venue and " (from game)" or ""
            card.line3:SetText("Deposit " .. Money(r.deposit) .. depNote .. " · expect to lose " .. Money(r.lost))
        elseif r then
            card.profit:SetText(color(MUTED, "Set your price"))
            card.line1:SetText("Break-even " .. Money(math.ceil(r.breakEvenUnit)) .. " / unit")
            card.line2:SetText("Deposit " .. Money(r.deposit) .. " per stack")
            card.line3:SetText("")
        else
            card.profit:SetText(color(MUTED, "Cost unknown"))
            card.line1:SetText("Visit the vendor, or set a cost override.")
            card.line2:SetText("Deposit " .. Money(a.deposit[venue]) .. " per stack")
            card.line3:SetText("")
        end
    end
    self.cards.neutral.frame:SetShown(a.showNeutral)
    self.activityCard.frame:SetShown(not a.showNeutral)
    self:RefreshActivity(a)
    self:RefreshChart(a)

    self:RefreshTable(a)
end

local ACTIVITY_COLOR = { busy = GOOD, active = "ff9ccc4c", slow = ACCENT, stagnant = BAD }

-- How much is being bought, from the order books across your scans.
function U:RefreshActivity(a)
    local c, act = self.activityCard, a.activity
    c.head:SetText("Demand · last 7 days of scans")
    if act and act.level then
        local per = act.demandPerDay and ("  ~" .. units(act.demandPerDay) .. " bought a day") or ""
        c.profit:SetText(color(ACTIVITY_COLOR[act.key], act.level.label) .. color(MUTED, per))
        local flow = string.format("%s bought, %s newly listed in %s", units(act.bought), units(act.added), span(act.span))
        c.line1:SetText(act.flooding and color(BAD, "Supply piling up: ") .. flow or flow)
        if a.perDay then
            c.line2:SetText("If you list first: " .. Money(a.perDay, true, true) .. " a day")
        elseif act.turnover and act.turnover > 0 then
            c.line2:SetText("The market sells through every " .. span(86400 / act.turnover))
        else
            c.line2:SetText("")
        end
    else
        local head, detail = U.ActivityPending(act)
        c.profit:SetText(color(MUTED, head))
        c.line1:SetText(detail)
        c.line2:SetText("")
    end
    local last = act and act.last
    c.line3:SetText(last and (count(last.q) .. " listed " .. ago(time() - last.t)) or "")
end

-- Right-hand table: the live market (each price level, how many are listed
-- there, and profit if you undercut it, with a ghost row for your price), or
-- the what-if ladder around your price.
function U:RefreshTable(a)
    local mode = self.tableMode or (a.levels and "market" or "ladder")
    for key, tab in pairs(self.tableTabs) do
        local on = key == mode
        tab.line:SetShown(on)
        tab.label:SetTextColor(on and 1 or .62, on and .82 or .6, on and .2 or .56)
    end
    local neutral = a.showNeutral
    local heads = self.tableHeads
    heads[3]:SetText(neutral and "Faction" or "Profit")
    heads[4]:SetShown(neutral)
    local rows, note = {}, nil
    if mode == "market" then
        self.tablePer:SetText("per stack of " .. a.stackSize .. ", 1c under")
        heads[1]:SetText("Price")
        heads[2]:SetText("Qty")
        rows = a.marketRows or {}
        if not a.levels then
            rows = {}
            note = P.ahOpen and "No listings recorded yet. Press Scan AH, or open this item on the AH Buy or Auctions page."
                or "No listings recorded yet. Open the auction house and scan this item."
        elseif not a.plan then
            note = "Set a cost to see profit at each price."
        end
    else
        self.tablePer:SetText("profit per stack of " .. a.stackSize)
        heads[1]:SetText("Price / unit")
        heads[2]:SetText("")
        rows = a.ladder or {}
        if not a.plan then note = "Set a cost to see the ladder." end
    end
    self.tableNote:SetText(note or "")
    self.tableNote:SetShown(note ~= nil)

    local function best(row)
        if not row.faction then return nil end
        return neutral and math.max(row.faction.profit, row.neutral.profit) or row.faction.profit
    end
    local maxAbs = 1
    for _, row in ipairs(rows) do
        local b = best(row)
        if b then maxAbs = math.max(maxAbs, math.abs(b)) end
    end
    local offset = note and 3 or 0 -- leave room for the note
    for i, l in ipairs(self.ladder) do
        local row = i > offset and rows[i - offset] or nil
        l.button:SetShown(row ~= nil)
        if row then
            l.button.row = row
            local tag = row.tags and row.tags[1]
            if mode == "market" then
                l.button.price = (not row.ghost) and row.listAt or nil
                if row.ghost then
                    l.price:SetText(color(ACCENT, "> ") .. Money(row.price))
                    l.second:SetText(color(ACCENT, count(row.qty)))
                else
                    l.price:SetText(Money(row.price))
                    l.second:SetText(count(row.qty) .. (row.mine > 0 and color(ACCENT, "*") or ""))
                end
                l.mark:SetShown(row.ghost == true)
                l.mark:SetColorTexture(.91, .74, .33, row.ghost and .22 or .14)
            else
                l.button.price = row.price
                l.price:SetText(Money(row.price) .. (tag and color(ACCENT, " " .. tag) or ""))
                l.second:SetText("")
                l.mark:SetShown((a.price and row.price == a.price) or tag ~= nil)
                l.mark:SetColorTexture(.91, .74, .33, .14)
            end
            l.faction:SetText(row.faction and Money(row.faction.profit, true, true) or color(MUTED, "-"))
            l.neutral:SetText(row.neutral and Money(row.neutral.profit, true, true) or color(MUTED, "-"))
            l.neutral:SetShown(neutral)
            local b = best(row)
            if b then
                l.bar:SetWidth(math.max(1, math.floor((neutral and 136 or 68) * math.min(1, math.abs(b) / maxAbs))))
                if b >= 0 then l.bar:SetColorTexture(.05, .64, .05, .22) else l.bar:SetColorTexture(.82, .23, .23, .22) end
                l.bar:Show()
            else
                l.bar:Hide()
            end
        end
    end
end

function U:CaptionFilter()
    for _, f in ipairs(self.filters or {}) do
        if f.value == self.filter then self:Caption(self.filterDropdown, f.label) end
    end
end

function U:Refresh()
    self:RefreshList()
    self:RefreshDetail()
end

---------------------------------------------------------------------------
-- Hosting: AH tab or standalone window
---------------------------------------------------------------------------
function U:Window()
    if self.window then return self.window end
    local app = self.app
    local w = CreateFrame("Frame", "AuctionHouseProfitsWindow", UIParent, "BackdropTemplate")
    w:SetSize(820, 540)
    w:SetPoint("CENTER")
    w:SetFrameStrata("HIGH")
    w:SetMovable(true)
    w:EnableMouse(true)
    w:RegisterForDrag("LeftButton")
    w:SetScript("OnDragStart", w.StartMoving)
    w:SetScript("OnDragStop", w.StopMovingOrSizing)
    w:SetClampedToScreen(true)
    w:Hide()
    local ok, err = app.ui:Style(w, "dialog")
    warn(app, ok, err)
    local title = text(w, "GameFontNormal", "heading")
    title:SetPoint("TOPLEFT", 16, -12)
    title:SetText("Auction House Profits")
    local close = CreateFrame("Button", nil, w, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() w:Hide() end)
    w:SetScript("OnHide", function() if U.host == "window" then U:Detach() end end)
    if UISpecialFrames then table.insert(UISpecialFrames, "AuctionHouseProfitsWindow") end
    self.window = w
    return w
end

-- Lift our own frames above the host's content (only frames we created).
local function raise(frame, level)
    frame:SetFrameLevel(level)
    local children = { frame:GetChildren() }
    for _, child in ipairs(children) do
        raise(child, math.max(child:GetFrameLevel() or 0, level + 1))
    end
end

-- host = "ah" (frame = AuctionHouseFrame) or "window"
function U:ShowIn(host, frame)
    local panel = self:Build()
    if self.host == "ah" and host ~= "ah" and self.onLeaveAH then self.onLeaveAH() end
    panel:ClearAllPoints()
    self.top:ClearAllPoints()
    if host == "ah" then
        panel:SetParent(frame)
        panel:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -24)
        panel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 28)
        raise(panel, frame:GetFrameLevel() + 40)
        self.top:SetPoint("TOPLEFT", panel, "TOPLEFT", 56, 0) -- clear of the portrait
        self.top:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
        if self.window then self.window:Hide() end
    else
        local w = self:Window()
        panel:SetParent(w)
        panel:SetPoint("TOPLEFT", w, "TOPLEFT", 10, -32)
        panel:SetPoint("BOTTOMRIGHT", w, "BOTTOMRIGHT", -10, 10)
        raise(panel, w:GetFrameLevel() + 2)
        self.top:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
        self.top:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
        w:Show()
    end
    self.host = host
    panel:Show()
    if self.onShown then self.onShown() end
    self:Refresh()
end

function U:Detach()
    if not self.panel then return end
    self.panel:Hide()
    self.host = nil
    if self.onHidden then self.onHidden() end
end

function U:IsShown() return self.panel ~= nil and self.panel:IsShown() end

function U:ToggleWindow()
    if self.host == "window" and self:IsShown() then
        self.window:Hide()
    else
        self:ShowIn("window")
    end
end

function U:Init(app) self.app = app end
