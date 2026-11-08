# BankiAlt

[![Release](https://github.com/aveyder/bankialt/actions/workflows/release.yml/badge.svg)](https://github.com/aveyder/bankialt/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/aveyder/bankialt?label=release)](https://github.com/aveyder/bankialt/releases/latest)
[![CurseForge](https://img.shields.io/curseforge/v/1790319?label=CurseForge)](https://www.curseforge.com/wow/addons/bankialt)
[![Downloads](https://img.shields.io/curseforge/dt/1790319?label=downloads)](https://www.curseforge.com/wow/addons/bankialt)

**Your bank alt, in your pocket.**

Stop the mailbox grind: typing the alt's name, dragging items one by one, 12 per mail, then doing it all again on the alt. BankiAlt turns your bank alt into a **virtual bag** you can open from any character, anywhere.

## Why you'll love it

- 📬 **Bulk mail in one click.** Alt-click or drag everything you want to stash (or right-click it on the Send tab) and hit **Send**. BankiAlt splits it into as many mails as needed.
- 🎒 **A bag for your banker.** See everything you've sent, from any of your characters, even far from a mailbox.
- 🔎 **Know where every item is.** In flight, waiting in the mailbox, back from the AH, or mailed back to you. Each item gets a small status icon in its slot.
- 💰 **Gold at a glance.** The banker's current gold, plus what its auctions should bring in. Items posted on the AH leave the bag and show up under **Auctions** instead: hover it to see each auction and its time left, right-click it to settle an auction whose mail never came.
- 📥 **One-click collect** on the banker. It only takes mail from your own characters and never touches anything else.
- 🛡️ **Can't be messed with.** Only mail from your own characters counts, so other players can't change your bag.
- 🧩 **Feels built-in.** Blizzard-style window, and a button in Bagnon's title bar if you use Bagnon.

## Get started

1. Install it from [CurseForge](https://www.curseforge.com/wow/addons/bankialt), or download the zip from the [latest release](https://github.com/aveyder/bankialt/releases/latest), or clone it into `Interface/AddOns`:
   ```
   git clone https://github.com/aveyder/bankialt.git
   ```
2. In game: `/balt config`, then set your banker and add your main characters.
3. Open a mailbox. That's it.

`/balt` opens the bag · `/balt config` opens the settings

Made for **WoW Forever**. Works with **Bagnon** (optional).

## What the addon does in your game

Everything happens inside the WoW client. BankiAlt doesn't talk to any website, doesn't send addon or chat messages, and only saves data on your own computer.

**Actions it takes for you, only after you click a button:**
- **Send** (on a main): switches the mailbox to its Send tab, attaches the items you added and mails them to your banker, 12 items per mail, one mail after another. Each mail costs the normal postage. The subject carries a tag such as `[BankiAlt:6aef92feb884] 1/2`, which is how the banker recognizes your mails.
- **Collect** (on the banker): takes the items out of mails that carry that tag and come from your own characters. Mails with cash on delivery, and mail from anyone else, are never touched.
- **Clicking an item you added** in the virtual bag picks the real item up from your bags, like clicking it in a bag would.

**What it reads:**
- Your bags, your money and your mailbox (senders, subjects, attachments and AH sale notices).
- On the banker, the bank while it's open.
- The auctions the banker posts and their prices. It notices every auction posted through the game's own posting functions (the Blizzard AH, Auctionator and similar addons); it doesn't scan the AH. An auction ends when its sale or return mail shows up in the banker's mailbox.

**Where it hooks into the game's UI:**
- **Alt-click in your bags** (Blizzard bags or Bagnon) adds an item to the send list. **Right-click** does the same on the mailbox's Send tab: the game attaches the item to the mail form, and BankiAlt takes it off again.
- **Items you added are greyed out in your bags**, the way the mailbox greys out attachments.
- **A button** in Bagnon's title bar, a minimap button, or a tab on the mailbox opens the virtual bag (you choose which in the settings).
- **Mail, deletion and vendor sales are watched** so the virtual bag knows when an item leaves the banker. The addon only observes these; it never sends, deletes or sells anything on its own.

**What it saves:** one account-wide file, `WTF\Account\<account>\SavedVariables\bankialt.lua`. It holds your settings, the names of your banker and mains, and the banker's last known items, gold and auctions. `/balt reset` clears the tracked data.

## Made with AI

BankiAlt was written with the help of AI (Claude Code by Anthropic) and tested in game by the author. If something doesn't work the way this README says, please open an issue.
