# GearScoreLite: Reborn

Helps you quickly and easily judge a player's level of gear.

A mod by **Kappa** for the **WoW FreedomUA** server, based on the final official
GearScoreLite (3x04) by Mirrikat45 & Gnomezilla.

For World of Warcraft 3.3.5 (WotLK). Current version: **4x03**.

## What is GearScore?

The GearScore algorithm gives you a good indication of the player's actual power level. Every item slot is intelligently weighted by how important and powerful each slot is; for example, a high level chest piece is "more powerful and provides more stats" than a high level belt, so the chest is "worth a higher score".

This intelligent weighting makes it much more useful than simply looking at the "average item level", since it's impossible to "cheat" the score by just wearing a few weak, high-level pieces in low-impact armor slots.

## Installation

Download the latest `GearScoreLite - Reborn - vX.Y.Z.zip` from the
[Releases page](https://github.com/myroslav-bakuta/GearScoreLite_Reborn_mod/releases),
then copy the `GearScoreLite` folder out of it into `Interface\AddOns\` and
restart the game.

Remove the original `GearScore` addon if you have it - the two conflict.

Upgrading from 4x02 or earlier resets your options to their defaults once. The
saved settings format changed in 4x03, and the addon discards an old layout
rather than migrating it.

## Highlights

- **Scores match GearScore 3.2.1 exactly.** The 7000-band gradient for ICC/BiS
  gear, the 12.25 colour scale, rounded average item level, and the Titan's Grip
  edge case (a two-hander in either hand halves both weapon slots) all behave
  like the reference implementation.
- **Asynchronous inspect with a session cache.** Scores no longer come out
  partial or wrong from reading gear before the server has answered; failed
  inspects are retried, and a cached score is refreshed once it goes stale or
  the player's gear changes.
- **A queue, so a whole raid gets scored.** The server grants one inspect at a
  time. Pending requests used to overwrite each other, so sweeping the raid
  frames left nobody scored but the last person hovered; they now wait their
  turn.
- **Tells you why a score is missing** instead of showing nothing - out of
  range, inspect window open, scanning, or queued.
- **Built-in diagnostics.** `/gs why` explains a single player, `/gs dump` opens
  a copyable log of recent scans. See the commands below.
- **Gradient colour mode** as an alternative to the classic 7 colour bands,
  interpolated in linear light with a configurable step size.
- **Draggable character-sheet number** with a bundled FiraSans-SemiBold font
  (falls back to the default WoW font if it can't be loaded).
- **Unit frame support** for ElvUI, oUF, ShadowedUnitFrames and VuhDo - the
  frame under the cursor is resolved directly when Blizzard's `mouseover` token
  misses it.
- **WeakAuras-friendly API** (see below).
- **Doesn't fight the Inspect window.** No GearScore calculation happens while
  Blizzard's Inspect or the Examiner addon is open, which fixes the bug where
  the Inspect window kept changing contents and showing random talents and gear.

## Commands

All of `/gs`, `/gset` and `/gearscore` work. Running `/gs` with no argument
prints the command list in-game.

| Command | Does |
| --- | --- |
| `/gs player` (or `show`) | Toggle player scores in tooltips |
| `/gs item` | Toggle item scores |
| `/gs level` | Toggle item levels |
| `/gs compare` | Toggle comparisons |
| `/gs target` | Toggle "Must Target" mode |
| `/gs combat` | Toggle hiding all GearScore tooltip output while in combat |
| `/gs mog` | Toggle the "transmog detected" warning (off by default) |
| `/gs status` | Toggle the "out of range / scanning" line shown when no score is known |
| `/gs sheet` | Toggle the character sheet number |
| `/gs unlock` / `/gs lock` | Unlock the character sheet number so you can drag it, then lock it again |
| `/gs color` | Switch between `classic` and `gradient` colours |
| `/gs step 200` | Gradient quantisation step, in GS |
| `/gs range 3000 6500` | Gradient low/high bounds |
| `/gs reset` | Restore every option to its default |

**Must Target mode** stops GearScore from inspecting anyone unless you're
already targeting them: you click the person, *then* you see their score. It
reduces tooltip clutter and UI lag. Off by default, so everyone is inspected on
mouseover.

**Transmog warning.** On AzerothCore with `mod-transmog`, an inspected player's
gear arrives as the cosmetic appearance, so a mogged slot drags their score
down and no addon can correct it - the real item is never sent. Slots far below
the character's median item level can be flagged as a warning, but it is only a
guess, and on a realm without transmog it can only ever be a false positive.
Off by default; enable with `/gs mog`.

### Diagnostics

If a score is missing and you want to know why:

| Command | Does |
| --- | --- |
| `/gs why [name]` | Explain why a player has no score (defaults to your target) |
| `/gs dump` | Open a copyable window with the recent scan log and current state |
| `/gs debug` | Toggle live scan logging in chat |
| `/gs queue` | Show the pending inspect queue |

The log is recorded even while `/gs debug` is off, so `/gs dump` works right
after something goes wrong without having to reproduce it. Debug output is
forced off on every load.

## API

For WeakAuras and other addons:

```lua
GearScoreLite.GetScore(unit)      -- score, averageItemLevel, complete, suspect
GearScoreLite.GetCached(name)     -- score, averageItemLevel, ageInSeconds, suspect
GearScoreLite.Request(unit)       -- queue an async inspect
GearScoreLite.GetPlayer()         -- your own score, averageItemLevel
GearScoreLite.RegisterCallback(f) -- f(name, score, averageItemLevel)
```

`GetScore()` returns `nil` if the unit is not a player. `suspect` means a slot
looks transmogrified, so the score is a lower bound rather than a reading.
`GetCached()` reads the cache only and never inspects.

`Request()` always re-reads, even when a fresh score is already cached: an
explicit call is treated as a deliberate request, unlike the automatic tooltip
path, which leaves a recent score alone.

The `GEARSCORELITE_UPDATE` event fires with `(name, score, averageItemLevel)`
whenever a score changes - use it as a custom WeakAuras trigger. Prefer
`GetCached()` in anything that runs every frame; `GetScore()` walks all 18
inventory slots on each call.

## Removed from the original

- **The enchant penalty**, which was completely broken. It was the last feature
  the original author added back in 2010 and it never worked; other community
  forks dropped it too, so this keeps everyone on the same calculations. It was
  pointless regardless - GearScore can't inspect gems, which matter more, and it
  never even checked whether the enchant was any good. If you care about
  someone's gems and enchants, do a normal inspect.
- **Dead PVP scoring.**
- **The 2010 sponsor registry** - a hardcoded list of player and realm names
  that got special tooltip labels.

See [CHANGELOG.md](GearScoreLite/CHANGELOG.md) for the full version history.

Have fun!
