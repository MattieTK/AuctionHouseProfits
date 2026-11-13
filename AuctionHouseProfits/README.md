# Auction House Profits

Is it worth buying this from a vendor and selling it on the auction house? This add-on answers that for WoW: Forever. It covers the AH cut, deposits you'll lose on listings that don't sell, faction versus neutral auction houses, and what your reputation discount changes.

## Where to find it

- **At the auction house:** open the new **Profits** tab, after Buy, Sell, Auctions and any tabs other add-ons add.
- **On the Auctions tab:** pick one of your items to get a post/relist strip in its header.
- **Anywhere else:** type `/ahp`, or use the add-ons button by the minimap.
- **Settings:** `/ahp options`, or the **Options** button in the window.

## What it shows

For the item you pick:

- **Vendor price** before discounts, and **your cost** at your reputation standing.
- **Lowest price on the AH** from your last scan, or from Auctionator, TradeSkillMaster or Auctioneer.
- **Your price** in gold, silver and copper boxes. It defaults to 1c under the cheapest other seller; type your own, or press **Reset** to go back.
- **Faction AH vs. neutral AH, side by side:** total profit, profit per unit, margin, ROI and break-even price. Also the deposit per listing and how much you can expect to lose to listings that expire.
- **Profit per unit by standing:** cost and profit at Neutral, Friendly, Honored, Revered and Exalted.
- **Live market:** each price you could list at (1c under each seller), how many units sell before yours, and profit per stack. Click a row to use that price.
- **Price ladder:** 150% down to 50% of your price, with both break-even points marked.
- **Post:** lists your stack from your bags at your price and duration.

## Posting from the Auctions tab

Select one of your items on Blizzard's **Auctions** tab and a strip appears in the item header:

- **Undercut** lists 1c under the cheapest other seller; **Match** lists at their price. Units already listed at the same price sell before yours.
- **Qty** and the price boxes set what to post; **Post** lists it from your bags.
- The strip shows profit if it sells, the deposit, and how many units are ahead of you.
- It also shows how many you have listed and sold, and the profit on the sold ones against what you paid.

## How it learns prices

- **Vendor prices:** open any merchant and the add-on records what they charge and your standing with them. Turn this off in Options.
- **Market prices:** with the AH open, selecting an item runs one price search, or press **Scan AH**. Searches you run on the Buy or Auctions pages, or through Auctionator, update the recorded listings too. There's no background scanning. Prices from Auctionator, TSM or Auctioneer are used automatically when those add-ons are installed.
- **What you paid:** buying from a merchant records the price once the money leaves your bags. Sold auctions use it for profit; otherwise the vendor price at your standing.
- **Reputation discounts:** the defaults are 5% at Friendly, 10% at Honored, 15% at Revered and 20% at Exalted. The add-on also compares merchant prices against the usual 4× vendor markup, then shows the discount it actually saw at each standing under **Options → Reputation**. If those don't match the defaults, change them there.

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
