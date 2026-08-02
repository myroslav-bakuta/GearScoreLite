# Changelog

## 4x03
Scores were missing for most players in a raid. The cause was structural: the
addon tracked exactly one pending inspect, so hovering a second player discarded
the first, and every target change cancelled the scan in flight. Sweeping a raid
frame left nobody scored but the last person hovered.

- fix: pending inspects are queued instead of overwriting one another. The server
  still grants one inspect at a time, but units now wait their turn rather than
  being dropped; up to 40 are held, and the oldest is discarded first because the
  newest is whoever the user is looking at right now
- fix: `PLAYER_TARGET_CHANGED` no longer cancels the running scan. Retargeting
  mid-scan was abandoning work that was about to complete
- fix: `target` and `mouseover` are swapped for the `raidN`/`partyN` token when
  the same player is in the group. Both tooltip tokens point elsewhere the moment
  the user looks away, which aborted the scan they had just started
- fix: cached scores expire after 10 minutes, and another player's entry is
  dropped outright on `UNIT_INVENTORY_CHANGED`. A score was previously kept for
  the whole session, so regems and mid-raid loot never showed up
- feat: `/gs debug` logs every scan step, `/gs dump` opens a copyable window with
  the recent log and current state, `/gs why <name>` explains why one player has
  no score, `/gs queue` shows what is pending. The log is always recorded, so
  `/gs dump` works after the fact without reproducing the fault
- feat: the tooltip says why a score is missing instead of showing nothing --
  out of range, inspect window open, scanning, or queued. Toggle with
  `/gs status`
- feat: the transmog warning is now opt-in and off by default (`/gs mog`). On a
  realm without mod-transmog it can only ever be a false positive
- note: `GS_SettingsVersion` is 6, so saved options reset to their defaults once

## 4x02
Crash and lockup fixes found by running the addon against a real Lua 5.1
interpreter with a mocked 3.3.5a API. All three faults needed timing or a third
party addon to reproduce, which is why manual testing never surfaced them.

- fix: an error thrown by a registered callback no longer takes GearScore down
  with it. `Announce` called listeners directly, so a fault in another addon
  unwound out through the tooltip hook and left `inTooltipHook` stuck true,
  which silently suppressed every later tooltip for the rest of the session.
  Listeners and `WeakAuras.ScanEvents` are now called through `pcall`, and the
  `inTooltipHook` / `refreshing` guards reset even when something below throws
- fix: no longer errors on a partially filled item cache. `GetItemInfo`
  populates its entry field by field, so the name can be back while rarity and
  item level are still nil; the scan gated on the name alone and the item
  tooltip hook gated on nothing, so both reached the scoring maths with nil and
  raised "attempt to compare number with nil"
- fix: a slot whose item data was still arriving no longer counts as scored.
  It previously contributed -1 to the total while the scan reported itself
  complete, locking in a score several hundred points low; such a scan is now
  reported incomplete so the retry loop keeps going and the average item level
  stays honest
- fix: the internal 187.05 heirloom placeholder no longer reaches the tooltip
  as a real item level. It was zeroed only on the scored path, so an heirloom
  in a slot outside `GS_ItemTypes` returned the sentinel verbatim
- chore: Lua 5.1 test harness in `.luatest/` (mocked WoW API, 279 checks over
  the colour schemes, scoring, tooltips, slash commands, events and public API).
  Run with `python .luatest/run.py`
Raid reliability. Scores went missing or read far too low in ICC, mostly
because an inspect that had not answered yet was treated as an answer of zero.

- fix: handle `INSPECT_READY` instead of only polling on a timer. The reply is
  now what triggers the re-read, so a score no longer depends on the server
  answering inside a fixed window
- fix: an inspect that returns nothing (target out of the ~28 yard range or
  behind line of sight) no longer overwrites a known score with 0, which is
  what made GearScore vanish when a raid member drifted away
- fix: retry window raised from 5s to 12s, and the inspect request is
  re-sent on a 1.5s debounce rather than once per unit. The server grants one
  inspect at a time, so in a 25-man raid the queue alone could outlast the old
  window and leave the entry stuck at 0
- feat: transmogrified slots are flagged in the tooltip. A 3.3.5 client only
  receives visible-item ids for other players, so on AzerothCore with
  mod-transmog a mogged slot is indistinguishable from real gear and drags the
  score down; slots far below the character's median item level are now called
  out as "transmog detected -- score understated" instead of silently lowering
  the number. `GetScore`/`GetCached` return this as a fourth value

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
