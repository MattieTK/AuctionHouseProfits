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

test("ladder includes your price and both break-evens, sorted high to low", function()
    local rows = M.Ladder(plan(), 900)
    local tags = {}
    for i, row in ipairs(rows) do
        if i > 1 then assert(rows[i - 1].price > row.price, "sorted") end
        for _, t in ipairs(row.tags) do tags[t] = row end
        assert(row.faction and row.neutral)
    end
    assert(tags.yours and tags.yours.price == 900)
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

test("gold, silver and copper boxes", function()
    assert(M.Coins("1", "20", "5") == 12005)
    assert(M.Coins("", "20", "48") == 2048)
    assert(M.Coins("", "", "98") == 98)
    assert(M.Coins("2", "", "") == 20000)
    assert(M.Coins("", "", "") == nil, "all blank clears")
    assert(M.Coins("1.5", "", "") == nil, "whole numbers only")
    assert(M.Coins("x", "", "") == nil)
    assert(M.Coins(nil, nil, 7) == 7)
end)

-- The Fine Thread queue from the in-game recording: 77 at 96c, 1,172 at 98c
-- (plus 7 of yours), 8 more at 98c, 16 at 99c, 471 at 1s 2c.
local queue = {
    { price = 96, qty = 77, sellers = 2 },
    { price = 98, qty = 1172, seller = "Uncle Havoki" },
    { price = 98, qty = 7, mine = 7 },
    { price = 98, qty = 8 },
    { price = 99, qty = 16 },
    { price = 102, qty = 471, sellers = 4 },
}

test("market levels merge prices and split out your units", function()
    local levels = M.Levels(queue)
    assert(#levels == 4)
    assert(levels[1].price == 96 and levels[1].qty == 77)
    assert(levels[2].price == 98 and levels[2].qty == 1187 and levels[2].mine == 7)
    assert(levels[2].seller == "Uncle Havoki")
    assert(#M.Levels(queue, 2) == 2, "limit keeps the cheapest")
    assert(#M.Levels({ { price = 0, qty = 5 }, { price = 10, qty = 0 } }) == 0, "ignores junk")
end)

test("queue position and undercut", function()
    local levels = M.Levels(queue)
    assert(M.AheadAt(levels, 95) == 0)
    assert(M.AheadAt(levels, 96) == 77, "same price: the older listings sell first")
    assert(M.AheadAt(levels, 98) == 77 + 1180, "your own units don't count against you")
    assert(M.Undercut(levels) == 95)
    assert(M.LowestOther(levels) == 96)
    -- Only your own units at the bottom: undercut the cheapest other seller.
    local mineFirst = M.Levels({ { price = 50, qty = 3, mine = 3 }, { price = 60, qty = 10 } })
    assert(M.Undercut(mineFirst) == 59 and M.LowestOther(mineFirst) == 60)
    assert(M.Undercut({}) == nil)
    assert(M.Undercut(M.Levels({ { price = 1, qty = 5 } })) == 1, "never below 1c")
    -- Clients without copper prices: whole silver, 1s under.
    assert(M.Undercut(M.Levels({ { price = 2100, qty = 5 } }), false) == 2000)
    assert(M.PostablePrice(2099, false) == 2000 and M.PostablePrice(50, false) == 100 and M.PostablePrice(2099.7) == 2099)
    assert(M.Positions(levels, nil, nil, false)[1].price == 100, "95c rounds to the 1s floor")
end)

test("positions: 1c under each level, with profit", function()
    local levels = M.Levels(queue)
    local p = plan(60)
    local rows = M.Positions(levels, p)
    assert(rows[1].price == 95 and rows[1].ahead == 0)
    assert(rows[2].price == 97 and rows[2].ahead == 77)
    assert(rows[3].price == 98 and rows[3].ahead == 1257, "1c under 99c ties with the 98c queue")
    assert(rows[4].price == 101)
    assert(rows[1].faction and rows[1].neutral and rows[1].faction.profit > rows[1].neutral.profit)
    assert(#M.Positions(levels, nil, 2) == 2 and M.Positions(levels)[1].faction == nil)
end)

test("market rows: quantity at each level, and a ghost for your price", function()
    local levels = M.Levels(queue) -- 96 x77, 98 x1187 (7 yours), 99 x16, 102 x471
    local rows = M.MarketRows(levels, plan(60), 98, 20)
    assert(#rows == 5)
    assert(rows[1].price == 96 and rows[1].qty == 77 and rows[1].listAt == 95 and rows[1].ahead == 0)
    assert(rows[2].price == 98 and rows[2].qty == 1187 and rows[2].mine == 7)
    assert(rows[3].ghost and rows[3].price == 98 and rows[3].qty == 20, "ghost queues behind the 98c units")
    assert(rows[3].ahead == 77 + 1180 and rows[3].faction, "others at or under your price sell first")
    assert(rows[4].price == 99 and rows[5].price == 102)
    local first = M.MarketRows(levels, nil, 90, 5)
    assert(first[1].ghost and first[1].ahead == 0 and first[1].faction == nil)
    -- A long market keeps the ghost visible when trimmed.
    local trimmed = M.MarketRows(levels, nil, 200, 5, 3)
    assert(#trimmed == 3 and trimmed[3].ghost and trimmed[1].price == 96 and trimmed[2].price == 98)
    assert(#M.MarketRows(levels, nil, nil) == 4, "no price, no ghost")
end)

test("depth round-trips as text", function()
    local text = M.EncodeDepth({ { price = 288, qty = 35 }, { price = 289, qty = 1 } }, true)
    assert(text == "288:35,289:1+")
    local levels, cut = M.DecodeDepth(text)
    assert(#levels == 2 and levels[1].price == 288 and levels[2].qty == 1 and cut)
    local empty, emptyCut = M.DecodeDepth("")
    assert(#empty == 0 and not emptyCut and M.DecodeDepth(nil) == nil)
end)

local function book(text) return (M.DecodeDepth(text)) end

test("order books: buying takes the cheap end, supply adds, cancels sit apart", function()
    -- Only new supply: everything that was there still is.
    local c = M.CompareDepth(book("288:35,290:1"), false, book("288:35,290:1,300:10"), false)
    assert(c.bought == 0 and c.added == 10 and c.removed == 0)
    -- Buyers ate 79 of the cheapest level.
    c = M.CompareDepth(book("20:379,25:473"), false, book("20:300,25:473"), false)
    assert(c.bought == 79 and c.added == 0)
    -- The 288s sold out and someone undercut at 287: 35 bought, 20 new.
    c = M.CompareDepth(book("288:35,289:5"), false, book("287:20,289:5"), false)
    assert(c.bought == 35 and c.added == 20 and c.removed == 0)
    -- Dear units vanished while cheap ones sat there: cancelled, not bought.
    c = M.CompareDepth(book("10:5,50:20"), false, book("10:5"), false)
    assert(c.bought == 0 and c.removed == 20)
    -- Levels past where the newer book was cut off aren't counted as gone.
    c = M.CompareDepth(book("10:5,20:5,90:50"), false, book("10:2,20:5"), true)
    assert(c.bought == 3 and c.removed == 0)
    -- Sold out completely.
    c = M.CompareDepth(book("10:5,11:3"), false, book(""), false)
    assert(c.bought == 8)
end)

test("demand: rated by what's bought, not by the listed count moving", function()
    local now = 1000000
    local function hist(books, step)
        local h = {}
        for i, d in ipairs(books) do
            local levels = book(d)
            local q = 0; for _, l in ipairs(levels) do q = q + l.qty end
            h[i] = { t = now - (#books - i) * step, p = levels[1] and levels[1].price, q = q, d = d }
        end
        return h
    end
    -- Count changes every scan, but only because supply keeps arriving.
    local piling = M.Activity(hist({ "288:35,290:1", "288:35,290:1,295:5", "288:35,290:6,295:5",
        "288:35,290:6,295:9", "288:35,290:6,295:9,300:20" }, 3600), now, 7)
    assert(piling.bought == 0 and piling.added == 34 and piling.key == "stagnant" and piling.flooding,
        "more supply, no demand: stagnant")
    -- Steady trading: the count hardly moves but the cheap end keeps selling and refilling.
    local healthy = M.Activity(hist({ "20:100,21:100", "20:40,21:100,19:0", "19:60,20:40,21:100",
        "19:10,20:40,21:100", "18:50,19:10,20:40,21:100" }, 1800), now, 7)
    assert(healthy.bought == 60 + 50 and healthy.key == "busy" and healthy.buys == 2 and not healthy.flooding,
        "busy, got " .. tostring(healthy.key))
    near(healthy.demandPerDay, 110 / 7200 * 86400, 1e-6, "bought per day")
    -- A little buying from a big pile.
    local slow = M.Activity(hist({ "50:500", "50:497", "50:497", "50:495" }, 3600), now, 7)
    assert(slow.key == "slow" and slow.bought == 5)
    -- Quick rescans and old-style points without depth don't rate anything.
    local quick = M.Activity(hist({ "10:5", "10:5", "10:5" }, 30), now, 7)
    assert(quick.key == nil and quick.compared == 2)
    assert(M.Activity({ { t = now - 600, q = 5 }, { t = now, q = 3 } }, now, 7).compared == 0)
    -- A gap long enough for listings to expire isn't compared.
    assert(M.Activity(hist({ "10:5", "11:5" }, M.PAIR_MAX + 1), now, 7).compared == 0)
    near(M.ProfitPerDay(10, healthy, 20), 200, 1e-9, "capped at what you list")
    near(M.ProfitPerDay(10, { demandPerDay = 3 }, 20), 30, 1e-9)
    assert(M.ProfitPerDay(10, piling, 20) == 0, "nothing bought")
    assert(M.ProfitPerDay(10, quick, 20) == nil, "too short to measure")
end)

test("chart buckets keep the last count and lowest price", function()
    local b = M.Buckets({ { t = 0, p = 30, q = 5 }, { t = 10, p = 25, q = 7 }, { t = 60, p = 40, q = 2 } }, 0, 100, 4)
    assert(#b == 4 and b[1].q == 7 and b[1].p == 25 and b[1].n == 2)
    assert(b[2].n == nil and b[3].q == 2 and b[3].p == 40 and b[4].n == nil)
end)

test("sale profit and quotes", function()
    -- 13 Fine Thread sold for 12s 74c gross at 5%; paid 90c each.
    local r = M.SaleProfit(1274, 13, 90, 0.05)
    assert(r.cut == 63 and r.net == 1211 and r.cost == 1170 and r.profit == 41)
    assert(M.SaleProfit(1000, 5, nil, 0.05).profit == nil, "unknown cost")
    local q = M.Quote(20, 97, 90, 0.05, 15)
    assert(q.gross == 1940 and q.cut == 97 and q.profit == 1940 - 97 - 1800 and q.deposit == 15)
    near(q.profitUnit, q.profit / 20, 1e-9)
end)

test("vendor pays nothing for items it refuses, whatever their sell price", function()
    assert(M.VendorPays(14047, 400) == 400)
    assert(M.VendorPays(14047, 0) == 0 and M.VendorPays(14047, nil) == 0)
    assert(M.VENDOR_REFUSES[6947], "Instant Poison (Rank 1)")
    assert(M.VendorPays(6947, 25) == 0, "shows a sell price, vendors refuse it")
end)

test("vendor snipe: per unit or per purchase", function()
    -- A vendor pays 50c each; you want 10c.
    assert(M.VendorDeal(40, 1, 50, 10, "unit") == 10)
    assert(M.VendorDeal(41, 1, 50, 10, "unit") == nil, "9c short")
    assert(M.VendorDeal(450, 10, 50, 10, "unit") == nil, "5c a unit isn't 10c a unit")
    assert(M.VendorDeal(450, 10, 50, 10, "buy") == 50, "50c in all clears 10c a purchase")
    assert(M.VendorDeal(50, 1, 50, 0, "buy") == nil, "break-even is no deal")
    assert(M.VendorDeal(49, 1, 50, 0, "unit") == 1)
    assert(M.VendorDeal(1, 1, 0, 0, "unit") == nil, "vendors won't buy it")
    assert(M.SnipeLimit(10, 50, 10, "unit") == 400 and M.SnipeLimit(10, 50, 10, "buy") == 490)
end)

test("vendor snipe: commodities take the cheap end, skip your own, stop at your gold", function()
    local levels = { { price = 30, qty = 5, mine = 2 }, { price = 38, qty = 4, mine = 0 },
        { price = 45, qty = 100, mine = 0 } }
    local b = M.CommodityBuy(levels, 50, 10, "unit")
    assert(b.qty == 7 and b.cost == 3 * 30 + 4 * 38 and b.profit == 7 * 50 - b.cost, "45c leaves 5c a unit")
    assert(b.maxPrice == 38, "the dearest unit it includes")
    b = M.CommodityBuy(levels, 50, 10, "buy")
    assert(b.qty == 107 and b.profit == 107 * 50 - (90 + 152 + 4500), "every profitable unit when counting per purchase")
    b = M.CommodityBuy(levels, 50, 10, "unit", 150)
    assert(b.qty == 4 and b.cost == 128, "3 at 30c and 1 at 38c is all 1s 50c buys")
    assert(M.CommodityBuy(levels, 50, 10, "unit", 20) == nil, "can't afford one")
    assert(M.CommodityBuy({ { price = 49, qty = 1, mine = 0 } }, 50, 500, "buy") == nil, "1c in all")
    assert(M.CommodityBuy({}, 50, 0, "unit") == nil)
end)

test("vendor snipe: item auctions best first, never your own", function()
    -- buyout is each auction's price; qty is how many identical auctions the row groups.
    local auctions = {
        { auctionID = 1, qty = 1, buyout = 80, mine = false },
        { auctionID = 2, qty = 1, buyout = 20, mine = false },
        { auctionID = 3, qty = 1, buyout = 10, mine = true },
        { auctionID = 4, qty = 2, buyout = 50, mine = false },
    }
    local b = M.ItemBuys(auctions, 100, 25, "unit")
    assert(#b.auctions == 2 and b.auctions[1].auctionID == 2 and b.auctions[2].auctionID == 4, "most profit per press first")
    assert(b.auctions[2].profit == 50, "profit is per purchase of one")
    assert(b.qty == 3 and b.cost == 20 + 2 * 50 and b.profit == 80 + 2 * 50)
    b = M.ItemBuys(auctions, 100, 25, "unit", 40)
    assert(#b.auctions == 1 and b.auctions[1].auctionID == 2, "only what you can pay for")
    assert(M.ItemBuys(auctions, 100, 1000, "unit") == nil)
end)

test("vendor snipe: a row of 32 at 8s 27c is 32 auctions at 8s 27c, not 32 for 8s 27c", function()
    -- Schematic: Catseye Ultra Goggles, vendor pays 8s 25c. Only the two at 8s are a deal.
    local rows = {
        { auctionID = 1, qty = 2, buyout = 800 }, { auctionID = 2, qty = 32, buyout = 827 },
        { auctionID = 3, qty = 5, buyout = 828 }, { auctionID = 4, qty = 2, buyout = 829 },
        { auctionID = 5, qty = 1, buyout = 1238 },
    }
    for _, basis in ipairs({ "unit", "buy" }) do
        local b = M.ItemBuys(rows, 825, 20, basis)
        assert(#b.auctions == 1 and b.auctions[1].auctionID == 1 and b.qty == 2, basis)
        assert(b.cost == 1600 and b.profit == 50 and b.auctions[1].profit == 25, basis)
    end
end)

test("vendor snipe: estimate from a full scan", function()
    -- Three auctions: 5 for 100c, 1 for 60c, 10 for 450c; vendor pays 50c.
    local e = M.EstimateDeal({ 5, 100, 1, 60, 10, 450 }, 50, 10, "unit")
    assert(e.qty == 5 and e.cost == 100 and e.profit == 150, "10 for 450c is only 5c a unit")
    e = M.EstimateDeal({ 5, 100, 1, 60, 10, 450 }, 50, 10, "buy")
    assert(e.qty == 15 and e.cost == 550 and e.profit == 150 + 50)
    assert(M.EstimateDeal({ 1, 60 }, 50, 0, "unit") == nil)
end)

test("earnings ledger sums days by range", function()
    assert(M.IsDayKey("2026-11-16") and not M.IsDayKey("16/11/2026") and not M.IsDayKey(5))
    local days = {}
    days["2026-11-10"] = {}
    M.LedgerAdd(days["2026-11-10"], "s", { n = 1, units = 4, spent = 100, value = 160 })
    M.LedgerAdd(days["2026-11-10"], "s", { n = 1, units = 1, spent = 800, value = 825 })
    days["2026-11-16"] = {}
    M.LedgerAdd(days["2026-11-16"], "a", { n = 1, units = 13, gross = 27300, net = 25935, profit = 7215, costed = 1 })
    M.LedgerAdd(days["2026-11-16"], "a", { n = 1, units = 1, gross = 500, net = 475, profit = 0, costed = 0 })
    days.bogus = { s = { n = 9, spent = 0, value = 99999 } }
    local all = M.LedgerSum(days)
    assert(all.days == 2 and all.s.n == 2 and all.s.units == 5 and all.snipe == 85)
    assert(all.a.n == 2 and all.a.costed == 1 and all.sales == 7215 and all.profit == 7300)
    local recent = M.LedgerSum(days, "2026-11-11")
    assert(recent.days == 1 and recent.snipe == 0 and recent.profit == 7215)
    assert(M.LedgerSum(days, nil, "2026-11-10").profit == 85)
    assert(M.LedgerProfit(nil) == 0)
end)

test("each deal knows what its best single item makes", function()
    -- Commodity: the cheapest unit makes the most.
    local c = M.CommodityBuy({ { price = 100, qty = 2 }, { price = 380, qty = 50 } }, 400, 1, "unit")
    assert(c.qty == 52 and c.best == 300 and c.profit == 2 * 300 + 50 * 20)
    -- Gear: the cheapest auction, however many dearer ones there are.
    local g = M.ItemBuys({ { auctionID = 1, qty = 32, buyout = 823 }, { auctionID = 2, qty = 1, buyout = 800 } }, 825, 1, "unit")
    assert(g.best == 25 and g.profit == 32 * 2 + 25)
    -- Estimates: per unit, from (count, total buyout) pairs.
    local e = M.EstimateDeal({ 32, 32 * 823, 1, 800 }, 825, 1, "unit")
    assert(e.best == 25 and e.profit == 64 + 25)
end)

test("full-scan auctions as an order book, for buying trade goods straight from the scan", function()
    local levels = M.FlatLevels({ 5, 2500, 10, 2000, 0, 50, 3, 300 })
    assert(#levels == 3 and levels[1].price == 100 and levels[1].qty == 3 and levels[2].price == 200 and levels[3].price == 500)
    local b = M.CommodityBuy(levels, 400, 100, "unit")
    assert(b.qty == 13 and b.cost == 2300 and b.best == 300 and b.maxPrice == 200)
end)

test("profit per bag slot", function()
    assert(M.PerSlot(100, 20, 5, 20) == 100, "20 at +5c fill one slot")
    assert(M.PerSlot(105, 21, 5, 20) == 52.5, "21 need two slots")
    assert(M.PerSlot(30, 3, 10, 1) == 10, "gear: one slot each, the best one's profit")
    assert(M.PerSlot(30, 3, 10, nil) == 10 and M.PerSlot(0, 0, 0, 20) == 0)
end)

print(total .. " model tests passed")
