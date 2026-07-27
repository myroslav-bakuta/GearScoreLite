# Changelog

## 4x00
Full rewrite of the scoring engine, tooltip hooks, settings and character-sheet
UI on top of the inherited codebase. The major version bump reflects the scale
of that rewrite and the incompatible saved-variables format.

- feat: scores now match GearScore 3.2.1 exactly (7000-band gradient for
  ICC/BiS gear, 12.25 colour scale, rounded average iLevel, Titan's Grip
  halves both weapon slots when a two-hander is equipped in either hand)
- feat: asynchronous inspect with a session cache and retry loop, so scores
  stop being partial or wrong from reading gear before the server responds
- feat: gradient colour mode (`GS_Gradient`/`ColorMode`) as an alternative to
  the classic 7-band colours, interpolated in linear light and quantised by
  a configurable `GradientStep`; `/gs color`, `/gs step`, `/gs range`
- feat: GearScoreLite.* API (GetScore, GetCached, Request, GetPlayer,
  RegisterCallback) and GEARSCORELITE_UPDATE event for WeakAuras
- feat: character sheet number is now a draggable, mouse-enabled anchor
  frame (`/gs unlock` / `/gs lock`) instead of a fixed FontString, with a
  bundled FiraSans-SemiBold font and fallback to the default WoW font
- feat: settings are boolean (`true`/`false`) instead of the legacy
  `1`/`-1`/`3` sentinel values, with a `GS_SettingsVersion` bump that
  discards incompatible saved variables instead of silently mismigrating them
- feat: `/gs combat` to hide all GearScore tooltip output while in combat
- feat: `/gs sheet` to toggle the character sheet number on/off
- feat: unitframe detection (ElvUI/oUF/ShadowUF/VuhDo) rewritten to resolve
  the frame under the cursor when Blizzard's "mouseover" token misses it
- fix: no longer errors out on players whose items are not in the local cache
- fix: average item level no longer renders as "-nan" on empty inventories
- fix: stop spamming NotifyInspect from every item tooltip
- fix: keep TempScore/ItemLink/ItemName/ItemLevel out of the global namespace
- fix: settings no longer alias the defaults table
- rem: broken enchant penalty, dead PVP scoring, the 2010 sponsor registry
  (hardcoded list of player/realm names with special tooltip labels)
- chore: changelog moved out of GearScoreLite.lua into this file

## 3x06
- fix: no longer errors out on players whose items are not in the local cache
- fix: average item level no longer renders as "-nan" on empty inventories
- fix: stop spamming NotifyInspect from every item tooltip
- fix: keep TempScore/ItemLink/ItemName/ItemLevel out of the global namespace
- fix: settings no longer alias the defaults table
- feat: scores now match GearScore 3.2.1 exactly (7000 colour band, 12.25 colour scale, rounded average iLevel, Titan's Grip edge case)
- feat: asynchronous inspect with a session cache, so scores stop being partial
- feat: GearScoreLite.* API and GEARSCORELITE_UPDATE event for WeakAuras
- feat: shift+drag the character sheet number
- rem: broken enchant penalty, dead PVP scoring, the 2010 sponsor registry

## 3x05
- See git commit history for full details.
- fix: larger GS font size for personal character's window
- feat: add support for "must target" mode
- fix: remove nonsensical check for combat state
- fix: initialize combat tracker state on startup
- fix: remove braindead enchant score algorithm
- feat: add support for ElvUI, Shadowed and VuhDo unit frames
- fix: don't calculate GearScore while inspect window open
- fix: properly apply default settings for "false" values
