-- Pure model tests. Run from addon/: lua5.1 tests/model_test.lua
local ns = {}
assert(loadfile("AuctionHouseProfits/Model.lua"))("AuctionHouseProfits", ns)
local M = ns.Model

local total = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error(name .. ": " .. tostring(err), 0) end
    total = total + 1
    print("PASS " .. name)
end
local function near(a, b, tol, what)
    assert(math.abs(a - b) <= (tol or 0.01), string.format("%s: expected %.4f, got %.4f", what or "value", b, a))
end

local rules = { cutFaction = 5, cutNeutral = 15, depositPerHour = 2.5, neutralMultiplier = 5, minDeposit = 100,
    discounts = { [4] = 0, [5] = 0, [6] = 10, [7] = 10, [8] = 10 } }

test("money text", function()
    assert(M.MoneyText(0) == "0c")
    assert(M.MoneyText(12345) == "1g 23s 45c")
    assert(M.MoneyText(10000) == "1g")
    assert(M.MoneyText(-250) == "-2s 50c")
    assert(M.MoneyText(250, true) == "+2s 50c")
    assert(M.MoneyText(0.4, true) == "0c")
end)

test("parse money", function()
    assert(M.ParseMoney("1g 20s 5c") == 12005)
    assert(M.ParseMoney("1g20s") == 12000)
    assert(M.ParseMoney("20s") == 2000)
    assert(M.ParseMoney("350c") == 350)
    assert(M.ParseMoney("1.25") == 12500, "bare numbers are gold")
    assert(M.ParseMoney(" 2 ") == 20000)
    assert(M.ParseMoney("1.5g") == 15000)
    assert(M.ParseMoney("") == nil)
    assert(M.ParseMoney("abc") == nil)
    assert(M.ParseMoney("5g potato") == nil)
end)

test("deposits follow 2.5% per hour with a 1s floor", function()
    -- 8h/12h/24h = 20/30/60% of vendor price x quantity
    assert(M.FormulaDeposit(rules, 40, 20, 1, "faction") == 160)
    assert(M.FormulaDeposit(rules, 40, 20, 2, "faction") == 240)
    assert(M.FormulaDeposit(rules, 40, 20, 3, "faction") == 480)
    assert(M.FormulaDeposit(rules, 40, 20, 3, "neutral") == 2400)
    assert(M.FormulaDeposit(rules, 1, 1, 1, "faction") == 100, "minimum deposit applies")
    local r = { depositPerHour = 2.5, neutralMultiplier = 5, minDeposit = 1 }
    assert(M.FormulaDeposit(r, 0, 20, 3, "faction") == 1)
end)

test("odds of selling", function()
    local o = M.Odds(70, 3)
    near(o.pSold, 0.973, 1e-9, "pSold")
    near(o.expListings, 0.973 / 0.7, 1e-9, "listings")
    near(o.expFailed, 0.973 / 0.7 - 0.973, 1e-9, "failed")
    local u = M.Odds(50, 0)
    assert(u.pSold == 1); near(u.expListings, 2, 1e-9); near(u.expFailed, 1, 1e-9)
    local sure = M.Odds(100, 3)
    assert(sure.pSold == 1 and sure.expFailed == 0)
end)

local function plan(unitCost)
    return { stackSize = 20, stacks = 5, unitCost = unitCost or 600, vendorSellUnit = 40, unsold = "vendor",
        odds = M.Odds(70, 3), rules = rules,
        deposit = { faction = M.FormulaDeposit(rules, 40, 20, 3, "faction"), neutral = M.FormulaDeposit(rules, 40, 20, 3, "neutral") } }
end

test("evaluate matches hand-worked example", function()
    -- 20 x Runecloth bought at 6s each, listed at 9s each, faction AH, 24h.
    local r = M.Evaluate(plan(), "faction", 900, true)
    assert(r.buyout == 18000 and r.cut == 900 and r.deposit == 480)
    local lost = (0.973 / 0.7 - 0.973) * 480
    local revenue = 0.973 * 17100 + 0.027 * 800
    near(r.lost, lost, 1e-6, "lost deposits")
    near(r.profit, revenue - lost - 12000, 1e-6, "profit per stack")
    near(r.profitTotal, r.profit * 5, 1e-6, "total")
    near(r.breakEvenUnit, (12000 + lost - 0.027 * 800) / (0.973 * 0.95) / 20, 1e-6, "break-even")
    -- at break-even, continuous profit is zero
    local be = M.Evaluate(plan(), "faction", r.breakEvenUnit, false)
    near(be.profit, 0, 1e-6, "profit at break-even")
end)

test("neutral is worse with the same price", function()
    local f = M.Evaluate(plan(), "faction", 900, true)
    local n = M.Evaluate(plan(), "neutral", 900, true)
    assert(n.cut == 2700 and n.deposit == 2400)
    assert(n.profit < f.profit and n.breakEvenUnit > f.breakEvenUnit)
end)

test("unsold handling", function()
    local p = plan(); p.unsold = "zero"
    local zero = M.Evaluate(p, "faction", 900, true)
    p.unsold = "keep"
    local keep = M.Evaluate(p, "faction", 900, true)
    assert(keep.profit > zero.profit)
end)

test("reputation discounts", function()
    near(M.BaseUnitPrice(rules, 90, 6), 100, 1e-9, "honored price back to list")
    near(M.UnitCostAt(rules, 100, 4), 100, 1e-9)
    near(M.UnitCostAt(rules, 100, 8), 90, 1e-9)
    assert(M.Discount(rules, 99) == 0)
end)

test("ladder includes market and both break-evens, sorted high to low", function()
    local rows = M.Ladder(plan(), 900)
    local tags = {}
    for i, row in ipairs(rows) do
        if i > 1 then assert(rows[i - 1].price > row.price, "sorted") end
        for _, t in ipairs(row.tags) do tags[t] = row end
        assert(row.faction and row.neutral)
    end
    assert(tags.market and tags.market.price == 900)
    assert(tags["faction b/e"] and tags["neutral b/e"])
    assert(tags["faction b/e"].faction.profit >= 0, "rounded-up break-even is not a loss")
    -- Above 1g, break-even rows round up to the next silver, never down into a loss.
    local pricey = plan(9000)
    for _, row in ipairs(M.Ladder(pricey, 13000)) do
        for _, t in ipairs(row.tags) do
            if t == "faction b/e" then assert(row.faction.profit >= 0, "faction b/e row is not a loss") end
            if t == "neutral b/e" then assert(row.neutral.profit >= 0, "neutral b/e row is not a loss") end
        end
    end
    -- No market price: ladder centres on break-even instead.
    local blind = M.Ladder(plan(), nil)
    assert(#blind >= 5)
end)

test("nice prices", function()
    assert(M.NicePrice(12345) == 12300)
    assert(M.NicePrice(987.6) == 988)
end)

test("discount calibration", function()
    assert(M.SampleRatio(36, 10) == 0.9)
    assert(M.SampleRatio(400, 10) == nil, "outliers ignored")
    assert(M.SampleRatio(10, 0) == nil)
    local pct, n = M.MedianDiscount({ 0.9, 0.9, 0.91, 0.89, 0.9 })
    assert(pct == 10 and n == 5)
    local none = M.MedianDiscount({})
    assert(none == nil)
    assert(M.MedianDiscount({ 1, 1 }) == 0)
    assert(M.MedianDiscount({ 0.95, 0.95 }) == 5)
end)

print(total .. " model tests passed")
