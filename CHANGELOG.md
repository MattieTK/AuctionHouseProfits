# Changelog

## 0.4.6

- **Items vendors refuse are left out, whatever sell price they show.** Some items show a vendor price on their tooltip, but every vendor answers "The merchant doesn't want that item." The sniper no longer lists them as deals or rechecks them, and on the Profits tab unsold stacks of them aren't counted as sold to a vendor. The first is Instant Poison (Rank 1). More get added as they're reported.

## 0.4.5

Faster sniping, so fewer deals are gone before you can buy them.

- **Trade goods are bought straight from the full scan,** with no search first. A commodity purchase is by item and quantity, and the game quotes the total before anything is paid, so the quote is the check: if the cheap units have gone, the purchase is cancelled as before. If that happens, the next press waits for a fresh look at the listings. The button shows `~` on the price while it's from the scan.
- **Gear checks start while the scan is still being read,** best deal per item first, instead of after it. Gear still needs a search before buying, because the game buys it by auction ID and the full scan doesn't include them.
- **The list appears as soon as the scan is read.** Items whose vendor price is still loading join as it arrives, instead of holding everything for up to 8 seconds.
- **Each check starts the moment the last one answers,** not on the next timer tick. Pressing Buy on a deal still being checked moves it to the front.
- **Sort by profit per bag slot.** The **Sort** button at the top of the sniper switches between profit per item and profit per bag slot: what one press makes for each slot it fills. 20 of a +5c trade good fill one slot (+1s a slot), while a +10c piece of gear fills a slot on its own, so stackable deals come first. Rows show "a slot" instead of "each", and hovering a row shows both, with the stack size. Also on the Options page.
- **When a check finds a deal gone, the chat says so,** with the price the scan saw and what's there now, so you can tell a deal someone else bought from a misread price.

## 0.4.4

- **The sniper ranks deals by what one item makes,** not the total across every auction. You may not win them all, so the most valuable single purchase comes first: one auction at +50c now beats 32 at +2c each. Each row shows its best profit per item ("+25c each"); hover it for the total if you get them all. Checked deals still come before estimates, and each estimate moves up once it's checked.

## 0.4.3

- **Hover the next deal in the sniper for the item's tooltip,** as if you'd hovered its link, so other add-ons' prices (vendor, market) show there too. Below it, the vendor price this add-on is using, each and for what one press buys. Shift-click it to link the item in chat.

## 0.4.2

- **What the add-on has made you, kept for good.** Every sniper buy is recorded with what a vendor pays for it, and every auction sale of an item whose cost is known with its profit after the AH cut. Both are kept by day, across logouts and characters on the account.
- The sniper panel shows what you've made today and in all, and the Profits tab shows the all-time total. Hover either for today, the last 7 and 30 days, all time, where it came from, and a day-by-day line for the last week. `/ahp made` prints the same to chat.
- On first load it starts from the auction sales already on record (the last 30 days).

## 0.4.1

From in-game testing.

- **Fixed: the vendor sniper counted grouped gear auctions as one stack.** The auction house groups identical auctions into one row: "8s 27c · 32" is 32 auctions at 8s 27c each, not 32 items for 8s 27c. The sniper read it the second way, so a row priced above the vendor price showed up as a big profit. Each row now counts at its price per auction, only rows below vendor price (less your minimum) are deals, and each press buys one auction.
- **The Buy button says exactly what one press buys:** "Buy 1 for 8s" or "Buy 10 for 23s 60c". The line above shows what a vendor pays and your profit; for trade goods, the dearest unit it includes. Hover it for the full detail: how many more of that auction are left, the most a trade-good purchase may cost before it's cancelled, and that nothing else in the list is bought.
- **Fixed: market prices for gear and recipes on the Profits tab** were divided by the number of auctions in the cheapest row for the same reason.

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
