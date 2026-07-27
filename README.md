# GearScoreLite: Reborn

Helps you quickly and easily judge a player's level of gear.

A mod by **Kappa** for the **WoW FreedomUA** server, based on the final official
GearScoreLite (3x04) by Mirrikat45 & Gnomezilla.

For World of Warcraft 3.3.5 (WotLK). Current version: **4x00**.

## What is GearScore?

The GearScore algorithm gives you a good indication of the player's actual power level. Every item slot is intelligently weighted by how important and powerful each slot is; for example, a high level chest piece is "more powerful and provides more stats" than a high level belt, so the chest is "worth a higher score".

This intelligent weighting makes it much more useful than simply looking at the "average item level", since it's impossible to "cheat" the score by just wearing a few weak, high-level pieces in low-impact armor slots.

## Installation

Copy the `GearScoreLite` folder into `Interface\AddOns\` and restart the game.
Remove the original `GearScore` addon if you have it - the two conflict.

## Highlights

- **Scores match GearScore 3.2.1 exactly.** The 7000-band gradient for ICC/BiS
  gear, the 12.25 colour scale, rounded average item level, and the Titan's Grip
  edge case (a two-hander in either hand halves both weapon slots) all behave
  like the reference implementation.
- **Asynchronous inspect with a session cache.** Scores no longer come out
  partial or wrong from reading gear before the server has answered; failed
  inspects are retried.
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

## API

For WeakAuras and other addons:

```lua
GearScoreLite.GetScore(unit)      -- score, averageItemLevel, complete
GearScoreLite.GetCached(name)     -- score, averageItemLevel, ageInSeconds (cache only)
GearScoreLite.Request(unit)       -- queue an async inspect
GearScoreLite.GetPlayer()         -- your own score, averageItemLevel
GearScoreLite.RegisterCallback(f) -- f(name, score, averageItemLevel)
```

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
