-- Settings are owned by SND (AuctionHouseProfitsDB, profile-aware).
local _, ns = ...
local M = ns.Model

ns.SOURCE_CHOICES = {
    { value = "auto", label = "Automatic (best available)" },
    { value = "scan", label = "My AH scans" },
    { value = "auctionator", label = "Auctionator" },
    { value = "tsm", label = "TradeSkillMaster" },
    { value = "auctioneer", label = "Auctioneer" },
    { value = "manual", label = "Manual price only" },
}

function ns.ConfigureSettings(app)
    local sources = {}
    for i, c in ipairs(ns.SOURCE_CHOICES) do sources[i] = c.value end
    app:Settings({
        savedVariables = { "AuctionHouseProfitsDB" },
        fields = {
            cutFaction = { type = "number", default = 5, min = 0, max = 50, label = "Faction AH cut (%)" },
            cutNeutral = { type = "number", default = 15, min = 0, max = 50, label = "Neutral AH cut (%)" },
            depositPerHour = { type = "number", default = 2.5, min = 0, max = 25, label = "Deposit, % of vendor price per hour" },
            neutralMultiplier = { type = "number", default = 5, min = 1, max = 20, label = "Neutral deposit multiplier" },
            minDeposit = { type = "integer", default = 100, min = 0, max = 100000, label = "Minimum deposit (copper)" },
            useGameDeposit = { type = "boolean", default = true, label = "Ask the game for the exact deposit when the AH is open" },
            duration = { type = "enum", default = 3, values = { 1, 2, 3 }, label = "Default duration" },
            sellChance = { type = "integer", default = 70, min = 1, max = 100, label = "Chance a listing sells (%)" },
            maxListings = { type = "integer", default = 3, min = 0, max = 20, label = "Max listings per stack (0 = until sold)" },
            unsold = { type = "enum", default = "vendor", values = { "vendor", "keep", "zero" }, label = "Stacks that never sell" },
            defaultStacks = { type = "integer", default = 1, min = 1, max = 100, label = "Default number of stacks" },
            discountFriendly = { type = "number", default = 0, min = 0, max = 50, label = "Friendly discount (%)" },
            discountHonored = { type = "number", default = 10, min = 0, max = 50, label = "Honored discount (%)" },
            discountRevered = { type = "number", default = 10, min = 0, max = 50, label = "Revered discount (%)" },
            discountExalted = { type = "number", default = 10, min = 0, max = 50, label = "Exalted discount (%)" },
            priceSource = { type = "enum", default = "auto", values = sources, label = "Market price source" },
            scanFreshMinutes = { type = "integer", default = 120, min = 5, max = 1440, label = "AH scans count as fresh for (minutes)" },
            autoScan = { type = "boolean", default = true, label = "Scan the AH when I select an item" },
            recordMerchants = { type = "boolean", default = true, label = "Record vendor prices when I visit merchants" },
            openOnProfitsTab = { type = "boolean", default = false, label = "Open the auction house on the Profits tab" },
            theme = { type = "enum", default = "forever", values = { "forever", "modern" }, label = "Theme" },
        },
    })
end

-- Snapshot of the rules the model needs, read from committed settings.
function ns.Rules(app)
    return {
        cutFaction = app:Get("cutFaction"), cutNeutral = app:Get("cutNeutral"),
        depositPerHour = app:Get("depositPerHour"), neutralMultiplier = app:Get("neutralMultiplier"),
        minDeposit = app:Get("minDeposit"),
        discounts = {
            [4] = 0, [5] = app:Get("discountFriendly"), [6] = app:Get("discountHonored"),
            [7] = app:Get("discountRevered"), [8] = app:Get("discountExalted"),
        },
    }
end

local function durationChoices()
    local labels = { _G.AUCTION_DURATION_ONE, _G.AUCTION_DURATION_TWO, _G.AUCTION_DURATION_THREE }
    local out = {}
    for i, hours in ipairs(M.DURATION_HOURS) do
        out[i] = { value = i, label = type(labels[i]) == "string" and labels[i] or (hours .. " hours") }
    end
    return out
end

-- Live readout of what merchants actually charged you, per standing.
local function calibrationComponent()
    return {
        type = "custom", id = "calibration",
        create = function(parent)
            local text = parent.ahpCalibration
            if not text then
                text = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                text:SetPoint("TOPLEFT", 0, 0)
                text:SetJustifyH("LEFT")
                text:SetJustifyV("TOP")
                parent.ahpCalibration = text
            end
            local component = {}
            function component:Refresh()
                local lines = { "Discounts seen at merchants (vs. 4x vendor sell price):" }
                local any = false
                for _, s in ipairs(M.STANDINGS) do
                    local pct, n = ns.Data:Calibration(s.reaction)
                    if pct then
                        any = true
                        lines[#lines + 1] = string.format("  %s: about %s%% off (%d items)", s.label, pct, n)
                    end
                end
                if not any then lines[#lines + 1] = "  Nothing yet. Visit a vendor and this fills in." end
                text:SetText(table.concat(lines, "\n"))
            end
            function component:Layout(width)
                text:SetWidth(width)
                self:Refresh()
                return text:GetStringHeight() + 6
            end
            function component:Hide() end
            return component
        end,
    }
end

function ns.ConfigureOptions(app, SND)
    local profiles = SND.Pages.Profiles()
    return app:Options({
        title = "Auction House Profits",
        layout = { fieldWidth = 200, minLabelWidth = 220 },
        pages = {
            { id = "auction", label = "Auction house", sections = {
                { title = "Fees", controls = {
                    { type = "number", key = "cutFaction", label = "Faction AH cut (%)" },
                    { type = "number", key = "cutNeutral", label = "Neutral AH cut (%)" },
                    { type = "number", key = "depositPerHour", label = "Deposit, % of vendor price per hour",
                      hint = "8h = 20%, 12h = 30%, 24h = 60% of vendor price at 2.5." },
                    { type = "number", key = "neutralMultiplier", label = "Neutral deposit multiplier" },
                    { type = "number", key = "minDeposit", label = "Minimum deposit (copper)", hint = "100 = 1 silver." },
                    { type = "checkbox", key = "useGameDeposit", label = "Ask the game for the exact deposit when the AH is open" },
                } },
                { title = "Selling", controls = {
                    { type = "select", key = "duration", label = "Default duration", choices = durationChoices() },
                    { type = "slider", key = "sellChance", label = "Chance a listing sells (%)", step = 1 },
                    { type = "number", key = "maxListings", label = "Max listings per stack", hint = "0 keeps relisting until it sells." },
                    { type = "select", key = "unsold", label = "Stacks that never sell", choices = {
                        { value = "vendor", label = "Sell to a vendor" },
                        { value = "keep", label = "Keep (count at cost)" },
                        { value = "zero", label = "Write off" },
                    } },
                    { type = "number", key = "defaultStacks", label = "Default number of stacks" },
                } },
            } },
            { id = "reputation", label = "Reputation", sections = {
                { title = "Vendor discounts by standing", controls = {
                    { type = "number", key = "discountFriendly", label = "Friendly (%)" },
                    { type = "number", key = "discountHonored", label = "Honored (%)" },
                    { type = "number", key = "discountRevered", label = "Revered (%)" },
                    { type = "number", key = "discountExalted", label = "Exalted (%)" },
                    calibrationComponent(),
                } },
            } },
            { id = "prices", label = "Prices", sections = {
                { title = "Market price", controls = {
                    { type = "select", key = "priceSource", label = "Market price source", choices = ns.SOURCE_CHOICES },
                    { type = "number", key = "scanFreshMinutes", label = "AH scans count as fresh for (minutes)" },
                    { type = "checkbox", key = "autoScan", label = "Scan the AH when I select an item" },
                    { type = "checkbox", key = "recordMerchants", label = "Record vendor prices when I visit merchants" },
                } },
                { title = "Window", controls = {
                    { type = "checkbox", key = "openOnProfitsTab", label = "Open the auction house on the Profits tab" },
                    { type = "select", key = "theme", label = "Theme", choices = app.ui:Themes() },
                } },
            } },
            profiles,
        },
    })
end
