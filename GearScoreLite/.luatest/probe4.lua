package.path = ".luatest/?.lua;" .. package.path
local mock = require("wowmock"); local G=_G; mock.install(G); local state=mock.state
local function say(...) io.write(...) io.write("\n") end
state.units["player"]={name="K",class="WARRIOR",classLocal="W",exists=true,isPlayer=true}
dofile("informationLite.lua"); dofile("GearScoreLite.lua")
mock.fireEvent(G.GearScore,"ADDON_LOADED","GearScoreLite")

say("=== Sweep every rarity x ilvl for errors / GS_Formula gaps ===")
local bad = 0
for rarity = 0, 8 do
  for _, ilvl in ipairs({0,1,50,100,120,121,150,200,232,245,264,284,300}) do
    state.items["|Hitem:s|h"]={name="s",rarity=rarity,ilvl=ilvl,equipLoc="INVTYPE_CHEST"}
    local o,e = pcall(G.GearScore_GetItemScore,"|Hitem:s|h")
    if not o then bad=bad+1; say(string.format("  ERROR rarity=%d ilvl=%d -> %s",rarity,ilvl,tostring(e))) end
  end
end
say("  total errors: "..bad)

say("")
say("=== Which (Table, rarity) combos are nil in GS_Formula? ===")
for _,t in ipairs({"A","B"}) do
  for r=1,4 do
    if not G.GS_Formula[t][r] then say("  GS_Formula."..t.."["..r.."] = nil") end
  end
end
say("  -> reached only when ItemLevel>120 (Table A) and remapped rarity==1.")
say("  Remap: 0->2, 1->2, 5->4, 7->3. So rarity 1 never survives as 1. Safe today.")

say("")
say("=== Sweep every equipLoc in GS_ItemTypes ===")
local n,errs=0,0
for loc in pairs(G.GS_ItemTypes) do
  state.items["|Hitem:l|h"]={name="l",rarity=4,ilvl=245,equipLoc=loc}
  local o,e=pcall(G.GearScore_GetItemScore,"|Hitem:l|h")
  n=n+1; if not o then errs=errs+1; say("  ERROR "..loc.." -> "..tostring(e)) end
end
say(string.format("  swept %d equipLocs, %d errors",n,errs))
