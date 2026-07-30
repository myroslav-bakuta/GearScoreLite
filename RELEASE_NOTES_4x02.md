# GearScoreLite Reborn 4x02 - Crash Fixes

Three faults that could break GearScore mid-session, found by testing against a real Lua 5.1 interpreter with a mocked 3.3.5a client API. Settings unchanged, upgrades in place.

## Fixes

- An error inside another addon's listener no longer freezes every GearScore tooltip until `/reload`. Listeners and `WeakAuras.ScanEvents` now run through `pcall`, and the `inTooltipHook` / `refreshing` guards reset even when something below them throws.
- Half-loaded item data no longer throws `attempt to compare number with nil`. `GetItemInfo` fills its cache field by field, so the name can arrive while rarity and item level are still `nil`.
- Gear that is still loading no longer locks in a low score. Such a scan is now reported incomplete so the retry loop keeps going.
- The internal heirloom placeholder (`187.05`) no longer reaches the tooltip as a real item level.

## Testing

- Lua 5.1 test harness in `.luatest/`: mocked WoW 3.3.5a API plus 279 checks covering both colour schemes, every rarity and equip slot, transmog detection, Titan's Grip, hunter weighting, slash commands, events and the public API.
- Run with `python .luatest/run.py` (needs `pip install lupa`). Lua 5.1 specifically: later versions changed integer division, `%` and `math.floor` semantics.

## Housekeeping

- The `GearScoreLite.lua` header still read `4x00`, missed during the 4x01 bump. It now tracks the `.toc`.
