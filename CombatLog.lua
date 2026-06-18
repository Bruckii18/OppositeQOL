-- OppositeQOL - Combat Log Status
-- A passive indicator of whether combat logging (the /combatlog toggle that
-- writes WoWCombatLog.txt) is currently on. It does NOT start or stop logging --
-- dedicated auto-loggers already do that. This just surfaces the live state so
-- you can tell at a glance whether your pull is being recorded: a green/grey dot
-- on the minimap button, plus a line in its tooltip and the /oqol log command.
--
-- Detection is locale-independent: we read LoggingCombat() on a light timer (to
-- catch a manual /combatlog, which fires no event) plus on zone/encounter
-- changes (snappy when an auto-logger flips it on raid entry), and ask the
-- minimap button to repaint when the state changes.

local addonName, ns = ...

local M = {}
ns.CombatLog = M
ns:RegisterModule("combatLog", M)

M.name    = "Combat Log Status"
M.desc    = "Shows whether combat logging is active (minimap dot + tooltip)."
M.default = true
M.hasUI   = false

-- Colored status labels, reusing the suite's green/red hexes (cf. Core's list).
local GREEN, RED = "ff66d977", "ffeb6161"

-- LoggingCombat() may be absent on very old clients; guard it.
local LoggingCombat = _G.LoggingCombat or function() return false end

local POLL = 2  -- seconds between polls; a single boolean read, negligible cost

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
function M:IsActive()
    return self.active and true or false
end

-- Read the live state; if it changed, cache it and repaint the minimap dot.
function M:Check()
    local on = LoggingCombat() and true or false
    if on ~= self.active then
        self.active = on
        self:Refresh()
    end
    return self.active
end

-- Colored "active" / "not active" for the minimap tooltip and /oqol log.
function M:StatusText()
    if self.active then
        return "|c" .. GREEN .. "active|r"
    end
    return "|c" .. RED .. "not active|r"
end

-- Ask the minimap button to repaint its dot (no-op if it isn't built yet, or if
-- the Minimap module is loaded later -- it pulls the state itself on creation).
function M:Refresh()
    if ns.MinimapButton and ns.MinimapButton.RefreshStatus then
        ns.MinimapButton:RefreshStatus()
    end
end

-- ---------------------------------------------------------------------------
-- Events: an auto-logger may flip logging right around a zone/encounter change,
-- so re-check immediately and once more shortly after to catch the lag.
-- ---------------------------------------------------------------------------
local function recheck(self)
    self:Check()
    if C_Timer and C_Timer.After then
        C_Timer.After(1, function() self:Check() end)
    end
end

function M:PLAYER_ENTERING_WORLD() recheck(self) end
function M:ZONE_CHANGED_NEW_AREA() recheck(self) end
function M:ENCOUNTER_START()       recheck(self) end
function M:ENCOUNTER_END()         recheck(self) end

local EVENTS = {
    "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA",
    "ENCOUNTER_START", "ENCOUNTER_END",
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function M:OnInitialize()
    ns.db.combatLog = ns.db.combatLog or {}
    self.db = ns.db.combatLog
    self.active = LoggingCombat() and true or false
end

function M:OnEnable()
    if not self.listener then
        self.listener = CreateFrame("Frame")
        self.listener:SetScript("OnEvent", function(_, event, ...)
            local handler = self[event]
            if handler then handler(self, ...) end
        end)
    end
    for _, e in ipairs(EVENTS) do
        pcall(self.listener.RegisterEvent, self.listener, e)
    end
    -- A manual /combatlog fires no event, so poll lightly as the catch-all.
    if C_Timer and C_Timer.NewTicker and not self.ticker then
        self.ticker = C_Timer.NewTicker(POLL, function() self:Check() end)
    end
    self:Check()
    self:Refresh()  -- paint even if the state did not change since init
end

function M:OnDisable()
    if self.listener then self.listener:UnregisterAllEvents() end
    if self.ticker then self.ticker:Cancel(); self.ticker = nil end
    self:Refresh()  -- module off -> minimap drops the dot back to neutral (hidden)
end
