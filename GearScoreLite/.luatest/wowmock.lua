-- Minimal WoW 3.3.5a API mock, enough to load GearScoreLite under plain Lua 5.1
-- and drive its logic. Frames record their scripts so tests can fire them.

local M = {}

-- ---------------------------------------------------------------- state ----
local state = {
    time = 1000,
    combat = false,
    frames = {},
    prints = {},
    events = {},        -- [frame] = { [event]=true }
    tooltipLines = {},
    inventory = {},     -- [unit] = { [slot] = itemLink }
    items = {},         -- [link] = { name, link, rarity, ilvl, ..., equipLoc }
    units = {},         -- [token] = { name=, class=, isPlayer=, exists= }
    notifyInspect = {},
    scanEvents = {},
}
M.state = state

-- ---------------------------------------------------------------- helpers --
local function mkregion()
    local r = {}
    function r:SetFont(path, size)
        self._font, self._size = path, size
        -- Mock the real client contract: returns false for a missing file.
        if path and path:find("FiraSans") and not M.fontExists then return false end
        return true
    end
    function r:SetPoint() end
    function r:SetAllPoints() end
    function r:SetTexture() end
    function r:SetText(t) self._text = t end
    function r:GetText() return self._text end
    function r:SetTextColor(...) self._color = { ... } end
    function r:Show() self._shown = true end
    function r:Hide() self._shown = false end
    function r:IsShown() return self._shown end
    return r
end

local function mkframe(name, parent)
    local f = { _name = name, _parent = parent, _scripts = {}, _events = {}, _shown = true }
    function f:SetWidth(w) self._w = w end
    function f:SetHeight(h) self._h = h end
    function f:SetPoint(...) self._point = { ... } end
    function f:ClearAllPoints() self._point = nil end
    function f:SetFrameLevel(l) self._level = l end
    function f:GetFrameLevel() return self._level or 1 end
    function f:EnableMouse(e) self._mouse = e end
    function f:SetMovable(m) self._movable = m end
    function f:RegisterForDrag() end
    function f:StartMoving() end
    function f:StopMovingOrSizing() end
    function f:GetEffectiveScale() return 1 end
    function f:GetLeft() return self._left or 0 end
    function f:GetTop() return self._top or 0 end
    function f:CreateTexture() return mkregion() end
    function f:CreateFontString(nm) local r = mkregion(); if nm then _G[nm] = r end; return r end
    function f:SetScript(k, fn) self._scripts[k] = fn end
    function f:GetScript(k) return self._scripts[k] end
    function f:HookScript(k, fn)
        local prev = self._scripts[k]
        self._scripts[k] = function(...) if prev then prev(...) end; return fn(...) end
    end
    function f:RegisterEvent(e) self._events[e] = true end
    function f:UnregisterEvent(e) self._events[e] = nil end
    function f:Show() self._shown = true end
    function f:Hide() self._shown = false end
    function f:IsShown() return self._shown end
    function f:SetOwner() end
    function f:SetBackdrop(b) self._backdrop = b end
    function f:SetFrameStrata(s) self._strata = s end
    -- EditBox / ScrollFrame / Button surface used by the debug dump window.
    function f:SetMultiLine(m) self._multiline = m end
    function f:SetAutoFocus(a) self._autofocus = a end
    function f:SetFontObject(o) self._fontobject = o end
    function f:SetText(t) self._text = t end
    function f:GetText() return self._text end
    function f:SetCursorPosition(p) self._cursor = p end
    function f:SetScrollChild(c) self._child = c end
    function f:HighlightText() end
    function f:AddLine(text, r, g, b)
        table.insert(state.tooltipLines, { text = text, r = r, g = g, b = b, double = false })
    end
    function f:AddDoubleLine(l, r2, r, g, b, r3, g3, b3)
        table.insert(state.tooltipLines, { text = l, right = r2, r = r, g = g, b = b, double = true })
    end
    table.insert(state.frames, f)
    return f
end
M.mkframe = mkframe

-- ------------------------------------------------------------- globals -----
function M.install(G)
    _G = G
    G._G = G

    G.CreateFrame = function(kind, name, parent) local f = mkframe(name, parent); if name then G[name] = f end; return f end
    G.UIParent = mkframe("UIParent")
    G.PaperDollFrame = mkframe("PaperDollFrame")
    G.PaperDollFrame._left, G.PaperDollFrame._top = 0, 0

    local function mktooltip(name)
        local t = mkframe(name)
        t._unitName, t._unitToken = nil, nil
        function t:GetUnit() return self._unitName, self._unitToken end
        function t:SetUnit(unit)
            self._unitToken = unit
            self._unitName = G.UnitName(unit)
            local fn = self._scripts["OnTooltipSetUnit"]
            if fn then fn(self) end
        end
        function t:GetItem() return self._itemName, self._itemLink end
        return t
    end
    G.GameTooltip = mktooltip("GameTooltip")
    G.ShoppingTooltip1 = mktooltip("ShoppingTooltip1")
    G.ShoppingTooltip2 = mktooltip("ShoppingTooltip2")
    G.ItemRefTooltip = mktooltip("ItemRefTooltip")

    G.GetTime = function() return state.time end

    G.UnitExists = function(u) local d = state.units[u]; return d ~= nil and d.exists ~= false end
    G.UnitIsPlayer = function(u) local d = state.units[u]; return d ~= nil and d.isPlayer ~= false end
    G.UnitName = function(u) local d = state.units[u]; return d and d.name end
    G.UnitClass = function(u) local d = state.units[u]; return d and d.classLocal, d and d.class end
    G.UnitIsUnit = function(a, b)
        local x, y = state.units[a], state.units[b]
        return x ~= nil and y ~= nil and x.name == y.name
    end
    G.UnitAffectingCombat = function() return state.combat end
    G.CanInspect = function(u) local d = state.units[u]; return d ~= nil and d.canInspect ~= false end
    G.UnitIsConnected = function(u) local d = state.units[u]; return d ~= nil and d.connected ~= false end
    G.UnitCanCooperate = function(a, b) local d = state.units[b]; return d ~= nil and d.cooperate ~= false end
    -- Index 1 is the ~28 yard inspect range in the real client.
    G.CheckInteractDistance = function(u, index) local d = state.units[u]; return d ~= nil and d.inRange ~= false end
    G.NotifyInspect = function(u) table.insert(state.notifyInspect, { unit = u, time = state.time }) end

    G.GetInventoryItemLink = function(unit, slot)
        local d = state.units[unit]
        if not d then return nil end
        local inv = state.inventory[d.name]
        return inv and inv[slot]
    end

    G.GetItemInfo = function(link)
        local it = state.items[link]
        if not it then return nil end
        -- name, link, rarity, ilvl, minLevel, type, subType, stackCount, equipLoc
        return it.name, link, it.rarity, it.ilvl, 0, "Armor", "Plate", 1, it.equipLoc
    end
    G.IsEquippableItem = function(link)
        local it = state.items[link]
        return it ~= nil and it.equipLoc ~= nil and it.equipLoc ~= ""
    end

    G.GetMouseFocus = function() return state.mouseFocus end

    G.SlashCmdList = {}
    G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        table.insert(state.prints, table.concat(parts, " "))
    end
    G.date = os.date
    -- Read the real .toc rather than repeating the version here, so a release
    -- bump cannot leave the mock asserting against a stale number.
    G.GetAddOnMetadata = function(addon, field)
        if field ~= "Version" then return nil end
        local f = io.open("GearScoreLite.toc", "r")
        if not f then return nil end
        local body = f:read("*a"); f:close()
        return body:match("##%s*Version:%s*(%S+)")
    end
    G.format = string.format
    G.ChatFontNormal = {}
    G.strlower = string.lower
    G.strtrim = function(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end
    G.tinsert = table.insert

    G.InspectFrame = nil
    G.Examiner = nil
    G.WeakAuras = nil

    return G
end

-- --------------------------------------------------------------- driving ---
function M.fireEvent(frame, event, arg1)
    if not frame._events[event] then return false end
    local fn = frame._scripts["OnEvent"]
    if not fn then return false end
    fn(frame, event, arg1)
    return true
end

function M.tick(frame, elapsed)
    local fn = frame._scripts["OnUpdate"]
    if fn and frame:IsShown() then
        state.time = state.time + elapsed
        fn(frame, elapsed)
    end
end

function M.clearTooltip() state.tooltipLines = {} end

return M
