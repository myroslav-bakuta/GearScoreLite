# GearScoreLite: Reborn

Shows how well geared a player is, right on their tooltip.

A mod by **Kappa** for the **WoW FreedomUA** server, based on the final official GearScoreLite (3x04) by Mirrikat45 & Gnomezilla.

For World of Warcraft 3.3.5 (WotLK).

## What is GearScore?

GearScore is a rough measure of a player's power. Each item slot is weighted by how much it contributes: a high level chest piece carries more stats than a high level belt, so the chest is worth more.

That weighting makes it more useful than average item level. Wearing a few weak high-level pieces in low-impact slots does not inflate the score.

## Installation

Download the latest `GearScoreLite-Reborn-vX.Y.Z.zip` from the [Releases page](https://github.com/myroslav-bakuta/GearScoreLite/releases), copy the `GearScoreLite` folder from it into `Interface\AddOns\`, and restart the game.

Remove the original `GearScore` addon if you have it. Both define the same globals, and whichever loads last breaks the other without any error.

When the saved settings format changes, upgrading resets your options to their defaults once. The addon discards the old layout rather than migrating it.

## Reading a score

A player's score appears on their tooltip. While it is being established it carries a label:

| Shown | Means |
| --- | --- |
| `GearScore: 6478 (scanning)` | Their gear is still arriving or being confirmed; the number can still change |
| `GearScore: 6478 (scanned)` | Just read from a finished inspect |
| `GearScore: 6478` | A settled score read a little while ago |
| `GearScore: 6478 (memory)` | From a previous session, shown while a fresh read runs |

On a realm with transmogrification the first reading is often the cosmetic set, because the client shows that before the inspect reply lands. The cosmetic items never carry gems, while the real ones arrive about half a second later with their gems. Once gems show up, the addon knows it has the real set, uses it even if it scores lower than the cosmetic one, and settles in about a second. For a player who wears no gems at all it waits until the set stops changing, which takes a few seconds. Only a settled or gem-confirmed score is saved for later sessions.

The game only hands over a player's gear while some unit token points at them: your target, focus, the player under the cursor, or a party or raid member. If you move the cursor away from a stranger before their scan finishes, the scan pauses, and the unfinished number stays marked `(scanning)`. Hover them again within two minutes and it continues from where it stopped. Players in your group, your target and your focus are read to the end without hovering.

## Features

- Scores match GearScore 3.2.1: the 7000 band for ICC/BiS gear, the 12.25 colour scale, rounded average item level, and the Titan's Grip rule (a two-hander in either hand halves both weapon slots).
- Transmog-aware inspect. The cosmetic set looks complete before the real one arrives, so the addon tells them apart by gems, which only the real items carry. A mogged player ends up with their real score, and a later cosmetic reading can't replace it.
- An inspect queue. The server grants one inspect at a time, so the others wait their turn, and sweeping over the raid frames scores everyone you hovered.
- When a score is missing, the tooltip says why: out of range, inspect window open, scanning, or queued.
- A diagnostic log (`/gs debug`) saved to disk, so a problem can be reported with everything needed to fix it.
- A gradient colour mode as an alternative to the classic 7 colour bands, interpolated in linear light with a configurable step.
- A draggable number on the character sheet, in the bundled FiraSans-SemiBold font (or the default WoW font if it can't be loaded).
- Unit frames from ElvUI, oUF, ShadowedUnitFrames and VuhDo work: when Blizzard's `mouseover` token misses the frame under the cursor, the addon resolves it directly.
- An API for WeakAuras and other addons (see below).
- While Blizzard's Inspect window or Examiner is open, GearScore sends no inspect requests of its own, so the window never switches to another player's gear and talents.

## Commands

`/gs`, `/gset` and `/gearscore` all work. `/gs` on its own prints the command list in game.

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
| `/gs rescan [name]` | Drop the cached score and read the player again (your target if no name) |

Must Target mode stops GearScore from inspecting anyone you haven't targeted: you click the person, then you see their score. It cuts tooltip clutter and UI lag. It is off by default, so everyone is inspected on mouseover.

Player names in `/gs rescan` ignore letter case, Cyrillic included: `/gs rescan мирослав` finds `Мирослав`.

## Reporting a problem

1. Type `/gs debug`. Logging stays on across `/reload` and relogs until you type `/gs debug` again.
2. Reproduce the problem: hover the player whose score looks wrong, wait, hover again.
3. Type `/reload`. The game writes the log to disk only on `/reload` or logout.
4. Send `WTF\Account\<your account>\SavedVariables\GearScoreLite.lua`.

The log holds:

- a header for each session: addon version, client build, locale, realm, your settings and the list of loaded addons;
- about the last 120 lines from before you switched it on;
- every scan step, and the items read in each slot whenever the set changes;
- inspect replies, and inspects sent by other addons, with the name of the addon that sent them;
- inventory and target changes;
- at each `/reload` or logout, a snapshot of every score read that session.

The log keeps the newest 5000 lines. `/gs debug clear` empties it.

## API

For WeakAuras and other addons:

```lua
GearScoreLite.GetScore(unit)      -- score, averageItemLevel, complete, suspect, slotsRead, slotsOccupied
GearScoreLite.GetCached(name)     -- score, averageItemLevel, ageInSeconds, suspect, rememberedAt
GearScoreLite.GetState(name)      -- "scanning", "queued", "paused" or nil
GearScoreLite.Request(unit)       -- queue an async inspect
GearScoreLite.Forget(name)        -- drop this session's reading, so the next look re-reads it
GearScoreLite.GetPlayer()         -- your own score, averageItemLevel
GearScoreLite.RegisterCallback(f) -- f(name, score, averageItemLevel)
```

`GetScore()` returns `nil` if the unit is not a player. `suspect` means a slot looks transmogrified, so the score is a lower bound rather than a reading. `GetCached()` reads the cache only and never inspects. `rememberedAt` is a `time()` stamp, set when the number comes from a previous session; `ageInSeconds` is then 0.

`Request()` always re-reads, even when a fresh score is cached. The automatic tooltip path leaves a recent score alone; an explicit call is treated as a deliberate request.

The `GEARSCORELITE_UPDATE` event fires with `(name, score, averageItemLevel)` whenever a score changes, your own included. Use it as a custom WeakAuras trigger. Prefer `GetCached()` in anything that runs every frame, because `GetScore()` walks all 18 inventory slots on each call.

## Removed from the original

- The enchant penalty. It was the last feature the original author added, back in 2010, and it never worked. Other community forks dropped it too, so everyone stays on the same calculation. GearScore can't see gems, which matter more, and the penalty never checked whether an enchant was any good. If you care about someone's gems and enchants, inspect them normally.
- PvP scoring, which no longer did anything.
- The 2010 sponsor registry: a hardcoded list of player and realm names that got special tooltip labels.

Have fun!
