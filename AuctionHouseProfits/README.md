# Auction House Profits

Is it worth buying this from a vendor and selling it on the auction house? This add-on answers that for WoW: Forever. It covers the AH cut, deposits you'll lose on listings that don't sell, faction versus neutral auction houses, and what your reputation discount changes.

## Where to find it

- **At the auction house:** open the new **Profits** tab next to Buy, Sell and Auctions.
- **Anywhere else:** type `/ahp`, or use the add-ons button by the minimap.
- **Settings:** `/ahp options`, or the **Options** button in the window.

## What it shows

For the item you pick:

- **Vendor price** before discounts, and **your cost** at your reputation standing.
- **Market price** from your own AH scan, Auctionator, TradeSkillMaster or Auctioneer, or a price you type in.
- **Faction AH vs. neutral AH, side by side:** total profit, profit per unit, margin, ROI and break-even price. Also the deposit per listing and how much you can expect to lose to listings that expire.
- **Buying at each standing:** cost and profit per unit at Neutral, Friendly, Honored, Revered and Exalted.
- **Profit at each price:** a ladder from 150% of market down to 50%, with both break-even points marked. Click a row to use that price.

## How it learns prices

- **Vendor prices:** open any merchant and the add-on records what they charge and your standing with them. Turn this off in Options.
- **Market prices:** with the AH open, selecting an item runs one price search, or press **Scan AH**. There's no background scanning. Prices from Auctionator, TSM or Auctioneer are used automatically when those add-ons are installed.
- **Reputation discounts:** the defaults are 10% at Honored, Revered and Exalted. The add-on also compares merchant prices against the usual 4× vendor markup, then shows the discount it actually saw at each standing under **Options → Reputation**. If those don't match the defaults, change them there.

## The math

For one stack of `n` items listed at price `p` each:

- The AH takes its cut when the stack sells: 5% at faction AHs, 15% at neutral ones, both editable.
- The deposit is paid every time you list. You get it back when the stack sells and lose it if the listing expires or you cancel. With the AH open, the add-on asks the game for the exact deposit; otherwise it uses 2.5% of vendor price per hour (8h = 20%, 12h = 30%, 24h = 60%), 5× that at neutral AHs, with a 1 silver minimum.
- With a chance `c` that a listing sells and up to `M` listings, the stack sells with probability `1 − (1 − c)^M`. Every listing except the one that sells costs a deposit. Stacks that never sell are vendored, kept at cost, or written off; you choose which.
- Profit = chance it sells × (`n·p` − cut) + chance it doesn't × leftover value − expected lost deposits − cost.

There's also a web version of the calculator at https://auctionhouseprofits.tk.gg.

## Notes

- Built for WoW: Forever only (interface 16001).
- Saved data: `AuctionHouseProfitsDB` (settings and profiles) and `AuctionHouseProfitsData` (recorded prices), both account-wide.
- Built on [SomethingNeedDoing](https://github.com/elithrar/SomethingNeedDoing) v0.5.2, bundled under `Libs/` (Apache-2.0).
