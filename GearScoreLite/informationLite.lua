-------------------------------------------------------------------------------
--                     GearScoreLite: Reborn -- data tables                  --
--                                                                           --
-- Values here are kept byte-identical to GearScore 3.2.1 (maintained fork).  --
-- Changing any number desynchronises the score from every other GearScore    --
-- user, which is the whole point of the addon. Do not "tune" them.           --
-------------------------------------------------------------------------------

GS_ItemTypes = {
	["INVTYPE_RELIC"] = { ["SlotMOD"] = 0.3164, ["ItemSlot"] = 18, ["Enchantable"] = false },
	["INVTYPE_TRINKET"] = { ["SlotMOD"] = 0.5625, ["ItemSlot"] = 33, ["Enchantable"] = false },
	["INVTYPE_2HWEAPON"] = { ["SlotMOD"] = 2.000, ["ItemSlot"] = 16, ["Enchantable"] = true },
	["INVTYPE_WEAPONMAINHAND"] = { ["SlotMOD"] = 1.0000, ["ItemSlot"] = 16, ["Enchantable"] = true },
	["INVTYPE_WEAPONOFFHAND"] = { ["SlotMOD"] = 1.0000, ["ItemSlot"] = 17, ["Enchantable"] = true },
	["INVTYPE_RANGED"] = { ["SlotMOD"] = 0.3164, ["ItemSlot"] = 18, ["Enchantable"] = true },
	["INVTYPE_THROWN"] = { ["SlotMOD"] = 0.3164, ["ItemSlot"] = 18, ["Enchantable"] = false },
	["INVTYPE_RANGEDRIGHT"] = { ["SlotMOD"] = 0.3164, ["ItemSlot"] = 18, ["Enchantable"] = false },
	["INVTYPE_SHIELD"] = { ["SlotMOD"] = 1.0000, ["ItemSlot"] = 17, ["Enchantable"] = true },
	["INVTYPE_WEAPON"] = { ["SlotMOD"] = 1.0000, ["ItemSlot"] = 36, ["Enchantable"] = true },
	["INVTYPE_HOLDABLE"] = { ["SlotMOD"] = 1.0000, ["ItemSlot"] = 17, ["Enchantable"] = false },
	["INVTYPE_HEAD"] = { ["SlotMOD"] = 1.0000, ["ItemSlot"] = 1, ["Enchantable"] = true },
	["INVTYPE_NECK"] = { ["SlotMOD"] = 0.5625, ["ItemSlot"] = 2, ["Enchantable"] = false },
	["INVTYPE_SHOULDER"] = { ["SlotMOD"] = 0.7500, ["ItemSlot"] = 3, ["Enchantable"] = true },
	["INVTYPE_CHEST"] = { ["SlotMOD"] = 1.0000, ["ItemSlot"] = 5, ["Enchantable"] = true },
	["INVTYPE_ROBE"] = { ["SlotMOD"] = 1.0000, ["ItemSlot"] = 5, ["Enchantable"] = true },
	["INVTYPE_WAIST"] = { ["SlotMOD"] = 0.7500, ["ItemSlot"] = 6, ["Enchantable"] = false },
	["INVTYPE_LEGS"] = { ["SlotMOD"] = 1.0000, ["ItemSlot"] = 7, ["Enchantable"] = true },
	["INVTYPE_FEET"] = { ["SlotMOD"] = 0.75, ["ItemSlot"] = 8, ["Enchantable"] = true },
	["INVTYPE_WRIST"] = { ["SlotMOD"] = 0.5625, ["ItemSlot"] = 9, ["Enchantable"] = true },
	["INVTYPE_HAND"] = { ["SlotMOD"] = 0.7500, ["ItemSlot"] = 10, ["Enchantable"] = true },
	["INVTYPE_FINGER"] = { ["SlotMOD"] = 0.5625, ["ItemSlot"] = 31, ["Enchantable"] = false },
	["INVTYPE_CLOAK"] = { ["SlotMOD"] = 0.5625, ["ItemSlot"] = 15, ["Enchantable"] = true },
}

-- Bumped whenever the shape of GS_Settings changes incompatibly. On mismatch the
-- saved table is discarded rather than migrated: pre-3x06 releases stored -1 for
-- "off", and -1 is truthy in Lua, so a silent migration would turn every disabled
-- option back on.
GS_SettingsVersion = 7

GS_DefaultSettings = {
	["Version"] = GS_SettingsVersion,
	["Player"] = true,        -- GearScore line on player tooltips
	["Item"] = true,          -- GearScore line on item tooltips
	["Level"] = false,        -- also show item level
	["MustTarget"] = false,   -- only score the unit you have targeted
	["HideInCombat"] = false, -- suppress all tooltip output while in combat
	["Status"] = true,        -- say why a score is missing instead of showing nothing
	["Debug"] = false,        -- log every scan step to chat; never saved as on
	["PaperDoll"] = true,     -- number on the character sheet
	["Locked"] = true,        -- while locked the number ignores the mouse entirely
	["AnchorX"] = 72,         -- character sheet number, offset from PaperDollFrame TOPLEFT
	["AnchorY"] = -241,
	-- Colour scheme. "gradient" interpolates between GS_Gradient.Stops, quantised
	-- by GradientStep. "classic" is the inherited 7-band GearScore 3.2.1 scheme
	-- in GS_Quality.
	["ColorMode"] = "gradient",
	["GradientStep"] = 200,   -- GS per colour jump
	["GradientMin"] = 3000,   -- below this the colour sticks to the first stop
	["GradientMax"] = 6500,   -- above this it sticks to the last
}

-- Two or more hex stops, spaced evenly across [GradientMin, GradientMax]. Cyan =
-- low GS, red = high, matching the classic scheme's convention that red/gold is
-- top-end gear. Every stop is fully saturated and light enough to stand out on
-- the dark tooltip background: contrast stays between 5.5 and 13.1.
--
-- The route matters. Cyan and yellow sit on opposite ends of the blue-yellow
-- axis, so interpolating straight between them passes through grey -- the
-- midrange washes out to sat 0.14. Going around through green instead keeps
-- saturation at 0.56 or above the whole way.
--
-- Kept out of SavedVariables: this is an editable data table like GS_Quality,
-- not a user setting.
GS_Gradient = {
	["Stops"] = { "00b8ff", "6ee000", "ffc400", "ff1e1e" },
}

GS_Formula = {
	["A"] = {
		[4] = { ["A"] = 91.4500, ["B"] = 0.6500 },
		[3] = { ["A"] = 81.3750, ["B"] = 0.8125 },
		[2] = { ["A"] = 73.0000, ["B"] = 1.0000 }
	},
	["B"] = {
		[4] = { ["A"] = 26.0000, ["B"] = 1.2000 },
		[3] = { ["A"] = 0.7500, ["B"] = 1.8000 },
		[2] = { ["A"] = 8.0000, ["B"] = 2.0000 },
		[1] = { ["A"] = 0.0000, ["B"] = 2.2500 }
	}
}

GS_Quality = {
	-- 6000-7000: full ICC/BiS territory. Without this band every top geared
	-- player clamped to the same colour and description. The red->gold gradient
	-- itself only runs 6300-7000 (realistic ICC BiS floor up to Shadowmourne-tier
	-- ceiling); 6000-6300 stays pure red via the A/B/C/D values overshooting and
	-- getting clamped in GearScore_GetQuality.
	[7000] = {
		["Red"] = { ["A"] = 1, ["B"] = 6300, ["C"] = 0.00014286, ["D"] = -1 },
		["Green"] = { ["A"] = 0, ["B"] = 6300, ["C"] = 0.00114286, ["D"] = 1 },
		["Blue"] = { ["A"] = 0, ["B"] = 6300, ["C"] = 0.00071429, ["D"] = 1 },
		["Description"] = "Artifact"
	},
	[6000] = {
		["Red"] = { ["A"] = 0.94, ["B"] = 5000, ["C"] = 0.00006, ["D"] = 1 },
		["Green"] = { ["A"] = 0.47, ["B"] = 5000, ["C"] = 0.00047, ["D"] = -1 },
		["Blue"] = { ["A"] = 0, ["B"] = 0, ["C"] = 0, ["D"] = 0 },
		["Description"] = "Legendary"
	},
	[5000] = {
		["Red"] = { ["A"] = 0.69, ["B"] = 4000, ["C"] = 0.00025, ["D"] = 1 },
		["Green"] = { ["A"] = 0.28, ["B"] = 4000, ["C"] = 0.00019, ["D"] = 1 },
		["Blue"] = { ["A"] = 0.97, ["B"] = 4000, ["C"] = 0.00096, ["D"] = -1 },
		["Description"] = "Epic"
	},
	[4000] = {
		["Red"] = { ["A"] = 0.0, ["B"] = 3000, ["C"] = 0.00069, ["D"] = 1 },
		["Green"] = { ["A"] = 0.5, ["B"] = 3000, ["C"] = 0.00022, ["D"] = -1 },
		["Blue"] = { ["A"] = 1, ["B"] = 3000, ["C"] = 0.00003, ["D"] = -1 },
		["Description"] = "Superior"
	},
	[3000] = {
		["Red"] = { ["A"] = 0.12, ["B"] = 2000, ["C"] = 0.00012, ["D"] = -1 },
		["Green"] = { ["A"] = 1, ["B"] = 2000, ["C"] = 0.00050, ["D"] = -1 },
		["Blue"] = { ["A"] = 0, ["B"] = 2000, ["C"] = 0.001, ["D"] = 1 },
		["Description"] = "Uncommon"
	},
	[2000] = {
		["Red"] = { ["A"] = 1, ["B"] = 1000, ["C"] = 0.00088, ["D"] = -1 },
		["Green"] = { ["A"] = 1, ["B"] = 000, ["C"] = 0.00000, ["D"] = 0 },
		["Blue"] = { ["A"] = 1, ["B"] = 1000, ["C"] = 0.001, ["D"] = -1 },
		["Description"] = "Common"
	},
	[1000] = {
		["Red"] = { ["A"] = 0.55, ["B"] = 0, ["C"] = 0.00045, ["D"] = 1 },
		["Green"] = { ["A"] = 0.55, ["B"] = 0, ["C"] = 0.00045, ["D"] = 1 },
		["Blue"] = { ["A"] = 0.55, ["B"] = 0, ["C"] = 0.00045, ["D"] = 1 },
		["Description"] = "Trash"
	},
}

GS_CommandList = {
	"---GearScore Options List---",
	"/gs player  -> Toggles display of scores on players.",
	"/gs item    -> Toggles display of scores for items.",
	"/gs level   -> Toggles iLevel information.",
	"/gs target  -> Only score the unit you currently have targeted.",
	"/gs combat  -> Toggles hiding all GearScore output while in combat.",
	"/gs status  -> Toggles the 'out of range / scanning' line when no score is known.",
	"/gs sheet   -> Toggles the number on the character sheet.",
	"/gs unlock  -> Lets you drag the character sheet number ('/gs lock' when done).",
	"/gs color   -> Switches colour scheme (gradient / classic).",
	"/gs step N  -> Gradient colour step size in GS (default 200).",
	"/gs range MIN MAX -> Score range the gradient spans (default 3000 6500).",
	"/gs reset   -> Resets GearScore's options back to default.",
	"--- Diagnostics ---",
	"/gs debug   -> Toggles live scan logging in chat.",
	"/gs why [name] -> Explains why a player has no score (defaults to your target).",
	"/gs gear [name] -> Lists the item the last scan read in each slot, with its score (needs /gs debug).",
	"/gs rescan [name] -> Drops the cached score and reads the player again.",
	"/gs dump    -> Opens a copyable window with the recent scan log.",
	"/gs queue   -> Shows the pending inspect queue.",
}
