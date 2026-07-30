-- GearScoreLite: Reborn -- test suite, plain Lua 5.1
package.path = ".luatest/?.lua;" .. package.path

local mock = require("wowmock")
local G = _G
mock.install(G)
local state = mock.state

-- ------------------------------------------------------------ test infra --
local pass, fail, failures = 0, 0, {}
local function ok(cond, name, detail)
    if cond then pass = pass + 1
    else
        fail = fail + 1
        local msg = tostring(name) .. (detail and ("  -- " .. tostring(detail)) or "")
        failures[fail] = msg
        io.write("!! FAIL: ", msg, "\n")
    end
end
local function eq(a, b, name)
    ok(a == b, name, "expected " .. tostring(b) .. ", got " .. tostring(a))
end
local function near(a, b, tol, name)
    ok(type(a) == "number" and math.abs(a - b) <= tol, name,
       "expected ~" .. tostring(b) .. ", got " .. tostring(a))
end
local function say(s) io.write(s, "\n") end
local function section(s) say("\n== " .. s .. " ==") end

-- --------------------------------------------------------------- fixtures --
state.units["player"]   = { name = "Kappa",  class = "WARRIOR", classLocal = "Warrior", exists = true, isPlayer = true }
state.units["target"]   = { name = "Target", class = "MAGE",    classLocal = "Mage",    exists = true, isPlayer = true }
state.units["mouseover"]= { name = "Target", class = "MAGE",    classLocal = "Mage",    exists = true, isPlayer = true }

local function mkitem(id, rarity, ilvl, equipLoc)
    local link = "|cffffffff|Hitem:" .. id .. "|h[Item" .. id .. "]|h|r"
    state.items[link] = { name = "Item" .. id, rarity = rarity, ilvl = ilvl, equipLoc = equipLoc }
    return link
end

-- A plausible full epic set.
local SLOTS = {
    [1]="INVTYPE_HEAD",[2]="INVTYPE_NECK",[3]="INVTYPE_SHOULDER",[5]="INVTYPE_CHEST",
    [6]="INVTYPE_WAIST",[7]="INVTYPE_LEGS",[8]="INVTYPE_FEET",[9]="INVTYPE_WRIST",
    [10]="INVTYPE_HAND",[11]="INVTYPE_FINGER",[12]="INVTYPE_FINGER",
    [13]="INVTYPE_TRINKET",[14]="INVTYPE_TRINKET",[15]="INVTYPE_CLOAK",
    [16]="INVTYPE_WEAPONMAINHAND",[17]="INVTYPE_WEAPONOFFHAND",[18]="INVTYPE_RANGEDRIGHT",
}
local function equipFullSet(who, ilvl, rarity)
    state.inventory[who] = {}
    local n = 0
    for slot, loc in pairs(SLOTS) do
        state.inventory[who][slot] = mkitem(who .. "_" .. slot, rarity or 4, ilvl, loc)
        n = n + 1
    end
    return n
end
equipFullSet("Kappa", 245)
equipFullSet("Target", 232)

-- ----------------------------------------------------------------- load ----
section("Load")
local chunk1, err1 = loadfile("informationLite.lua")
ok(chunk1 ~= nil, "informationLite.lua compiles under Lua 5.1", err1)
if chunk1 then chunk1() end

local chunk2, err2 = loadfile("GearScoreLite.lua")
ok(chunk2 ~= nil, "GearScoreLite.lua compiles under Lua 5.1", err2)
if not chunk2 then
    say("FATAL: " .. tostring(err2))
    os.exit(1)
end
local okrun, runerr = pcall(chunk2)
ok(okrun, "GearScoreLite.lua executes at load", runerr)
if not okrun then say("FATAL: " .. tostring(runerr)); os.exit(1) end

local EventFrame = G.GearScore
ok(EventFrame ~= nil, "EventFrame created")
mock.fireEvent(EventFrame, "ADDON_LOADED", "GearScoreLite")
ok(type(G.GS_Settings) == "table", "GS_Settings initialised on ADDON_LOADED")
eq(G.GS_Settings.Version, G.GS_SettingsVersion, "settings version stamped")

-- ------------------------------------------------------- GetQuality bands --
section("GearScore_GetQuality")
G.GS_Settings.ColorMode = "classic"
for _, score in ipairs({ 1, 500, 999, 1000, 1001, 2500, 3999, 4000, 5500, 6000, 6300, 6999, 7000, 9999 }) do
    local r, b, g, desc = G.GearScore_GetQuality(score)
    ok(type(r) == "number" and type(g) == "number" and type(b) == "number" and type(desc) == "string",
       "classic quality returns 3 numbers + desc at " .. score)
    ok(r >= 0 and r <= 1 and g >= 0 and g <= 1 and b >= 0 and b <= 1,
       "classic channels clamped 0..1 at " .. score,
       string.format("r=%s b=%s g=%s", tostring(r), tostring(b), tostring(g)))
end
local _, _, _, d0 = G.GearScore_GetQuality(nil)
eq(d0, "Trash", "nil score -> Trash")
local _, _, _, d1 = G.GearScore_GetQuality(0)
eq(d1, "Trash", "score 0 -> Trash (clamped into band 1)")

-- ----------------------------------------------------------- gradient mode --
section("Gradient mode")
G.GS_Settings.ColorMode = "gradient"
for score = 0, 8000, 137 do
    local r, b, g, desc = G.GearScore_GetQuality(score)
    ok(type(r) == "number" and r >= 0 and r <= 1 and b >= 0 and b <= 1 and g >= 0 and g <= 1,
       "gradient channels in range at " .. score,
       string.format("r=%s b=%s g=%s", tostring(r), tostring(b), tostring(g)))
    ok(type(desc) == "string", "gradient desc is string at " .. score)
end

-- top stop must be reachable
local rTop, bTop, gTop = G.GearScore_GetQuality(6500)
near(rTop, 1.0, 0.02, "gradient at GradientMax hits the last stop (red=1)")
near(gTop, 0.118, 0.05, "gradient at GradientMax green low")

-- monotonic-ish: quantisation must produce distinct buckets
local seen = {}
for s = 3000, 6500, 50 do
    local r, b, g = G.GearScore_GetQuality(s)
    seen[string.format("%.3f_%.3f_%.3f", r, b, g)] = true
end
local nbuckets = 0
for _ in pairs(seen) do nbuckets = nbuckets + 1 end
ok(nbuckets >= 15, "gradient quantisation yields >=15 distinct colours over 3000-6500",
   "got " .. nbuckets)

-- degenerate configs must fall back, not error
local saveMin, saveMax, saveStep = G.GS_Settings.GradientMin, G.GS_Settings.GradientMax, G.GS_Settings.GradientStep
G.GS_Settings.GradientMin, G.GS_Settings.GradientMax = 5000, 5000
local okc = pcall(G.GearScore_GetQuality, 5000)
ok(okc, "GradientMax == GradientMin does not error")
G.GS_Settings.GradientMin, G.GS_Settings.GradientMax = 6000, 3000
okc = pcall(G.GearScore_GetQuality, 4000)
ok(okc, "inverted gradient range does not error")
G.GS_Settings.GradientMin, G.GS_Settings.GradientMax = saveMin, saveMax
G.GS_Settings.GradientStep = 0
okc = pcall(G.GearScore_GetQuality, 4000)
ok(okc, "GradientStep 0 does not error (clamped to 1)")
G.GS_Settings.GradientStep = -50
okc = pcall(G.GearScore_GetQuality, 4000)
ok(okc, "negative GradientStep does not error")
G.GS_Settings.GradientStep = 999999
okc = pcall(G.GearScore_GetQuality, 4000)
ok(okc, "absurd GradientStep does not error")
G.GS_Settings.GradientStep = saveStep

-- malformed stops
local saveStops = G.GS_Gradient.Stops
G.GS_Gradient.Stops = { "zzzzzz", "not-hex" }
okc = pcall(G.GearScore_GetQuality, 4000)
ok(okc, "unparseable gradient stops fall back to classic without error")
G.GS_Gradient.Stops = { "00b8ff" }
okc = pcall(G.GearScore_GetQuality, 4000)
ok(okc, "single gradient stop falls back to classic without error")
G.GS_Gradient.Stops = {}
okc = pcall(G.GearScore_GetQuality, 4000)
ok(okc, "empty gradient stop list falls back without error")
G.GS_Gradient.Stops = saveStops

-- ---------------------------------------------------------- GetItemScore ---
section("GearScore_GetItemScore")
local s0 = G.GearScore_GetItemScore(nil)
eq(s0, 0, "nil item link -> 0")

for _, rarity in ipairs({ 0, 1, 2, 3, 4, 5, 7 }) do
    local link = mkitem("q" .. rarity, rarity, 200, "INVTYPE_CHEST")
    local okv, score = pcall(G.GearScore_GetItemScore, link)
    ok(okv, "GetItemScore rarity " .. rarity .. " does not error", tostring(score))
    ok(type(score) == "number", "GetItemScore rarity " .. rarity .. " returns number")
end

-- unknown equip location must not blow up on the GS_ItemTypes lookup
local bag = mkitem("bag", 1, 0, "INVTYPE_BAG")
local okv, sc = pcall(G.GearScore_GetItemScore, bag)
ok(okv, "unknown equipLoc does not error", tostring(sc))
eq(sc, -1, "unknown equipLoc -> -1")

-- an item the client has not cached yet: GetItemInfo returns nil for everything
local uncached = "|cffffffff|Hitem:99999|h[Uncached]|h|r"
local okv2, sc2 = pcall(G.GearScore_GetItemScore, uncached)
ok(okv2, "uncached item (GetItemInfo -> nil) does not error", tostring(sc2))

-- ------------------------------------------------------------- GetScore ----
section("GearScore_GetScore")
local score, ilvl, complete, suspect = G.GearScore_GetScore("player")
ok(type(score) == "number" and score > 0, "player score computed", tostring(score))
eq(complete, true, "full cached set reports complete")
eq(suspect, false, "own inventory never flagged as mogged")
near(ilvl, 245, 1, "player average ilvl matches equipped")

local ts, tilvl, tcomplete = G.GearScore_GetScore("Target", "target")
ok(type(ts) == "number" and ts > 0, "target score computed via (name, unit)", tostring(ts))
near(tilvl, 232, 1, "target average ilvl")

-- non-player
state.units["npc"] = { name = "Innkeeper", exists = true, isPlayer = false }
eq(G.GearScore_GetScore("npc"), nil, "non-player returns nil")

-- naked
state.units["naked"] = { name = "Naked", class = "ROGUE", classLocal="Rogue", exists = true, isPlayer = true }
state.inventory["Naked"] = {}
local ns, nilvl, ncomplete = G.GearScore_GetScore("naked")
eq(ns, 0, "naked player scores 0")
eq(nilvl, 0, "naked player ilvl 0")
eq(ncomplete, true, "naked player scan is complete")

-- incomplete: one slot's item not in the local cache
state.units["partial"] = { name = "Partial", class="MAGE", classLocal="Mage", exists=true, isPlayer=true }
equipFullSet("Partial", 232)
state.inventory["Partial"][5] = "|cffffffff|Hitem:404|h[NotCached]|h|r"  -- no GetItemInfo entry
local ps, pilvl, pcomplete = G.GearScore_GetScore("partial")
eq(pcomplete, false, "uncached slot reports scan incomplete")
ok(ps > 0, "incomplete scan still returns a usable score")

-- transmog detection
state.units["mogged"] = { name = "Mogged", class="PALADIN", classLocal="Paladin", exists=true, isPlayer=true }
equipFullSet("Mogged", 245)
state.inventory["Mogged"][1] = mkitem("mogHead", 2, 20, "INVTYPE_HEAD")  -- lvl-20 cosmetic helm
local ms, milvl, mcomplete, msuspect = G.GearScore_GetScore("mogged")
eq(mcomplete, true, "mogged scan complete")
eq(msuspect, true, "low-ilvl armour slot flags transmog")

-- ...but a legitimately even set must not false-positive
local _, _, _, tsuspect = G.GearScore_GetScore("Target", "target")
eq(tsuspect, false, "even gear set is not flagged as transmog")

-- Titan's Grip: 2H in both hands
state.units["tg"] = { name = "TG", class="WARRIOR", classLocal="Warrior", exists=true, isPlayer=true }
equipFullSet("TG", 245)
state.inventory["TG"][16] = mkitem("tg2h1", 4, 245, "INVTYPE_2HWEAPON")
state.inventory["TG"][17] = mkitem("tg2h2", 4, 245, "INVTYPE_2HWEAPON")
local tgs = G.GearScore_GetScore("tg")
ok(type(tgs) == "number" and tgs > 0, "Titan's Grip set scores", tostring(tgs))

-- hunter weighting
state.units["hunter"] = { name = "Hunter", class="HUNTER", classLocal="Hunter", exists=true, isPlayer=true }
equipFullSet("Hunter", 245)
local hs = G.GearScore_GetScore("hunter")
ok(type(hs) == "number" and hs > 0, "hunter score computed", tostring(hs))

-- ------------------------------------------------------- slash commands ----
section("Slash commands")
local slash = G.SlashCmdList["MY2SCRIPT"]
ok(type(slash) == "function", "slash handler registered")
for _, cmd in ipairs({ "", "player", "show", "item", "level", "compare", "target", "combat",
                       "sheet", "lock", "unlock", "color", "colour", "reset", "help", "garbage",
                       "step", "step 0", "step abc", "step 250", "step -5", "step 1e9",
                       "range", "range 1 2", "range abc def", "range 3000 6500",
                       "range 6500 3000", "range 100", "  player  ", "PLAYER" }) do
    local okc2, e = pcall(slash, cmd)
    ok(okc2, "/gs '" .. cmd .. "' does not error", tostring(e))
end
local okc3, e3 = pcall(slash, nil)
ok(okc3, "/gs with nil argument does not error", tostring(e3))

-- verify step/range actually applied
slash("reset")
slash("step 250")
eq(G.GS_Settings.GradientStep, 250, "step command applied")
slash("range 2000 7000")
eq(G.GS_Settings.GradientMin, 2000, "range min applied")
eq(G.GS_Settings.GradientMax, 7000, "range max applied")
slash("reset")
eq(G.GS_Settings.GradientStep, 200, "reset restores default step")

-- reset must not alias the defaults table
slash("reset")
G.GS_Settings.GradientStep = 12345
eq(G.GS_DefaultSettings.GradientStep, 200, "reset copies defaults, does not alias them")
slash("reset")

-- ---------------------------------------------------------- unit tooltip ---
section("Unit tooltip hook")
G.GS_Settings.Player = true
G.GS_Settings.Level = true
G.GS_Settings.Compare = true
mock.clearTooltip()
G.GameTooltip:SetUnit("target")
local found = false
for _, l in ipairs(state.tooltipLines) do
    if type(l.text) == "string" and l.text:find("GearScore:") then found = true end
end
ok(found, "GearScore line added to unit tooltip")

-- No duplicate GearScore line from a single SetUnit
local n = 0
for _, l in ipairs(state.tooltipLines) do
    if type(l.text) == "string" and l.text:find("^GearScore:") then n = n + 1 end
end
eq(n, 1, "exactly one GearScore line per tooltip pass (no duplicate from refresh)")

-- HideInCombat
G.GS_Settings.HideInCombat = true
mock.fireEvent(EventFrame, "PLAYER_REGEN_DISABLED")
mock.clearTooltip()
G.GameTooltip:SetUnit("target")
local combatFound = false
for _, l in ipairs(state.tooltipLines) do
    if type(l.text) == "string" and l.text:find("GearScore:") then combatFound = true end
end
eq(combatFound, false, "HideInCombat suppresses tooltip output")
mock.fireEvent(EventFrame, "PLAYER_REGEN_ENABLED")
G.GS_Settings.HideInCombat = false

-- tooltip on a non-player must be silent
mock.clearTooltip()
G.GameTooltip:SetUnit("npc")
local npcLines = #state.tooltipLines
eq(npcLines, 0, "no GearScore output for NPC tooltips")

-- ---------------------------------------------------------- item tooltip ---
section("Item tooltip hook")
G.GS_Settings.Item = true
mock.clearTooltip()
local chest = mkitem("tt_chest", 4, 245, "INVTYPE_CHEST")
local okit, eit = pcall(G.GearScore_HookItem, "Chest", chest, G.GameTooltip)
ok(okit, "GearScore_HookItem on equippable item does not error", tostring(eit))
ok(#state.tooltipLines > 0, "item tooltip got a line")

mock.clearTooltip()
local okit2 = pcall(G.GearScore_HookItem, "Nothing", nil, G.GameTooltip)
ok(okit2, "GearScore_HookItem with nil link does not error")

-- non-equippable
mock.clearTooltip()
state.items["potion"] = { name = "Potion", rarity = 1, ilvl = 1, equipLoc = "" }
local okit3 = pcall(G.GearScore_HookItem, "Potion", "potion", G.GameTooltip)
ok(okit3, "non-equippable item does not error")
eq(#state.tooltipLines, 0, "non-equippable item adds no line")

-- hunter item lines
state.units["player"].class = "HUNTER"
mock.clearTooltip()
local bow = mkitem("tt_bow", 4, 245, "INVTYPE_RANGEDRIGHT")
local okit4 = pcall(G.GearScore_HookItem, "Bow", bow, G.GameTooltip)
ok(okit4, "hunter ranged item tooltip does not error")
local hunterLine = false
for _, l in ipairs(state.tooltipLines) do
    if type(l.text) == "string" and l.text:find("HunterScore") then hunterLine = true end
end
ok(hunterLine, "HunterScore line added for hunter ranged weapon")
state.units["player"].class = "WARRIOR"

-- uncached item in tooltip (GetItemInfo nil) -- the real client hits this constantly
mock.clearTooltip()
state.items["|cffffffff|Hitem:77777|h[Ghost]|h|r"] = nil
local ghostLink = "|cffffffff|Hitem:77777|h[Ghost]|h|r"
G.IsEquippableItem = function() return true end   -- client says equippable, info not cached
local okit5, eit5 = pcall(G.GearScore_HookItem, "Ghost", ghostLink, G.GameTooltip)
ok(okit5, "uncached-but-equippable item does not error in tooltip", tostring(eit5))
G.IsEquippableItem = function(link)
    local it = state.items[link]; return it ~= nil and it.equipLoc ~= nil and it.equipLoc ~= ""
end

-- ------------------------------------------------------------- events ------
section("Events")
for _, ev in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_EQUIPMENT_CHANGED",
                      "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
                      "INSPECT_READY", "PLAYER_TARGET_CHANGED" }) do
    local okev, eev = pcall(mock.fireEvent, EventFrame, ev, nil)
    ok(okev, "event " .. ev .. " handled without error", tostring(eev))
end
local okev2 = pcall(mock.fireEvent, EventFrame, "UNIT_INVENTORY_CHANGED", "player")
ok(okev2, "UNIT_INVENTORY_CHANGED(player) handled")
local okev3 = pcall(mock.fireEvent, EventFrame, "UNIT_INVENTORY_CHANGED", "target")
ok(okev3, "UNIT_INVENTORY_CHANGED(target) handled")
local okev4 = pcall(mock.fireEvent, EventFrame, "UNIT_INVENTORY_CHANGED", nil)
ok(okev4, "UNIT_INVENTORY_CHANGED(nil) handled")

-- ADDON_LOADED with a corrupt saved table
G.GS_Settings = "not a table"
local okev5 = pcall(mock.fireEvent, EventFrame, "ADDON_LOADED", "GearScoreLite")
ok(okev5, "ADDON_LOADED with corrupt GS_Settings handled")

-- The frame unregisters ADDON_LOADED on first run, so re-register to prove
-- the recovery path itself works.
EventFrame:RegisterEvent("ADDON_LOADED")
G.GS_Settings = { Version = 1, Player = false }   -- stale version
mock.fireEvent(EventFrame, "ADDON_LOADED", "GearScoreLite")
eq(G.GS_Settings.Version, G.GS_SettingsVersion, "stale settings version discarded and rebuilt")
eq(G.GS_Settings.Player, true, "defaults restored after version mismatch")

-- ----------------------------------------------------------- rescan loop ---
section("Rescan loop / OnUpdate")
local RescanFrame
for _, f in ipairs(state.frames) do
    if f._scripts["OnUpdate"] then RescanFrame = f end
end
ok(RescanFrame ~= nil, "rescan frame with OnUpdate exists")
if RescanFrame then
    RescanFrame:Show()
    local okup = true
    for i = 1, 80 do
        local o, e = pcall(mock.tick, RescanFrame, 0.6)
        if not o then okup = false; print("   tick error: " .. tostring(e)); break end
    end
    ok(okup, "80 OnUpdate ticks run without error")
    ok(not RescanFrame:IsShown(), "rescan frame hides itself when idle")
end

-- ------------------------------------------------------------ public API ---
section("Public API")
ok(type(G.GearScoreLite) == "table", "GearScoreLite API table exists")
for _, fn in ipairs({ "GetScore", "GetCached", "Request", "GetPlayer", "RegisterCallback" }) do
    ok(type(G.GearScoreLite[fn]) == "function", "API." .. fn .. " is a function")
end
local okapi, apierr = pcall(G.GearScoreLite.GetScore, "player")
ok(okapi, "API.GetScore('player')", tostring(apierr))
eq(G.GearScoreLite.GetCached("NoSuchPlayer"), nil, "API.GetCached miss -> nil")
local okapi2 = pcall(G.GearScoreLite.GetCached, nil)
ok(okapi2, "API.GetCached(nil) does not error")
local okapi3 = pcall(G.GearScoreLite.Request, nil)
ok(okapi3, "API.Request(nil) does not error")
local okapi4 = pcall(G.GearScoreLite.Request, "target")
ok(okapi4, "API.Request('target') does not error")
local okapi5 = pcall(G.GearScoreLite.RegisterCallback, "not a function")
ok(okapi5, "API.RegisterCallback with non-function does not error")

local fired = {}
G.GearScoreLite.RegisterCallback(function(name, sc, il) table.insert(fired, { name, sc, il }) end)
-- force a score change to trigger Announce
state.inventory["Target"][5] = mkitem("Target_5_new", 4, 264, "INVTYPE_CHEST")
G.GearScoreLite.Request("target")
ok(#fired > 0, "registered callback fired on score change", "fired " .. #fired)

local ps2, pi2 = G.GearScoreLite.GetPlayer()
ok(type(ps2) == "number" and type(pi2) == "number", "API.GetPlayer returns two numbers")

-- a callback that throws must not take the addon down
G.GearScoreLite.RegisterCallback(function() error("boom") end)
state.inventory["Target"][5] = mkitem("Target_5_new2", 4, 200, "INVTYPE_CHEST")
local okcb, cberr = pcall(G.GearScoreLite.Request, "target")
ok(okcb, "a throwing listener does not break the announce path", tostring(cberr))

-- ------------------------------------------------------------- results -----
say("\n" .. string.rep("=", 60))
say(string.format("PASS: %d   FAIL: %d", pass, fail))
if fail > 0 then
    say("\nFAILURES:")
    for _, f in ipairs(failures) do print("  - " .. f) end
end
say(string.rep("=", 60))
os.exit(fail == 0 and 0 or 1)
