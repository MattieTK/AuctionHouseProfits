# Changelog

## 0.4.0

- **Vendor sniper.** A panel beside the auction house finds auctions you can buy for less than a vendor pays, and buys them **one press at a time without moving the mouse**: the Buy button stays put and each press buys the deal at the top of the list. Right-click it to skip a deal. Both are also key bindings (Key Bindings → AddOns → Auction House Profits).
- **Minimum profit in gold, silver and copper boxes**, per unit (every unit must make it) or per purchase (one press must make it in all).
- **Full scan** reads every auction at once (the game allows one every 15 minutes per account). In between, **Recheck** searches the items that had deals before, and any search you run on the Buy page is checked too.
- Each deal is checked against the live listings before you press Buy. Trade goods buy every profitable unit in one press, and the purchase is only confirmed if the server's price is still a deal; otherwise it's cancelled. Gear buys one auction per press, most profitable first. Your own auctions are never bought.
- Shows what you've bought since login against what vendors pay, and warns when your bags are full.
- `/ahp snipe`, or the **Sniper** button on the Profits tab, shows or hides it.

## 0.3.2

- **Items sold by many vendors keep every vendor,** not just the last one you visited. Costs use the vendor that's cheapest at your current standing with each. List prices are normally the same, so that's the vendor you're on the best terms with: Honored with one city beats Friendly with another. On a tie it prefers unlimited stock, then the vendor seen most recently.
- Hover **Your cost** to see every vendor with your standing and price there. The item header says how many other vendors sell it.
- The "Last merchant" filter includes items that merchant sells even when another vendor is cheaper.

## 0.3.1

- **Demand is measured from what was bought, not from the listed count moving.** Each scan now keeps the order book: units at each price. Buyers always take the cheapest first, so units gone from the cheap end were bought. Units gone from dearer prices while cheaper ones were untouched were cancelled or expired. Anything new is supply. A market that only gains listings is now Stagnant, not Busy. A steady market whose cheap end keeps selling and refilling is Busy, even if its total barely moves.
- Busy, Active and Slow are rated by how fast the market's stock sells (bought per day against units listed). Stagnant means nothing bought in 3+ hours of scans. A warning shows when supply piles up faster than it sells.
- The chart shows units bought between scans in green.
- Scans more than 8 hours apart aren't compared, because listings expire in that time. History from 0.3.0 has no order books, so ratings start over from your next scans.

## 0.3.0

From in-game testing at the Undercity auction house.

- **Market activity.** Every search is kept as price and volume history for 14 days. The add-on tracks how often the listed count changes between scans and estimates how many units leave the AH a day. From that it rates the market Busy, Active, Slow or Stagnant and works out profit per day if you list first.
- **The list ranks busy, profitable markets first.** Bars on each row show activity. You can also sort by profit per unit or by busiest markets.
- **Price & volume chart** for the selected item: lowest price and units listed from your scans.
- **Scan list** searches every item in the list in turn, to build that history quickly.
- **Live market shows the quantity at each price** instead of the running "ahead" count, which moved to the tooltip. A highlighted row shows where your price would sit.
- **Your standing comes from the game.** It's read from each vendor when you visit, target or mouse over them, so the "Buy at standing" menu and the standing table are gone.
- **The neutral AH is hidden unless you turn it on** (Options → Auction house), or you're standing at one.
- Two-digit silver and copper now show in the price boxes.
- The Profits tab copies the spacing between Auctionator's tabs, and its label no longer drops when selected.

## 0.2.1

- **Reputation discounts match WoW Forever:** full price at Neutral and Friendly, 10% off from Honored up. 0.2.0 wrongly used Classic's 5/10/15/20%. One setting now covers Honored, Revered and Exalted. The standing table and "Buy at standing" show the two price tiers instead of five rows.

## 0.2.0

From in-game testing at the Undercity auction house.

- **Post and relist from the Auctions tab.** Pick one of your items there to get Undercut, Match, quantity and price boxes and a Post button. You also see profit if it sells, how many units sell before yours, and what your listed and sold auctions made against what you paid.
- **Post from the Profits tab:** posts your stack at your price, from your bags.
- **Live market table:** every price on the AH from your last scan, how many units sell before yours at each, and profit per stack for faction and neutral. Click a row to list there.
- **Your price defaults to 1c under the cheapest other seller.** It's now separate from the market price, and typing it no longer marks the market price as "Manual". Old typed prices carry over as your price.
- **Gold, silver and copper boxes** for prices, instead of typing `1g 2s 3c`.
- **Duration follows the AH Sell page**, and dropdowns show their value again.
- **Reputation discounts default to 5/10/15/20%** for Friendly/Honored/Revered/Exalted (were 0/10/10/10).
- **Remembers what you paid vendors.** Sold auctions are logged so profit uses your real cost.
- The Profits tab sits after Auctionator's tabs instead of on top of them.
- Labels say whether profit is per unit or per stack.

## 0.1.0

First release.

- Profits tab in the auction house, plus a standalone window (`/ahp`) and add-on compartment entry.
- Records vendor prices and your reputation standing when you open a merchant.
- Market prices from your own AH price check, Auctionator, TradeSkillMaster, Auctioneer or a manual price.
- Faction vs. neutral AH comparison: cut, deposits (exact from the game when the AH is open), expected lost deposits, break-even, margin and ROI.
- Profit by reputation standing, and a profit ladder across price points.
- Observed vendor discount per standing, from merchant prices.
