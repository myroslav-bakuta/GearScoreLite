-------------------------------------------------------------------------------
--                        GearScoreLite: Reborn                              --
--                              mod by Kappa                                 --
--              https://github.com/myroslav-bakuta/GearScoreLite             --
--       (forked from https://github.com/Arcitec/GearScoreLite_Reborn)       --
--                                                                           --
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

local GSL = {
	cache = {},
	player = { score = 0, ilvl = 0 },
	listeners = {},
	scanName = nil,
	scanUnit = nil,
	scanTries = 0,
	scanRead = 0,
	scanDeadline = nil,
	playerTries = 0,
	timer = 0,
	lastInspectName = nil,
	lastInspectTime = 0,
	inspectTarget = nil,
	answeredFor = nil,
	inCombat = false,
	refreshing = false,
	queue = {},
	queued = {},
	blocked = {},
	unsure = {},
	log = {},
	logTime = {},
	logNext = 1,
	parked = {},
	yields = {},
	lastPrune = 0,
}

local LOG_MAX = 120
local DEBUG_MAX = 5000
local DEBUG_TRIM = 500

local function Debugging()
	return ( GS_Settings ) and ( GS_Settings.Debug ) and true or false
end

local function DebugWrite(Text)
	if ( type(GS_DebugLog) ~= "table" ) or ( type(GS_DebugLog.lines) ~= "table" ) then
		GS_DebugLog = { lines = {} }
	end
	local Lines = GS_DebugLog.lines
	Lines[#Lines + 1] = Text
	if ( #Lines > DEBUG_MAX + DEBUG_TRIM ) then
		local Kept = {}
		for i = #Lines - DEBUG_MAX + 1, #Lines do Kept[#Kept + 1] = Lines[i]; end
		GS_DebugLog.lines = Kept
	end
end

local function Log(Format, ...)
	local Ok, Text = pcall(format, Format, ...)
	if not ( Ok ) then Text = tostring(Format); end

	local Now = time()
	GSL.log[GSL.logNext] = Text
	GSL.logTime[GSL.logNext] = Now
	GSL.logNext = ( GSL.logNext % LOG_MAX ) + 1

	if ( Debugging() ) then
		DebugWrite(format("%s %9.2f  %s", date("%Y-%m-%d %H:%M:%S", Now), GetTime(), Text))
	end
end

local function Trace(...)
	if ( Debugging() ) then Log(...); end
end

local function LogLines()
	local Lines = {}
	for i = 0, LOG_MAX - 1 do
		local Index = ( ( GSL.logNext - 1 + i ) % LOG_MAX ) + 1
		local Entry = GSL.log[Index]
		if ( Entry ) then Lines[#Lines + 1] = date("%H:%M:%S", GSL.logTime[Index]) .. "  " .. Entry; end
	end
	return Lines
end

local function HexToRGB(Hex)
	local Value = tonumber(Hex, 16)
	if not ( Value ) then return nil; end
	return floor(Value / 65536) / 255, ( floor(Value / 256) % 256 ) / 255, ( Value % 256 ) / 255
end

local function ToLinear(C)
	if ( C <= 0.04045 ) then return C / 12.92; end
	return ((C + 0.055) / 1.055) ^ 2.4
end

local function ToSRGB(C)
	if ( C <= 0.0031308 ) then return C * 12.92; end
	return 1.055 * (C ^ (1 / 2.4)) - 0.055
end

local GradientCache, GradientCacheStops, GradientCacheCount = nil, nil, nil

local function BuildGradient()
	local Stops = ( GS_Gradient and GS_Gradient.Stops ) or {}
	if ( GradientCache ) and ( GradientCacheStops == Stops ) and ( GradientCacheCount == #Stops ) then
		return GradientCache
	end

	local Built = {}
	for i = 1, #Stops do
		local R, G, B = HexToRGB(Stops[i])
		if ( R ) then Built[#Built + 1] = { ToLinear(R), ToLinear(G), ToLinear(B) }; end
	end
	if ( #Built < 2 ) then return nil; end

	GradientCache, GradientCacheStops, GradientCacheCount = Built, Stops, #Stops
	return Built
end

local function GradientRGB(Score)
	local Stops = BuildGradient()
	if not ( Stops ) then return nil; end

	local Low  = ( GS_Settings and GS_Settings.GradientMin ) or 3000
	local High = ( GS_Settings and GS_Settings.GradientMax ) or 6500
	if ( High <= Low ) then return nil; end

	local Step = ( GS_Settings and GS_Settings.GradientStep ) or 200
	if ( Step < 1 ) then Step = 1; end
	if ( Step > (High - Low) / 2 ) then Step = (High - Low) / 2; end

	local Clamped = min(High, max(Low, Score))
	local Quantised = Low + floor((Clamped - Low) / Step) * Step
	if ( Quantised + Step > High ) then Quantised = High; end
	local T = min(1, max(0, (Quantised - Low) / (High - Low)))

	local Segments = #Stops - 1
	local Scaled = T * Segments
	local Seg = min(floor(Scaled), Segments - 1)
	local Local = Scaled - Seg
	local A, B = Stops[Seg + 1], Stops[Seg + 2]

	return min(1, max(0, ToSRGB(A[1] + (B[1] - A[1]) * Local))),
	       min(1, max(0, ToSRGB(A[2] + (B[2] - A[2]) * Local))),
	       min(1, max(0, ToSRGB(A[3] + (B[3] - A[3]) * Local)))
end

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
		if ( R ) then return R, B, G, ScoreDescription(ItemScore); end
	end
	if not ( ItemScore ) then return 0, 0, 0, "Trash"; end
	if ( ItemScore > 6999 ) then ItemScore = 6999; end
	if ( ItemScore < 1 ) then ItemScore = 1; end
	for i = 0, 6 do
		local Bucket = GS_Quality[( i + 1 ) * 1000]
		if ( Bucket ) and ( ItemScore > i * 1000 ) and ( ItemScore <= ( ( i + 1 ) * 1000 ) ) then
			local ChannelRed   = Bucket.Red["A"]   + (((ItemScore - Bucket.Red["B"])   * Bucket.Red["C"])   * Bucket.Red["D"])
			local ChannelGreen = Bucket.Green["A"] + (((ItemScore - Bucket.Green["B"]) * Bucket.Green["C"]) * Bucket.Green["D"])
			local ChannelBlue  = Bucket.Blue["A"]  + (((ItemScore - Bucket.Blue["B"])  * Bucket.Blue["C"])  * Bucket.Blue["D"])
			ChannelRed   = min(1, max(0, ChannelRed))
			ChannelGreen = min(1, max(0, ChannelGreen))
			ChannelBlue  = min(1, max(0, ChannelBlue))
			return ChannelRed, ChannelBlue, ChannelGreen, Bucket.Description
		end
	end
	return 0.1, 0.1, 0.1, "Legendary"
end

local function QualityRGB(Score)
	local Red, Blue, Green, Description = GearScore_GetQuality(Score)
	return Red, Green, Blue, Description
end

function GearScore_GetItemScore(ItemLink)
	if not ( ItemLink ) then return 0, 0; end
	local QualityScale = 1
	local _, _, ItemRarity, ItemLevel, _, _, _, _, ItemEquipLoc = GetItemInfo(ItemLink)
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
			local Red, Green, Blue = GearScore_GetQuality((floor(((ItemLevel - Table[ItemRarity].A) / Table[ItemRarity].B) * Scale)) * 12.25)
			local GearScore = floor(((ItemLevel - Table[ItemRarity].A) / Table[ItemRarity].B) * Slot.SlotMOD * Scale * QualityScale)
			if ( ItemLevel == 187.05 ) then ItemLevel = 0; end
			if ( GearScore < 0 ) then GearScore = 0; Red, Green, Blue = GearScore_GetQuality(1); end
			return GearScore, ItemLevel, Slot.ItemSlot, Red, Green, Blue, 0, ItemEquipLoc
		end
	end
	if ( ItemLevel == 187.05 ) then ItemLevel = 0; end
	return -1, ItemLevel or 0, 50, 1, 1, 1, 0, ItemEquipLoc
end

local MOG_RATIO = 0.6
local MOG_FLOOR = 40

local function MedianOf(Values)
	local Count = #Values
	if ( Count == 0 ) then return nil; end
	sort(Values)
	if ( Count % 2 == 1 ) then return Values[(Count + 1) / 2]; end
	return ( Values[Count / 2] + Values[Count / 2 + 1] ) / 2
end

local function ItemReady(Cache, ItemLink)
	local Known = Cache[ItemLink]
	if ( Known == nil ) then
		local _, _, Rarity, Level = GetItemInfo(ItemLink)
		Known = ( Rarity and Level ) and { Rarity, Level } or false
		Cache[ItemLink] = Known
	end
	if not ( Known ) then return nil; end
	return Known[1], Known[2]
end

-- The visible-item fields the client fills for anybody in view carry the
-- permanent enchant but never gems; only a real inspect reply does. A link with
-- a gem therefore proves the slot came from the inspect, not the transmog.
local function HasGems(ItemLink)
	local G1, G2, G3, G4 = ItemLink:match("item:%-?%d+:%-?%d+:(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+)")
	return ( G1 ~= nil ) and ( ( G1 ~= "0" ) or ( G2 ~= "0" ) or ( G3 ~= "0" ) or ( G4 ~= "0" ) )
end

function GearScore_GetScore(Name, Target)
	if ( Target == nil ) then Target = Name; end
	if not ( Target ) or not ( UnitIsPlayer(Target) ) then return nil; end

	local Ready = {}
	local _, PlayerEnglishClass = UnitClass(Target)
	local GearScore, ItemCount, LevelTotal, TitanGrip = 0, 0, 0, 1
	local Complete = true
	local CanBeMogged = not UnitIsUnit(Target, "player")
	local Levels = {}

	local MainLink = GetInventoryItemLink(Target, 16)
	local OffLink = GetInventoryItemLink(Target, 17)
	if ( MainLink ) and ( OffLink ) then
		if ( select(9, GetItemInfo(MainLink)) == "INVTYPE_2HWEAPON" ) then TitanGrip = 0.5; end
		if ( select(9, GetItemInfo(OffLink)) == "INVTYPE_2HWEAPON" ) then TitanGrip = 0.5; end
	end

	local Breakdown = ( GS_Settings and GS_Settings.Debug ) and {} or nil

	local Occupied, Gemmed = 0, 0
	for i = 1, 18 do
		if ( i ~= 4 ) then
			local ItemLink = GetInventoryItemLink(Target, i)
			if ( ItemLink ) then
				Occupied = Occupied + 1
				if ( HasGems(ItemLink) ) then Gemmed = Gemmed + 1; end
				local ReadyRarity, ReadyLevel = ItemReady(Ready, ItemLink)
				if ( ReadyRarity ) and ( ReadyLevel ) then
					local TempScore, ItemLevel = GearScore_GetItemScore(ItemLink)
					if ( TempScore < 0 ) then
						Log("slot %d not scorable, skipped: %s", i, tostring(ItemLink))
					else
					if ( i == 16 ) or ( i == 17 ) then
						TempScore = TempScore * TitanGrip
						if ( PlayerEnglishClass == "HUNTER" ) then TempScore = TempScore * 0.3164; end
					end
					if ( i == 18 ) and ( PlayerEnglishClass == "HUNTER" ) then TempScore = TempScore * 5.3224; end
					GearScore = GearScore + TempScore
					ItemCount = ItemCount + 1
					LevelTotal = LevelTotal + ( ItemLevel or 0 )
					if ( Breakdown ) then
						Breakdown[#Breakdown + 1] = { slot = i, link = ItemLink,
						                              ilvl = ItemLevel or 0, score = floor(TempScore) }
					end
					if ( CanBeMogged ) and ( ItemLevel ) and ( ItemLevel > 0 )
					   and ( i ~= 16 ) and ( i ~= 17 ) and ( i ~= 18 ) then
						Levels[#Levels + 1] = ItemLevel
					end
					end
				else
					Complete = false
				end
			end
		end
	end

	if ( Occupied == 0 ) and not ( UnitIsUnit(Target, "player") ) then Complete = false; end

	if ( GearScore < 0 ) then GearScore = 0; end
	local Average = 0
	if ( ItemCount > 0 ) then Average = floor((LevelTotal / ItemCount) + 0.5); end

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

	return floor(GearScore), Average, Complete, Suspect, ItemCount, Occupied, Breakdown, Gemmed
end

-- Case folding for player names, done byte by byte on UTF-8. strlower is not
-- used: it goes through the C locale's tolower, which folds only ASCII at best
-- and corrupts UTF-8 lead bytes under a non-C locale. Folded here: A-Z, the
-- Cyrillic capitals U+0400-U+042F (lead byte 0xD0) and U+0490 Ґ, and the
-- Latin-1 capitals U+00C0-U+00DE except the multiplication sign.
local function FoldAscii(Char)
	return string.char(Char:byte() + 32)
end

local function FoldCyrillic(Byte)
	local B = Byte:byte()
	if ( B <= 0x8F ) then return "\209" .. string.char(B + 0x10); end
	if ( B <= 0x9F ) then return "\208" .. string.char(B + 0x20); end
	if ( B <= 0xAF ) then return "\209" .. string.char(B - 0x20); end
	return nil
end

local function FoldLatin(Byte)
	local B = Byte:byte()
	if ( B >= 0x80 ) and ( B <= 0x9E ) and ( B ~= 0x97 ) then return "\195" .. string.char(B + 0x20); end
	return nil
end

local function FoldCase(Text)
	Text = Text:gsub("[A-Z]", FoldAscii)
	Text = Text:gsub("\208([\128-\175])", FoldCyrillic)
	Text = Text:gsub("\210\144", "\210\145")
	Text = Text:gsub("\195([\128-\158])", FoldLatin)
	return Text
end

local function MatchName(Unit, Name, Loose)
	if not ( UnitExists(Unit) ) then return nil; end
	local Actual = UnitName(Unit)
	if not ( Actual ) then return nil; end
	if ( Actual == Name ) or ( ( Loose ) and ( FoldCase(Actual) == FoldCase(Name) ) ) then return Actual; end
	return nil
end

local function GroupUnit(Name, Loose)
	local Raid = GetNumRaidMembers and GetNumRaidMembers() or 40
	for i = 1, Raid do
		local Actual = MatchName("raid" .. i, Name, Loose)
		if ( Actual ) then return "raid" .. i, Actual; end
	end
	local Party = GetNumPartyMembers and GetNumPartyMembers() or 4
	for i = 1, Party do
		local Actual = MatchName("party" .. i, Name, Loose)
		if ( Actual ) then return "party" .. i, Actual; end
	end
	return nil, nil
end

local LooseUnits = { "target", "focus", "mouseover" }

local function FindUnit(Name, Loose)
	if not ( Name ) or ( Name == "" ) then return nil, nil; end
	local Unit, Actual = GroupUnit(Name, Loose)
	if ( Unit ) then return Unit, Actual; end
	for i = 1, #LooseUnits do
		Actual = MatchName(LooseUnits[i], Name, Loose)
		if ( Actual ) then return LooseUnits[i], Actual; end
	end
	return nil, nil
end

local RescanFrame = CreateFrame("Frame", nil, UIParent)
RescanFrame:Hide()

local SCAN_TRIES = 24
local SCAN_DEADLINE = 30
local SCAN_CONFIRM = 6
local SCAN_SETTLE = 6
local SCAN_CONFIRM_BUSY = 2
local SCAN_SETTLE_REAL = 1

local function InspectInUse()
	if ( InspectFrame ) and ( InspectFrame:IsShown() ) then return true; end
	if ( Examiner ) and ( Examiner.IsShown ) and ( Examiner:IsShown() ) then return true; end
	return false
end

local function InspectingUnit(Unit)
	if not ( Unit ) then return false; end
	if ( InspectFrame ) and ( InspectFrame:IsShown() ) and ( InspectFrame.unit )
	   and ( UnitIsUnit(InspectFrame.unit, Unit) ) then return true; end
	if ( Examiner ) and ( Examiner.IsShown ) and ( Examiner:IsShown() ) and ( Examiner.unit )
	   and ( UnitIsUnit(Examiner.unit, Unit) ) then return true; end
	return false
end

local function Announce(Name, Score, Average)
	if ( WeakAuras ) and ( WeakAuras.ScanEvents ) then
		pcall(WeakAuras.ScanEvents, "GEARSCORELITE_UPDATE", Name, Score, Average)
	end
	for i = 1, #GSL.listeners do
		pcall(GSL.listeners[i], Name, Score, Average)
	end
end

local function RefreshTooltip(Name)
	if ( GSL.refreshing ) or ( GSL.inTooltipHook ) or not ( GameTooltip:IsShown() ) then return; end
	local Shown, Unit = GameTooltip:GetUnit()
	if ( Shown ~= Name ) or not ( Unit ) then return; end
	GSL.refreshing = true
	pcall(GameTooltip.SetUnit, GameTooltip, Unit)
	GSL.refreshing = false
end

local function Obstacle(Unit)
	if not ( Unit ) or not ( UnitExists(Unit) ) then return "gone"; end
	if not ( UnitIsPlayer(Unit) ) then return "npc"; end
	if ( UnitIsUnit(Unit, "player") ) then return nil; end
	if ( UnitIsConnected ) and not ( UnitIsConnected(Unit) ) then return "offline"; end

	if ( InspectInUse() ) and not ( InspectingUnit(Unit) ) then return "inspectbusy"; end
	if not ( CanInspect(Unit) ) then return "cannotinspect"; end
	if ( CheckInteractDistance ) and not ( CheckInteractDistance(Unit, 1) ) then return "range"; end
	return nil
end

local ObstacleText = {
	["gone"]          = "unit no longer exists",
	["npc"]           = "not a player",
	["offline"]       = "player is offline",
	["inspectbusy"]   = "inspect window is open, slot in use",
	["cannotinspect"] = "cannot inspect yet (range, line of sight or faction)",
	["range"]         = "out of inspect range (~28 yards)",
}

local STORE_MAX = 300
local STORE_MAX_AGE = 14 * 24 * 60 * 60

local function Remember(Name, Entry)
	if ( type(GS_Cache) ~= "table" ) or not ( Name ) or not ( Entry ) then return; end
	if not ( Entry.complete ) or ( Entry.suspect ) or ( Entry.unanswered )
	   or ( Entry.score <= 0 ) then return; end
	local Saved = GS_Cache[Name]
	if not ( Entry.real ) and ( type(Saved) == "table" ) and ( Saved.real ) then return; end
	GS_Cache[Name] = { score = Entry.score, ilvl = Entry.ilvl, time = time(), real = Entry.real or nil }
end

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

local function DisplayEntry(Name)
	local Entry = GSL.cache[Name]
	if ( Entry ) and ( Entry.unanswered ) then
		local Saved = ( type(GS_Cache) == "table" ) and GS_Cache[Name] or nil
		if ( Saved ) and ( Saved.score > Entry.score ) then
			return { score = Saved.score, ilvl = Saved.ilvl, complete = true, suspect = false,
			         remembered = Saved.time, time = GetTime() }
		end
		return Entry
	end
	local Saved = ( type(GS_Cache) == "table" ) and GS_Cache[Name] or nil
	if not ( Saved ) then return Entry; end
	if ( Entry ) and ( Entry.complete ) and not ( Entry.suspect ) then return Entry; end
	if ( Entry ) and ( Entry.score >= Saved.score ) then return Entry; end
	if ( Entry ) and ( Entry.settled ) then return Entry; end
	return { score = Saved.score, ilvl = Saved.ilvl, complete = true, suspect = false,
	         remembered = Saved.time, time = GetTime() }
end

local function ItemsText(Breakdown)
	local Parts = {}
	for i = 1, #Breakdown do
		local Slot = Breakdown[i]
		local Item = tostring(Slot.link):match("|H(item:[%-%d:]+)|h") or tostring(Slot.link)
		Parts[#Parts + 1] = format("%d=%s@%d/%d", Slot.slot, Item, Slot.ilvl, Slot.score)
	end
	return table.concat(Parts, " ")
end

local function ScanUnit(Name, Unit)
	local Blocked = Obstacle(Unit)
	if ( Blocked ) then
		Log("scan %s blocked: %s", tostring(Name), ObstacleText[Blocked] or Blocked)
		if ( Blocked == "npc" ) or ( Blocked == "gone" ) then
			GSL.blocked[Name] = Blocked
			return true
		end
		GSL.blocked[Name] = Blocked
		return false
	end
	GSL.blocked[Name] = nil

	if not ( UnitIsUnit(Unit, "player") ) and ( CanInspect(Unit) ) and not ( InspectInUse() ) then
		local Now = GetTime()
		if ( GSL.lastInspectName ~= Name ) or ( ( Now - GSL.lastInspectTime ) > 1.5 ) then
			GSL.lastInspectName = Name
			GSL.lastInspectTime = Now
			GSL.inspectTarget = Name
			NotifyInspect(Unit)
			Log("NotifyInspect(%s) for %s", tostring(Unit), tostring(Name))
		end
	end

	local Score, Average, Complete, Suspect, Read, Total, Breakdown, Gemmed = GearScore_GetScore(Name, Unit)
	if not ( Score ) then return true; end

	-- Gems only ever arrive with this player's own inspect data, so a gemmed
	-- reading needs no reply attribution and is not a transmog guess.
	local Real = ( ( Gemmed or 0 ) > 0 ) and not ( UnitIsUnit(Unit, "player") )
	if ( Real ) then Suspect = false; end

	local Unanswered = false
	if ( Complete ) and not ( Real ) and not ( UnitIsUnit(Unit, "player") ) and ( GSL.answeredFor ~= Name ) then
		Complete = false
		Unanswered = true
		Suspect = true
	end

	Log("scan %s: score=%d ilvl=%d slots=%d/%d %s, gems in %d", tostring(Name), Score, Average,
	    Read or 0, Total or 0, Complete and "complete" or ( Unanswered and "unanswered" or "partial" ),
	    Gemmed or 0)
	if ( Breakdown ) then
		local Items = ItemsText(Breakdown)
		if ( GSL.lastItemsName ~= Name ) or ( GSL.lastItems ~= Items ) then
			GSL.lastItemsName, GSL.lastItems = Name, Items
			Log("scan %s items: %s", tostring(Name), Items)
		end
	end

	if ( Name == GSL.scanName ) and ( Read ) and ( Read > ( GSL.scanRead or 0 ) ) then
		GSL.scanRead = Read
		if ( GSL.scanDeadline ) and ( GetTime() < GSL.scanDeadline ) and ( GSL.scanTries < SCAN_TRIES ) then
			GSL.scanTries = SCAN_TRIES
		end
	end

	local Previous = GSL.cache[Name]

	local Settle = Complete
	if ( Complete ) and not ( Suspect ) and not ( UnitIsUnit(Unit, "player") ) then
		local Left = GSL.scanSettle or SCAN_SETTLE
		if ( Real ) and ( Left > SCAN_SETTLE_REAL ) then Left = SCAN_SETTLE_REAL; end
		if ( Left > 0 ) then
			GSL.scanSettle = Left - 1
			Settle = false
		end
	end

	if ( Complete ) and ( Total ) and ( Total > ( GSL.scanOccupied or 0 ) )
	   and not ( UnitIsUnit(Unit, "player") ) then
		GSL.scanSettle = Real and SCAN_SETTLE_REAL or SCAN_SETTLE
		if ( GSL.scanOccupied or 0 ) > 0 then
			Log("scan %s: slot count rose to %d, waiting for the rest",
			    tostring(Name), Total)
		else
			Log("scan %s: first reading (%d slots), confirming before settling",
			    tostring(Name), Total)
		end
		Settle = false
	end
	if ( Total ) and ( GSL.scanOccupied ) and ( GSL.scanOccupied > 0 )
	   and ( Total ~= GSL.scanOccupied ) then
		GSL.scanGrew = true
	end
	if ( Total ) and ( Total > ( GSL.scanOccupied or 0 ) ) then
		GSL.scanOccupied = Total
	end
	if ( Complete ) and ( Suspect ) and not ( UnitIsUnit(Unit, "player") ) then
		local Budget = ( #GSL.queue > 0 ) and SCAN_CONFIRM_BUSY or SCAN_CONFIRM
		local Left = GSL.scanConfirm or SCAN_CONFIRM
		if ( Left > Budget ) then Left = Budget; end
		if ( Left > 0 ) then
			GSL.scanConfirm = Left - 1
			Settle = false
		end
	end

	if ( Score == 0 ) and ( Previous ) and ( Previous.score > 0 ) then
		return false
	end

	if ( Previous ) and ( Previous.real ) and not ( Real ) then
		Log("scan %s: ignored a reading without gems (%d), the one held has them (%d)",
		    tostring(Name), Score, Previous.score)
		return Settle
	end

	local Improves = ( Previous ) and ( Complete ) and not ( Suspect )
	                 and ( not ( Previous.complete ) or ( Previous.suspect ) )
	if ( Real ) and ( Previous ) and not ( Previous.real ) then
		Improves = true
	end
	if ( Previous ) and ( Average ) and ( Previous.ilvl )
	   and ( Average > Previous.ilvl + 20 ) then
		Improves = true
	end
	if ( Previous ) and ( Complete ) and ( Average ) and ( Previous.ilvl )
	   and ( Average > Previous.ilvl ) then
		Improves = true
	end
	if ( Previous ) and ( Previous.score > Score ) and not ( Improves ) then
		Log("scan %s: ignored a lower reading (%d < %d), inspect data went stale",
		    tostring(Name), Score, Previous.score)
		return Settle
	end

	GSL.cache[Name] = { score = Score, ilvl = Average, complete = Complete, suspect = Suspect,
	                    unanswered = Unanswered, partialSet = GSL.scanGrew or nil,
	                    read = Read, occupied = Total, time = GetTime(), real = Real or nil }
	if ( Complete ) and not ( Suspect ) then
		GSL.unsure[Name] = nil
		-- A gemless reading may still be the transmog; it is remembered only
		-- once its scan settles (see DoRescan), your own gear excepted.
		if ( Real ) or ( UnitIsUnit(Unit, "player") ) then Remember(Name, GSL.cache[Name]); end
	end
	if not ( Previous ) or ( Previous.score ~= Score ) then
		Announce(Name, Score, Average)
		RefreshTooltip(Name)
	end
	return Settle
end

local QUEUE_MAX = 40

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
	GSL.scanSettle = SCAN_SETTLE
	GSL.scanOccupied = 0
	GSL.scanGrew = false
	GSL.scanBlockedTicks = 0
end

local PARK_TTL = 120

-- Obstacles that clear up by themselves later (walking into range, coming
-- online); a scan held up by one gives the slot to whoever is waiting.
local Unreachable = { ["range"] = true, ["cannotinspect"] = true, ["offline"] = true }
local BLOCKED_YIELD = 2
local YIELD_MAX = 3

local function Park(Name)
	GSL.parked[Name] = { confirm = GSL.scanConfirm, settle = GSL.scanSettle, occupied = GSL.scanOccupied,
	                     grew = GSL.scanGrew, read = GSL.scanRead, time = GetTime() }
	local Entry = GSL.cache[Name]
	if ( Entry ) then Entry.interrupted = true; end
end

local function BeginScan(Name, Unit)
	GSL.scanName = Name
	GSL.scanUnit = Unit
	GSL.scanTries = SCAN_TRIES
	GSL.scanRead = 0
	GSL.scanDeadline = GetTime() + SCAN_DEADLINE
	GSL.scanConfirm = SCAN_CONFIRM
	GSL.scanSettle = SCAN_SETTLE
	GSL.scanOccupied = 0
	GSL.scanGrew = false
	GSL.scanBlockedTicks = 0

	local Parked = GSL.parked[Name]
	GSL.parked[Name] = nil
	if ( Parked ) and ( ( GetTime() - Parked.time ) < PARK_TTL ) then
		GSL.scanConfirm = Parked.confirm
		GSL.scanSettle = Parked.settle
		GSL.scanOccupied = Parked.occupied
		GSL.scanGrew = Parked.grew
		GSL.scanRead = Parked.read
		Log("scan %s resumed after a pause (%d slots seen before)", tostring(Name), Parked.occupied or 0)
	end
	RescanFrame:Show()
end

local function NextInQueue()
	local Budget = #GSL.queue
	while ( #GSL.queue > 0 ) do
		local Name = table.remove(GSL.queue, 1)
		local Unit = GSL.queued[Name]
		GSL.queued[Name] = nil
		Budget = Budget - 1
		if not ( Unit ) or not ( MatchName(Unit, Name) ) then Unit = FindUnit(Name); end
		if not ( Unit ) then
			Log("queue: dropped stale entry %s", tostring(Name))
		elseif ( Budget > 0 ) and ( Unreachable[Obstacle(Unit) or ""] ) then
			-- Out of reach right now; somebody later in the line may not be.
			GSL.queue[#GSL.queue + 1] = Name
			GSL.queued[Name] = Unit
			Log("queue: %s is out of reach, trying the next one", tostring(Name))
		else
			BeginScan(Name, Unit)
			Log("queue -> scanning %s (%d still waiting)", tostring(Name), #GSL.queue)
			return true
		end
	end
	return false
end

local function Yield(Name, Unit, Reason)
	local Count = ( GSL.yields[Name] or 0 ) + 1
	Park(Name)
	CancelRescan()
	if ( Count <= YIELD_MAX ) then
		GSL.yields[Name] = Count
		GSL.queue[#GSL.queue + 1] = Name
		GSL.queued[Name] = Unit
		Log("scan %s yields the slot: %s, back of the queue (%d waiting)", tostring(Name),
		    ObstacleText[Reason] or Reason, #GSL.queue)
	else
		GSL.yields[Name] = nil
		Log("scan %s dropped: still %s after %d turns, resumes on the next hover", tostring(Name),
		    ObstacleText[Reason] or Reason, YIELD_MAX)
	end
	NextInQueue()
end

local function DoRescan()
	local Name, Unit = GSL.scanName, GSL.scanUnit
	if not ( Name ) or not ( Unit ) then CancelRescan(); NextInQueue(); return; end
	if not ( MatchName(Unit, Name) ) then
		local Moved = FindUnit(Name)
		if not ( Moved ) then
			Log("scan %s paused: no unit token points at them, resumes on the next hover", tostring(Name))
			Park(Name)
			CancelRescan(); NextInQueue(); return
		end
		Log("scan %s: %s no longer points at them, following %s", tostring(Name), tostring(Unit), Moved)
		Unit = Moved
		GSL.scanUnit = Moved
	end
	GSL.scanTries = GSL.scanTries - 1
	local Finished = ScanUnit(Name, Unit)
	local Reason = GSL.blocked[Name]
	if not ( Finished ) and ( Unreachable[Reason or ""] ) then
		GSL.scanBlockedTicks = ( GSL.scanBlockedTicks or 0 ) + 1
		if ( GSL.scanBlockedTicks >= BLOCKED_YIELD ) and ( #GSL.queue > 0 ) then
			Yield(Name, Unit, Reason)
			return
		end
	else
		GSL.scanBlockedTicks = 0
	end
	if ( Finished ) then
		GSL.yields[Name] = nil
		local Entry = GSL.cache[Name]
		if ( Entry ) then
			Entry.interrupted = nil
			Log("scan %s done: score=%d ilvl=%d%s%s", tostring(Name), Entry.score, Entry.ilvl,
			    Entry.real and ", gems seen" or ", no gems seen", Entry.suspect and " (suspect)" or "")
			Remember(Name, Entry)
		end
		CancelRescan()
		RefreshTooltip(Name)
		NextInQueue()
	elseif ( GSL.scanTries <= 0 ) then
		Log("scan %s gave up: %d slots read, budget exhausted", tostring(Name), GSL.scanRead or 0)
		GSL.yields[Name] = nil
		local Entry = GSL.cache[Name]
		if ( Entry ) and ( Entry.unanswered ) then
			Log("scan %s: discarding an unanswered reading (%d) rather than settling it",
			    tostring(Name), Entry.score)
			GSL.cache[Name] = nil
		elseif ( Entry ) then
			Entry.settled = true
			Entry.interrupted = nil
			Remember(Name, Entry)
		end
		CancelRescan()
		NextInQueue()
	end
end

local function UpdatePlayer()
	local Score, Average, Complete = GearScore_GetScore("player")
	if ( Score ) then
		local Changed = ( Score ~= GSL.player.score ) or ( Average ~= GSL.player.ilvl )
		local Name = UnitName("player")
		GSL.player.score = Score
		GSL.player.ilvl = Average
		GSL.cache[Name] = { score = Score, ilvl = Average, complete = Complete, suspect = false, time = GetTime() }
		if ( Changed ) and ( Name ) then
			Trace("own score: %d, ilvl %d, %s", Score, Average, Complete and "complete" or "items still loading")
			Announce(Name, Score, Average)
		end
	end
	return Complete
end

local UpdatePaperDoll

local CACHE_TTL = 600

local FRESH_LABEL = 10

local CACHE_TTL_UNSURE = 20
local UNSURE_RETRIES = 3

local function IsFresh(Name)
	local Entry = GSL.cache[Name]
	if not ( Entry ) or ( Entry.score <= 0 ) then return false; end
	if ( Entry.interrupted ) then return false; end
	if not ( Entry.complete ) and not ( Entry.settled ) then return false; end
	if not ( Entry.complete ) then
		return ( GetTime() - Entry.time ) < CACHE_TTL_UNSURE
	end
	if ( Entry.partialSet ) then
		return ( GetTime() - Entry.time ) < CACHE_TTL_UNSURE
	end
	local Unsure = ( Entry.suspect )
	                and ( ( GSL.unsure[Name] or 0 ) < UNSURE_RETRIES )
	return ( GetTime() - Entry.time ) < ( Unsure and CACHE_TTL_UNSURE or CACHE_TTL )
end

local function StableUnit(Name, Unit)
	if not ( Unit ) then return Unit; end
	if ( Unit ~= "target" ) and ( Unit ~= "mouseover" ) and ( Unit ~= "focus" ) then return Unit; end
	local Group = GroupUnit(Name)
	if ( Group ) then return Group; end
	if ( Unit == "mouseover" ) and ( MatchName("target", Name) ) then return "target"; end
	return Unit
end

local SESSION_MAX_AGE = 3600
local PRUNE_EVERY = 300

local function Busy(Name)
	return ( Name == GSL.scanName ) or ( GSL.queued[Name] ~= nil )
end

local function PruneSession()
	local Now = GetTime()
	if ( Now - GSL.lastPrune ) < PRUNE_EVERY then return; end
	GSL.lastPrune = Now

	local Me, Dropped = UnitName("player"), 0
	for Name, Entry in pairs(GSL.cache) do
		if ( Name ~= Me ) and not ( Busy(Name) ) and ( ( Now - ( Entry.time or 0 ) ) > SESSION_MAX_AGE ) then
			GSL.cache[Name] = nil
			Dropped = Dropped + 1
		end
	end
	for _, Map in ipairs({ GSL.blocked, GSL.unsure, GSL.yields }) do
		for Name in pairs(Map) do
			if not ( GSL.cache[Name] ) and not ( Busy(Name) ) then Map[Name] = nil; end
		end
	end
	for Name, Parked in pairs(GSL.parked) do
		if ( ( Now - Parked.time ) >= PARK_TTL ) then GSL.parked[Name] = nil; end
	end
	if ( Dropped > 0 ) then Log("session cache: dropped %d readings older than an hour", Dropped); end
end

local function Track(Name, Unit, Force)
	PruneSession()
	if not ( Unit ) or not ( UnitExists(Unit) ) or not ( UnitIsPlayer(Unit) ) then return; end
	Name = Name or UnitName(Unit)
	if not ( Name ) then return; end
	if not ( Force ) and ( IsFresh(Name) ) then return; end
	Unit = StableUnit(Name, Unit)

	local Stale = GSL.cache[Name]
	if ( Stale ) and ( Stale.suspect or Stale.settled ) then
		GSL.unsure[Name] = ( GSL.unsure[Name] or 0 ) + 1
	end

	local Blocked = Obstacle(Unit)
	GSL.blocked[Name] = Blocked
	if ( Blocked == "npc" ) or ( Blocked == "gone" ) then
		Log("skip %s: %s", tostring(Name), ObstacleText[Blocked] or Blocked)
		Dequeue(Name)
		return
	end

	if ( GSL.scanName == Name ) then GSL.scanUnit = Unit; return; end
	if ( GSL.queued[Name] ) then GSL.queued[Name] = Unit; return; end

	if not ( GSL.scanName ) then
		if ( GSL.parked[Name] ) then
			-- Restore the paused counters first, so this reading counts towards them.
			BeginScan(Name, Unit)
			DoRescan()
		elseif not ( ScanUnit(Name, Unit) ) then
			BeginScan(Name, Unit)
		end
		return
	end

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
		NextInQueue()
	end

	if ( GSL.playerTries <= 0 ) and not ( GSL.scanName ) and ( #GSL.queue == 0 ) then self:Hide(); end
end)

local function QueuePlayerRescan()
	if not ( UpdatePlayer() ) then
		GSL.playerTries = 10
		RescanFrame:Show()
	end
	UpdatePaperDoll()
end

local function ResolveTooltipUnit()
	local Name, Unit = GameTooltip:GetUnit()
	if not ( Name ) then return nil, nil; end
	if ( Unit ) and ( UnitExists(Unit) ) then return Name, Unit; end
	if ( UnitExists("mouseover") ) and ( UnitName("mouseover") == Name ) then return Name, "mouseover"; end

	local Focus = GetMouseFocus()
	if ( Focus ) then
		local Candidate = Focus.unit or Focus.raidid
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

	if ( Unit ) and not ( GSL.refreshing ) then
		if ( not GS_Settings.MustTarget ) or ( UnitIsUnit("target", Unit) ) then
			GSL.inTooltipHook = true
			pcall(Track, Name, Unit)
			GSL.inTooltipHook = false
		end
	end

	local Entry = DisplayEntry(Name)
	if not ( Entry ) or ( Entry.score <= 0 ) then
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
		Score = Score .. " (memory)"
	elseif not ( Entry.complete ) or ( Entry.interrupted ) or ( GSL.scanName == Name ) then
		Score = Score .. " (scanning)"
	elseif ( Entry.time ) and ( ( GetTime() - Entry.time ) < FRESH_LABEL ) then
		Score = Score .. " (scanned)"
	end

	if ( GS_Settings.Level ) then
		GameTooltip:AddDoubleLine("GearScore: " .. Score, "(iLevel: " .. Entry.ilvl .. ")", Red, Green, Blue, Red, Green, Blue)
	else
		GameTooltip:AddLine("GearScore: " .. Score, Red, Green, Blue)
	end

	if ( Entry.remembered ) then
		local Age = time() - Entry.remembered
		local Ago
		if ( Age < 60 ) then Ago = "moments ago"
		elseif ( Age < 3600 ) then Ago = floor(Age / 60) .. "m ago"
		elseif ( Age < 86400 ) then Ago = floor(Age / 3600) .. "h ago"
		else Ago = floor(Age / 86400) .. "d ago"
		end
		GameTooltip:AddLine("(remembered, " .. Ago .. " -- rescanning)", 0.6, 0.6, 0.6)
	end

end

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

	if ( ItemScore < 0 ) or not ( GS_Settings.Item ) then
		if ( GS_Settings.Level ) and ( ItemLevel ) and ( ItemLevel > 0 ) then
			Tooltip:AddLine("iLevel " .. ItemLevel)
		end
		return
	end

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
	if ( self.SetUserPlaced ) then self:SetUserPlaced(false); end
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

local function ResolveByName(Query)
	if ( Query ) and ( Query ~= "" ) then
		local Unit, Actual = FindUnit(Query, true)
		if ( Unit ) then return Actual, Unit; end
		return Query, nil
	end
	if ( UnitExists("target") ) then return UnitName("target"), "target"; end
	if ( UnitExists("mouseover") ) then return UnitName("mouseover"), "mouseover"; end
	return nil, nil
end

local function DebugSession(Reason, FlushRing)
	local Version = GetAddOnMetadata and GetAddOnMetadata("GearScoreLite", "Version") or "?"
	DebugWrite("")
	DebugWrite(format("==== GearScoreLite %s, %s, %s ====", tostring(Version), date("%Y-%m-%d %H:%M:%S"), Reason))
	if ( GetBuildInfo ) then
		local ClientVersion, Build = GetBuildInfo()
		DebugWrite(format("client %s (%s), locale %s, realm %s", tostring(ClientVersion), tostring(Build),
			tostring(GetLocale and GetLocale()), tostring(GetRealmName and GetRealmName())))
	end
	local _, Class = UnitClass("player")
	DebugWrite(format("player %s, %s, level %s, score %d, ilvl %d", tostring(UnitName("player")),
		tostring(Class), tostring(UnitLevel and UnitLevel("player")), GSL.player.score, GSL.player.ilvl))

	local Keys, Parts = {}, {}
	for Key in pairs(GS_Settings) do Keys[#Keys + 1] = Key; end
	sort(Keys)
	for i = 1, #Keys do Parts[#Parts + 1] = Keys[i] .. "=" .. tostring(GS_Settings[Keys[i]]); end
	DebugWrite("settings: " .. table.concat(Parts, " "))

	if ( GetNumAddOns ) and ( GetAddOnInfo ) and ( IsAddOnLoaded ) then
		local Loaded = {}
		for i = 1, GetNumAddOns() do
			local AddOn = GetAddOnInfo(i)
			if ( AddOn ) and ( IsAddOnLoaded(AddOn) ) then Loaded[#Loaded + 1] = AddOn; end
		end
		DebugWrite(format("addons loaded (%d): %s", #Loaded, table.concat(Loaded, ", ")))
	end

	if ( FlushRing ) then
		local Lines = LogLines()
		if ( #Lines > 0 ) then
			DebugWrite(format("-- %d lines logged before debug was switched on --", #Lines))
			for i = 1, #Lines do DebugWrite(Lines[i]); end
			DebugWrite("-- live from here --")
		end
	end
end

local function DebugSnapshot(Reason)
	local Names, Parked = {}, 0
	for Name in pairs(GSL.cache) do Names[#Names + 1] = Name; end
	for _ in pairs(GSL.parked) do Parked = Parked + 1; end
	sort(Names)
	DebugWrite(format("-- session cache at %s: %d players, scanning %s, queued %d, paused %d --",
		Reason, #Names, tostring(GSL.scanName), #GSL.queue, Parked))
	local Now = GetTime()
	for i = 1, min(#Names, 300) do
		local Entry = GSL.cache[Names[i]]
		local Flags = {}
		for _, Flag in ipairs({ "complete", "real", "suspect", "unanswered", "settled", "interrupted", "partialSet" }) do
			if ( Entry[Flag] ) then Flags[#Flags + 1] = Flag; end
		end
		DebugWrite(format("  %s score=%d ilvl=%d slots=%s/%s age=%ds %s", Names[i], Entry.score, Entry.ilvl,
			tostring(Entry.read or "-"), tostring(Entry.occupied or "-"), floor(Now - ( Entry.time or Now )),
			table.concat(Flags, ",")))
	end
end

local function Toggle(Key, Label)
	GS_Settings[Key] = not GS_Settings[Key]
	print("GearScore -- " .. Label .. ": " .. ( GS_Settings[Key] and "On" or "Off" ))
end

function GS_MANSET(Command)
	local Raw = strtrim(Command or "")
	Command = strlower(Raw)
	local Verb, Args = Command:match("^(%S+)%s*(.*)$")
	Verb, Args = Verb or Command, Args or ""
	local RawArgs = Raw:match("^%S+%s+(.*)$") or ""

	if ( Command == "player" ) or ( Command == "show" ) then Toggle("Player", "Player Scores")
	elseif ( Command == "item" ) then Toggle("Item", "Item Scores")
	elseif ( Command == "level" ) then Toggle("Level", "Item Levels")
	elseif ( Command == "target" ) then Toggle("MustTarget", "Must Target")
	elseif ( Command == "combat" ) then Toggle("HideInCombat", "Hide In Combat")
	elseif ( Command == "status" ) then Toggle("Status", "Missing Score Reason")
	elseif ( Command == "debug clear" ) then
		GS_DebugLog = { lines = {} }
		if ( GS_Settings.Debug ) then DebugSession("log cleared", false); end
		print("GearScore -- debug log cleared.")
	elseif ( Command == "debug" ) then
		if ( GS_Settings.Debug ) then
			DebugSnapshot("debug switched off")
			DebugWrite(format("==== debug switched off, %s ====", date("%Y-%m-%d %H:%M:%S")))
			GS_Settings.Debug = false
			print("GearScore -- debug logging: Off.")
		else
			GS_Settings.Debug = true
			DebugSession("switched on", true)
			print("GearScore -- debug logging: On. The log is saved to WTF\\Account\\<account>\\SavedVariables\\GearScoreLite.lua")
			print("  on /reload or logout. Reproduce the problem, then /reload and send that file.")
		end
	elseif ( Verb == "rescan" ) then
		local Who, Token = ResolveByName(strtrim(RawArgs))
		if ( Token ) then
			GSL.cache[Who] = nil
			GSL.parked[Who] = nil
			Track(Who, Token, true)
			print("GearScore -- re-reading " .. tostring(Who) .. ", check again in a moment.")
		else
			print("GearScore -- /gs rescan <name>, or target somebody first.")
		end
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

local EventFrame = CreateFrame("Frame", "GearScore", UIParent)

EventFrame:SetScript("OnEvent", function(self, event, arg1)
	if ( event == "PLAYER_REGEN_ENABLED" ) then
		GSL.inCombat = false

	elseif ( event == "PLAYER_REGEN_DISABLED" ) then
		GSL.inCombat = true

	elseif ( event == "PLAYER_EQUIPMENT_CHANGED" ) or ( event == "PLAYER_ENTERING_WORLD" ) then
		QueuePlayerRescan()

	elseif ( event == "INSPECT_TALENT_READY" ) or ( event == "INSPECT_READY" ) then
		if ( GSL.inspectTarget ) then
			GSL.answeredFor = GSL.inspectTarget
			Log("inspect reply, attributed to %s", tostring(GSL.inspectTarget))
		end
		if ( GSL.scanName ) then DoRescan(); end

	elseif ( event == "UNIT_INVENTORY_CHANGED" ) then
		if ( arg1 ~= "player" ) then
			Trace("UNIT_INVENTORY_CHANGED %s (%s)%s", tostring(arg1), tostring(arg1 and UnitName(arg1)),
			      ( arg1 and GSL.scanName and UnitName(arg1) == GSL.scanName ) and ", under the scanner" or "")
		end
		if ( arg1 ) and ( arg1 ~= "player" ) and ( UnitName(arg1) )
		   and ( UnitName(arg1) == GSL.inspectTarget ) then
			GSL.answeredFor = UnitName(arg1)
		end
		if ( arg1 == "player" ) then
			QueuePlayerRescan()
		elseif ( GSL.scanName ) and ( arg1 ) and ( UnitName(arg1) == GSL.scanName ) then
			GSL.cache[GSL.scanName] = nil
			if ( type(GS_Cache) == "table" ) then GS_Cache[GSL.scanName] = nil; end
			DoRescan()
		elseif ( arg1 ) then
			local Who = UnitName(arg1)
			if ( Who ) then
				local Had = ( GSL.cache[Who] ~= nil )
				GSL.cache[Who] = nil
				GSL.unsure[Who] = nil
				GSL.blocked[Who] = nil
				GSL.parked[Who] = nil
				if ( type(GS_Cache) == "table" ) then GS_Cache[Who] = nil; end
				if ( Had ) then Log("cache invalidated for %s (inventory changed)", tostring(Who)); end
			end
		end

	elseif ( event == "PLAYER_TARGET_CHANGED" ) then
		Trace("target -> %s", tostring(UnitName("target")))
		if not ( GS_Settings ) or not ( GS_Settings.Player ) then return; end
		if ( GS_Settings.HideInCombat ) and ( GSL.inCombat ) then return; end
		if ( UnitExists("target") ) and ( UnitIsPlayer("target") ) then Track(UnitName("target"), "target"); end

	elseif ( event == "ADDON_LOADED" ) and ( arg1 == "GearScoreLite" ) then
		if ( type(GS_Settings) ~= "table" ) or ( GS_Settings.Version ~= GS_SettingsVersion ) then
			GS_Settings = {}
		end
		for Key, Value in pairs(GS_DefaultSettings) do
			if ( GS_Settings[Key] == nil ) then GS_Settings[Key] = Value; end
		end
		PruneStore()
		GSL.inCombat = UnitAffectingCombat("player") and true or false
		ApplyAnchor()
		UpdatePaperDoll()
		if ( GS_Settings.Debug ) then
			DebugSession("loaded", false)
			print("GearScore -- debug logging is on (/gs debug to stop).")
		end
		self:UnregisterEvent("ADDON_LOADED")

	elseif ( event == "PLAYER_LOGOUT" ) then
		if ( Debugging() ) then DebugSnapshot("logout or reload"); end
	end
end)

local function InspectCaller()
	if not ( debugstack ) then return "?"; end
	local Stack = debugstack(3, 12, 0) or ""
	for AddOn in Stack:gmatch("AddOns[\\/]([^\\/]+)[\\/]") do
		if ( AddOn ~= "GearScoreLite" ) then return AddOn; end
	end
	return "unknown"
end

if ( hooksecurefunc ) then
	hooksecurefunc("NotifyInspect", function(Unit)
		local Who = ( Unit ) and UnitName(Unit) or nil
		if ( Who ) then GSL.inspectTarget = Who; end
		if ( Debugging() ) then
			Log("NotifyInspect(%s) for %s by another addon: %s", tostring(Unit), tostring(Who), InspectCaller())
		end
	end)
end

EventFrame:RegisterEvent("ADDON_LOADED")
EventFrame:RegisterEvent("PLAYER_LOGOUT")
EventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
EventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
EventFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
EventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
EventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
EventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")

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

GearScoreLite = {
	GetScore = function(unit) return GearScore_GetScore(unit) end,

	GetCached = function(name)
		local Entry = name and DisplayEntry(name)
		if not ( Entry ) then return nil; end
		return Entry.score, Entry.ilvl, GetTime() - Entry.time, Entry.suspect, Entry.remembered
	end,

	Request = function(unit)
		if ( unit ) and ( UnitExists(unit) ) then Track(UnitName(unit), unit, true); end
	end,

	Forget = function(name)
		if not ( name ) then return; end
		GSL.cache[name] = nil
		GSL.unsure[name] = nil
		GSL.parked[name] = nil
		GSL.yields[name] = nil
	end,

	GetState = function(name)
		if not ( name ) then return nil; end
		if ( GSL.scanName == name ) then return "scanning"; end
		if ( GSL.queued[name] ) then return "queued"; end
		if ( GSL.parked[name] ) then return "paused"; end
		return nil
	end,

	GetPlayer = function() return GSL.player.score, GSL.player.ilvl end,

	RegisterCallback = function(callback)
		if ( type(callback) == "function" ) then tinsert(GSL.listeners, callback); end
	end,
}
