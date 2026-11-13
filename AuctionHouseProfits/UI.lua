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
    end
    return frame
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

function U:BuildDetail(body)
    local app = self.app
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
    local title = text(content, "GameFontNormalLarge", "heading")
    title:SetPoint("TOPLEFT", iconButton, "TOPRIGHT", 8, -1)
    title:SetPoint("RIGHT", -110, 0)
    self.title = title
    local sub = text(content, "GameFontDisableSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    sub:SetPoint("RIGHT", -110, 0)
    self.sub = sub
    local scan = button(content, "scan", "Scan AH", 100)
    scan:SetPoint("TOPRIGHT", 0, -4)
    scan:SetScript("OnClick", function() U:ScanSelected() end)
    self.scanButton = scan

    -- Price stats
    local y = -44
    self.stats = {
        vendor = stat(content, 0, y, 125, "Vendor price"),
        cost = stat(content, 132, y, 125, "Your cost"),
        market = stat(content, 264, y, 140, "Market price"),
        sell = stat(content, 411, y, 120, "Vendor buys at"),
    }

    -- Inputs
    y = -90
    local stackBox = labeled(content, "stackSize", "input", "Stack size", 0, y, 60)
    bindInput(stackBox, function(v) U:SetPlan("stackSize", tonumber(v) and math.max(1, math.floor(tonumber(v))) or nil) end,
        function() return U.current and tostring(U.current.stackSize) end)
    local stacksBox = labeled(content, "stacks", "input", "Stacks", 68, y, 50)
    bindInput(stacksBox, function(v) U:SetPlan("stacks", tonumber(v) and math.max(1, math.floor(tonumber(v))) or nil) end,
        function() return U.current and tostring(U.current.stacks) end)
    local duration = labeled(content, "duration", "dropdown", "Duration", 126, y, 92)
    duration:SetupMenu(function(_, root)
        local labels = { _G.AUCTION_DURATION_ONE, _G.AUCTION_DURATION_TWO, _G.AUCTION_DURATION_THREE }
        for i, hours in ipairs(M.DURATION_HOURS) do
            local label = type(labels[i]) == "string" and labels[i] or (hours .. " hours")
            root:CreateRadio(label, function() return U.current and U.current.duration == i end,
                function() U:SetPlan("duration", i) end, i)
        end
    end)
    local standing = labeled(content, "standing", "dropdown", "Buy at standing", 226, y, 110)
    standing:SetupMenu(function(_, root)
        for _, s in ipairs(M.STANDINGS) do
            root:CreateRadio(s.label, function() return U.current and U.current.standing == s.reaction end,
                function() U:SetPlan("standing", s.reaction) end, s.reaction)
        end
    end)
    local manual = labeled(content, "manual", "input", "Your price / unit", 344, y, 90)
    bindInput(manual, function(v) U:SetManual(v) end, function()
        local m = U.selected and D:Manual(U.selected)
        return m and M.MoneyText(m) or ""
    end)
    local cost = labeled(content, "cost", "input", "Cost override / unit", 442, y, 90)
    bindInput(cost, function(v) U:SetCostOverride(v) end, function()
        local c = U.current and U.current.costOverride
        return c and M.MoneyText(c) or ""
    end)
    self.inputs = { stackSize = stackBox, stacks = stacksBox, duration = duration, standing = standing, manual = manual, cost = cost }

    -- Faction vs neutral cards
    y = -134
    self.cards = {}
    for i, venue in ipairs(M.VENUES) do
        local card = section(content)
        card:SetPoint("TOPLEFT", (i - 1) * 270, y)
        card:SetSize(262, 82)
        local strip = card:CreateTexture(nil, "ARTWORK")
        strip:SetPoint("TOPLEFT", 3, -3)
        strip:SetPoint("BOTTOMLEFT", 3, 3)
        strip:SetWidth(3)
        local c = venue == "faction" and FACTION_COLOR or NEUTRAL_COLOR
        strip:SetColorTexture(c[1], c[2], c[3], 1)
        local head = text(card, "GameFontNormalSmall")
        head:SetPoint("TOPLEFT", 12, -7)
        local profit = text(card, "GameFontHighlightLarge")
        profit:SetPoint("TOPLEFT", 12, -21)
        local line1 = text(card, "GameFontHighlightSmall")
        line1:SetPoint("TOPLEFT", 12, -42)
        line1:SetPoint("RIGHT", -8, 0)
        local line2 = text(card, "GameFontDisableSmall")
        line2:SetPoint("TOPLEFT", 12, -56)
        line2:SetPoint("RIGHT", -8, 0)
        local line3 = text(card, "GameFontDisableSmall")
        line3:SetPoint("TOPLEFT", 12, -68)
        line3:SetPoint("RIGHT", -8, 0)
        self.cards[venue] = { frame = card, head = head, profit = profit, line1 = line1, line2 = line2, line3 = line3 }
    end

    -- Reputation table
    y = -224
    local repTitle = text(content, "GameFontNormalSmall")
    repTitle:SetPoint("TOPLEFT", 0, y)
    repTitle:SetText("Buying at each standing (profit per unit)")
    self.repTitle = repTitle
    self.repRows = {}
    for i = 0, #M.STANDINGS do
        local r = {}
        local rowY = y - 16 - i * ROW_H
        r.name = text(content, i == 0 and "GameFontDisableSmall" or "GameFontHighlightSmall")
        r.name:SetPoint("TOPLEFT", 0, rowY); r.name:SetWidth(62)
        r.cost = text(content, i == 0 and "GameFontDisableSmall" or "GameFontHighlightSmall")
        r.cost:SetPoint("TOPLEFT", 64, rowY); r.cost:SetWidth(66); r.cost:SetJustifyH("RIGHT")
        r.faction = text(content, i == 0 and "GameFontDisableSmall" or "GameFontHighlightSmall")
        r.faction:SetPoint("TOPLEFT", 134, rowY); r.faction:SetWidth(62); r.faction:SetJustifyH("RIGHT")
        r.neutral = text(content, i == 0 and "GameFontDisableSmall" or "GameFontHighlightSmall")
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

    -- Price ladder
    local lx = 270
    local ladderTitle = text(content, "GameFontNormalSmall")
    ladderTitle:SetPoint("TOPLEFT", lx, y)
    ladderTitle:SetText("Profit per stack at each price")
    local heads = text(content, "GameFontDisableSmall")
    heads:SetPoint("TOPLEFT", lx, y - 16)
    heads:SetText("Price / unit")
    local hf = text(content, "GameFontDisableSmall")
    hf:SetPoint("TOPLEFT", lx + 78, y - 16); hf:SetWidth(84); hf:SetJustifyH("RIGHT"); hf:SetText("Faction")
    local hn = text(content, "GameFontDisableSmall")
    hn:SetPoint("TOPLEFT", lx + 164, y - 16); hn:SetWidth(84); hn:SetJustifyH("RIGHT"); hn:SetText("Neutral")
    self.ladder = {}
    for i = 1, LADDER_ROWS do
        local rowY = y - 16 - i * ROW_H
        local b = CreateFrame("Button", nil, content)
        b:SetPoint("TOPLEFT", lx - 2, rowY + 1)
        b:SetSize(258, ROW_H)
        local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, .07)
        local mark = b:CreateTexture(nil, "BACKGROUND"); mark:SetAllPoints(); mark:SetColorTexture(.91, .74, .33, .14)
        local bar = b:CreateTexture(nil, "BORDER"); bar:SetPoint("LEFT", 80, 0); bar:SetHeight(ROW_H - 4)
        local price = text(b, "GameFontHighlightSmall"); price:SetPoint("LEFT", 2, 0); price:SetWidth(78)
        local f = text(b, "GameFontHighlightSmall"); f:SetPoint("LEFT", 80, 0); f:SetWidth(84); f:SetJustifyH("RIGHT")
        local n = text(b, "GameFontHighlightSmall"); n:SetPoint("LEFT", 166, 0); n:SetWidth(84); n:SetJustifyH("RIGHT")
        b:SetScript("OnClick", function(self) if self.price then U:SetManualCopper(self.price) end end)
        b:SetScript("OnEnter", function(self)
            if not self.row or not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(Money(self.row.price) .. " per unit")
            for _, venue in ipairs(M.VENUES) do
                local r = self.row[venue]
                GameTooltip:AddDoubleLine((venue == "faction" and "Faction" or "Neutral") .. " profit, all stacks",
                    Money(r.profitTotal, true, true), 1, 1, 1, 1, 1, 1)
            end
            GameTooltip:AddLine("Click to use this as your price.", .6, .6, .6)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        self.ladder[i] = { button = b, mark = mark, bar = bar, price = price, faction = f, neutral = n }
    end
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

function U:SetManualCopper(copper)
    if not self.selected then return end
    D:SetManual(self.selected, copper)
    self:Changed()
end

function U:SetManual(textValue)
    if not self.selected then return end
    local copper = M.ParseMoney(textValue or "")
    if (textValue or ""):match("^%s*$") then copper = nil end
    if copper == nil and not (textValue or ""):match("^%s*$") then return self:Refresh() end
    D:SetManual(self.selected, copper)
    self:Changed()
end

function U:SetCostOverride(textValue)
    if not self.selected then return end
    local blank = (textValue or ""):match("^%s*$")
    local copper = not blank and M.ParseMoney(textValue) or nil
    if not blank and not copper then return self:Refresh() end
    D:SetPlan(self.selected, "cost", copper)
    self:Changed()
end

function U:ScanSelected(quiet)
    if not self.selected then return end
    local ok, why = P:Scan(self.selected)
    if ok and self.onScanStarted then self.onScanStarted() end
    if not ok and not quiet and UIErrorsFrame and why then UIErrorsFrame:AddMessage(why, 1, .3, .3) end
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
    self.count:SetText(#rows .. " " .. (where or "items"))
    local sources = P:Available()
    local labels = {}
    for _, key in ipairs(sources) do labels[#labels + 1] = P.SOURCES[key].label end
    self.status:SetText((P.ahOpen and color(GOOD, "AH open") or color(MUTED, "AH closed")) ..
        (#labels > 0 and color(MUTED, " · " .. table.concat(labels, ", ")) or ""))
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
    local subParts = { "Item " .. id }
    if a.vendor then
        local who = a.vendor.npc or "a vendor"
        if a.vendor.zone then who = who .. ", " .. a.vendor.zone end
        subParts[#subParts + 1] = "Sold by " .. who
        if a.vendor.limited then subParts[#subParts + 1] = "limited supply" end
    else
        subParts[#subParts + 1] = "No vendor recorded"
    end
    self.sub:SetText(table.concat(subParts, " · "))

    local scanning = P:IsScanning(id)
    self.scanButton.label:SetText(scanning and "Scanning..." or "Scan AH")
    self.scanButton:SetEnabled(P.ahOpen and not scanning)

    -- Stats
    local s = self.stats
    if a.baseUnit then
        s.vendor.value:SetText(Money(a.baseUnit))
        s.vendor.sub:SetText(a.vendor.qty > 1 and ("sold in " .. a.vendor.qty .. "s") or "per unit, no discount")
    else
        s.vendor.value:SetText(color(MUTED, "unknown"))
        s.vendor.sub:SetText("visit the vendor")
    end
    if a.unitCost then
        s.cost.value:SetText(Money(a.unitCost))
        local st = M.STANDING_BY_REACTION[a.standing]
        s.cost.sub:SetText(a.costOverride and "your override" or ((st and st.label or "") .. ", " .. M.Discount(a.rules, a.standing) .. "% off"))
    else
        s.cost.value:SetText(color(MUTED, "unknown"))
        s.cost.sub:SetText("set a cost override")
    end
    if a.market then
        s.market.value:SetText(Money(a.market.price))
        s.market.sub:SetText(sourceLabel(a.market))
    else
        s.market.value:SetText(color(MUTED, "no data"))
        s.market.sub:SetText(P.ahOpen and "press Scan AH" or "open the AH or set a price")
    end
    s.sell.value:SetText(info.sellPrice > 0 and Money(info.sellPrice) or color(MUTED, "can't sell"))
    s.sell.sub:SetText("per unit")

    -- Inputs
    local inputs = self.inputs
    if not inputs.stackSize:HasFocus() then inputs.stackSize:SetText(tostring(a.stackSize)) end
    if not inputs.stacks:HasFocus() then inputs.stacks:SetText(tostring(a.stacks)) end
    if not inputs.manual:HasFocus() then
        local m = D:Manual(id); inputs.manual:SetText(m and M.MoneyText(m) or "")
    end
    if not inputs.cost:HasFocus() then inputs.cost:SetText(a.costOverride and M.MoneyText(a.costOverride) or "") end
    for _, key in ipairs({ "duration", "standing" }) do
        local dd = inputs[key]
        if dd.GenerateMenu and not (dd.IsMenuOpen and dd:IsMenuOpen()) then dd:GenerateMenu() end
    end

    -- Cards
    local hours = M.DURATION_HOURS[a.duration]
    for _, venue in ipairs(M.VENUES) do
        local card, r = self.cards[venue], a[venue]
        local cut = M.CutRate(a.rules, venue) * 100
        card.head:SetText(string.format("%s AH · %s%% cut · %dh", venue == "faction" and "Faction" or "Neutral", cut, hours))
        if r and a.market then
            card.profit:SetText(Money(r.profitTotal, true, true) .. color(MUTED, string.format("  for %d x %d", a.stacks, a.stackSize)))
            card.line1:SetText("Per unit " .. Money(r.profitUnit, true, true) .. "   Margin " .. pct(r.margin) .. "   ROI " .. pct(r.roi))
            card.line2:SetText("Break-even " .. Money(math.ceil(r.breakEvenUnit)) .. " / unit")
            local depNote = a.gameDepositVenue == venue and " (from game)" or ""
            card.line3:SetText("Deposit " .. Money(r.deposit) .. depNote .. " · expect to lose " .. Money(r.lost))
        elseif r then
            card.profit:SetText(color(MUTED, "No market price"))
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
    for i, st in ipairs(M.STANDINGS) do
        local r, row = self.repRows[i], a.byStanding and a.byStanding[i]
        local mine = st.reaction == a.standing
        r.name:SetText(mine and color(ACCENT, st.label) or st.label)
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
        local st = M.STANDING_BY_REACTION[a.vendor.reaction or 4]
        local note = "Price recorded at " .. (st and st.label or "Neutral")
        if seen then note = note .. "; merchants there charged about " .. seen .. "% under list" end
        self.repNote:SetText(note .. ". Edit discounts in Options.")
    end

    -- Ladder
    local rows = a.ladder or {}
    local maxAbs = 1
    for _, row in ipairs(rows) do maxAbs = math.max(maxAbs, math.abs(row.faction.profit), math.abs(row.neutral.profit)) end
    for i, l in ipairs(self.ladder) do
        local row = rows[i]
        l.button:SetShown(row ~= nil)
        if row then
            l.button.row, l.button.price = row, row.price
            local tag = row.tags[1]
            l.price:SetText(Money(row.price) .. (tag and color(ACCENT, " " .. tag) or ""))
            l.faction:SetText(Money(row.faction.profit, true, true))
            l.neutral:SetText(Money(row.neutral.profit, true, true))
            l.mark:SetShown(tag ~= nil)
            local best = math.max(row.faction.profit, row.neutral.profit)
            local w = math.max(1, math.floor(170 * math.min(1, math.abs(best) / maxAbs)))
            l.bar:SetWidth(w)
            if best >= 0 then l.bar:SetColorTexture(.05, .64, .05, .22) else l.bar:SetColorTexture(.82, .23, .23, .22) end
        end
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
