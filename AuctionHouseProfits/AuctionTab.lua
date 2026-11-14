-- Adds a "Profits" tab to the auction house.
-- The tab lives in our own holder frame so its template's parentArray never
-- touches AuctionHouseFrame.Tabs. Opening it switches the AH to an empty,
-- addon-owned display mode: Blizzard's own SetDisplayMode then hides every
-- Buy/Sell/Auctions subframe (some sit at frame level 350 or HIGH strata, so
-- an overlay alone would leave e.g. the Post button clickable). The mode has
-- no tab index, so Blizzard leaves tab selection to us. Blizzard tabs are only
-- observed through additive hooks.
local ADDON, ns = ...
local U, M = ns.UI, ns.Model
local T = { attached = false, hooked = {} }
ns.AuctionTab = T

local TAB_GAP = -15 -- Blizzard_AuctionHouseFrame.xml spaces its tabs by -15
local PROFITS_MODE = {} -- empty display mode: no Blizzard subframes, no tab

local function blizzardTabs()
    local ah = AuctionHouseFrame
    return type(ah) == "table" and type(ah.Tabs) == "table" and ah.Tabs or {}
end

-- The right-most tab under the AH frame, whoever added it. Auctionator and
-- others add their own tabs after Blizzard's, so "last Blizzard tab" isn't
-- enough: we'd sit on top of theirs. Tabs are buttons hanging below the
-- frame's bottom edge. Also returns the tab before it, to copy the spacing.
function T:LastTab()
    local ah = AuctionHouseFrame
    local tabs = blizzardTabs()
    local bottom = ah and ah.GetBottom and ah:GetBottom()
    if not bottom then return tabs[#tabs], tabs[#tabs - 1] end
    local seen, row = {}, {}
    local function consider(f)
        if type(f) ~= "table" or seen[f] or f == self.tab or f == self.holder then return end
        seen[f] = true
        if not f.GetObjectType or f:GetObjectType() ~= "Button" or not f:IsShown() then return end
        local top, right, left = f:GetTop(), f:GetRight(), f:GetLeft()
        if top and right and left and top <= bottom + 6 and top >= bottom - 40 then row[#row + 1] = f end
    end
    for _, tab in ipairs(tabs) do consider(tab) end
    for _, child in ipairs({ ah:GetChildren() }) do
        consider(child)
        if type(child) == "table" and child.GetObjectType and child:GetObjectType() == "Frame" and child.GetChildren then
            for _, grandchild in ipairs({ child:GetChildren() }) do consider(grandchild) end
        end
    end
    if #row == 0 then return tabs[#tabs], tabs[#tabs - 1] end
    table.sort(row, function(a, b) return a:GetRight() < b:GetRight() end)
    return row[#row], row[#row - 1]
end

-- Blizzard's tab art has transparent edges, so its tabs overlap by 15px.
-- Other addons' tabs (Auctionator's) may be drawn edge to edge with a gap.
-- Use whatever spacing the last two tabs have between them.
function T:Gap(last, prev)
    if not last or not prev or not last.GetLeft or not prev.GetRight then return TAB_GAP end
    local l, r = last:GetLeft(), prev:GetRight()
    local gap = M.Number(l) and M.Number(r) and l - r or nil
    if not gap or gap < -20 or gap > 20 then return TAB_GAP end
    return math.floor(gap + 0.5)
end

function T:Reanchor()
    local last, prev = self:LastTab()
    if not self.tab or not last then return end
    self.tab:ClearAllPoints()
    -- An addon tab anchored (indirectly) to ours would make a cycle; fall
    -- back to Blizzard's last tab rather than erroring.
    if not pcall(self.tab.SetPoint, self.tab, "LEFT", last, "RIGHT", self:Gap(last, prev), 0) then
        local tabs = blizzardTabs()
        self.tab:ClearAllPoints()
        if tabs[#tabs] then self.tab:SetPoint("LEFT", tabs[#tabs], "RIGHT", TAB_GAP, 0) end
    end
end

function T:RestoreBlizzardTabs()
    local ah = AuctionHouseFrame
    if not ah then return end
    local selected = PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(ah)
    for i, tab in ipairs(blizzardTabs()) do
        if i == selected then PanelTemplates_SelectTab(tab) else PanelTemplates_DeselectTab(tab) end
    end
end

function T:Open()
    local ah = AuctionHouseFrame
    if not ah or not ah:IsShown() then return end
    if SOUNDKIT and PlaySound then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB) end
    if type(ah.SetDisplayMode) == "function" then ah:SetDisplayMode(PROFITS_MODE) end
    -- Blizzard (and Auctionator) set their own titles when you switch back.
    if type(ah.SetTitle) == "function" then ah:SetTitle("Auction House Profits") end
    U:ShowIn("ah", ah)
    for _, tab in ipairs(blizzardTabs()) do PanelTemplates_DeselectTab(tab) end
    PanelTemplates_SelectTab(self.tab)
end

function T:Close()
    if U.host == "ah" then U:Detach() end
    if self.tab then PanelTemplates_DeselectTab(self.tab) end
    self:RestoreBlizzardTabs()
end

-- The view is moving to the standalone window: give the AH its Buy page back.
function T:Release()
    local ah = AuctionHouseFrame
    if self.tab then PanelTemplates_DeselectTab(self.tab) end
    if ah and ah.displayMode == PROFITS_MODE and AuctionHouseFrameDisplayMode and ah:IsShown() then
        ah:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
    end
    self:RestoreBlizzardTabs()
end

function T:IsOpen() return U.host == "ah" and U:IsShown() end

-- Hook any Blizzard (or other addon) tab we haven't seen yet.
function T:HookTabs(owner)
    for _, tab in ipairs(blizzardTabs()) do
        if not self.hooked[tab] then
            local ok, err = owner:HookScript(tab, "OnClick", function() if T:IsOpen() then T:Close() end end)
            if not ok then return false, err end
            self.hooked[tab] = true
        end
    end
    return true
end

function T:Attach(app, core)
    if self.attached then return true end
    local ah = AuctionHouseFrame
    if type(ah) ~= "table" or #blizzardTabs() == 0 then return false end

    if not self.tab then
        local holder = CreateFrame("Frame", nil, ah)
        holder:SetSize(1, 1)
        holder:SetPoint("BOTTOMLEFT")
        local ok, tab = pcall(CreateFrame, "Button", "AuctionHouseProfitsAHTab", holder, "AuctionHouseFrameTabTemplate")
        if not ok then ok, tab = pcall(CreateFrame, "Button", "AuctionHouseProfitsAHTab", holder, "PanelTabButtonTemplate") end
        if not ok then
            app.log:Warn("Could not create the auction house tab")
            return false
        end
        tab:SetText("Profits")
        -- Blizzard drops a selected tab's label 5px; next to other addons'
        -- tabs (which are rarely selected) that reads as misaligned.
        tab.selectedTextY = tab.deselectedTextY or 2
        tab:SetScript("OnClick", function() T:Open() end)
        self.tab, self.holder = tab, holder
        PanelTemplates_DeselectTab(tab)
    end
    self:Reanchor()

    -- One owner per attempt: on any failure, cancel it so a retry starts clean.
    local owner = app:Scope()
    local function check(ok, err)
        if not ok then owner:Cancel(); app.log:Warn("Auction house hook failed: " .. (err and err.message or "?")) end
        return ok
    end
    if not check(self:HookTabs(owner)) then return false end
    if not check(owner:PostHook(ah, "SetDisplayMode", function(_, mode)
        if mode ~= PROFITS_MODE and T:IsOpen() then T:Close() end
    end)) then return false end
    if not check(owner:HookScript(ah, "OnHide", function() T:Close() end)) then return false end
    if not check(owner:HookScript(ah, "OnShow", function()
        T:Reanchor()
        T:HookTabs(owner)
        -- Other addons may add their tabs during this same OnShow.
        core:After(0, "ah-reanchor", function() T:Reanchor() end)
        core:After(0.5, "ah-reanchor-late", function() T:Reanchor() end)
        if app:Get("openOnProfitsTab") then
            core:After(0, "ah-open-profits", function() T:Open() end)
        end
    end)) then return false end
    U.onLeaveAH = function() T:Release() end
    self.attached = true
    return true
end
