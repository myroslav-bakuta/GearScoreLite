package.path=".luatest/?.lua;"..package.path
local mock=require("wowmock"); local G=_G; mock.install(G); local state=mock.state
local function say(...) io.write(...) io.write("\n") end
state.units["player"]={name="K",class="WARRIOR",classLocal="W",exists=true,isPlayer=true}
dofile("informationLite.lua"); dofile("GearScoreLite.lua")
mock.fireEvent(G.GearScore,"ADDON_LOADED","GearScoreLite")
local SLOTS={[1]="INVTYPE_HEAD",[2]="INVTYPE_NECK",[3]="INVTYPE_SHOULDER",[5]="INVTYPE_CHEST",
[6]="INVTYPE_WAIST",[7]="INVTYPE_LEGS",[8]="INVTYPE_FEET",[9]="INVTYPE_WRIST",[10]="INVTYPE_HAND",
[11]="INVTYPE_FINGER",[12]="INVTYPE_FINGER",[13]="INVTYPE_TRINKET",[14]="INVTYPE_TRINKET",[15]="INVTYPE_CLOAK"}

say("=== Half-filled cache entry must NOT be silently scored as complete ===")
state.units["p"]={name="P",class="MAGE",classLocal="M",exists=true,isPlayer=true}
state.inventory["P"]={}
for s,l in pairs(SLOTS) do
  local link="|Hitem:p"..s.."|h"
  state.items[link]={name="i"..s,rarity=4,ilvl=245,equipLoc=l}
  state.inventory["P"][s]=link
end
local s1,i1,c1=G.GearScore_GetScore("p")
say(string.format("  fully cached : score=%s ilvl=%s complete=%s",tostring(s1),tostring(i1),tostring(c1)))

-- now make ONE slot half-filled (name present, ilvl nil)
state.items["|Hitem:p5|h"]={name="i5",rarity=4,ilvl=nil,equipLoc="INVTYPE_CHEST"}
local s2,i2,c2=G.GearScore_GetScore("p")
say(string.format("  one half-fill: score=%s ilvl=%s complete=%s",tostring(s2),tostring(i2),tostring(c2)))
say("  ^ complete should ideally be FALSE so the retry loop keeps going.")
say("    score dropped by "..tostring(s1-s2).." because the slot contributes -1.")
