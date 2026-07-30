# GearScoreLite Reborn 4x00 - Full Rewrite

Full rewrite of the scoring engine, tooltip hooks, settings and character-sheet UI. The major bump reflects an incompatible saved-variables format: settings reset on upgrade.

## Features

- Scores now match GearScore 3.2.1 exactly: 7000-band gradient for ICC/BiS gear, 12.25 colour scale, rounded average iLevel, Titan's Grip halving both weapon slots.
- Asynchronous inspect with a session cache and retry loop, so scores are no longer partial from reading gear before the server responds.
- Gradient colour mode as an alternative to the classic 7-band colours, interpolated in linear light and quantised by a configurable step. New commands: `/gs color`, `/gs step`, `/gs range`.
- `GearScoreLite.*` API (`GetScore`, `GetCached`, `Request`, `GetPlayer`, `RegisterCallback`) and a `GEARSCORELITE_UPDATE` event for WeakAuras.
- Character sheet number is now a draggable anchor frame (`/gs unlock` / `/gs lock`) with a bundled FiraSans-SemiBold font.
- Settings are boolean instead of the legacy `1`/`-1`/`3` sentinels, with a version bump that discards incompatible saved variables rather than mismigrating them.
- `/gs combat` hides all tooltip output while in combat; `/gs sheet` toggles the character sheet number.
- Unitframe detection (ElvUI/oUF/ShadowUF/VuhDo) rewritten to resolve the frame under the cursor when Blizzard's mouseover token misses it.

## Fixes

- Cooldown timers on WeakAuras icons work again alongside OmniCC. `OptionalDeps` forced WeakAuras to load before this addon, and therefore before OmniCC, so OmniCC's hook never saw a WeakAuras cooldown. The line bought nothing and is gone.
- No longer errors on players whose items are not in the local cache.
- Average item level no longer renders as `-nan` on empty inventories.
- Stopped spamming `NotifyInspect` from every item tooltip.
- Kept `TempScore` / `ItemLink` / `ItemName` / `ItemLevel` out of the global namespace.
- Settings no longer alias the defaults table.

## Removed

- Broken enchant penalty, dead PVP scoring, and the 2010 sponsor registry.

## Chore

- Changelog moved out of `GearScoreLite.lua` into `CHANGELOG.md`.

Note: due to the incompatible saved-variables format, your settings reset to defaults after updating.
