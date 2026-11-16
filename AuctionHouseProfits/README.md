# Auction House Profits

Is it worth buying this from a vendor and selling it on the auction house? This add-on answers that for WoW: Forever. It also works the other way round: its vendor sniper finds auctions a vendor will pay more for, and buys them one press at a time. It covers the AH cut, deposits you'll lose on listings that don't sell, faction versus neutral auction houses, and what your reputation discount changes.

## Where to find it

- **At the auction house:** open the new **Profits** tab, after Buy, Sell, Auctions and any tabs other add-ons add.
- **On the Auctions tab:** pick one of your items to get a post/relist strip in its header.
- **Beside the auction house:** the vendor sniper panel. Hide it with its close button or `/ahp snipe`.
- **Anywhere else:** type `/ahp`, or use the add-ons button by the minimap.
- **Settings:** `/ahp options`, or the **Options** button in the window.

## What it shows

For the item you pick:

- **Vendor price** before discounts, and **your cost** at your standing with that vendor. The game reports your standing whenever you visit, target or mouse over the vendor, so there's nothing to set.
- **Lowest price on the AH** from your last scan, or from Auctionator, TradeSkillMaster or Auctioneer.
- **Your price** in gold, silver and copper boxes. It defaults to 1c under the cheapest other seller; type your own, or press **Reset** to go back.
- **Profit at the faction AH:** total profit, profit per unit, margin, ROI and break-even price. Also the deposit per listing and how much you can expect to lose to listings that expire. Turn on **Show the neutral auction house** in Options to compare Booty Bay, Gadgetzan and Everlook side by side. It always shows while you're standing at one.
- **Demand:** what buyers actually took between your scans, and what you'd make a day if you list first. Each scan keeps the order book (units at each price). Buyers always take the cheapest first, so units gone from the cheap end were bought. Units gone from dearer prices while cheaper ones sat there were cancelled or expired. Units that weren't there before are new supply. A market is **Busy** when its whole stock sells about once a day, **Active** at a fifth a day, **Slow** with some buying, and **Stagnant** when nothing sold in 3+ hours of scans, however much new supply turned up. You also get a warning when supply piles up faster than it sells.
- **Price & volume chart:** the lowest price (line), units listed (blue) and units bought since the scan before (green), from your scans over the last week. Hover for the numbers.
- **Live market:** every price level on the AH, how many units are listed at each, and profit per stack if you list 1c under it. A highlighted row shows where your price would sit. Click a level to list 1c under it.
- **Price ladder:** 150% down to 50% of your price, with both break-even points marked.
- **Post:** lists your stack from your bags at your price and duration.

## Posting from the Auctions tab

Select one of your items on Blizzard's **Auctions** tab and a strip appears in the item header:

- **Undercut** lists 1c under the cheapest other seller; **Match** lists at their price. Units already listed at the same price sell before yours.
- **Qty** and the price boxes set what to post; **Post** lists it from your bags.
- The strip shows profit if it sells, the deposit, and how many units are ahead of you.
- It also shows how many you have listed and sold, and the profit on the sold ones against what you paid.

## Vendor sniper

A panel beside the auction house finds auctions you can buy for less than a vendor pays, so you can buy them and sell them straight to a vendor.

- Set your **Min profit** in the gold, silver and copper boxes. **each** means every unit must make that much; click it for **per buy**, where one purchase must make it in all.
- **Full scan** reads every auction at once. The game allows one every 15 minutes per account, so in between the button becomes **Recheck**, which searches the items that had deals before. Searches you run on the Buy page are checked too.
- Deals marked `~` are estimates from the full scan. The sniper checks each one against the live listings by itself, top of the list first.
- **Buy** stays in the same place: each press buys the deal at the top, then the next one moves up. Trade goods buy every profitable unit in one press, and are only confirmed if the server's price is still a deal. Gear buys one auction per press. **Right-click** Buy, or press **Skip**, to pass on a deal. Click a deal in the list to buy it next.
- For no mouse at all, bind keys under Key Bindings → AddOns → Auction House Profits.
- `/ahp snipe` or the **Sniper** button on the Profits tab shows or hides it.

The game only lets an add-on buy from a click or key press, so nothing is ever bought in the background.

## How it learns prices

- **Vendor prices:** open any merchant and the add-on records what they charge and your standing with them. Turn this off in Options. Goods sold by many vendors keep every vendor. Costs use the one that's cheapest at your standing, which normally means the vendor you're on the best terms with. Hover **Your cost** to see them all.
- **Market prices:** with the AH open, selecting an item runs one price search, or press **Scan AH**. **Scan list** searches every item in the list in turn. Searches you run on the Buy or Auctions pages, or through Auctionator, update the recorded listings and history too. Nothing scans in the background.
- **Sorting:** the list puts profitable, busy markets first (**Profit per day**). Items without enough scans to judge come next, by profit per unit. The bars beside each profit show how busy its market is. You can also sort by **Profit per unit** or **Busiest markets**. Prices from Auctionator, TSM or Auctioneer are used automatically when those add-ons are installed.
- **What you paid:** buying from a merchant records the price once the money leaves your bags. Sold auctions use it for profit; otherwise the vendor price at your standing.
- **Reputation discounts:** WoW Forever has two price tiers: full price at Neutral and Friendly, 10% off at Honored, Revered and Exalted. The add-on also compares merchant prices against the usual 4× vendor markup, then shows the discount it actually saw at each standing under **Options → Reputation**. If those don't match the defaults, change them there.

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
