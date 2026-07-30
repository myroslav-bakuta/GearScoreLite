-------------------------------------------------------------------------------
--                        GearScoreLite: Reborn                              --
--                             Version 4x02                                  --
--                              mod by Kappa                                 --
--     https://github.com/myroslav-bakuta/GearScoreLite_Reborn_mod          --
--   (forked from https://github.com/Arcitec/GearScoreLite_Reborn)          --
--                    See CHANGELOG.md for version history                  --
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- NOTE: this addon defines the same globals as the full GearScore addon
-- (GearScore_GetScore, GS_Quality, GS_Settings, ...). The two cannot be loaded
-- at the same time -- whichever loads last wins and the other silently breaks.
-------------------------------------------------------------------------------

local floor, min, max, select = math.floor, math.min, math.max, select
local tonumber = tonumber
local GetInventoryItemLink, GetItemInfo = GetInventoryItemLink, GetItemInfo
local UnitIsPlayer, UnitClass, UnitName, UnitExists = UnitIsPlayer, UnitClass, UnitName, UnitExists
local UnitIsUnit, CanInspect, NotifyInspect = UnitIsUnit, CanInspect, NotifyInspect
local GetTime, sort = GetTime, table.sort

-- Session state. Nothing here is saved: an inspect is cheap to redo and stale
-- scores are worse than no score.
local GSL = {
	cache = {},            -- [name] = { score, ilvl, complete, suspect, time }
	player = { score = 0, ilvl = 0 },
	listeners = {},
	scanName = nil,
	scanUnit = nil,
	scanTries = 0,
	playerTries = 0,
	timer = 0,
	lastInspectName = nil,
	lastInspectTime = 0,
	inCombat = false,
	refreshing = false,
}

-------------------------------- Get Quality ----------------------------------

-- IMPORTANT: this returns the channels in the order (red, BLUE, green). Every
-- legacy caller compensates for that by either unpacking into "Red, Blue, Green"
-- or by re-ordering the arguments it passes on, so the order must not be
-- "corrected" here in isolation. New code should call QualityRGB() instead.

-------------------------------- Gradient mode --------------------------------

-- Lua 5.1 in WoW has no guaranteed bitwise library (`bit` exists on retail-era
-- 3.3.5 clients but not on every private-server build), so hex is decoded with
-- plain division and modulo.
local function HexToRGB(Hex)
	local Value = tonumber(Hex, 16)
	if not ( Value ) then return nil; end
	return floor(Value / 65536) / 255, ( floor(Value / 256) % 256 ) / 255, ( Value % 256 ) / 255
end

-- sRGB is gamma-encoded, so averaging it directly muddies the midtones.
-- Interpolate in linear light instead.
local function ToLinear(C)
	if ( C <= 0.04045 ) then return C / 12.92; end
	return ((C + 0.055) / 1.055) ^ 2.4
end

local function ToSRGB(C)
	if ( C <= 0.0031308 ) then return C * 12.92; end
	return 1.055 * (C ^ (1 / 2.4)) - 0.055
end

-- Parsed stops, cached in linear light. Rebuilt only when the stop list changes.
local GradientCache, GradientCacheKey = nil, nil

local function BuildGradient()
	local Stops = ( GS_Gradient and GS_Gradient.Stops ) or {}
	local Key = table.concat(Stops, ",")
	if ( GradientCache ) and ( GradientCacheKey == Key ) then return GradientCache; end

	local Built = {}
	for i = 1, #Stops do
		local R, G, B = HexToRGB(Stops[i])
		if ( R ) then Built[#Built + 1] = { ToLinear(R), ToLinear(G), ToLinear(B) }; end
	end
	if ( #Built < 2 ) then return nil; end  -- caller falls back to classic

	GradientCache, GradientCacheKey = Built, Key
	return Built
end

-- Returns (red, green, blue) in TRUE rgb order, or nil to fall back to classic.
local function GradientRGB(Score)
	local Stops = BuildGradient()
	if not ( Stops ) then return nil; end

	local Low  = ( GS_Settings and GS_Settings.GradientMin ) or 3000
	local High = ( GS_Settings and GS_Settings.GradientMax ) or 6500
	if ( High <= Low ) then return nil; end

	-- A step at or above the range would collapse the whole ramp onto the top
	-- stop, silently losing the gradient. Keep at least two colours.
	local Step = ( GS_Settings and GS_Settings.GradientStep ) or 200
	if ( Step < 1 ) then Step = 1; end
	if ( Step > (High - Low) / 2 ) then Step = (High - Low) / 2; end

	-- Quantise the SCORE, not the normalised position: snapping `t` instead would
	-- spread (High - Low) across floor((High - Low) / Step) buckets, so a 3000-6500
	-- range with Step 200 would jump every 205.9 GS rather than every 200.
	--
	-- The last bucket is widened to reach High. When the range is not an exact
	-- multiple of Step the final bucket is short (6400-6500 here), and flooring it
	-- would leave the top stop -- pure red, the whole point of the high end --
	-- unreachable by any score.
	local Clamped = min(High, max(Low, Score))
	local Quantised = Low + floor((Clamped - Low) / Step) * Step
	if ( Quantised + Step > High ) then Quantised = High; end
	local T = min(1, max(0, (Quantised - Low) / (High - Low)))

	-- Locate the segment between two adjacent stops.
	local Segments = #Stops - 1
	local Scaled = T * Segments
	local Seg = min(floor(Scaled), Segments - 1)
	local Local = Scaled - Seg
	local A, B = Stops[Seg + 1], Stops[Seg + 2]

	return min(1, max(0, ToSRGB(A[1] + (B[1] - A[1]) * Local))),
	       min(1, max(0, ToSRGB(A[2] + (B[2] - A[2]) * Local))),
	       min(1, max(0, ToSRGB(A[3] + (B[3] - A[3]) * Local)))
end

-- Descriptions stay meaningful in gradient mode: the label is a property of the
-- score, not of the colour scheme, so reuse the classic bands.
local function ScoreDescription(Score)
	if not ( Score ) or ( Score < 1 ) then return "Trash"; end
	if ( Score > 6999 ) then Score = 6999; end
	for i = 0, 6 do
		local Bucket = GS_Quality[( i + 1 ) * 1000]
		if ( Bucket ) and ( Score > i * 1000 ) and ( Score <= ( ( i + 1 ) * 1000 ) ) then
			return Bucket.Description
		end
	end
	return "Legendary"
end

function GearScore_GetQuality(ItemScore)
	if ( GS_Settings ) and ( GS_Settings.ColorMode == "gradient" ) and ( ItemScore ) then
		local R, G, B = GradientRGB(ItemScore)
		-- (red, BLUE, green) -- the legacy return order is preserved exactly.
		if ( R ) then return R, B, G, ScoreDescription(ItemScore); end
	end
	if not ( ItemScore ) then return 0, 0, 0, "Trash"; end
	if ( ItemScore > 6999 ) then ItemScore = 6999; end
	if ( ItemScore < 1 ) then ItemScore = 1; end  -- 0 matches no band
	for i = 0, 6 do
		local Bucket = GS_Quality[( i + 1 ) * 1000]
		if ( Bucket ) and ( ItemScore > i * 1000 ) and ( ItemScore <= ( ( i + 1 ) * 1000 ) ) then
			local ChannelRed   = Bucket.Red["A"]   + (((ItemScore - Bucket.Red["B"])   * Bucket.Red["C"])   * Bucket.Red["D"])
			local ChannelGreen = Bucket.Green["A"] + (((ItemScore - Bucket.Green["B"]) * Bucket.Green["C"]) * Bucket.Green["D"])
			local ChannelBlue  = Bucket.Blue["A"]  + (((ItemScore - Bucket.Blue["B"])  * Bucket.Blue["C"])  * Bucket.Blue["D"])
			-- Clamp: the 6000-7000 band's gradient anchor sits at 6300, so scores
			-- below that overshoot past pure red/black on each channel.
			ChannelRed   = min(1, max(0, ChannelRed))
			ChannelGreen = min(1, max(0, ChannelGreen))
			ChannelBlue  = min(1, max(0, ChannelBlue))
			return ChannelRed, ChannelBlue, ChannelGreen, Bucket.Description
		end
	end
	return 0.1, 0.1, 0.1, "Legendary"
end

-- Sane wrapper: actual (red, green, blue, description).
local function QualityRGB(Score)
	local Red, Blue, Green, Description = GearScore_GetQuality(Score)
	return Red, Green, Blue, Description
end

------------------------------ Get Item Score ---------------------------------

function GearScore_GetItemScore(ItemLink)
	if not ( ItemLink ) then return 0, 0; end
	local QualityScale = 1
	local _, _, ItemRarity, ItemLevel, _, _, _, _, ItemEquipLoc = GetItemInfo(ItemLink)
	-- GetItemInfo() fills its cache entry field by field: the name can already be
	-- back while rarity or item level are still nil. Callers that gate on the name
	-- alone (GearScore_GetScore) or on nothing at all (the item tooltip hook) then
	-- reach the comparisons below with nil and throw. Treat a half-filled entry as
	-- "not cached yet" and let the caller retry.
	if ( ItemRarity == nil ) or ( ItemLevel == nil ) then return -1, 0, 50, 1, 1, 1, 0, ItemEquipLoc; end
	local Scale = 1.8618
	if ( ItemRarity == 5 ) then QualityScale = 1.3; ItemRarity = 4;
	elseif ( ItemRarity == 1 ) then QualityScale = 0.005; ItemRarity = 2
	elseif ( ItemRarity == 0 ) then QualityScale = 0.005; ItemRarity = 2 end
	if ( ItemRarity == 7 ) then ItemRarity = 3; ItemLevel = 187.05; end
	local Slot = GS_ItemTypes[ItemEquipLoc]
	if ( Slot ) then
		local Table = ( ItemLevel > 120 ) and GS_Formula["A"] or GS_Formula["B"]
		if ( ItemRarity >= 2 ) and ( ItemRarity <= 4 ) then
			-- Colours come from the unmodified slot score so that, say, a ring and a
			-- chest of the same item level read as the same quality.
			local Red, Green, Blue = GearScore_GetQuality((floor(((ItemLevel - Table[ItemRarity].A) / Table[ItemRarity].B) * Scale)) * 12.25)
			local GearScore = floor(((ItemLevel - Table[ItemRarity].A) / Table[ItemRarity].B) * Slot.SlotMOD * Scale * QualityScale)
			if ( ItemLevel == 187.05 ) then ItemLevel = 0; end
			if ( GearScore < 0 ) then GearScore = 0; Red, Green, Blue = GearScore_GetQuality(1); end
			return GearScore, ItemLevel, Slot.ItemSlot, Red, Green, Blue, 0, ItemEquipLoc
		end
	end
	-- 187.05 is the internal heirloom stand-in, not a real item level. The scored
	-- path above zeroes it before returning; this fall-through (unknown slot, or a
	-- rarity outside 2-4) has to do the same or the sentinel reaches the tooltip.
	if ( ItemLevel == 187.05 ) then ItemLevel = 0; end
	return -1, ItemLevel or 0, 50, 1, 1, 1, 0, ItemEquipLoc
end

-------------------------------- Get Score ------------------------------------

-- Transmogrification, and why a score can only ever be flagged and not fixed.
--
-- On AzerothCore with mod-transmog the real item stays in the character's
-- inventory server-side, but a 3.3.5 client inspecting another player never
-- receives it. All it gets is the visible-item entry id in the inspect packet,
-- which IS the transmog appearance -- so GetInventoryItemLink() and
-- GetInventoryItemID() both resolve to the cosmetic item. There is no client API
-- that returns the item underneath; the data simply is not sent. Only the local
-- player is exempt, because "player" reads the real inventory directly.
--
-- So instead of pretending to correct it, flag it: a slot whose item level sits
-- far below the character's own median is almost always mogged, since real gear
-- within one character clusters tightly. Compared against the MEDIAN, not the
-- mean -- the mean is dragged down by the very slots being looked for, and a
-- heavily mogged set would then stop tripping the check at all.
local MOG_RATIO = 0.6   -- slot ilvl below 60% of the median reads as cosmetic
local MOG_FLOOR = 40    -- ...but never flag on a trivially small absolute gap

local function MedianOf(Values)
	local Count = #Values
	if ( Count == 0 ) then return nil; end
	sort(Values)
	if ( Count % 2 == 1 ) then return Values[(Count + 1) / 2]; end
	return ( Values[Count / 2] + Values[Count / 2 + 1] ) / 2
end

-- Accepts either the legacy (name, unit) pair or a bare unit token.
-- Returns score, average item level, whether every equipped item was readable,
-- and whether any slot looks transmogrified. An incomplete scan is still a
-- usable number, just a low one.
function GearScore_GetScore(Name, Target)
	if ( Target == nil ) then Target = Name; end
	if not ( Target ) or not ( UnitIsPlayer(Target) ) then return nil; end

	local _, PlayerEnglishClass = UnitClass(Target)
	local GearScore, ItemCount, LevelTotal, TitanGrip = 0, 0, 0, 1
	local Complete = true
	-- Own inventory is read directly, so it is never subject to the mog blind spot.
	local CanBeMogged = not UnitIsUnit(Target, "player")
	local Levels = {}

	-- Titan's Grip: a two-hander in either hand halves both weapon slots.
	local MainLink = GetInventoryItemLink(Target, 16)
	local OffLink = GetInventoryItemLink(Target, 17)
	if ( MainLink ) and ( OffLink ) then
		if ( select(9, GetItemInfo(MainLink)) == "INVTYPE_2HWEAPON" ) then TitanGrip = 0.5; end
		if ( select(9, GetItemInfo(OffLink)) == "INVTYPE_2HWEAPON" ) then TitanGrip = 0.5; end
	end

	for i = 1, 18 do
		if ( i ~= 4 ) then
			local ItemLink = GetInventoryItemLink(Target, i)
			if ( ItemLink ) then
				-- Check the fields the score actually needs, not just the name.
				-- GetItemInfo() populates its cache entry progressively, so the
				-- name can be back while rarity and item level are still nil;
				-- gating on the name alone let such a slot through to be scored
				-- as -1, quietly understating the total on a scan that then
				-- reported itself complete and stopped retrying.
				local _, _, ReadyRarity, ReadyLevel = GetItemInfo(ItemLink)
				if ( ReadyRarity ) and ( ReadyLevel ) then
					local TempScore, ItemLevel = GearScore_GetItemScore(ItemLink)
					if ( i == 16 ) or ( i == 17 ) then
						TempScore = TempScore * TitanGrip
						if ( PlayerEnglishClass == "HUNTER" ) then TempScore = TempScore * 0.3164; end
					end
					if ( i == 18 ) and ( PlayerEnglishClass == "HUNTER" ) then TempScore = TempScore * 5.3224; end
					GearScore = GearScore + TempScore
					ItemCount = ItemCount + 1
					LevelTotal = LevelTotal + ( ItemLevel or 0 )
					-- Weapons are excluded from the mog check: their item levels
					-- legitimately differ from armour, and from each other under
					-- Titan's Grip, so they produce false positives.
					if ( CanBeMogged ) and ( ItemLevel ) and ( ItemLevel > 0 )
					   and ( i ~= 16 ) and ( i ~= 17 ) and ( i ~= 18 ) then
						Levels[#Levels + 1] = ItemLevel
					end
				else
					-- Not cached locally yet; the GetItemInfo() call above queues the
					-- server lookup. Skip the slot so the average stays honest and
					-- report the scan as incomplete so the caller repeats it.
					Complete = false
				end
			end
		end
	end

	if ( GearScore < 0 ) then GearScore = 0; end
	local Average = 0
	if ( ItemCount > 0 ) then Average = floor((LevelTotal / ItemCount) + 0.5); end

	-- Needs enough armour slots for a median to mean anything. A partial scan is
	-- left unflagged: the missing slots are exactly the ones that would set the
	-- median, so an early verdict here would be noise.
	local Suspect = false
	if ( Complete ) and ( #Levels >= 5 ) then
		local Median = MedianOf(Levels)
		if ( Median ) then
			for i = 1, #Levels do
				if ( Levels[i] < Median * MOG_RATIO ) and ( Median - Levels[i] >= MOG_FLOOR ) then
					Suspect = true
					break
				end
			end
		end
	end

	return floor(GearScore), Average, Complete, Suspect
end

--------------------------- Asynchronous inspect ------------------------------

-- NotifyInspect() is asynchronous, GetItemInfo() returns nil until the item
-- reaches the local cache, and the server hands out one inspect slot at a time.
-- Reading the gear on the line after NotifyInspect(), as this addon used to,
-- is why GearScore was so often partial or plain wrong.

local RescanFrame = CreateFrame("Frame", nil, UIParent)
RescanFrame:Hide()

local function InspectInUse()
	if ( InspectFrame ) and ( InspectFrame:IsShown() ) then return true; end
	if ( Examiner ) and ( Examiner.IsShown ) and ( Examiner:IsShown() ) then return true; end
	return false
end

-- Listeners are third party code. An error thrown in one of them used to unwind
-- all the way out through ScanUnit and the tooltip hook, and because the hook
-- sets GSL.inTooltipHook before calling Track() and clears it after, the flag
-- stayed stuck true -- so every later tooltip silently produced nothing. Isolate
-- each callback so one broken addon cannot take GearScore down with it.
local function Announce(Name, Score, Average)
	if ( WeakAuras ) and ( WeakAuras.ScanEvents ) then
		pcall(WeakAuras.ScanEvents, "GEARSCORELITE_UPDATE", Name, Score, Average)
	end
	for i = 1, #GSL.listeners do
		pcall(GSL.listeners[i], Name, Score, Average)
	end
end

-- Redraw a tooltip that is still showing the unit we just finished scanning.
-- SetUnit() re-fires OnTooltipSetUnit, which then picks the fresh value out of
-- the cache; the flag stops that pass from queueing another scan.
--
-- Only for scans that land later, from the rescan loop or an event. A scan that
-- ran inside the tooltip hook has already updated the cache that the very same
-- hook is about to read, and redrawing from in there would leave the outer pass
-- appending a second, duplicate GearScore line.
local function RefreshTooltip(Name)
	if ( GSL.refreshing ) or ( GSL.inTooltipHook ) or not ( GameTooltip:IsShown() ) then return; end
	local Shown, Unit = GameTooltip:GetUnit()
	if ( Shown ~= Name ) or not ( Unit ) then return; end
	-- SetUnit() re-enters our own OnTooltipSetUnit hook, so an error raised
	-- anywhere in that pass would skip the reset and leave refreshing stuck true,
	-- permanently disabling both the rescan redraw and the inspect guard below.
	GSL.refreshing = true
	pcall(GameTooltip.SetUnit, GameTooltip, Unit)
	GSL.refreshing = false
end

local function ScanUnit(Name, Unit)
	if ( CanInspect(Unit) ) and not ( InspectInUse() ) then
		local Now = GetTime()
		-- Re-request on a 1.5s debounce rather than a single shot per unit. The
		-- rescan loop ticks every 0.5s, so the previous 2s gate let at most every
		-- fourth pass through and the rest spun over an empty inventory; if the
		-- one request that did go out was dropped, nothing ever asked again.
		if ( GSL.lastInspectName ~= Name ) or ( ( Now - GSL.lastInspectTime ) > 1.5 ) then
			GSL.lastInspectName = Name
			GSL.lastInspectTime = Now
			NotifyInspect(Unit)
		end
	end

	local Score, Average, Complete, Suspect = GearScore_GetScore(Name, Unit)
	if not ( Score ) then return true; end

	local Previous = GSL.cache[Name]

	-- Out of inspect range (~28 yards) or behind line of sight, every slot reads
	-- nil and the scan scores 0. That is absence of data, not a score of zero:
	-- overwriting a known-good entry with it is what made scores vanish mid-raid
	-- whenever the target drifted away. Keep what we had and report the scan as
	-- unfinished so the retry loop keeps going.
	if ( Score == 0 ) and ( Previous ) and ( Previous.score > 0 ) then
		return false
	end

	GSL.cache[Name] = { score = Score, ilvl = Average, complete = Complete, suspect = Suspect, time = GetTime() }
	if not ( Previous ) or ( Previous.score ~= Score ) then
		Announce(Name, Score, Average)
		RefreshTooltip(Name)
	end
	return Complete
end

local function CancelRescan()
	GSL.scanName = nil
	GSL.scanUnit = nil
	GSL.scanTries = 0
end

local function DoRescan()
	local Name, Unit = GSL.scanName, GSL.scanUnit
	if not ( Name ) or not ( Unit ) then CancelRescan(); return; end
	if not ( UnitExists(Unit) ) or ( UnitName(Unit) ~= Name ) then CancelRescan(); return; end
	GSL.scanTries = GSL.scanTries - 1
	if ( ScanUnit(Name, Unit) ) or ( GSL.scanTries <= 0 ) then CancelRescan(); end
end

local function UpdatePlayer()
	local Score, Average, Complete = GearScore_GetScore("player")
	if ( Score ) then
		GSL.player.score = Score
		GSL.player.ilvl = Average
		GSL.cache[UnitName("player")] = { score = Score, ilvl = Average, complete = Complete, suspect = false, time = GetTime() }
	end
	return Complete
end

local UpdatePaperDoll  -- forward declaration; defined with the character sheet UI

-- Queue an inspect for a unit and keep retrying until its items arrive.
local function Track(Name, Unit)
	if not ( Unit ) or not ( UnitExists(Unit) ) or not ( UnitIsPlayer(Unit) ) then return; end
	Name = Name or UnitName(Unit)
	if not ( Name ) then return; end
	if not ( ScanUnit(Name, Unit) ) then
		GSL.scanName = Name
		GSL.scanUnit = Unit
		-- 24 tries at 0.5s = 12 seconds. The old 10 tries (5s) routinely expired
		-- before the reply arrived: the server hands out one inspect slot at a
		-- time, so in a 25-man raid the queue alone can outlast that, and the
		-- entry was then abandoned at 0 until the next mouseover.
		GSL.scanTries = 24
		RescanFrame:Show()
	end
end

RescanFrame:SetScript("OnUpdate", function(self, elapsed)
	GSL.timer = GSL.timer + elapsed
	if ( GSL.timer < 0.5 ) then return; end
	GSL.timer = 0

	if ( GSL.playerTries > 0 ) then
		GSL.playerTries = GSL.playerTries - 1
		if ( UpdatePlayer() ) then GSL.playerTries = 0; end
		UpdatePaperDoll()
	end
	if ( GSL.scanName ) then DoRescan(); end

	-- Nothing pending: stop burning a frame handler until we are needed again.
	if ( GSL.playerTries <= 0 ) and not ( GSL.scanName ) then self:Hide(); end
end)

local function QueuePlayerRescan()
	if not ( UpdatePlayer() ) then
		GSL.playerTries = 10
		RescanFrame:Show()
	end
	UpdatePaperDoll()
end

------------------------------ Unit tooltips ----------------------------------

-- Blizzard's "mouseover" token does not cover third party unitframes, so fall
-- back to the frame under the cursor and read the unit off it. To support
-- another unitframe addon, add whichever property it stores the unit in.
local function ResolveTooltipUnit()
	local Name, Unit = GameTooltip:GetUnit()
	if not ( Name ) then return nil, nil; end
	if ( Unit ) and ( UnitExists(Unit) ) then return Name, Unit; end
	if ( UnitExists("mouseover") ) and ( UnitName("mouseover") == Name ) then return Name, "mouseover"; end

	local Focus = GetMouseFocus()
	if ( Focus ) then
		local Candidate = Focus.unit or Focus.raidid  -- ElvUI/oUF/ShadowUF use .unit, VuhDo uses .raidid
		if ( type(Candidate) == "string" ) and ( UnitExists(Candidate) ) and ( UnitName(Candidate) == Name ) then
			return Name, Candidate
		end
	end
	return Name, nil
end

function GearScore_HookSetUnit()
	if not ( GS_Settings ) or not ( GS_Settings.Player ) then return; end
	if ( GS_Settings.HideInCombat ) and ( GSL.inCombat ) then return; end

	local Name, Unit = ResolveTooltipUnit()
	if not ( Name ) then return; end

	-- Refuse to touch the inspect slot while an inspect window owns it: our
	-- NotifyInspect() would switch the talents shown in that window.
	if ( Unit ) and not ( GSL.refreshing ) and not ( InspectInUse() ) then
		if ( not GS_Settings.MustTarget ) or ( UnitIsUnit("target", Unit) ) then
			-- Cleared through pcall: if anything below throws, an unguarded
			-- assignment would never run and the flag would stay true, which
			-- suppresses RefreshTooltip() for the rest of the session.
			GSL.inTooltipHook = true
			pcall(Track, Name, Unit)
			GSL.inTooltipHook = false
		end
	end

	local Entry = GSL.cache[Name]
	if not ( Entry ) or ( Entry.score <= 0 ) then return; end

	local Red, Green, Blue = QualityRGB(Entry.score)
	local Score = tostring(Entry.score)
	if not ( Entry.complete ) then Score = Score .. "+"; end  -- still filling in

	if ( GS_Settings.Level ) then
		GameTooltip:AddDoubleLine("GearScore: " .. Score, "(iLevel: " .. Entry.ilvl .. ")", Red, Green, Blue, Red, Green, Blue)
	else
		GameTooltip:AddLine("GearScore: " .. Score, Red, Green, Blue)
	end

	-- Say it outright rather than showing a quietly wrong number: an inspected
	-- player's gear arrives as visible-item ids, so a transmogrified slot is
	-- indistinguishable from the real thing and drags the score down.
	if ( Entry.suspect ) then
		GameTooltip:AddLine("(transmog detected -- score understated)", 1, 0.65, 0.1)
	end

	if ( GS_Settings.Compare ) then
		local Mine = GSL.player.score
		local Theirs = Entry.score
		if ( Mine > Theirs ) then
			GameTooltip:AddDoubleLine("YourScore: " .. Mine, "(+" .. ( Mine - Theirs ) .. ")", 0, 1, 0, 0, 1, 0)
		elseif ( Mine < Theirs ) then
			GameTooltip:AddDoubleLine("YourScore: " .. Mine, "(-" .. ( Theirs - Mine ) .. ")", 1, 0, 0, 1, 0, 0)
		else
			GameTooltip:AddDoubleLine("YourScore: " .. Mine, "(+0)", 0, 1, 1, 0, 1, 1)
		end
	end
end

------------------------------ Item tooltips ----------------------------------

local HunterRanged = {
	["INVTYPE_RANGEDRIGHT"] = true, ["INVTYPE_RANGED"] = true,
}
local HunterMelee = {
	["INVTYPE_2HWEAPON"] = true, ["INVTYPE_WEAPONMAINHAND"] = true,
	["INVTYPE_WEAPONOFFHAND"] = true, ["INVTYPE_WEAPON"] = true, ["INVTYPE_HOLDABLE"] = true,
}

function GearScore_HookItem(ItemName, ItemLink, Tooltip)
	if not ( GS_Settings ) or not ( ItemLink ) then return; end
	if ( GS_Settings.HideInCombat ) and ( GSL.inCombat ) then return; end
	if not ( IsEquippableItem(ItemLink) ) then return; end

	local ItemScore, ItemLevel, _, Red, Blue, Green, _, ItemEquipLoc = GearScore_GetItemScore(ItemLink)

	if ( ItemScore < 0 ) then
		if ( GS_Settings.Level ) and ( ItemLevel ) and ( ItemLevel > 0 ) then
			Tooltip:AddLine("iLevel " .. ItemLevel)
		end
		return
	end
	if not ( GS_Settings.Item ) then return; end

	if ( GS_Settings.Level ) and ( ItemLevel ) then
		Tooltip:AddDoubleLine("GearScore: " .. ItemScore, "(iLevel " .. ItemLevel .. ")", Red, Green, Blue, Red, Green, Blue)
	else
		Tooltip:AddLine("GearScore: " .. ItemScore, Red, Green, Blue)
	end

	local _, PlayerEnglishClass = UnitClass("player")
	if ( PlayerEnglishClass == "HUNTER" ) then
		if ( HunterRanged[ItemEquipLoc] ) then
			Tooltip:AddLine("HunterScore: " .. floor(ItemScore * 5.3224), Red, Green, Blue)
		elseif ( HunterMelee[ItemEquipLoc] ) then
			Tooltip:AddLine("HunterScore: " .. floor(ItemScore * 0.3164), Red, Green, Blue)
		end
	end
end

local function ItemTooltipHook(self)
	local ItemName, ItemLink = self:GetItem()
	GearScore_HookItem(ItemName, ItemLink, self)
end

---------------------------- Character sheet ----------------------------------

-- The frame only captures the mouse while unlocked, otherwise it would sit on
-- top of the character sheet's stat rows and eat their tooltips.
local Anchor = CreateFrame("Frame", "GearScoreLiteAnchor", PaperDollFrame)
Anchor:SetWidth(80)
Anchor:SetHeight(28)
Anchor:SetPoint("TOPLEFT", PaperDollFrame, "TOPLEFT", 72, -241)
Anchor:SetFrameLevel(PaperDollFrame:GetFrameLevel() + 5)
Anchor:EnableMouse(false)
Anchor:SetMovable(true)
Anchor:RegisterForDrag("LeftButton")

local AnchorHighlight = Anchor:CreateTexture(nil, "BACKGROUND")
AnchorHighlight:SetAllPoints(Anchor)
AnchorHighlight:SetTexture(0.1, 0.6, 1, 0.35)
AnchorHighlight:Hide()

-- SetFont returns false when the file is missing or the client rejects the TTF,
-- and the FontString then draws nothing at all. Always verify and fall back.
local FONT_PATH = "Interface\\AddOns\\GearScoreLite\\FiraSans-SemiBold.ttf"
local FONT_FALLBACK = "Fonts\\FRIZQT__.TTF"

local function ApplyFont(Region, Size)
	if not ( Region:SetFont(FONT_PATH, Size) ) then
		Region:SetFont(FONT_FALLBACK, Size)
	end
end

local PersonalGearScore = Anchor:CreateFontString("PersonalGearScore", "OVERLAY")
ApplyFont(PersonalGearScore, 14)
PersonalGearScore:SetPoint("TOPLEFT", Anchor, "TOPLEFT", 0, 0)
PersonalGearScore:SetText("0")

local GearScore2 = Anchor:CreateFontString("GearScore2", "OVERLAY")
ApplyFont(GearScore2, 11)
GearScore2:SetPoint("TOPLEFT", PersonalGearScore, "BOTTOMLEFT", 0, -1)
GearScore2:SetText("GearScore")

Anchor:SetScript("OnDragStart", function(self) self:StartMoving() end)

Anchor:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	-- Store a plain offset from the frame's own TOPLEFT rather than whatever
	-- point StartMoving() left behind, so an ElvUI reskin cannot strand it.
	local Scale = self:GetEffectiveScale()
	local ParentScale = PaperDollFrame:GetEffectiveScale()
	local X = ( self:GetLeft() * Scale - PaperDollFrame:GetLeft() * ParentScale ) / ParentScale
	local Y = ( self:GetTop() * Scale - PaperDollFrame:GetTop() * ParentScale ) / ParentScale
	GS_Settings.AnchorX = X
	GS_Settings.AnchorY = Y
	self:ClearAllPoints()
	self:SetPoint("TOPLEFT", PaperDollFrame, "TOPLEFT", X, Y)
end)

Anchor:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("GearScore")
	GameTooltip:AddLine("Average item level: " .. GSL.player.ilvl, 1, 1, 1)
	GameTooltip:AddLine("Drag to move, then /gs lock.", 0.6, 0.6, 0.6)
	GameTooltip:Show()
end)
Anchor:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Defined as a local above so the rescan loop can call it.
function UpdatePaperDoll()
	if not ( GS_Settings ) then return; end
	if not ( GS_Settings.PaperDoll ) then Anchor:Hide(); return; end
	Anchor:Show()
	local Red, Green, Blue = QualityRGB(GSL.player.score)
	PersonalGearScore:SetText(GSL.player.score)
	PersonalGearScore:SetTextColor(Red, Green, Blue, 1)
end

local function ApplyAnchor()
	Anchor:ClearAllPoints()
	Anchor:SetPoint("TOPLEFT", PaperDollFrame, "TOPLEFT", GS_Settings.AnchorX or 72, GS_Settings.AnchorY or -241)
	local Unlocked = not GS_Settings.Locked
	Anchor:EnableMouse(Unlocked)
	if ( Unlocked ) then AnchorHighlight:Show() else AnchorHighlight:Hide() end
end

------------------------------ Slash commands ---------------------------------

local function Toggle(Key, Label)
	GS_Settings[Key] = not GS_Settings[Key]
	print("GearScore -- " .. Label .. ": " .. ( GS_Settings[Key] and "On" or "Off" ))
end

function GS_MANSET(Command)
	Command = strlower(strtrim(Command or ""))
	-- "step" and "range" take arguments; every other verb is a bare word and
	-- still matches the Command comparisons below unchanged.
	local Verb, Args = Command:match("^(%S+)%s*(.*)$")
	Verb, Args = Verb or Command, Args or ""

	if ( Command == "player" ) or ( Command == "show" ) then Toggle("Player", "Player Scores")
	elseif ( Command == "item" ) then Toggle("Item", "Item Scores")
	elseif ( Command == "level" ) then Toggle("Level", "Item Levels")
	elseif ( Command == "compare" ) then Toggle("Compare", "Comparisons")
	elseif ( Command == "target" ) then Toggle("MustTarget", "Must Target")
	elseif ( Command == "combat" ) then Toggle("HideInCombat", "Hide In Combat")
	elseif ( Command == "sheet" ) then Toggle("PaperDoll", "Character Sheet Number"); UpdatePaperDoll()
	elseif ( Command == "lock" ) or ( Command == "unlock" ) then
		GS_Settings.Locked = ( Command == "lock" )
		ApplyAnchor()
		print("GearScore -- character sheet number: " .. ( GS_Settings.Locked and "locked" or "unlocked, drag it" ))
	elseif ( Verb == "color" ) or ( Verb == "colour" ) then
		GS_Settings.ColorMode = ( GS_Settings.ColorMode == "gradient" ) and "classic" or "gradient"
		UpdatePaperDoll()
		print("GearScore -- colour scheme: " .. GS_Settings.ColorMode)
	elseif ( Verb == "step" ) then
		local N = tonumber(Args)
		if ( N ) and ( N >= 1 ) then
			GS_Settings.GradientStep = floor(N)
			UpdatePaperDoll()
			print("GearScore -- gradient step: " .. GS_Settings.GradientStep .. " GS")
		else
			print("GearScore -- usage: /gs step 200")
		end
	elseif ( Verb == "range" ) then
		local Low, High = Args:match("^(%d+)%s+(%d+)$")
		Low, High = tonumber(Low), tonumber(High)
		if ( Low ) and ( High ) and ( High > Low ) then
			GS_Settings.GradientMin, GS_Settings.GradientMax = Low, High
			UpdatePaperDoll()
			print("GearScore -- gradient range: " .. Low .. " to " .. High)
		else
			print("GearScore -- usage: /gs range 3000 6500")
		end
	elseif ( Command == "reset" ) then
		for Key in pairs(GS_Settings) do GS_Settings[Key] = nil; end
		for Key, Value in pairs(GS_DefaultSettings) do GS_Settings[Key] = Value; end
		ApplyAnchor()
		UpdatePaperDoll()
		print("GearScore -- options reset to default.")
	else
		for _, Line in ipairs(GS_CommandList) do print(Line); end
	end
end

--------------------------------- Events --------------------------------------

local EventFrame = CreateFrame("Frame", "GearScore", UIParent)

EventFrame:SetScript("OnEvent", function(self, event, arg1)
	if ( event == "PLAYER_REGEN_ENABLED" ) then
		GSL.inCombat = false

	elseif ( event == "PLAYER_REGEN_DISABLED" ) then
		GSL.inCombat = true

	elseif ( event == "PLAYER_EQUIPMENT_CHANGED" ) or ( event == "PLAYER_ENTERING_WORLD" ) then
		QueuePlayerRescan()

	elseif ( event == "INSPECT_READY" ) then
		-- The actual "gear has arrived" signal. Until this was handled the addon
		-- only ever guessed, re-reading the inventory on a timer and giving up
		-- after a fixed number of tries whether or not the data had landed.
		--
		-- arg1 is the inspected unit's GUID on 3.3.5, which cannot be turned back
		-- into a unit token, so the pending scan is what gets re-read. It is the
		-- only inspect this addon has in flight.
		if ( GSL.scanName ) then DoRescan(); end

	elseif ( event == "UNIT_INVENTORY_CHANGED" ) then
		if ( arg1 == "player" ) then
			QueuePlayerRescan()
		elseif ( GSL.scanName ) and ( arg1 ) and ( UnitName(arg1) == GSL.scanName ) then
			DoRescan()
		end

	elseif ( event == "PLAYER_TARGET_CHANGED" ) then
		if ( GSL.scanName ) and ( GSL.scanName ~= UnitName("target") ) then CancelRescan(); end
		if ( UnitExists("target") ) and ( UnitIsPlayer("target") ) then Track(UnitName("target"), "target"); end

	elseif ( event == "ADDON_LOADED" ) and ( arg1 == "GearScoreLite" ) then
		if ( type(GS_Settings) ~= "table" ) or ( GS_Settings.Version ~= GS_SettingsVersion ) then
			GS_Settings = {}
		end
		-- Copy, never alias: assigning GS_DefaultSettings directly would make every
		-- later option change rewrite the defaults it is filled in from.
		for Key, Value in pairs(GS_DefaultSettings) do
			if ( GS_Settings[Key] == nil ) then GS_Settings[Key] = Value; end
		end
		GSL.inCombat = UnitAffectingCombat("player") and true or false
		ApplyAnchor()
		UpdatePaperDoll()
		self:UnregisterEvent("ADDON_LOADED")
	end
end)

EventFrame:RegisterEvent("ADDON_LOADED")
EventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
EventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
EventFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
EventFrame:RegisterEvent("INSPECT_READY")
EventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
EventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
EventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")

GameTooltip:HookScript("OnTooltipSetUnit", GearScore_HookSetUnit)
GameTooltip:HookScript("OnTooltipSetItem", ItemTooltipHook)
ShoppingTooltip1:HookScript("OnTooltipSetItem", ItemTooltipHook)
ShoppingTooltip2:HookScript("OnTooltipSetItem", ItemTooltipHook)
ItemRefTooltip:HookScript("OnTooltipSetItem", ItemTooltipHook)
PaperDollFrame:HookScript("OnShow", function() QueuePlayerRescan() end)

SlashCmdList["MY2SCRIPT"] = GS_MANSET
SLASH_MY2SCRIPT1 = "/gset"
SLASH_MY2SCRIPT2 = "/gs"
SLASH_MY2SCRIPT3 = "/gearscore"

------------------------------- Public API ------------------------------------

-- For WeakAuras and other addons. Prefer GetCached() in anything that runs per
-- frame: GetScore() walks 18 inventory slots on every call.
--
-- WeakAuras: use a custom trigger on the event GEARSCORELITE_UPDATE, which fires
-- with (name, score, averageItemLevel) whenever a score changes.
GearScoreLite = {
	-- score, averageItemLevel, complete, suspect -- nil if the unit is not a
	-- player. `suspect` means a slot looks transmogrified, so the score is a
	-- lower bound rather than a reading.
	GetScore = function(unit) return GearScore_GetScore(unit) end,

	-- score, averageItemLevel, ageInSeconds, suspect -- cache only, never inspects.
	GetCached = function(name)
		local Entry = name and GSL.cache[name]
		if not ( Entry ) then return nil; end
		return Entry.score, Entry.ilvl, GetTime() - Entry.time, Entry.suspect
	end,

	-- Queue an asynchronous inspect; the result arrives via GEARSCORELITE_UPDATE.
	Request = function(unit)
		if ( unit ) and ( UnitExists(unit) ) then Track(UnitName(unit), unit); end
	end,

	-- Your own score, always current, never needs an inspect.
	GetPlayer = function() return GSL.player.score, GSL.player.ilvl end,

	-- callback(name, score, averageItemLevel)
	RegisterCallback = function(callback)
		if ( type(callback) == "function" ) then tinsert(GSL.listeners, callback); end
	end,
}
