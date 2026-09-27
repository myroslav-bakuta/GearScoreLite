# GearScoreLite: Reborn

Helps you quickly and easily judge a player's level of gear.

A mod by **Kappa** for the **WoW FreedomUA** server, based on the final official GearScoreLite (3x04) by Mirrikat45 & Gnomezilla.

For World of Warcraft 3.3.5 (WotLK).

## What is GearScore?

The GearScore algorithm gives you a good indication of the player's actual power level. Every item slot is intelligently weighted by how important and powerful each slot is; for example, a high level chest piece is "more powerful and provides more stats" than a high level belt, so the chest is "worth a higher score".

This intelligent weighting makes it much more useful than simply looking at the "average item level", since it's impossible to "cheat" the score by just wearing a few weak, high-level pieces in low-impact armor slots.

## Installation

Download the latest `GearScoreLite-Reborn-vX.Y.Z.zip` from the [Releases page](https://github.com/myroslav-bakuta/GearScoreLite/releases), then copy the `GearScoreLite` folder out of it into `Interface\AddOns\` and restart the game.

Remove the original `GearScore` addon if you have it - the two define the same globals and whichever loads last silently breaks the other.

Upgrading resets your options to their defaults once whenever the saved settings format changes. The addon discards an old layout rather than migrating it.

## Reading a score

A player's score appears on their tooltip, with a label while it is being established:

| Shown | Means |
| --- | --- |
| `GearScore: 6478 (scanning)` | The client is still sending their gear; the number will rise |
| `GearScore: 6478 (scanned)` | Just read from a finished inspect |
| `GearScore: 6478` | A settled score read a little while ago |
| `GearScore: 6478 (memory)` | From a previous session, shown while a fresh read runs |

On a realm with transmogrification the first reading is often the *cosmetic* set, because that is what the client serves before the inspect reply lands. The addon waits for the real gear and replaces the number on its own - normally within a second, without any action from you.

## Highlights

- **Scores match GearScore 3.2.1 exactly.** The 7000-band gradient for ICC/BiS gear, the 12.25 colour scale, rounded average item level, and the Titan's Grip edge case (a two-hander in either hand halves both weapon slots) all behave like the reference implementation.
- **Transmog-aware inspect.** Gear arrives in batches and a cosmetic set looks complete long before the real one does. Scans are settled on whether the set is still changing, not on how it looks, so a mogged player converges on their true score instead of freezing at the appearance's value.
- **A queue, so a whole raid gets scored.** The server grants one inspect at a time. Pending requests used to overwrite each other, so sweeping the raid frames left nobody scored but the last person hovered; they now wait their turn.
- **Tells you why a score is missing** instead of showing nothing - out of range, inspect window open, scanning, or queued.
- **Built-in diagnostics.** `/gs why` explains a single player, `/gs dump` opens a copyable log of recent scans.
- **Gradient colour mode** as an alternative to the classic 7 colour bands, interpolated in linear light with a configurable step size.
- **Draggable character-sheet number** with a bundled FiraSans-SemiBold font (falls back to the default WoW font if it can't be loaded).
- **Unit frame support** for ElvUI, oUF, ShadowedUnitFrames and VuhDo - the frame under the cursor is resolved directly when Blizzard's `mouseover` token misses it.
- **WeakAuras-friendly API** (see below).
- **Doesn't fight the Inspect window.** No GearScore calculation happens while Blizzard's Inspect or the Examiner addon is open, which fixes the bug where the Inspect window kept changing contents and showing random talents and gear.

## Commands

All of `/gs`, `/gset` and `/gearscore` work. Running `/gs` with no argument prints the command list in-game.

| Command | Does |
| --- | --- |
| `/gs player` (or `show`) | Toggle player scores in tooltips; while off, nobody is inspected automatically |
| `/gs item` | Toggle item scores |
| `/gs level` | Toggle item levels |
| `/gs target` | Toggle "Must Target" mode |
| `/gs combat` | Toggle hiding all GearScore tooltip output while in combat |
| `/gs status` | Toggle the "out of range / scanning" line shown when no score is known |
| `/gs sheet` | Toggle the character sheet number |
| `/gs unlock` / `/gs lock` | Unlock the character sheet number so you can drag it, then lock it again |
| `/gs color` | Switch between `classic` and `gradient` colours |
| `/gs step 200` | Gradient quantisation step, in GS |
| `/gs range 3000 6500` | Gradient low/high bounds |
| `/gs reset` | Restore every option to its default |

**Must Target mode** stops GearScore from inspecting anyone unless you're already targeting them: you click the person, *then* you see their score. It reduces tooltip clutter and UI lag. Off by default, so everyone is inspected on mouseover.

### Diagnostics

If a score is missing or looks wrong and you want to know why:

| Command | Does |
| --- | --- |
| `/gs why [name]` | Explain why a player has no score (defaults to your target) |
| `/gs gear [name]` | List the item read in each slot, with its score (needs `/gs debug`) |
| `/gs rescan [name]` | Drop the cached score and read the player again |
| `/gs dump` | Open a copyable window with the recent scan log and current state |
| `/gs debug` | Toggle live scan logging in chat |
| `/gs queue` | Show the pending inspect queue |

Names in these commands ignore letter case for Latin names: `/gs why arthas` finds `Arthas`.

The log is recorded even while `/gs debug` is off, so `/gs dump` works right after something goes wrong without having to reproduce it. Debug output is forced off on every load.

## API

For WeakAuras and other addons:

```lua
GearScoreLite.GetScore(unit)      -- score, averageItemLevel, complete, suspect, slotsRead, slotsOccupied
GearScoreLite.GetCached(name)     -- score, averageItemLevel, ageInSeconds, suspect, rememberedAt
GearScoreLite.Request(unit)       -- queue an async inspect
GearScoreLite.Forget(name)        -- drop this session's reading, so the next look re-reads it
GearScoreLite.GetPlayer()         -- your own score, averageItemLevel
GearScoreLite.RegisterCallback(f) -- f(name, score, averageItemLevel)
```

`GetScore()` returns `nil` if the unit is not a player. `suspect` means a slot looks transmogrified, so the score is a lower bound rather than a reading. `GetCached()` reads the cache only and never inspects. `rememberedAt` is set (a `time()` stamp) when the number comes from a previous session rather than a live read; `ageInSeconds` is then 0.

`Request()` always re-reads, even when a fresh score is already cached: an explicit call is treated as a deliberate request, unlike the automatic tooltip path, which leaves a recent score alone.

The `GEARSCORELITE_UPDATE` event fires with `(name, score, averageItemLevel)` whenever a score changes, your own included - use it as a custom WeakAuras trigger. Prefer `GetCached()` in anything that runs every frame; `GetScore()` walks all 18 inventory slots on each call.

## Removed from the original

- **The enchant penalty**, which was completely broken. It was the last feature the original author added back in 2010 and it never worked; other community forks dropped it too, so this keeps everyone on the same calculations. It was pointless regardless - GearScore can't inspect gems, which matter more, and it never even checked whether the enchant was any good. If you care about someone's gems and enchants, do a normal inspect.
- **Dead PVP scoring.**
- **The 2010 sponsor registry** - a hardcoded list of player and realm names that got special tooltip labels.

Have fun!
