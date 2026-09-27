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
}

local LOG_MAX = 120

local function Log(Format, ...)
	local Ok, Text = pcall(format, Format, ...)
	if not ( Ok ) then Text = tostring(Format); end

	local Now = time()
	GSL.log[GSL.logNext] = Text
	GSL.logTime[GSL.logNext] = Now
	GSL.logNext = ( GSL.logNext % LOG_MAX ) + 1

	if ( GS_Settings ) and ( GS_Settings.Debug ) then
		print("|cff66ccffGS|r " .. date("%H:%M:%S", Now) .. "  " .. Text)
	end
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

	local Occupied = 0
	for i = 1, 18 do
		if ( i ~= 4 ) then
			local ItemLink = GetInventoryItemLink(Target, i)
			if ( ItemLink ) then
				Occupied = Occupied + 1
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

	return floor(GearScore), Average, Complete, Suspect, ItemCount, Occupied, Breakdown
end

local function MatchName(Unit, Name, Loose)
	if not ( UnitExists(Unit) ) then return nil; end
	local Actual = UnitName(Unit)
	if not ( Actual ) then return nil; end
	if ( Actual == Name ) or ( ( Loose ) and ( strlower(Actual) == strlower(Name) ) ) then return Actual; end
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
	GS_Cache[Name] = { score = Entry.score, ilvl = Entry.ilvl, time = time() }
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

	local Score, Average, Complete, Suspect, Read, Total, Breakdown = GearScore_GetScore(Name, Unit)
	if not ( Score ) then return true; end

	local Unanswered = false
	if ( Complete ) and not ( UnitIsUnit(Unit, "player") ) and ( GSL.answeredFor ~= Name ) then
		Complete = false
		Unanswered = true
		Suspect = true
	end

	Log("scan %s: score=%d ilvl=%d slots=%d/%d %s", tostring(Name), Score, Average,
	    Read or 0, Total or 0, Complete and "complete" or "partial")

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
		if ( Left > 0 ) then
			GSL.scanSettle = Left - 1
			Settle = false
		end
	end

	if ( Complete ) and ( Total ) and ( Total > ( GSL.scanOccupied or 0 ) )
	   and not ( UnitIsUnit(Unit, "player") ) then
		GSL.scanSettle = SCAN_SETTLE
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

	local Improves = ( Previous ) and ( Complete ) and not ( Suspect )
	                 and ( not ( Previous.complete ) or ( Previous.suspect ) )
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
	                    read = Read, occupied = Total, time = GetTime(),
	                    breakdown = GS_Settings.Debug and Breakdown or nil }
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
	RescanFrame:Show()
end

local function NextInQueue()
	while ( #GSL.queue > 0 ) do
		local Name = table.remove(GSL.queue, 1)
		local Unit = GSL.queued[Name]
		GSL.queued[Name] = nil
		if not ( Unit ) or not ( MatchName(Unit, Name) ) then Unit = FindUnit(Name); end
		if ( Unit ) then
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
	if not ( MatchName(Unit, Name) ) then
		local Moved = FindUnit(Name)
		if not ( Moved ) then
			Log("scan %s abandoned: unit changed", tostring(Name))
			CancelRescan(); NextInQueue(); return
		end
		Log("scan %s: %s no longer points at them, following %s", tostring(Name), tostring(Unit), Moved)
		Unit = Moved
		GSL.scanUnit = Moved
	end
	GSL.scanTries = GSL.scanTries - 1
	if ( ScanUnit(Name, Unit) ) then
		CancelRescan()
		NextInQueue()
	elseif ( GSL.scanTries <= 0 ) then
		Log("scan %s gave up: %d slots read, budget exhausted", tostring(Name), GSL.scanRead or 0)
		local Entry = GSL.cache[Name]
		if ( Entry ) and ( Entry.unanswered ) then
			Log("scan %s: discarding an unanswered reading (%d) rather than settling it",
			    tostring(Name), Entry.score)
			GSL.cache[Name] = nil
		elseif ( Entry ) then
			Entry.settled = true
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
		if ( Changed ) and ( Name ) then Announce(Name, Score, Average); end
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

local function Track(Name, Unit, Force)
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
		if not ( ScanUnit(Name, Unit) ) then BeginScan(Name, Unit); end
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
	elseif not ( Entry.complete ) then
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
	if ( type(UISpecialFrames) == "table" ) then tinsert(UISpecialFrames, "GearScoreLiteDumpFrame"); end
	DumpFrame = Frame
	return Frame
end

local function DumpText()
	local Out = {}
	local Version = GetAddOnMetadata and GetAddOnMetadata("GearScoreLite", "Version") or "?"
	Out[#Out + 1] = "GearScoreLite: Reborn " .. tostring(Version) .. " -- scan log"
	Out[#Out + 1] = format("player: %s  score=%d  ilvl=%d",
		tostring(UnitName("player")), GSL.player.score, GSL.player.ilvl)
	Out[#Out + 1] = format("settings: colour=%s status=%s combat=%s target=%s",
		tostring(GS_Settings and GS_Settings.ColorMode),
		tostring(GS_Settings and GS_Settings.Status),
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

local SlotNames = {
	[1] = "head", [2] = "neck", [3] = "shoulder", [5] = "chest", [6] = "waist",
	[7] = "legs", [8] = "feet", [9] = "wrist", [10] = "hands", [11] = "finger1",
	[12] = "finger2", [13] = "trinket1", [14] = "trinket2", [15] = "back",
	[16] = "main hand", [17] = "off hand", [18] = "ranged",
}

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

local function KnownName(Query)
	local Saved = ( type(GS_Cache) == "table" ) and GS_Cache or {}
	if ( GSL.cache[Query] ) or ( Saved[Query] ) then return Query; end
	local Lower = strlower(Query)
	for Name in pairs(GSL.cache) do
		if ( strlower(Name) == Lower ) then return Name; end
	end
	for Name in pairs(Saved) do
		if ( type(Name) == "string" ) and ( strlower(Name) == Lower ) then return Name; end
	end
	return Query
end

local function ResolveByName(Query)
	if ( Query ) and ( Query ~= "" ) then
		local Unit, Actual = FindUnit(Query, true)
		if ( Unit ) then return Actual, Unit; end
		return KnownName(Query), nil
	end
	if ( UnitExists("target") ) then return UnitName("target"), "target"; end
	if ( UnitExists("mouseover") ) then return UnitName("mouseover"), "mouseover"; end
	return nil, nil
end

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

local function Explain(Query)
	local Name, Unit = ResolveByName(Query)
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
		print("  no unit token in range (not in your raid, party, target, focus or mouseover)")
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
			print("            real gear is better than this score. /gs gear lists the slots.")
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

	if ( GSL.answeredFor == Name ) then
		print("  inspect data: the client is holding this player's gear")
	elseif ( GSL.answeredFor ) then
		print("  inspect data: the client is holding " .. tostring(GSL.answeredFor)
		      .. "'s gear, not this player's")
	else
		print("  inspect data: none held yet (request in flight)")
	end

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
			print("  no inspect data held right now -- the client keeps only the most")
			print("  recent inspect, so this says nothing about the score above")
		end
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
				if ( type(GS_Cache) == "table" ) then GS_Cache[Who] = nil; end
				if ( Had ) then Log("cache invalidated for %s (inventory changed)", tostring(Who)); end
			end
		end

	elseif ( event == "PLAYER_TARGET_CHANGED" ) then
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
		GS_Settings.Debug = false
		PruneStore()
		GSL.inCombat = UnitAffectingCombat("player") and true or false
		ApplyAnchor()
		UpdatePaperDoll()
		self:UnregisterEvent("ADDON_LOADED")
	end
end)

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
	end,

	GetPlayer = function() return GSL.player.score, GSL.player.ilvl end,

	RegisterCallback = function(callback)
		if ( type(callback) == "function" ) then tinsert(GSL.listeners, callback); end
	end,
}
