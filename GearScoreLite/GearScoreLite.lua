-------------------------------------------------------------------------------
--                        GearScoreLite: Reborn                              --
--                             Version 4x03                                  --
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
local GetTime, sort, time = GetTime, table.sort, time
local format, date, tostring = string.format, date, tostring
local UnitIsConnected = UnitIsConnected

-- Session state. Only clean finished reads leave this table, into GS_Cache; see
-- the remembered-scores section for what is kept and why.
local GSL = {
	cache = {},            -- [name] = { score, ilvl, complete, suspect, time }
	player = { score = 0, ilvl = 0 },
	listeners = {},
	scanName = nil,
	scanUnit = nil,
	scanTries = 0,
	scanRead = 0,          -- most slots read so far, to tell progress from a stall
	scanDeadline = nil,    -- hard stop for the active scan, whatever progress says
	playerTries = 0,
	timer = 0,
	lastInspectName = nil,
	lastInspectTime = 0,
	inspectTarget = nil,   -- who the last NotifyInspect on this client asked about
	answeredFor = nil,     -- whose gear the client is holding right now, by name
	inCombat = false,
	refreshing = false,
	queue = {},            -- names waiting for an inspect slot, oldest first
	queued = {},           -- [name] = unit token, membership test for the above
	blocked = {},          -- [name] = reason code from the last blocked scan
	unsure = {},           -- [name] = re-reads spent on a number that still looks wrong
	log = {},              -- ring buffer of recent scan events, for /gs dump
	logNext = 1,
}

------------------------------- Diagnostics -----------------------------------

-- Every failure mode of an inspect looks identical from outside: no score in
-- the tooltip. Out of range, an inspect window holding the slot, and items still
-- in flight are three different faults, so record which one actually happened.

local LOG_MAX = 120  -- ring buffer; a raid pull generates entries fast

-- GetTime() is seconds since client start, which is meaningless in a pasted
-- report. Log wall-clock instead so timings can be read directly.
local function Stamp()
	return date("%H:%M:%S")
end

local function Log(Format, ...)
	local Ok, Text = pcall(format, Format, ...)
	if not ( Ok ) then Text = tostring(Format); end
	Text = Stamp() .. "  " .. Text

	-- Written even when debug output is off: /gs dump right after something goes
	-- wrong is the common case, and asking the user to reproduce it with debug
	-- enabled loses the very event they wanted to report.
	GSL.log[GSL.logNext] = Text
	GSL.logNext = ( GSL.logNext % LOG_MAX ) + 1

	if ( GS_Settings ) and ( GS_Settings.Debug ) then
		print("|cff66ccffGS|r " .. Text)
	end
end

-- Oldest first. The buffer wraps, so read from logNext around to logNext - 1.
local function LogLines()
	local Lines = {}
	for i = 0, LOG_MAX - 1 do
		local Entry = GSL.log[( ( GSL.logNext - 1 + i ) % LOG_MAX ) + 1]
		if ( Entry ) then Lines[#Lines + 1] = Entry; end
	end
	return Lines
end

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

-- Transmogrification, and the timing trap it sets.
--
-- A 3.3.5 client knows two different things about another player's gear. The
-- visible-item entry ids arrive with the unit itself, from render range, with no
-- inspect at all -- and on a realm with mod-transmog those fields hold the
-- COSMETIC item, because they are what the 3D model is drawn from. The real gear
-- only arrives with the inspect reply, which is what Blizzard's inspect window
-- draws once INSPECT_TALENT_READY fires.
--
-- Both are read through GetInventoryItemLink(). Which one it returns depends
-- entirely on whether the reply has landed yet. Reading too early therefore
-- yields a complete-looking set of cosmetic items: every slot returns a link, so
-- nothing looks missing, and the transmog set gets scored and cached as final
-- while the inspect window a metre away shows the real gear. ScanUnit() refuses
-- to call a scan complete until the reply has actually arrived.
--
-- The flag below still earns its place: the reply can genuinely be lost, and a
-- realm may mog the inspect data too. A slot whose item level sits
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
-- whether any slot looks transmogrified, and -- for diagnostics -- how many
-- equipped slots were read out of how many were occupied. An incomplete scan is
-- still a usable number, just a low one.
-- One scan asks GetItemInfo() about the same link twice per slot -- once to see
-- whether the fields it needs are back, once inside GearScore_GetItemScore() --
-- and the rescan loop repeats the whole scan up to two dozen times. Memoising
-- the readiness probe for the duration of a single call halves that.
--
-- Strictly within one call. The entire retry design rests on the answer
-- CHANGING as items arrive, so a table that outlived the call would pin the
-- first, emptiest reading and the scan would never complete.
local function ItemReady(Cache, ItemLink)
	local Known = Cache[ItemLink]
	if ( Known == nil ) then
		local _, _, Rarity, Level = GetItemInfo(ItemLink)
		-- false, not nil: nil would re-probe on every lookup and defeat the point.
		Known = ( Rarity and Level ) and { Rarity, Level } or false
		Cache[ItemLink] = Known
	end
	if not ( Known ) then return nil; end
	return Known[1], Known[2]
end

function GearScore_GetScore(Name, Target)
	if ( Target == nil ) then Target = Name; end
	if not ( Target ) or not ( UnitIsPlayer(Target) ) then return nil; end

	local Ready = {}
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

	-- What each slot actually contributed, kept for /gs gear. A wrong total is
	-- only diagnosable against the per-slot items the client handed us: seeing a
	-- level 20 shirt where the inspect window shows tier gear settles in one look
	-- whether a low score is transmog or a scoring fault.
	local Breakdown = {}

	local Occupied = 0
	for i = 1, 18 do
		if ( i ~= 4 ) then
			local ItemLink = GetInventoryItemLink(Target, i)
			if ( ItemLink ) then
				Occupied = Occupied + 1
				-- Check the fields the score actually needs, not just the name:
				-- GetItemInfo() populates its cache entry progressively, so the
				-- name can be back while rarity and item level are still nil.
				local ReadyRarity, ReadyLevel = ItemReady(Ready, ItemLink)
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
					Breakdown[#Breakdown + 1] = { slot = i, link = ItemLink,
					                              ilvl = ItemLevel or 0, score = floor(TempScore) }
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

	-- Zero occupied slots on somebody else means the inspect reply has not landed
	-- yet, not that they are naked: every slot reads nil until it does. Calling
	-- that complete lets the caller cache the zero and never arm a retry. The
	-- player's own inventory is read directly, so an empty one there is real.
	if ( Occupied == 0 ) and not ( UnitIsUnit(Target, "player") ) then Complete = false; end

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

	return floor(GearScore), Average, Complete, Suspect, ItemCount, Occupied, Breakdown
end

--------------------------- Asynchronous inspect ------------------------------

-- NotifyInspect() is asynchronous, GetItemInfo() returns nil until the item
-- reaches the local cache, and the server hands out one inspect slot at a time.
-- Gear read on the line after NotifyInspect() is therefore always empty.

local RescanFrame = CreateFrame("Frame", nil, UIParent)
RescanFrame:Hide()

-- The loop ticks every 0.5s, so this is a 12 second budget. It is refreshed
-- whenever a retry reads more slots than the one before it, and capped by
-- SCAN_DEADLINE so a slot whose item never arrives cannot hold the loop open.
local SCAN_TRIES = 24
local SCAN_DEADLINE = 30  -- seconds from the start of a scan, whatever happens
local SCAN_CONFIRM = 6      -- extra passes before settling a read that looks mogged
local SCAN_CONFIRM_BUSY = 2 -- ...cut down while others are queued for the same slot

local function InspectInUse()
	if ( InspectFrame ) and ( InspectFrame:IsShown() ) then return true; end
	if ( Examiner ) and ( Examiner.IsShown ) and ( Examiner:IsShown() ) then return true; end
	return false
end

-- Is an open inspect window already holding THIS unit? Then its gear is in the
-- client -- the window is drawing it -- and reading costs nothing. Only the
-- NotifyInspect() request must be withheld, since that would retarget the window.
local function InspectingUnit(Unit)
	if not ( Unit ) then return false; end
	if ( InspectFrame ) and ( InspectFrame:IsShown() ) and ( InspectFrame.unit )
	   and ( UnitIsUnit(InspectFrame.unit, Unit) ) then return true; end
	if ( Examiner ) and ( Examiner.IsShown ) and ( Examiner:IsShown() ) and ( Examiner.unit )
	   and ( UnitIsUnit(Examiner.unit, Unit) ) then return true; end
	return false
end

-- Listeners are third party code. An error thrown in one would unwind out
-- through ScanUnit and the tooltip hook, leaving GSL.inTooltipHook stuck true
-- and every later tooltip silent. Isolate each callback so one broken addon
-- cannot take GearScore down with it.
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

-- Why a unit cannot be scored right now, as a short reason code, or nil when
-- nothing is standing in the way. Ordered from permanent to transient so the
-- caller can decide whether retrying is worth anything.
--
-- CheckInteractDistance index 1 is the ~28 yard inspect range. It is the same
-- distance the server enforces on the inspect packet, so a false here means the
-- request would be refused no matter how many times it is repeated.
local function Obstacle(Unit)
	if not ( Unit ) or not ( UnitExists(Unit) ) then return "gone"; end
	if not ( UnitIsPlayer(Unit) ) then return "npc"; end
	if ( UnitIsUnit(Unit, "player") ) then return nil; end
	if ( UnitIsConnected ) and not ( UnitIsConnected(Unit) ) then return "offline"; end
	-- Deliberately no faction test here. UnitCanCooperate() answers "can I group,
	-- trade or buff this unit", which is not the same question as "can I inspect
	-- it" -- and private-server builds commonly allow cross-faction inspect
	-- outright. Treating a hostile player as permanently unscannable skipped them
	-- entirely: no queue entry, no retry, no score, ever. CanInspect() below is
	-- the client's own verdict and already reflects whatever rules this realm has.

	-- Only a window held on somebody ELSE blocks us; one held on this very unit
	-- has already fetched the gear we want.
	if ( InspectInUse() ) and not ( InspectingUnit(Unit) ) then return "inspectbusy"; end
	if not ( CanInspect(Unit) ) then return "cannotinspect"; end
	if ( CheckInteractDistance ) and not ( CheckInteractDistance(Unit, 1) ) then return "range"; end
	return nil
end

-- Reason codes rendered for humans. Kept next to Obstacle() so a new code
-- cannot be added without a matching line here.
local ObstacleText = {
	["gone"]          = "unit no longer exists",
	["npc"]           = "not a player",
	["offline"]       = "player is offline",
	["inspectbusy"]   = "inspect window is open, slot in use",
	["cannotinspect"] = "cannot inspect yet (range, line of sight or faction)",
	["range"]         = "out of inspect range (~28 yards)",
}

--------------------------- Remembered scores ---------------------------------

-- The gap this closes is the first seconds of a mouseover. The client has not
-- answered yet, so there is either no number at all or the cosmetic set, and that
-- is exactly when the user is looking. A score read cleanly once is still roughly
-- true a week later, so it is shown straight away while a fresh scan runs behind
-- it, and the live read replaces it the moment it lands.
--
-- Only clean finished reads are kept. A number that still looked transmogged, or
-- one that gave up without a reply, is precisely what must not be made permanent.
-- Both bounds are deliberately tight. Every entry here is parsed out of
-- SavedVariables.lua at each login, and the value of a remembered score decays
-- fast: in WotLK progression the gear behind it has usually moved on within a
-- raid lockout or two, at which point showing it buys nothing and costs a wrong
-- number on screen until the live read lands.
local STORE_MAX = 300                      -- names kept; a raid night touches a couple of hundred
local STORE_MAX_AGE = 14 * 24 * 60 * 60    -- a fortnight, about two lockouts

local function Remember(Name, Entry)
	if ( type(GS_Cache) ~= "table" ) or not ( Name ) or not ( Entry ) then return; end
	if not ( Entry.complete ) or ( Entry.suspect ) or ( Entry.score <= 0 ) then return; end
	-- time() is wall clock; GetTime() is uptime and means nothing across sessions.
	GS_Cache[Name] = { score = Entry.score, ilvl = Entry.ilvl, time = time() }
end

-- Anything malformed is dropped rather than repaired: the file is user-editable
-- and a stray value would otherwise reach the tooltip and the score arithmetic.
local function PruneStore()
	if ( type(GS_Cache) ~= "table" ) then GS_Cache = {}; return; end
	local Now, Names = time(), {}
	for Name, Saved in pairs(GS_Cache) do
		if ( type(Name) ~= "string" ) or ( type(Saved) ~= "table" )
		   or ( type(Saved.score) ~= "number" ) or ( Saved.score <= 0 )
		   or ( type(Saved.time) ~= "number" ) or ( ( Now - Saved.time ) > STORE_MAX_AGE ) then
			GS_Cache[Name] = nil
		else
			if ( type(Saved.ilvl) ~= "number" ) then Saved.ilvl = 0; end
			Names[#Names + 1] = Name
		end
	end
	if ( #Names <= STORE_MAX ) then return; end
	sort(Names, function(a, b) return GS_Cache[a].time > GS_Cache[b].time end)
	for i = STORE_MAX + 1, #Names do GS_Cache[Names[i]] = nil; end
end

-- What the tooltip and the public API should show for a name.
local function DisplayEntry(Name)
	local Entry = GSL.cache[Name]
	local Saved = ( type(GS_Cache) == "table" ) and GS_Cache[Name] or nil
	if not ( Saved ) then return Entry; end
	-- A finished, clean read of what they are wearing now beats any memory.
	if ( Entry ) and ( Entry.complete ) and not ( Entry.suspect ) then return Entry; end
	-- Otherwise memory only stands in while it is the better number: a scan still
	-- filling in slots, or one reading the cosmetic set, is low by definition.
	if ( Entry ) and ( Entry.score >= Saved.score ) then return Entry; end
	return { score = Saved.score, ilvl = Saved.ilvl, complete = true, suspect = false,
	         remembered = Saved.time, time = GetTime() }
end

local function ScanUnit(Name, Unit)
	local Blocked = Obstacle(Unit)
	if ( Blocked ) then
		Log("scan %s blocked: %s", tostring(Name), ObstacleText[Blocked] or Blocked)
		-- Permanent for this unit, so let the caller stop retrying. Range, a busy
		-- inspect slot and a client that is not ready to inspect yet are all
		-- transient: report unfinished and try again.
		if ( Blocked == "npc" ) or ( Blocked == "gone" ) then
			GSL.blocked[Name] = Blocked
			return true
		end
		GSL.blocked[Name] = Blocked
		return false
	end
	GSL.blocked[Name] = nil

	-- Never while an inspect window is open: this request would retarget it. When
	-- the window already holds this unit the gear is readable below anyway.
	if ( CanInspect(Unit) ) and not ( InspectInUse() ) then
		local Now = GetTime()
		-- Debounced rather than fired once per unit: a request the server drops
		-- has to be asked again, or the unit is stuck with no score at all.
		if ( GSL.lastInspectName ~= Name ) or ( ( Now - GSL.lastInspectTime ) > 1.5 ) then
			GSL.lastInspectName = Name
			GSL.lastInspectTime = Now
			-- Only the target moves: the client goes on serving whoever it already
			-- holds until this reply actually lands. Set here as well as in the
			-- NotifyInspect hook because the local upvalue above bypasses it.
			GSL.inspectTarget = Name
			NotifyInspect(Unit)
			Log("NotifyInspect(%s) for %s", tostring(Unit), tostring(Name))
		end
	end

	local Score, Average, Complete, Suspect, Read, Total, Breakdown = GearScore_GetScore(Name, Unit)
	if not ( Score ) then return true; end

	-- A full set of links is not proof the gear arrived: the visible-item fields
	-- fill every slot from render range alone, and on a transmog realm they hold
	-- the cosmetic set. Accepting that as final is how a BiS-geared player ends up
	-- cached at their transmog score for the next ten minutes.
	--
	-- The test has to be per player, not "some reply landed". A normal install has
	-- seven other addons asking for the same single inspect slot, and every one of
	-- their replies fires the same event here. Treating any of them as an answer
	-- meant a reply about somebody else in the raid certified our half-read
	-- cosmetic set as final, which is exactly the reported fault.
	if ( Complete ) and not ( UnitIsUnit(Unit, "player") ) and ( GSL.answeredFor ~= Name ) then
		Complete = false
	end

	Log("scan %s: score=%d ilvl=%d slots=%d/%d %s", tostring(Name), Score, Average,
	    Read or 0, Total or 0, Complete and "complete" or "partial")

	-- Item data lands slot by slot, and a fixed try count expires mid-fill in a
	-- raid, locking in a number several hundred points low. A scan reading more
	-- slots than last time is progressing, so give its budget back; SCAN_DEADLINE
	-- still stops gear that never resolves.
	if ( Name == GSL.scanName ) and ( Read ) and ( Read > ( GSL.scanRead or 0 ) ) then
		GSL.scanRead = Read
		if ( GSL.scanDeadline ) and ( GetTime() < GSL.scanDeadline ) and ( GSL.scanTries < SCAN_TRIES ) then
			GSL.scanTries = SCAN_TRIES
		end
	end

	-- A complete read that still looks mogged is very often a half-updated one.
	-- The client replaces the visible-item entries with the real gear slot by slot,
	-- so a single pass can catch some slots already real and the rest still
	-- cosmetic: a third-party inspect list on this realm shows exactly that, tier
	-- pieces and level 120 cosmetics side by side in one snapshot. Spend a few more
	-- passes before settling. A reading can only improve, so the best one wins.
	-- The budget is capped against the queue HERE, each pass, rather than being
	-- fixed when the scan starts. By the time a queued unit reaches the scan slot
	-- everyone ahead of it has been dequeued, so a start-time check reads an empty
	-- queue and always grants the full budget -- the one case it was meant to
	-- limit. Re-reading it every pass is what actually yields the slot: these
	-- passes cost the rest of the raid their turn, and a genuinely transmogged
	-- player reads the same way at pass six as at pass two.
	local Settle = Complete
	if ( Complete ) and ( Suspect ) and not ( UnitIsUnit(Unit, "player") ) then
		local Budget = ( #GSL.queue > 0 ) and SCAN_CONFIRM_BUSY or SCAN_CONFIRM
		local Left = GSL.scanConfirm or SCAN_CONFIRM
		if ( Left > Budget ) then Left = Budget; end
		if ( Left > 0 ) then
			GSL.scanConfirm = Left - 1
			Settle = false
		end
	end

	local Previous = GSL.cache[Name]

	-- Out of inspect range (~28 yards) or behind line of sight, every slot reads
	-- nil and the scan scores 0. That is absence of data, not a score of zero, so
	-- keep the known-good entry and report the scan unfinished. Overwriting it is
	-- what makes a score vanish when a raid member drifts out of range.
	if ( Score == 0 ) and ( Previous ) and ( Previous.score > 0 ) then
		return false
	end

	-- A reading may only ever improve. Slots resolve one by one and the real gear
	-- replaces the visible-item entries, so the number climbs; it has no honest
	-- reason to fall. It falls when another addon inspects somebody else midway
	-- through our scan: the client drops this player's gear and GetInventoryItemLink
	-- quietly goes back to serving the cosmetic set. Overwriting here is what let a
	-- correctly read BiS player decay into their transmog score. A real downgrade
	-- arrives as UNIT_INVENTORY_CHANGED, which drops the entry outright.
	if ( Previous ) and ( Previous.score > Score ) then
		Log("scan %s: ignored a lower reading (%d < %d), inspect data went stale",
		    tostring(Name), Score, Previous.score)
		return Settle
	end

	-- Slot counts are kept with the entry because the live read below goes empty
	-- the moment anything else is inspected, and "0 of 0" then looks like a fault
	-- rather than a score taken correctly a minute ago.
	--
	-- The per-slot breakdown is kept only while debugging. It is seventeen small
	-- tables per player and nothing but /gs gear ever reads it, so in a full raid
	-- it is a few thousand tables held for the session to serve a command nobody
	-- runs. /gs gear says so and asks for /gs debug when it is missing.
	GSL.cache[Name] = { score = Score, ilvl = Average, complete = Complete, suspect = Suspect,
	                    read = Read, occupied = Total, time = GetTime(),
	                    breakdown = GS_Settings.Debug and Breakdown or nil }
	-- A clean complete read is the answer; stop charging re-reads against them,
	-- and it is the only kind worth remembering across sessions. Checked here
	-- rather than inside Remember() so the hot path does not call it 24 times per
	-- scan just to have it decline.
	if ( Complete ) and not ( Suspect ) then
		GSL.unsure[Name] = nil
		Remember(Name, GSL.cache[Name])
	end
	if not ( Previous ) or ( Previous.score ~= Score ) then
		Announce(Name, Score, Average)
		RefreshTooltip(Name)
	end
	return Settle
end

-- The server hands out one inspect slot at a time, so only one unit can ever be
-- in flight. Everyone else waits in this queue and is scanned in turn, rather
-- than being overwritten by the next mouseover.
local QUEUE_MAX = 40   -- a full 40-man raid; beyond that the oldest is dropped

local function Dequeue(Name)
	if not ( GSL.queued[Name] ) then return; end
	GSL.queued[Name] = nil
	for i = 1, #GSL.queue do
		if ( GSL.queue[i] == Name ) then table.remove(GSL.queue, i); break; end
	end
end

local function CancelRescan()
	if ( GSL.scanName ) then Dequeue(GSL.scanName); end
	GSL.scanName = nil
	GSL.scanUnit = nil
	GSL.scanTries = 0
	GSL.scanRead = 0
	GSL.scanDeadline = nil
	GSL.scanConfirm = SCAN_CONFIRM
end

-- Everything a fresh scan needs, in one place: the two budgets are easy to set
-- in one caller and forget in the other.
local function BeginScan(Name, Unit)
	GSL.scanName = Name
	GSL.scanUnit = Unit
	GSL.scanTries = SCAN_TRIES
	GSL.scanRead = 0
	GSL.scanDeadline = GetTime() + SCAN_DEADLINE
	-- Full budget here; ScanUnit() caps it against the queue on every pass, which
	-- is the only place the queue length is still meaningful.
	GSL.scanConfirm = SCAN_CONFIRM
	RescanFrame:Show()
end

-- Promote the next queued unit into the active scan slot.
local function NextInQueue()
	while ( #GSL.queue > 0 ) do
		local Name = table.remove(GSL.queue, 1)
		local Unit = GSL.queued[Name]
		GSL.queued[Name] = nil
		-- Queued units go stale: the player walked off, or the frame that supplied
		-- the token now points at somebody else. Verify before spending the slot.
		if ( Unit ) and ( UnitExists(Unit) ) and ( UnitName(Unit) == Name ) then
			BeginScan(Name, Unit)
			Log("queue -> scanning %s (%d still waiting)", tostring(Name), #GSL.queue)
			return true
		end
		Log("queue: dropped stale entry %s", tostring(Name))
	end
	return false
end

local function DoRescan()
	local Name, Unit = GSL.scanName, GSL.scanUnit
	if not ( Name ) or not ( Unit ) then CancelRescan(); NextInQueue(); return; end
	if not ( UnitExists(Unit) ) or ( UnitName(Unit) ~= Name ) then
		Log("scan %s abandoned: unit changed", tostring(Name))
		CancelRescan(); NextInQueue(); return
	end
	GSL.scanTries = GSL.scanTries - 1
	if ( ScanUnit(Name, Unit) ) then
		CancelRescan()
		NextInQueue()
	elseif ( GSL.scanTries <= 0 ) then
		Log("scan %s gave up: %d slots read, budget exhausted", tostring(Name), GSL.scanRead or 0)
		-- The reply never came, so whatever was read is all there will be. Mark it
		-- settled: without this the entry stays un-fresh and every later mouseover
		-- restarts the same doomed scan, which in a raid is most of them. `complete`
		-- stays false, so the tooltip still shows the number as provisional.
		local Entry = GSL.cache[Name]
		if ( Entry ) then Entry.settled = true; end
		CancelRescan()
		NextInQueue()
	end
end

-- Writes straight to the session cache and deliberately never calls Remember():
-- your own inventory is read directly and is always current, so a saved copy
-- could only ever be a staler version of a number already in hand. Keeping it
-- out also means /gs rescan and the store's age and size limits never have to
-- reason about an entry that behaves unlike every other one in there.
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

-- A complete score is still only a snapshot: people regem, swap trinkets and
-- pick up loot mid-raid. Re-inspect anything older than this on the next request.
local CACHE_TTL = 600  -- seconds

-- A reading that still trips the transmog check, or one that gave up without ever
-- getting a reply, is not a snapshot of anything: it is what the client happened
-- to hold while it was still catching up. The real gear does arrive, just later
-- and slot by slot, so these come back around in seconds instead of minutes and
-- the number converges on its own. A re-read can only improve it.
local CACHE_TTL_UNSURE = 20
-- ...but not forever. A genuinely transmogged player reads the same way every
-- time, and would otherwise be re-inspected every twenty seconds for the whole
-- raid night while everyone else waits for the one inspect slot.
local UNSURE_RETRIES = 3

local function IsFresh(Name)
	local Entry = GSL.cache[Name]
	if not ( Entry ) or ( Entry.score <= 0 ) then return false; end
	-- `settled` is a scan that ran out of budget without the inspect reply. It is
	-- not complete and never will be, so treat it as fresh to stop every mouseover
	-- from restarting it; the TTL still brings it back around eventually.
	if not ( Entry.complete ) and not ( Entry.settled ) then return false; end
	local Unsure = ( Entry.suspect or Entry.settled )
	                and ( ( GSL.unsure[Name] or 0 ) < UNSURE_RETRIES )
	return ( GetTime() - Entry.time ) < ( Unsure and CACHE_TTL_UNSURE or CACHE_TTL )
end

-- "target" and "mouseover" are the tokens the tooltip hands us, and both point
-- somewhere else the moment the user looks away -- which then abandons the scan
-- mid-flight. When the same player also sits in the group, the raidN/partyN
-- token names them stably for as long as they are in it, so prefer it.
local function StableUnit(Name, Unit)
	if not ( Unit ) then return Unit; end
	if ( Unit ~= "target" ) and ( Unit ~= "mouseover" ) and ( Unit ~= "focus" ) then return Unit; end
	for i = 1, 40 do
		local Candidate = "raid" .. i
		if ( UnitExists(Candidate) ) and ( UnitName(Candidate) == Name ) then return Candidate; end
	end
	for i = 1, 4 do
		local Candidate = "party" .. i
		if ( UnitExists(Candidate) ) and ( UnitName(Candidate) == Name ) then return Candidate; end
	end
	return Unit
end

-- Queue an inspect for a unit and keep retrying until its items arrive.
local function Track(Name, Unit, Force)
	if not ( Unit ) or not ( UnitExists(Unit) ) or not ( UnitIsPlayer(Unit) ) then return; end
	Name = Name or UnitName(Unit)
	if not ( Name ) then return; end
	Unit = StableUnit(Name, Unit)

	-- A fresh complete entry needs nothing; spending the single inspect slot on
	-- it would starve the units that have no score at all. `Force` is the public
	-- API asking outright, which is always a deliberate "read it again now".
	if not ( Force ) and ( IsFresh(Name) ) then return; end

	-- Charge the re-read against the short lifetime above, so a player whose gear
	-- never resolves is retried a few times and then left alone.
	local Stale = GSL.cache[Name]
	if ( Stale ) and ( Stale.suspect or Stale.settled ) then
		GSL.unsure[Name] = ( GSL.unsure[Name] or 0 ) + 1
	end

	-- Record the obstacle before anything else. A permanently blocked unit -- an
	-- NPC, or one already gone -- must never reach the queue: it can never
	-- succeed, and it would hold a slot the rest of the raid needs. Everything
	-- else, faction included, is retried.
	local Blocked = Obstacle(Unit)
	GSL.blocked[Name] = Blocked
	if ( Blocked == "npc" ) or ( Blocked == "gone" ) then
		Log("skip %s: %s", tostring(Name), ObstacleText[Blocked] or Blocked)
		Dequeue(Name)
		return
	end

	-- Already the active scan, or already waiting. Refresh the stored token --
	-- the same player can be hovered through a different frame -- but do not
	-- restart the attempt counter or push a duplicate into the queue.
	if ( GSL.scanName == Name ) then GSL.scanUnit = Unit; return; end
	if ( GSL.queued[Name] ) then GSL.queued[Name] = Unit; return; end

	-- Nothing in flight: scan immediately rather than waiting for the next tick.
	if not ( GSL.scanName ) then
		if not ( ScanUnit(Name, Unit) ) then BeginScan(Name, Unit); end
		return
	end

	-- Drop the oldest rather than the newest when the queue is full: the newest
	-- is whoever the user is looking at right now.
	if ( #GSL.queue >= QUEUE_MAX ) then
		local Oldest = table.remove(GSL.queue, 1)
		if ( Oldest ) then GSL.queued[Oldest] = nil; end
		Log("queue full, dropped %s", tostring(Oldest))
	end
	GSL.queue[#GSL.queue + 1] = Name
	GSL.queued[Name] = Unit
	Log("queued %s (position %d)", tostring(Name), #GSL.queue)
	RescanFrame:Show()
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
	if ( GSL.scanName ) then
		DoRescan()
	else
		-- The active slot fell idle -- a scan finished or was abandoned outside the
		-- tick -- so start the next queued unit instead of stalling until the user
		-- hovers somebody new.
		NextInQueue()
	end

	-- Nothing pending: stop burning a frame handler until we are needed again.
	if ( GSL.playerTries <= 0 ) and not ( GSL.scanName ) and ( #GSL.queue == 0 ) then self:Hide(); end
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

	-- No inspect-window guard here on purpose: ScanUnit() already withholds the
	-- NotifyInspect(), and repeating the check suppressed the harmless read too.
	if ( Unit ) and not ( GSL.refreshing ) then
		if ( not GS_Settings.MustTarget ) or ( UnitIsUnit("target", Unit) ) then
			-- Cleared through pcall: if anything below throws, an unguarded
			-- assignment would never run and the flag would stay true, which
			-- suppresses RefreshTooltip() for the rest of the session.
			GSL.inTooltipHook = true
			pcall(Track, Name, Unit)
			GSL.inTooltipHook = false
		end
	end

	local Entry = DisplayEntry(Name)
	if not ( Entry ) or ( Entry.score <= 0 ) then
		-- No number yet. Silence here is what makes the addon look broken: the
		-- user cannot tell "out of range" from "not working". Say which it is.
		if ( GS_Settings.Status ) and ( Unit ) and not ( UnitIsUnit(Unit, "player") ) then
			local Reason = GSL.blocked[Name]
			if ( Reason ) and ( Reason ~= "npc" ) then
				GameTooltip:AddLine("GearScore: " .. ( ObstacleText[Reason] or Reason ), 0.6, 0.6, 0.6)
			elseif ( GSL.scanName == Name ) then
				GameTooltip:AddLine("GearScore: scanning...", 0.6, 0.6, 0.6)
			elseif ( GSL.queued[Name] ) then
				GameTooltip:AddLine("GearScore: queued for inspect", 0.6, 0.6, 0.6)
			end
		end
		return
	end

	local Red, Green, Blue = QualityRGB(Entry.score)
	local Score = tostring(Entry.score)
	if ( Entry.remembered ) then
		-- Say it is from memory rather than passing it off as a live reading. An
		-- unmarked number is taken as what the player is wearing right now, and a
		-- week-old score presented that way is worse than no score: the user cannot
		-- tell it is stale, so they never think to wait the second it takes the real
		-- one to arrive and replace it.
		Score = Score .. "~"
	elseif not ( Entry.complete ) then
		Score = Score .. "+"  -- still filling in
	end

	if ( GS_Settings.Level ) then
		GameTooltip:AddDoubleLine("GearScore: " .. Score, "(iLevel: " .. Entry.ilvl .. ")", Red, Green, Blue, Red, Green, Blue)
	else
		GameTooltip:AddLine("GearScore: " .. Score, Red, Green, Blue)
	end

	if ( Entry.remembered ) then
		local Age = time() - Entry.remembered
		local Ago
		if ( Age < 3600 ) then Ago = "moments ago"
		elseif ( Age < 86400 ) then Ago = floor(Age / 3600) .. "h ago"
		else Ago = floor(Age / 86400) .. "d ago"
		end
		GameTooltip:AddLine("(remembered, " .. Ago .. " -- rescanning)", 0.6, 0.6, 0.6)
	end

	-- Say it outright rather than showing a quietly wrong number: an inspected
	-- player's gear arrives as visible-item ids, so a transmogrified slot is
	-- indistinguishable from the real thing and drags the score down.
	-- Opt-in: on a realm without mod-transmog the flag can only ever be a false
	-- positive, and even where it is right it is a guess about someone else's
	-- gear. Off by default, enable with /gs mog.
	if ( Entry.suspect ) and ( GS_Settings.Transmog ) then
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

------------------------------- Debug report ----------------------------------

-- A copyable window, because the chat frame cannot be selected with the mouse
-- in 3.3.5 and a scan log is far too long to retype. Built on first use only:
-- most sessions never open it.
local DumpFrame

local function BuildDumpFrame()
	if ( DumpFrame ) then return DumpFrame; end

	local Frame = CreateFrame("Frame", "GearScoreLiteDumpFrame", UIParent)
	Frame:SetWidth(560)
	Frame:SetHeight(420)
	Frame:SetPoint("CENTER")
	Frame:SetFrameStrata("DIALOG")
	Frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	Frame:SetMovable(true)
	Frame:EnableMouse(true)
	Frame:RegisterForDrag("LeftButton")
	Frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
	Frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

	local Title = Frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	Title:SetPoint("TOP", Frame, "TOP", 0, -16)
	Title:SetText("GearScoreLite -- scan log")

	local Hint = Frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	Hint:SetPoint("TOP", Title, "BOTTOM", 0, -2)
	Hint:SetText("Ctrl+A then Ctrl+C to copy, Escape to close")

	local Scroll = CreateFrame("ScrollFrame", "GearScoreLiteDumpScroll", Frame, "UIPanelScrollFrameTemplate")
	Scroll:SetPoint("TOPLEFT", Frame, "TOPLEFT", 18, -52)
	Scroll:SetPoint("BOTTOMRIGHT", Frame, "BOTTOMRIGHT", -36, 40)

	local Edit = CreateFrame("EditBox", "GearScoreLiteDumpEdit", Scroll)
	Edit:SetMultiLine(true)
	Edit:SetAutoFocus(false)
	Edit:SetFontObject(ChatFontNormal)
	Edit:SetWidth(490)
	Edit:SetScript("OnEscapePressed", function() Frame:Hide() end)
	Scroll:SetScrollChild(Edit)

	local Close = CreateFrame("Button", nil, Frame, "UIPanelButtonTemplate")
	Close:SetWidth(90)
	Close:SetHeight(22)
	Close:SetPoint("BOTTOM", Frame, "BOTTOM", 0, 14)
	Close:SetText("Close")
	Close:SetScript("OnClick", function() Frame:Hide() end)

	Frame.edit = Edit
	DumpFrame = Frame
	return Frame
end

-- Header first: the state questions get asked about anyway (version, settings,
-- what is in flight), so it travels with the log rather than in a follow-up.
local function DumpText()
	local Out = {}
	-- Read the version off the .toc rather than repeating it here, so a release
	-- bump cannot leave the debug report claiming the wrong build.
	local Version = GetAddOnMetadata and GetAddOnMetadata("GearScoreLite", "Version") or "?"
	Out[#Out + 1] = "GearScoreLite: Reborn " .. tostring(Version) .. " -- scan log"
	Out[#Out + 1] = format("player: %s  score=%d  ilvl=%d",
		tostring(UnitName("player")), GSL.player.score, GSL.player.ilvl)
	Out[#Out + 1] = format("settings: colour=%s status=%s mog=%s combat=%s target=%s",
		tostring(GS_Settings and GS_Settings.ColorMode),
		tostring(GS_Settings and GS_Settings.Status),
		tostring(GS_Settings and GS_Settings.Transmog),
		tostring(GS_Settings and GS_Settings.HideInCombat),
		tostring(GS_Settings and GS_Settings.MustTarget))
	Out[#Out + 1] = format("active scan: %s   queued: %d   inspect window open: %s",
		tostring(GSL.scanName), #GSL.queue, tostring(InspectInUse()))

	local Cached = 0
	for _ in pairs(GSL.cache) do Cached = Cached + 1; end
	Out[#Out + 1] = format("cached scores: %d", Cached)
	Out[#Out + 1] = ""
	Out[#Out + 1] = "--- log (oldest first) ---"

	local Lines = LogLines()
	if ( #Lines == 0 ) then
		Out[#Out + 1] = "(empty -- hover some players first)"
	else
		for i = 1, #Lines do Out[#Out + 1] = Lines[i]; end
	end
	return table.concat(Out, "\n")
end

local function ShowDump()
	local Frame = BuildDumpFrame()
	Frame.edit:SetText(DumpText())
	Frame.edit:SetCursorPosition(0)
	Frame:Show()
end

-- Diagnostics only. "slot 11" does not tell anyone which ring is missing.
local SlotNames = {
	[1] = "head", [2] = "neck", [3] = "shoulder", [5] = "chest", [6] = "waist",
	[7] = "legs", [8] = "feet", [9] = "wrist", [10] = "hands", [11] = "finger1",
	[12] = "finger2", [13] = "trinket1", [14] = "trinket2", [15] = "back",
	[16] = "main hand", [17] = "off hand", [18] = "ranged",
}

-- Slots whose item has not reached the local cache. They are exactly the slots
-- left out of the score, so they answer "why is this number too low". Transmog
-- collects here: the cosmetic item is usually one this client has never seen.
local function UnresolvedSlots(Unit)
	local Missing = {}
	for i = 1, 18 do
		if ( i ~= 4 ) then
			local ItemLink = GetInventoryItemLink(Unit, i)
			if ( ItemLink ) then
				local _, _, Rarity, Level = GetItemInfo(ItemLink)
				if not ( Rarity ) or not ( Level ) then
					Missing[#Missing + 1] = SlotNames[i] or ( "slot " .. i )
				end
			end
		end
	end
	return Missing
end

-- The slots the mog heuristic is reacting to, and the median it compared them
-- against. A bare "possibly transmogged" does not say which slots dragged the
-- number down, which is the only thing anyone actually wants to know.
-- Weapons are excluded here exactly as they are in the score itself.
local function MogOutliers(Unit)
	local Levels, BySlot = {}, {}
	for i = 1, 15 do
		if ( i ~= 4 ) then
			local ItemLink = GetInventoryItemLink(Unit, i)
			if ( ItemLink ) then
				local _, _, Rarity, Level = GetItemInfo(ItemLink)
				if ( Rarity ) and ( Level ) and ( Level > 0 ) then
					Levels[#Levels + 1] = Level
					BySlot[#BySlot + 1] = { slot = i, ilvl = Level }
				end
			end
		end
	end
	if ( #Levels < 5 ) then return nil; end
	local Median = MedianOf(Levels)
	if not ( Median ) then return nil; end

	local Low = {}
	for i = 1, #BySlot do
		local Entry = BySlot[i]
		if ( Entry.ilvl < Median * MOG_RATIO ) and ( Median - Entry.ilvl >= MOG_FLOOR ) then
			Low[#Low + 1] = ( SlotNames[Entry.slot] or ( "slot " .. Entry.slot ) ) .. " (" .. Entry.ilvl .. ")"
		end
	end
	return Median, Low
end

-- Resolve a name to a unit token, or fall back to the current target/mouseover.
-- Shared by /gs why and /gs gear so the two never disagree about who they mean.
local function ResolveByName(Query)
	if ( Query ) and ( Query ~= "" ) then
		for i = 1, 40 do
			local Candidate = "raid" .. i
			if ( UnitExists(Candidate) ) and ( UnitName(Candidate) == Query ) then return Query, Candidate; end
		end
		for i = 1, 4 do
			local Candidate = "party" .. i
			if ( UnitExists(Candidate) ) and ( UnitName(Candidate) == Query ) then return Query, Candidate; end
		end
		if ( UnitExists("target") ) and ( UnitName("target") == Query ) then return Query, "target"; end
		return Query, nil
	end
	if ( UnitExists("target") ) then return UnitName("target"), "target"; end
	if ( UnitExists("mouseover") ) then return UnitName("mouseover"), "mouseover"; end
	return nil, nil
end

-- /gs gear: the per-slot items the last scan actually read, printed as real item
-- links. Comparing this list against the inspect window is the only way to tell
-- a transmogrified slot from a scoring fault -- the score alone cannot.
local function ShowGear(Query)
	local Name = ResolveByName(Query)
	if not ( Name ) then
		print("GearScore -- /gs gear <name>, or target somebody first.")
		return
	end

	local Entry = GSL.cache[Name]
	if not ( Entry ) then
		print("|cff66ccffGearScore|r -- no scan recorded for " .. tostring(Name) .. " yet. Hover them first.")
		return
	end
	-- Distinguish "never scanned" from "scanned, but the breakdown was not being
	-- kept": the fix for the second is a setting, not hovering them again.
	if not ( Entry.breakdown ) or ( #Entry.breakdown == 0 ) then
		if not ( GS_Settings.Debug ) then
			print("|cff66ccffGearScore|r -- the per-slot breakdown is only recorded while debugging,")
			print("  because it is a lot of memory to hold for a whole raid. Run /gs debug, then")
			print("  hover " .. tostring(Name) .. " again and this will have something to show.")
		else
			print("|cff66ccffGearScore|r -- nothing readable in " .. tostring(Name) .. "'s slots on the last scan.")
		end
		return
	end

	print(format("|cff66ccffGearScore|r -- what the last scan read for %s (score %d, iLevel %d, %d seconds ago):",
		tostring(Name), Entry.score, Entry.ilvl, floor(GetTime() - Entry.time)))
	for i = 1, #Entry.breakdown do
		local Slot = Entry.breakdown[i]
		print(format("  %-10s iLevel %-4d GS %-5d %s",
			SlotNames[Slot.slot] or ( "slot " .. Slot.slot ),
			Slot.ilvl, Slot.score, tostring(Slot.link)))
	end
	if ( Entry.suspect ) then
		print("  Slots whose item is far below the rest are what the client received;")
		print("  on a transmog realm that IS the cosmetic item, not the real one.")
	end
end

-- /gs why: a one-shot verdict for a single player, which is what someone
-- actually wants when one name in the raid has no number.
local function Explain(Query)
	local Name, Unit

	if ( Query ) and ( Query ~= "" ) then
		Name = Query
		-- A name is not a unit token, so find a token that currently resolves to
		-- it; without one only the cache can be reported.
		for i = 1, 40 do
			local Candidate = "raid" .. i
			if ( UnitExists(Candidate) ) and ( UnitName(Candidate) == Name ) then Unit = Candidate; break; end
		end
		if not ( Unit ) then
			for i = 1, 4 do
				local Candidate = "party" .. i
				if ( UnitExists(Candidate) ) and ( UnitName(Candidate) == Name ) then Unit = Candidate; break; end
			end
		end
		if not ( Unit ) and ( UnitExists("target") ) and ( UnitName("target") == Name ) then Unit = "target"; end
	elseif ( UnitExists("target") ) then
		Unit, Name = "target", UnitName("target")
	elseif ( UnitExists("mouseover") ) then
		Unit, Name = "mouseover", UnitName("mouseover")
	end

	if not ( Name ) then
		print("GearScore -- /gs why <name>, or target somebody first.")
		return
	end

	print("|cff66ccffGearScore|r -- report for " .. tostring(Name) .. ":")

	if ( Unit ) then
		local Blocked = Obstacle(Unit)
		if ( Blocked ) then
			print("  blocked: " .. ( ObstacleText[Blocked] or Blocked ))
		else
			print("  inspectable: yes")
		end
	else
		print("  no unit token in range (not in your raid, party or target)")
	end

	local Entry = GSL.cache[Name]
	if ( Entry ) then
		print(format("  cached: score %d, ilvl %d, %s, %d seconds old",
			Entry.score, Entry.ilvl, Entry.complete and "complete" or "partial",
			floor(GetTime() - Entry.time)))
		if ( Entry.occupied ) then
			print(format("  that scan read %d of %d equipped slots", Entry.read or 0, Entry.occupied))
		end
		if ( Entry.suspect ) then
			print("  transmog: slots far below this character's median iLevel, so the")
			print("            real gear is better than this score. /gs mog shows it in the tooltip.")
		end
	else
		print("  cached: nothing yet")
	end

	local Saved = ( type(GS_Cache) == "table" ) and GS_Cache[Name] or nil
	if ( Saved ) then
		print(format("  remembered from an earlier session: score %d, ilvl %d, %d hours old",
			Saved.score, Saved.ilvl or 0, floor(( time() - Saved.time ) / 3600)))
	end

	if ( GSL.scanName == Name ) then
		print(format("  currently scanning, %d tries left", GSL.scanTries))
	elseif ( GSL.queued[Name] ) then
		print("  waiting in the inspect queue")
	end

	-- The single most useful line when a number looks too low. One inspect slot is
	-- shared by every addon on the client, and only the player it currently holds
	-- reads back real gear; everyone else reads their visible-item entries, which
	-- on a transmog realm is the cosmetic set.
	if ( GSL.answeredFor == Name ) then
		print("  inspect data: the client is holding this player's gear")
	elseif ( GSL.answeredFor ) then
		print("  inspect data: the client is holding " .. tostring(GSL.answeredFor)
		      .. "'s gear, not this player's")
	else
		print("  inspect data: none held yet (request in flight)")
	end

	-- Reported whatever the cache holds: gating on an empty cache hid the slot
	-- counts in the case that needs them most, a partial entry showing a number
	-- the user can already see is too low.
	if ( Unit ) then
		local _, _, _, _, Read, Occupied = GearScore_GetScore(Name, Unit)
		if ( Occupied ) and ( Occupied > 0 ) then
			print(format("  visible gear right now: %d of %d slots readable", Read or 0, Occupied))
			local Missing = UnresolvedSlots(Unit)
			if ( #Missing > 0 ) then
				print("  unresolved, item data still arriving: " .. table.concat(Missing, ", "))
			end
			local Median, Low = MogOutliers(Unit)
			if ( Median ) and ( Low ) and ( #Low > 0 ) then
				print(format("  median armour iLevel %d; far below it: %s", Median, table.concat(Low, ", ")))
			end
		else
			-- Not a fault, and in particular not a contradiction of a cached score
			-- above: the client holds inspect data for one unit at a time, so this
			-- reads empty as soon as anything else is inspected.
			print("  no inspect data held right now -- the client keeps only the most")
			print("  recent inspect, so this says nothing about the score above")
		end
	end
end

------------------------------ Slash commands ---------------------------------

local function Toggle(Key, Label)
	GS_Settings[Key] = not GS_Settings[Key]
	print("GearScore -- " .. Label .. ": " .. ( GS_Settings[Key] and "On" or "Off" ))
end

function GS_MANSET(Command)
	local Raw = strtrim(Command or "")
	Command = strlower(Raw)
	-- "step" and "range" take arguments; every other verb is a bare word and
	-- still matches the Command comparisons below unchanged.
	local Verb, Args = Command:match("^(%S+)%s*(.*)$")
	Verb, Args = Verb or Command, Args or ""
	-- Player names are case sensitive and Command is folded to lower case, so
	-- "/gs why Kappa" has to read its argument from the untouched input.
	local RawArgs = Raw:match("^%S+%s+(.*)$") or ""

	if ( Command == "player" ) or ( Command == "show" ) then Toggle("Player", "Player Scores")
	elseif ( Command == "item" ) then Toggle("Item", "Item Scores")
	elseif ( Command == "level" ) then Toggle("Level", "Item Levels")
	elseif ( Command == "compare" ) then Toggle("Compare", "Comparisons")
	elseif ( Command == "target" ) then Toggle("MustTarget", "Must Target")
	elseif ( Command == "combat" ) then Toggle("HideInCombat", "Hide In Combat")
	elseif ( Command == "mog" ) or ( Command == "transmog" ) then Toggle("Transmog", "Transmog Warning")
	elseif ( Command == "status" ) then Toggle("Status", "Missing Score Reason")
	elseif ( Command == "debug" ) then
		Toggle("Debug", "Debug Logging")
		if ( GS_Settings.Debug ) then print("GearScore -- /gs dump opens the log in a copyable window."); end
	elseif ( Verb == "why" ) then Explain(strtrim(RawArgs))
	elseif ( Verb == "gear" ) then ShowGear(strtrim(RawArgs))
	elseif ( Verb == "rescan" ) then
		local Who, Token = ResolveByName(strtrim(RawArgs))
		if ( Token ) then
			GSL.cache[Who] = nil
			Track(Who, Token, true)
			print("GearScore -- re-reading " .. tostring(Who) .. ", check again in a moment.")
		else
			print("GearScore -- /gs rescan <name>, or target somebody first.")
		end
	elseif ( Command == "dump" ) then ShowDump()
	elseif ( Command == "queue" ) then
		print(format("GearScore -- scanning: %s   queued: %d", tostring(GSL.scanName), #GSL.queue))
		for i = 1, #GSL.queue do print("  " .. i .. ". " .. tostring(GSL.queue[i])); end
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

	elseif ( event == "INSPECT_TALENT_READY" ) or ( event == "INSPECT_READY" ) then
		-- A reply, but the event carries no usable unit: arg1 cannot be turned back
		-- into a token. The client answers the most recent request, so that is who
		-- this belongs to -- tracked for every addon on the client, not just ours,
		-- via the NotifyInspect hook below.
		GSL.answeredFor = GSL.inspectTarget
		if ( GSL.scanName ) then DoRescan(); end

	elseif ( event == "UNIT_INVENTORY_CHANGED" ) then
		-- On somebody else this is usually the arrival of their inspected gear, and
		-- unlike INSPECT_TALENT_READY it names the unit: it is the precise moment
		-- GetInventoryItemLink() switches from the visible-item entries to the real
		-- set, which is why the inspect window and InspectEquip refresh on it.
		--
		-- Only counted for the player an inspect was actually requested for. The
		-- same event fires when a raid member swaps a visible weapon, and taking
		-- that as an arrival would certify their cosmetic set as real gear.
		if ( arg1 ) and ( arg1 ~= "player" ) and ( UnitName(arg1) )
		   and ( UnitName(arg1) == GSL.inspectTarget ) then
			GSL.answeredFor = UnitName(arg1)
		end
		if ( arg1 == "player" ) then
			QueuePlayerRescan()
		elseif ( GSL.scanName ) and ( arg1 ) and ( UnitName(arg1) == GSL.scanName ) then
			-- Mid-scan. Usually this is their inspected gear arriving, but it is
			-- equally the event for gear genuinely changing, and the two are
			-- indistinguishable here -- so the partial reading collected so far is
			-- stale either way and must not be allowed to act as a floor.
			--
			-- Without this the monotonic guard in ScanUnit() rejects every lower
			-- reading against a score that predates the change, so a player who
			-- downgrades while being scanned keeps their old number for the rest of
			-- the session. Dropping the entry is what makes "a real downgrade arrives
			-- as UNIT_INVENTORY_CHANGED" true for the unit under the scanner too,
			-- and not only for everybody else.
			GSL.cache[GSL.scanName] = nil
			if ( type(GS_Cache) == "table" ) then GS_Cache[GSL.scanName] = nil; end
			DoRescan()
		elseif ( arg1 ) then
			-- Somebody else changed gear: their cached score is now wrong, so drop
			-- it rather than serve a stale number until the TTL expires.
			--
			-- The remembered score goes with it. This event is the one moment we
			-- know for certain the saved number is out of date, and DisplayEntry()
			-- would otherwise step straight in and serve it in place of the entry
			-- just dropped -- leaving the stale score on screen, which is the exact
			-- opposite of invalidating it.
			--
			-- Not gated on there being a live entry: the remembered one outlives the
			-- session and is just as stale whether or not this session read them.
			-- `blocked` and `unsure` are cleared here too. Both are keyed by name and
			-- nothing else prunes them, so over a long session in a city they
			-- accumulate an entry per player walked past and never give it back.
			local Who = UnitName(arg1)
			if ( Who ) then
				local Had = ( GSL.cache[Who] ~= nil )
				GSL.cache[Who] = nil
				GSL.unsure[Who] = nil
				GSL.blocked[Who] = nil
				if ( type(GS_Cache) == "table" ) then GS_Cache[Who] = nil; end
				if ( Had ) then Log("cache invalidated for %s (inventory changed)", tostring(Who)); end
			end
		end

	elseif ( event == "PLAYER_TARGET_CHANGED" ) then
		-- Deliberately does not cancel the in-flight scan: the "target" token it
		-- holds is re-validated by name on each retry, and anything genuinely
		-- stale is dropped there.
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
		-- Debug spams every scan into chat, so it never survives a reload: leaving
		-- it on by accident looks exactly like the addon being broken.
		GS_Settings.Debug = false
		PruneStore()
		GSL.inCombat = UnitAffectingCombat("player") and true or false
		ApplyAnchor()
		UpdatePaperDoll()
		self:UnregisterEvent("ADDON_LOADED")
	end
end)

-- Who the client is about to fetch, whoever asked. INSPECT_TALENT_READY says
-- only "a reply arrived", so without this the addon cannot tell a reply about the
-- player it is scanning from a reply about anyone else -- and in a normal install
-- ElvUI, DBM, Skada, EPGP and BonusScanner are all asking for the same slot.
-- LibTalentQuery coordinates through this same hook, for the same reason.
if ( hooksecurefunc ) then
	hooksecurefunc("NotifyInspect", function(Unit)
		local Who = ( Unit ) and UnitName(Unit) or nil
		if ( Who ) then GSL.inspectTarget = Who; end
	end)
end

EventFrame:RegisterEvent("ADDON_LOADED")
EventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
EventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
EventFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
EventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
EventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
EventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")

-- 3.3.5a calls this INSPECT_TALENT_READY; INSPECT_READY is the Cataclysm name.
-- LibTalentQuery (vendored by DBM, Skada and EPGP) and ElvUI's tooltip both use
-- the 3.3.5 name, so registering only the Cataclysm one leaves the addon with no
-- "gear has arrived" signal and back on pure timer polling.
--
-- Through pcall because RegisterEvent() throws on an event the client does not
-- know, and the tooltip hooks, slash commands and public API all sit below here.
for _, Event in ipairs({ "INSPECT_TALENT_READY", "INSPECT_READY" }) do
	pcall(EventFrame.RegisterEvent, EventFrame, Event)
end

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

	-- score, averageItemLevel, ageInSeconds, suspect, remembered -- cache only,
	-- never inspects. `remembered` is nil for a reading taken this session, and
	-- otherwise the wall-clock time the number was last read cleanly: it is a
	-- stand-in shown while the client answers, not a live measurement.
	GetCached = function(name)
		local Entry = name and DisplayEntry(name)
		if not ( Entry ) then return nil; end
		return Entry.score, Entry.ilvl, GetTime() - Entry.time, Entry.suspect, Entry.remembered
	end,

	-- Queue an asynchronous inspect; the result arrives via GEARSCORELITE_UPDATE.
	-- Always re-reads, even when a fresh score is already cached: an explicit
	-- call is a deliberate request, unlike the automatic tooltip path.
	Request = function(unit)
		if ( unit ) and ( UnitExists(unit) ) then Track(UnitName(unit), unit, true); end
	end,

	-- Your own score, always current, never needs an inspect.
	-- Drop the live reading for a name, leaving the remembered one. The next
	-- request reads them again from scratch; this is what /gs rescan does.
	Forget = function(name)
		if not ( name ) then return; end
		GSL.cache[name] = nil
		GSL.unsure[name] = nil
	end,

	GetPlayer = function() return GSL.player.score, GSL.player.ilvl end,

	-- callback(name, score, averageItemLevel)
	RegisterCallback = function(callback)
		if ( type(callback) == "function" ) then tinsert(GSL.listeners, callback); end
	end,
}
