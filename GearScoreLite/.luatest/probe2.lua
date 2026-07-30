-- Isolate the heirloom / uncached-item paths through GetItemScore + GetScore.
package.path = ".luatest/?.lua;" .. package.path
local mock = require("wowmock")
local G = _G
mock.install(G)
local state = mock.state
local function say(...) io.write(...) io.write("\n") end

state.units["player"] = { name="Kappa", class="WARRIOR", classLocal="Warrior", exists=true, isPlayer=true }
dofile("informationLite.lua"); dofile("GearScoreLite.lua")
mock.fireEvent(G.GearScore, "ADDON_LOADED", "GearScoreLite")

local function mk(id, rarity, ilvl, loc)
    local link = "|Hitem:"..id.."|h"
    state.items[link] = { name=id, rarity=rarity, ilvl=ilvl, equipLoc=loc }
    return link
end

say("=== Heirloom (rarity 7) in slots WITH a GS_ItemTypes entry ===")
local hlRelic = mk("hlRelic", 7, 1, "INVTYPE_RELIC")
local a,b,c = G.GearScore_GetItemScore(hlRelic)
say("  RELIC   -> score=", tostring(a), " ilvl=", tostring(b))

local hlShoulder = mk("hlSh", 7, 1, "INVTYPE_SHOULDER")
local a2,b2 = G.GearScore_GetItemScore(hlShoulder)
say("  SHOULDER-> score=", tostring(a2), " ilvl=", tostring(b2))

say("")
say("=== Heirloom in a slot with NO GS_ItemTypes entry (falls to line 199) ===")
local hlBag = mk("hlBag", 7, 1, "INVTYPE_BAG")
local a3,b3 = G.GearScore_GetItemScore(hlBag)
say("  BAG     -> score=", tostring(a3), " ilvl=", tostring(b3), "   <-- 187.05 sentinel leaks?")

say("")
say("=== Rarity 7 that is NOT >=2 and <=4 after remap? (7->3, so it is) ===")
say("  (rarity 7 remaps to 3, so the guarded path is taken)")

say("")
say("=== UNCACHED item: GetItemInfo returns nil for every field ===")
local ghost = "|Hitem:doesnotexist|h"
local o, s, il, slot = pcall(G.GearScore_GetItemScore, ghost)
say("  pcall ok=", tostring(o))
say("  score=", tostring(s), " ilvl=", tostring(il), " slot=", tostring(slot))
say("  ^ ItemLevel is nil here; line 188 does ( ItemLevel > 120 ) only when Slot is truthy.")
say("  GS_ItemTypes[nil] is nil, so Slot is nil and the comparison is skipped.")

say("")
say("=== But: cached item with a KNOWN equipLoc and nil ItemLevel? ===")
-- Some private-server cores return a valid equipLoc with ilvl 0/nil mid-cache-fill.
state.items["|Hitem:weird|h"] = { name="weird", rarity=4, ilvl=nil, equipLoc="INVTYPE_CHEST" }
local o2, e2 = pcall(G.GearScore_GetItemScore, "|Hitem:weird|h")
say("  pcall ok=", tostring(o2), "  err/score=", tostring(e2))
say("  ^ THIS is the crash case: ItemLevel nil + valid equipLoc -> nil > 120")

say("")
say("=== Same shape via GearScore_GetScore (a whole unit) ===")
state.units["weird"] = { name="Weird", class="MAGE", classLocal="Mage", exists=true, isPlayer=true }
state.inventory["Weird"] = { [5] = "|Hitem:weird|h" }
local o3, e3 = pcall(G.GearScore_GetScore, "weird")
say("  pcall ok=", tostring(o3), "  err/score=", tostring(e3))

say("")
say("=== rarity nil (item cached but rarity missing) ===")
state.items["|Hitem:norare|h"] = { name="nr", rarity=nil, ilvl=200, equipLoc="INVTYPE_CHEST" }
local o4, e4 = pcall(G.GearScore_GetItemScore, "|Hitem:norare|h")
say("  pcall ok=", tostring(o4), " score=", tostring(e4))
