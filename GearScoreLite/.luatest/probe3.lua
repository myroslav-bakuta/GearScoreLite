-- Does the line-257 guard actually protect line 188/189?
-- GetItemInfo returns the NAME first. A partially-populated cache entry can
-- return a name while ilvl/rarity are still nil, which is exactly the shape
-- that crashes GetItemScore.
package.path = ".luatest/?.lua;" .. package.path
local mock = require("wowmock")
local G = _G
mock.install(G)
local state = mock.state
local function say(...) io.write(...) io.write("\n") end

state.units["player"] = { name="Kappa", class="WARRIOR", classLocal="Warrior", exists=true, isPlayer=true }
dofile("informationLite.lua"); dofile("GearScoreLite.lua")
mock.fireEvent(G.GearScore, "ADDON_LOADED", "GearScoreLite")

say("=== Case A: name present, ItemLevel nil, equipLoc valid ===")
state.items["|Hitem:A|h"] = { name="Named Chest", rarity=4, ilvl=nil, equipLoc="INVTYPE_CHEST" }
say("  GetItemInfo first return (name) = ", tostring((G.GetItemInfo("|Hitem:A|h"))))
say("  -> line 257 guard PASSES (name is truthy)")
state.units["a"] = { name="A", class="MAGE", classLocal="Mage", exists=true, isPlayer=true }
state.inventory["A"] = { [5] = "|Hitem:A|h" }
local o, e = pcall(G.GearScore_GetScore, "a")
say("  GearScore_GetScore -> ok=", tostring(o), "  err=", tostring(e))

say("")
say("=== Case B: name present, rarity nil, ilvl valid ===")
state.items["|Hitem:B|h"] = { name="Named Legs", rarity=nil, ilvl=232, equipLoc="INVTYPE_LEGS" }
state.units["b"] = { name="B", class="MAGE", classLocal="Mage", exists=true, isPlayer=true }
state.inventory["B"] = { [7] = "|Hitem:B|h" }
local o2, e2 = pcall(G.GearScore_GetScore, "b")
say("  GearScore_GetScore -> ok=", tostring(o2), "  err=", tostring(e2))

say("")
say("=== Case C: the item tooltip path (no line-257 guard at all) ===")
mock.clearTooltip()
G.IsEquippableItem = function() return true end
local o3, e3 = pcall(G.GearScore_HookItem, "Named Chest", "|Hitem:A|h", G.GameTooltip)
say("  GearScore_HookItem -> ok=", tostring(o3), "  err=", tostring(e3))
say("  ^ tooltip hook calls GetItemScore directly; ANY hovered item with a")
say("    half-filled cache entry throws inside OnTooltipSetItem.")

say("")
say("=== Case D: ilvl 0 (common on private-server cores for some items) ===")
state.items["|Hitem:D|h"] = { name="Zero", rarity=4, ilvl=0, equipLoc="INVTYPE_CHEST" }
local o4, e4, l4 = pcall(G.GearScore_GetItemScore, "|Hitem:D|h")
say("  GetItemScore ok=", tostring(o4), " score=", tostring(e4), " ilvl=", tostring(l4))
say("  (ilvl 0 uses GS_Formula.B; negative intermediate is clamped to 0)")

say("")
say("=== Case E: does GS_Formula.B have a [4] entry for epic low-ilvl items? ===")
say("  GS_Formula.B[4] = ", tostring(G.GS_Formula.B[4]))
say("  GS_Formula.A[1] = ", tostring(G.GS_Formula.A[1]), "  <-- nil!")
say("  A rarity-1 (poor->remapped to 2) item is fine, but what about ilvl>120 rarity 1?")
state.items["|Hitem:E|h"] = { name="Grey High", rarity=1, ilvl=200, equipLoc="INVTYPE_CHEST" }
local o5, e5 = pcall(G.GearScore_GetItemScore, "|Hitem:E|h")
say("  rarity1 ilvl200 -> ok=", tostring(o5), " score=", tostring(e5))
