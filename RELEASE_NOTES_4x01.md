# GearScoreLite Reborn 4x01 - Raid Reliability

Scores went missing or read far too low in ICC, because an inspect that had not answered yet was treated as an answer of zero. Settings unchanged, upgrades in place.

## Fixes

- Scores no longer vanish when you target someone. An inspect returning nothing (out of the ~28 yard range, or behind line of sight) used to overwrite a known score with `0`, which is hidden. The last known score is kept instead.
- `INSPECT_READY` is now handled, so the server's reply triggers the re-read instead of a fixed-window timer.
- Retry window raised from 5s to 12s, with the inspect re-sent on a 1.5s debounce rather than once per unit. The server grants one inspect at a time, so a 25-man raid queue could outlast the old window.

## Features

- Transmogrified slots are flagged in the tooltip as `(transmog detected -- score understated)`. A 3.3.5 client only receives visible-item ids, which on AzerothCore with `mod-transmog` are the cosmetic appearance, so no addon can correct the score. Detection uses the median item level, not the mean, and excludes weapons. Your own score is unaffected.
- `GetScore` / `GetCached` return this as a fourth value (`suspect`).
