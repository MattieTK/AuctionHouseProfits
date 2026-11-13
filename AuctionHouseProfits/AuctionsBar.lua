-- A post/relist strip on Blizzard's Auctions tab, in the item header that
-- shows when you pick one of your items. Blizzard frames are only observed
-- through additive hooks; the strip is our own frame parented to theirs.
local ADDON, ns = ...
local M, D, P, A, S, U = ns.Model, ns.Data, ns.Prices, ns.Analysis, ns.Post, ns.UI
local B = { attached = false }
ns.AuctionsBar = B

local GOOD, BAD, MUTED = "ff4cc24c", "ffee7a7a", "ff9d9a8f"
local function color(hex, s) return "|c" .. hex .. s .. "|r" end

local function auctionsFrame()
    local ah = AuctionHouseFrame
    return type(ah) == "table" and type(ah.AuctionsFrame) == "table" and ah.AuctionsFrame or nil
end

local function blizzButton(parent, label, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(label)
    return b
end

local function tip(frame, fn)
    frame:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        fn(GameTooltip)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
end

function B:Build(af)
    local bar = CreateFrame("Frame", "AuctionHouseProfitsAuctionsBar", af)
    bar:SetSize(384, 70)
    bar:SetPoint("RIGHT", af.ItemDisplay, "RIGHT", -44, -2)
    bar:SetFrameLevel((af.ItemDisplay:GetFrameLevel() or 1) + 10)
    bar:Hide()
    self.bar = bar

    local undercut = blizzButton(bar, "Undercut", 76)
    undercut:SetPoint("TOPLEFT", 0, 0)
    undercut:SetScript("OnClick", function() B:UsePrice("undercut") end)
    tip(undercut, function(t)
        local a = B.analysis
        local lowest, level = M.LowestOther(a and a.levels)
        t:AddLine("Undercut")
        if lowest then
            t:AddLine(string.format("List at %s, 1c under the %s other units at %s.",
                U.Money(math.max(1, lowest - 1)), BreakUpLargeNumbers and BreakUpLargeNumbers(level.qty - level.mine) or (level.qty - level.mine),
                U.Money(lowest)), 1, 1, 1, true)
        else
            t:AddLine("No other sellers seen yet.", 1, 1, 1, true)
        end
    end)
    local match = blizzButton(bar, "Match", 60)
    match:SetPoint("LEFT", undercut, "RIGHT", 2, 0)
    match:SetScript("OnClick", function() B:UsePrice("match") end)
    tip(match, function(t)
        t:AddLine("Match")
        t:AddLine("List at the cheapest other price. Units already listed at that price sell first.", 1, 1, 1, true)
    end)

    local qtyLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    qtyLabel:SetPoint("LEFT", match, "RIGHT", 10, 0)
    qtyLabel:SetText("Qty")
    local qty = CreateFrame("EditBox", nil, bar, "InputBoxTemplate")
    qty:SetSize(36, 20)
    qty:SetPoint("LEFT", qtyLabel, "RIGHT", 8, 0)
    qty:SetAutoFocus(false)
    qty:SetNumeric(true)
    qty:SetMaxLetters(5)
    local function commitQty(box)
        if box.cancelling then return end
        local n = tonumber(box:GetText())
        n = n and n >= 1 and math.floor(n) or nil
        if n ~= box.shown then B.qty = n end -- unchanged text keeps the default
        B:Refresh()
    end
    qty:SetScript("OnEnterPressed", function(box) commitQty(box); box:ClearFocus() end)
    qty:SetScript("OnEditFocusLost", commitQty)
    qty:SetScript("OnEscapePressed", function(box)
        box.cancelling = true; box:ClearFocus(); box.cancelling = nil
        B:Refresh()
    end)
    self.qtyBox = qty

    local money = U.MoneyInput(bar, function(parent)
        local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
        box:SetAutoFocus(false)
        return box
    end, function(copper)
        B.price = copper
        B:Refresh()
    end)
    money:SetPoint("LEFT", qty, "RIGHT", 12, 0)
    self.money = money

    local post = blizzButton(bar, "Post", 96)
    post:SetPoint("TOPLEFT", 0, -25)
    post:SetScript("OnClick", function() B:Post() end)
    tip(post, function(t)
        local ok, why = B:CanPost()
        t:AddLine(ok and "Post from your bags" or (why or "Can't post"))
        if B.analysis then
            t:AddLine(string.format("%s, %s in your bags.", (M.DURATION_HOURS[B.analysis.duration] or "?") .. "h",
                B.analysis.bagCount or 0), 1, 1, 1)
        end
    end)
    self.postButton = post

    local quote = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    quote:SetPoint("LEFT", post, "RIGHT", 8, 0)
    quote:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
    quote:SetJustifyH("LEFT")
    quote:SetWordWrap(false)
    self.quote = quote

    local owned = bar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    owned:SetPoint("TOPLEFT", 2, -54)
    owned:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
    owned:SetJustifyH("LEFT")
    owned:SetWordWrap(false)
    self.owned = owned
end

-- Which of your items Blizzard's Auctions tab is showing, if any.
local function selectedItem(af)
    if not af:IsShown() or not af.ItemDisplay:IsShown() then return nil end
    if type(af.IsDisplayingBids) == "function" and af:IsDisplayingBids() then return nil end
    local key = type(af.GetItemKey) == "function" and af:GetItemKey()
    local id = type(key) == "table" and key.itemID
    return M.Number(id) and not (issecretvalue and issecretvalue(id)) and id or nil
end

function B:Update()
    local af = auctionsFrame()
    if not af or not self.bar then return end
    local id = selectedItem(af)
    if id ~= self.itemID then self.itemID, self.qty, self.price = id, nil, nil end
    self.bar:SetShown(id ~= nil)
    if id then self:Refresh() end
end

function B:Defaults(a)
    local qty = self.qty or math.max(1, math.min(a.stackSize, a.bagCount > 0 and a.bagCount or a.stackSize))
    local price = self.price or a.undercut or a.price
    return qty, price
end

function B:UsePrice(kind)
    local a = self.analysis
    if not a or not a.levels then return end
    local lowest = M.LowestOther(a.levels)
    if not lowest then return end
    self.price = kind == "match" and lowest or M.Undercut(a.levels, S.CopperAllowed())
    self:Refresh()
end

function B:CanPost()
    if not self.itemID or not self.analysis then return false, "Pick an item." end
    local qty, price = self:Defaults(self.analysis)
    return S:CanPost(self.itemID, qty, price)
end

function B:Post()
    if not self.itemID or not self.analysis then return end
    local qty, price = self:Defaults(self.analysis)
    local ok, why = S:Post(self.itemID, qty, price, self.analysis.duration)
    if not ok and UIErrorsFrame and why then UIErrorsFrame:AddMessage(why, 1, .3, .3) end
    self:Refresh()
end

function B:Refresh()
    if not self.bar or not self.bar:IsShown() or not self.itemID then return end
    local now = time()
    local a = A.Item(self.app, self.itemID, now)
    self.analysis = a
    local qty, price = self:Defaults(a)

    if not self.qtyBox:HasFocus() then self.qtyBox:SetText(tostring(qty)); self.qtyBox.shown = qty end
    self.money:Set(price)
    local hasOthers = M.LowestOther(a.levels) ~= nil
    self.postButton:SetText(S:IsBusy() and "Posting..." or ("Post " .. qty))
    self.postButton:SetEnabled(self:CanPost() == true)

    if price then
        local q = A.Quote(self.app, self.itemID, qty, price, now)
        local parts = {}
        if q.profit then
            parts[#parts + 1] = "If sold " .. U.Money(q.profit, true, true) .. color(MUTED, " (" .. U.Money(q.profitUnit, true, true) .. color(MUTED, " each)"))
        else
            parts[#parts + 1] = color(MUTED, "Cost unknown")
        end
        parts[#parts + 1] = color(MUTED, "deposit ") .. U.Money(q.deposit)
        if q.ahead then
            parts[#parts + 1] = (q.ahead == 0 and color(GOOD, "first in line") or color(MUTED, (BreakUpLargeNumbers and BreakUpLargeNumbers(q.ahead) or q.ahead) .. " ahead"))
        end
        self.quote:SetText(table.concat(parts, color(MUTED, " · ")))
    else
        self.quote:SetText(color(MUTED, hasOthers and "Set a price." or "No listings seen yet. Set a price."))
    end

    -- What your auctions of this item made.
    local o = S:Owned(self.itemID)
    local parts = {}
    if o and o.listed > 0 then
        local cheapest
        for _, p in ipairs(o.prices) do if not cheapest or p.price < cheapest then cheapest = p.price end end
        parts[#parts + 1] = "Yours: " .. o.listed .. " listed" .. (cheapest and (" at " .. U.Money(cheapest)) or "")
    end
    local unitCost = A.CostBasis(self.app, self.itemID, now)
    if o and o.sold > 0 then
        local r = M.SaleProfit(o.soldGross, o.sold, unitCost, M.CutRate(a.rules, a.venue))
        parts[#parts + 1] = o.sold .. " sold" .. (r.profit and (", " .. U.Money(r.profit, true, true) .. color(MUTED, " profit")) or "")
    end
    local week = a.sales
    if week and week.profit then
        parts[#parts + 1] = "7 days: " .. U.Money(week.profit, true, true)
    end
    if unitCost then parts[#parts + 1] = "cost " .. U.Money(unitCost) .. "/unit" end
    self.owned:SetText(table.concat(parts, " · "))
end

function B:Attach(app, core)
    if self.attached then return true end
    local af = auctionsFrame()
    if not af or type(af.ItemDisplay) ~= "table" then return false end
    self.app = app
    if not self.bar then self:Build(af) end
    local owner = app:Scope()
    local function check(ok, err)
        if not ok then owner:Cancel(); app.log:Warn("Auctions tab hook failed: " .. (err and err.message or "?")) end
        return ok
    end
    local update = function() B:Update() end
    for _, method in ipairs({ "SetItemKey", "SetDisplayMode", "SetTab" }) do
        if type(af[method]) == "function" and not check(owner:PostHook(af, method, update)) then return false end
    end
    if not check(owner:HookScript(af, "OnShow", update)) then return false end
    if not check(owner:HookScript(af, "OnHide", update)) then return false end
    if not check(owner:HookScript(af.ItemDisplay, "OnShow", update)) then return false end
    if not check(owner:HookScript(af.ItemDisplay, "OnHide", update)) then return false end
    self.attached = true
    self:Update()
    return true
end
