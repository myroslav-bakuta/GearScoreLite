# GearScoreLite Reborn 4x03 - Raid Scanning and Diagnostics

Most players in a raid never got a score. The cause was structural: the addon tracked exactly one pending inspect, so hovering a second player discarded the first, and every target change cancelled the scan in flight. Sweeping a raid frame left nobody scored but the last person hovered.

**Your saved options reset to defaults once on first login.** The settings format changed to carry the new toggles, and the addon discards an old layout rather than migrating it.

## Fixes

- Pending inspects are queued instead of overwriting one another. The server still grants one inspect at a time, but units now wait their turn rather than being dropped. Up to 40 are held, and the oldest is discarded first, since the newest is whoever you are looking at right now.
- Changing target no longer cancels the running scan. Retargeting mid-scan was throwing away work that was about to finish.
- `target` and `mouseover` are swapped for the stable `raidN`/`partyN` token when that player is in your group. Both tooltip tokens point somewhere else the moment you look away, which aborted the scan they had just started.
- Cached scores now expire after 10 minutes, and another player's entry is dropped immediately when their gear changes. A score was previously kept for the whole session, so regems and mid-raid loot never appeared.

## New

- The tooltip says why a score is missing instead of showing nothing: out of range, inspect window open, scanning, or queued. Toggle with `/gs status`.
- The transmog warning is now opt-in and **off by default**. Enable it with `/gs mog`. On a realm without `mod-transmog` the flag can only ever be a false positive, and even where it is right it is a guess about someone else's gear.

## Diagnostics

If scores still go missing, these produce something concrete to report:

- `/gs debug` - log every scan step to chat.
- `/gs dump` - open a copyable window with the recent log plus current state.
- `/gs why <name>` - explain why one player has no score. Defaults to your target.
- `/gs queue` - show what is pending.

The log is recorded even while debug output is off, so `/gs dump` works right after something goes wrong without having to reproduce it. Debug output is forced off on every load: left on by accident, it looks exactly like the addon being broken.

## Testing

- 320 checks in `.luatest/`, up from 279. New coverage for the inspect queue, cache expiry, the status line, the transmog toggle and the debug commands.
- Run with `python .luatest/run.py` (needs `pip install lupa`). Lua 5.1 specifically, matching the 3.3.5a client.
