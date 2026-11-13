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
    f:SetSize(152, 22)
    local widths = { 46, 26, 26 }
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
    search:SetSize(LIST_W - 6, 22)
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
    filter:SetSize(150, 22)
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

    local gear = button(top, "options", "Options", 70)
    gear:SetPoint("RIGHT", -8, 0)
    gear:SetScript("OnClick", function()
        local ok, err = ns.Options:Toggle()
        warn(app, ok, err)
    end)
    local status = text(top, "GameFontDisableSmall")
    status:SetPoint("RIGHT", gear, "LEFT", -10, 0)
    status:SetJustifyH("RIGHT")
    self.status = status

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
    count:SetWidth(LIST_W - 12)
    self.count = count

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
        row.name = text(row)
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
        row.name:SetPoint("RIGHT", row.value, "LEFT", -6, 0)
        row:SetScript("OnClick", function(self) U:Select(self.data.id) end)
        row:SetScript("OnEnter", function(self)
            if self.data.link and GameTooltip then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(self.data.link)
                GameTooltip:Show()
            end
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

local function count(n)
    if not M.Number(n) then return "?" end
    return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)
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
    local post = button(content, "post", "Post", 86)
    post:SetPoint("RIGHT", scan, "LEFT", -6, 0)
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
    title:SetPoint("RIGHT", post, "LEFT", -8, 0)
    self.title = title
    local sub = text(content, "GameFontDisableSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    sub:SetPoint("RIGHT", post, "LEFT", -8, 0)
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

    -- Plan inputs
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
    local standing = labeled(content, "standing", "dropdown", "Buy at standing", 206, y, 100)
    standing:SetupMenu(function(_, root)
        for _, s in ipairs(M.STANDINGS) do
            root:CreateRadio(s.label, function() return U.current and U.current.standing == s.reaction end,
                function() U:SetPlan("standing", s.reaction) end, s.reaction)
        end
    end)
    local costLabel = text(content, "GameFontNormalSmall")
    costLabel:SetPoint("TOPLEFT", 314, y)
    costLabel:SetText("Cost override / unit")
    local cost = U.MoneyInput(content, function(parent, i) return control(parent, "cost" .. i, "input") end,
        function(copper) U:SetPlan("cost", copper) end)
    cost:SetPoint("TOPLEFT", 314, y - 13)
    local reset = button(content, "reset-price", "Reset", 60)
    reset:SetPoint("TOPLEFT", 472, y - 13)
    reset:SetScript("OnClick", function() U:SetPlan("price", nil) end)
    reset:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Reset your price")
        GameTooltip:AddLine("Go back to 1c under the cheapest other seller from your last scan.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    reset:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    self.inputs = { stackSize = stackBox, stacks = stacksBox, duration = duration, standing = standing, price = price, cost = cost }

    -- Faction vs neutral cards
    y = -138
    self.cards = {}
    for i, venue in ipairs(M.VENUES) do
        local card = section(content)
        card:SetPoint("TOPLEFT", (i - 1) * 270, y)
        card:SetSize(262, 80)
        local strip = card:CreateTexture(nil, "ARTWORK")
        strip:SetPoint("TOPLEFT", 3, -3)
        strip:SetPoint("BOTTOMLEFT", 3, 3)
        strip:SetWidth(3)
        local c = venue == "faction" and FACTION_COLOR or NEUTRAL_COLOR
        strip:SetColorTexture(c[1], c[2], c[3], 1)
        local head = text(card, "GameFontNormalSmall")
        head:SetPoint("TOPLEFT", 12, -7)
        head:SetPoint("RIGHT", -8, 0)
        local profit = text(card, "GameFontHighlightLarge")
        profit:SetPoint("TOPLEFT", 12, -21)
        profit:SetPoint("RIGHT", -8, 0)
        local line1 = text(card, "GameFontHighlightSmall")
        line1:SetPoint("TOPLEFT", 12, -41)
        line1:SetPoint("RIGHT", -8, 0)
        local line2 = text(card, "GameFontDisableSmall")
        line2:SetPoint("TOPLEFT", 12, -54)
        line2:SetPoint("RIGHT", -8, 0)
        local line3 = text(card, "GameFontDisableSmall")
        line3:SetPoint("TOPLEFT", 12, -66)
        line3:SetPoint("RIGHT", -8, 0)
        self.cards[venue] = { frame = card, head = head, profit = profit, line1 = line1, line2 = line2, line3 = line3 }
    end

    -- Reputation table
    y = -226
    local repTitle = text(content, "GameFontNormalSmall")
    repTitle:SetPoint("TOPLEFT", 0, y)
    repTitle:SetText("Profit per unit, by standing")
    self.repTitle = repTitle
    self.repRows = {}
    for i = 0, #M.STANDINGS do
        local r = {}
        local rowY = y - 16 - i * ROW_H
        local font = i == 0 and "GameFontDisableSmall" or "GameFontHighlightSmall"
        r.name = text(content, font)
        r.name:SetPoint("TOPLEFT", 0, rowY); r.name:SetWidth(62)
        r.cost = text(content, font)
        r.cost:SetPoint("TOPLEFT", 64, rowY); r.cost:SetWidth(66); r.cost:SetJustifyH("RIGHT")
        r.faction = text(content, font)
        r.faction:SetPoint("TOPLEFT", 134, rowY); r.faction:SetWidth(62); r.faction:SetJustifyH("RIGHT")
        r.neutral = text(content, font)
        r.neutral:SetPoint("TOPLEFT", 198, rowY); r.neutral:SetWidth(62); r.neutral:SetJustifyH("RIGHT")
        self.repRows[i] = r
    end
    self.repRows[0].name:SetText("Standing")
    self.repRows[0].cost:SetText("Cost")
    self.repRows[0].faction:SetText("Faction")
    self.repRows[0].neutral:SetText("Neutral")
    local repNote = text(content, "GameFontDisableSmall")
    repNote:SetPoint("TOPLEFT", 0, y - 16 - (#M.STANDINGS + 1) * ROW_H - 4)
    repNote:SetWidth(262)
    repNote:SetWordWrap(true)
    self.repNote = repNote

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
    hf:SetPoint("TOPLEFT", lx + 120, y - 16); hf:SetWidth(68); hf:SetJustifyH("RIGHT"); hf:SetText("Faction")
    local hn = text(content, "GameFontDisableSmall")
    hn:SetPoint("TOPLEFT", lx + 190, y - 16); hn:SetWidth(68); hn:SetJustifyH("RIGHT"); hn:SetText("Neutral")
    self.tableHeads = { h1, h2 }
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

function U:RowTooltip(b)
    local row = b.row
    if not row or not GameTooltip then return end
    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
    GameTooltip:AddLine(Money(row.price) .. " per unit")
    if row.undercuts then
        local l = row.undercuts
        local others = l.qty - (l.mine or 0)
        GameTooltip:AddLine(string.format("1c under %s at %s%s", count(others), Money(l.price),
            l.seller and (" (" .. l.seller .. ")") or (l.sellers and l.sellers > 1 and (" (" .. l.sellers .. " sellers)") or "")), 1, 1, 1)
        GameTooltip:AddLine(row.ahead == 0 and "Nothing cheaper: yours sell first." or (count(row.ahead) .. " units sell before yours."), .8, .8, .8)
    end
    if row.faction then
        for _, venue in ipairs(M.VENUES) do
            local r = row[venue]
            GameTooltip:AddDoubleLine((venue == "faction" and "Faction" or "Neutral") .. " profit per unit",
                Money(r.profitUnit, true, true), 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine((venue == "faction" and "Faction" or "Neutral") .. " profit, all stacks",
                Money(r.profitTotal, true, true), 1, 1, 1, 1, 1, 1)
        end
    end
    GameTooltip:AddLine("Click to use this as your price.", .6, .6, .6)
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
    local rows = A.List(self.app, self.filter, self.query, ns.lastMerchant and ns.lastMerchant.npc, time())
    if self.listBox and CreateDataProvider then
        self.listBox:SetDataProvider(CreateDataProvider(rows), ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition)
    end
    local where = ({ vendor = "vendor items", merchant = "from the last merchant", bags = "in your bags", all = "known items" })[self.filter]
    self.count:SetText(#rows .. " " .. (where or "items") .. " · profit per unit")
    local sources = P:Available()
    local labels = {}
    for _, key in ipairs(sources) do labels[#labels + 1] = P.SOURCES[key].label end
    self.status:SetText((P.ahOpen and color(GOOD, "AH open") or color(MUTED, "AH closed")) ..
        (#labels > 0 and color(MUTED, " · " .. table.concat(labels, ", ")) or ""))
    self:CaptionFilter()
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

    -- Stats
    local s = self.stats
    local buysAt = info.sellPrice > 0 and ("buys back at " .. Money(info.sellPrice)) or "can't sell to vendors"
    if a.baseUnit then
        s.vendor.value:SetText(Money(a.baseUnit) .. (a.vendor.qty > 1 and color(MUTED, " /" .. a.vendor.qty) or ""))
        s.vendor.sub:SetText(buysAt)
    else
        s.vendor.value:SetText(color(MUTED, "unknown"))
        s.vendor.sub:SetText(buysAt)
    end
    if a.unitCost then
        s.cost.value:SetText(Money(a.unitCost))
        local st = M.STANDING_BY_REACTION[a.standing]
        local basis = a.costOverride and "your override" or ((st and st.label or "") .. ", " .. M.Discount(a.rules, a.standing) .. "% off")
        if a.paidUnit then basis = basis .. ", paid " .. Money(a.paidUnit) end
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
    local st = M.STANDING_BY_REACTION[a.standing]
    self:Caption(inputs.standing, st and st.label or "")

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

    -- Standing table
    self.repTitle:SetText("Profit per unit at " .. (a.price and Money(a.price) or "your price") .. ", by standing")
    for i, sd in ipairs(M.STANDINGS) do
        local r, row = self.repRows[i], a.byStanding and a.byStanding[i]
        local mine = sd.reaction == a.standing
        r.name:SetText(mine and color(ACCENT, sd.label) or sd.label)
        r.cost:SetText(row and Money(row.unitCost) or color(MUTED, "-"))
        r.faction:SetText(row and row.faction and Money(row.faction.profitUnit, true, true) or color(MUTED, "-"))
        r.neutral:SetText(row and row.neutral and Money(row.neutral.profitUnit, true, true) or color(MUTED, "-"))
    end
    local seen = a.vendor and a.vendor.reaction and select(1, D:Calibration(a.vendor.reaction))
    if a.costOverride then
        self.repNote:SetText("Using your cost override, so standing doesn't apply.")
    elseif not a.baseUnit then
        self.repNote:SetText("Open this item's vendor to record its price.")
    else
        local sv = M.STANDING_BY_REACTION[a.vendor.reaction or 4]
        local note = "Price recorded at " .. (sv and sv.label or "Neutral")
        if seen then note = note .. "; merchants there charged about " .. seen .. "% under list" end
        self.repNote:SetText(note .. ". Edit discounts in Options.")
    end

    self:RefreshTable(a)
end

-- Right-hand table: where you'd sit in the AH queue at each price, or the
-- what-if ladder around your price.
function U:RefreshTable(a)
    local mode = self.tableMode or (a.levels and "market" or "ladder")
    for key, tab in pairs(self.tableTabs) do
        local on = key == mode
        tab.line:SetShown(on)
        tab.label:SetTextColor(on and 1 or .62, on and .82 or .6, on and .2 or .56)
    end
    self.tablePer:SetText("profit per stack of " .. a.stackSize)
    local rows, note = {}, nil
    if mode == "market" then
        self.tableHeads[1]:SetText("List at")
        self.tableHeads[2]:SetText("Ahead")
        rows = a.positions or {}
        if not a.levels then
            note = P.ahOpen and "No listings recorded yet. Press Scan AH, or open this item on the AH Buy or Auctions page."
                or "No listings recorded yet. Open the auction house and scan this item."
        elseif #rows == 0 then
            note = "Only your own auctions are listed. Set any price you like."
        elseif not a.plan then
            note = "Set a cost to see profit at each price."
        end
    else
        self.tableHeads[1]:SetText("Price / unit")
        self.tableHeads[2]:SetText("")
        rows = a.ladder or {}
        if not a.plan then note = "Set a cost to see the ladder." end
    end
    self.tableNote:SetText(note or "")
    self.tableNote:SetShown(note ~= nil)

    local maxAbs = 1
    for _, row in ipairs(rows) do
        if row.faction then maxAbs = math.max(maxAbs, math.abs(row.faction.profit), math.abs(row.neutral.profit)) end
    end
    local offset = note and 3 or 0 -- leave room for the note
    for i, l in ipairs(self.ladder) do
        local row = i > offset and rows[i - offset] or nil
        l.button:SetShown(row ~= nil)
        if row then
            l.button.row, l.button.price = row, row.price
            local tag = row.tags and row.tags[1]
            local current = a.price and row.price == a.price
            if mode == "market" then
                l.price:SetText(Money(row.price))
                l.second:SetText(row.ahead == 0 and color(GOOD, "0") or count(row.ahead))
            else
                l.price:SetText(Money(row.price) .. (tag and color(ACCENT, " " .. tag) or ""))
                l.second:SetText("")
            end
            l.faction:SetText(row.faction and Money(row.faction.profit, true, true) or color(MUTED, "-"))
            l.neutral:SetText(row.neutral and Money(row.neutral.profit, true, true) or color(MUTED, "-"))
            l.mark:SetShown(current or (mode == "ladder" and tag ~= nil))
            if row.faction then
                local best = math.max(row.faction.profit, row.neutral.profit)
                l.bar:SetWidth(math.max(1, math.floor(136 * math.min(1, math.abs(best) / maxAbs))))
                if best >= 0 then l.bar:SetColorTexture(.05, .64, .05, .22) else l.bar:SetColorTexture(.82, .23, .23, .22) end
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
