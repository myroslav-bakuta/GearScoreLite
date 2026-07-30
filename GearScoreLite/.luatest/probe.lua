-- Follow-up probes: consequences of the listener-error bug, plus edge cases.
package.path = ".luatest/?.lua;" .. package.path
local mock = require("wowmock")
local G = _G
mock.install(G)
local state = mock.state
local function say(...) io.write(...) io.write("\n") end

state.units["player"] = { name="Kappa", class="WARRIOR", classLocal="Warrior", exists=true, isPlayer=true }
state.units["target"] = { name="Target", class="MAGE", classLocal="Mage", exists=true, isPlayer=true }
state.units["mouseover"] = { name="Target", class="MAGE", classLocal="Mage", exists=true, isPlayer=true }

local function mkitem(id, rarity, ilvl, loc)
    local link = "|Hitem:" .. id .. "|h[I" .. id .. "]|h"
    state.items[link] = { name="I"..id, rarity=rarity, ilvl=ilvl, equipLoc=loc }
    return link
end
local SLOTS = {[1]="INVTYPE_HEAD",[2]="INVTYPE_NECK",[3]="INVTYPE_SHOULDER",[5]="INVTYPE_CHEST",
[6]="INVTYPE_WAIST",[7]="INVTYPE_LEGS",[8]="INVTYPE_FEET",[9]="INVTYPE_WRIST",[10]="INVTYPE_HAND",
[11]="INVTYPE_FINGER",[12]="INVTYPE_FINGER",[13]="INVTYPE_TRINKET",[14]="INVTYPE_TRINKET",
[15]="INVTYPE_CLOAK",[16]="INVTYPE_WEAPONMAINHAND",[17]="INVTYPE_WEAPONOFFHAND",[18]="INVTYPE_RANGEDRIGHT"}
local function equip(who, ilvl)
    state.inventory[who] = {}
    for s, l in pairs(SLOTS) do state.inventory[who][s] = mkitem(who.."_"..s.."_"..ilvl, 4, ilvl, l) end
end
equip("Kappa", 245); equip("Target", 232)

dofile("informationLite.lua"); dofile("GearScoreLite.lua")
local EventFrame = G.GearScore
mock.fireEvent(EventFrame, "ADDON_LOADED", "GearScoreLite")

say("=== PROBE 1: does a bad listener wedge the tooltip permanently? ===")
G.GearScoreLite.RegisterCallback(function() error("bad addon") end)

-- Simulate the real client: tooltip hook runs inside pcall-less WoW code, but
-- the error escapes GearScoreLite's own hook. Check the flags afterwards.
equip("Target", 264)   -- force a score change so Announce fires
local okhook, ehook = pcall(function() G.GameTooltip:SetUnit("target") end)
say("  tooltip SetUnit succeeded: ", tostring(okhook))
say("  error: ", tostring(ehook))

-- Now inspect the module flags via a fresh scan attempt.
mock.clearTooltip()
equip("Target", 200)
local ok2, e2 = pcall(function() G.GameTooltip:SetUnit("target") end)
say("  second SetUnit succeeded: ", tostring(ok2), "  err=", tostring(e2))
say("  tooltip lines produced on 2nd pass: ", tostring(#state.tooltipLines))
for i, l in ipairs(state.tooltipLines) do say("    ", i, ": ", tostring(l.text)) end

say("")
say("=== PROBE 2: is the score cache updated before or after Announce? ===")
local sc, il = G.GearScoreLite.GetCached("Target")
say("  cached Target score=", tostring(sc), " ilvl=", tostring(il))

say("")
say("=== PROBE 3: OnUpdate loop with a throwing listener ===")
local Rescan
for _, f in ipairs(state.frames) do if f._scripts["OnUpdate"] then Rescan = f end end
state.units["far"] = { name="Far", class="DRUID", classLocal="Druid", exists=true, isPlayer=true, canInspect=true }
state.inventory["Far"] = {}
pcall(G.GearScoreLite.Request, "far")
Rescan:Show()
local ticks, err = 0, nil
for i = 1, 40 do
    local o, e = pcall(mock.tick, Rescan, 0.6)
    ticks = ticks + 1
    if not o then err = e break end
end
say("  ticks run: ", tostring(ticks), "  error: ", tostring(err))

say("")
say("=== PROBE 4: MedianOf mutates the caller's table (sort in place) ===")
-- Levels is built fresh each call, so this is safe today, but verify ordering
-- assumptions hold for an even count.
say("  (checked by inspection: Levels is local per GetScore call)")

say("")
say("=== PROBE 5: ilvl 187.05 relic sentinel leaking into the average ===")
state.units["relic"] = { name="Relic", class="PALADIN", classLocal="Paladin", exists=true, isPlayer=true }
equip("Relic", 245)
-- rarity 7 (Heirloom) forces ItemLevel = 187.05 inside GetItemScore
state.inventory["Relic"][18] = mkitem("heirloom", 7, 1, "INVTYPE_RELIC")
local rs, ril, rc, rsus = G.GearScore_GetScore("relic")
say("  score=", tostring(rs), " avg ilvl=", tostring(ril), " complete=", tostring(rc), " suspect=", tostring(rsus))

say("")
say("=== PROBE 6: heirloom in an armour slot and the mog check ===")
state.units["hl"] = { name="HL", class="WARRIOR", classLocal="Warrior", exists=true, isPlayer=true }
equip("HL", 245)
state.inventory["HL"][3] = mkitem("hlShoulder", 7, 1, "INVTYPE_SHOULDER")
local hs, hil, hc, hsus = G.GearScore_GetScore("hl")
say("  score=", tostring(hs), " avg=", tostring(hil), " suspect=", tostring(hsus))

say("")
say("=== PROBE 7: GetItemScore arithmetic when GetItemInfo returns nil ===")
local okp7, ep7 = pcall(G.GearScore_GetItemScore, "|Hitem:unknown|h[?]|h")
say("  pcall ok=", tostring(okp7), " result/err=", tostring(ep7))

say("")
say("=== PROBE 8: negative / huge scores through the colour path ===")
for _, s in ipairs({ -5000, -1, 0, 1e9, 1/0 }) do
    local o, r = pcall(G.GearScore_GetQuality, s)
    say("  score=", tostring(s), " ok=", tostring(o), " r=", tostring(r))
end

say("")
say("=== PROBE 9: NaN score ===")
local nan = 0/0
local o9, r9 = pcall(G.GearScore_GetQuality, nan)
say("  NaN ok=", tostring(o9), " r=", tostring(r9))
local o9b, r9b = pcall(G.GearScore_GetQuality, nan)
say("  NaN gradient ok=", tostring(o9b), " r=", tostring(r9b))
