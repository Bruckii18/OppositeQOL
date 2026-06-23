-- OppositeQOL - Combat Log Status
-- Two parts that share one minimap dot:
--   1. A PASSIVE indicator of whether combat logging (the /combatlog toggle that
--      writes WoWCombatLog.txt) is currently on -- a green/red dot on the minimap
--      button, a tooltip line and /oqol log. This never changes the logging state.
--   2. An OPT-IN auto-start layer (default OFF): when enabled, it turns logging on
--      as you enter a raid / Mythic+ and (optionally) off again shortly after you
--      leave. Settings live in /oqol (Open) -> Combat Log.
--
-- Detection is locale-independent: we read LoggingCombat() on a light timer (to
-- catch a manual /combatlog, which fires no event) plus on zone/encounter
-- changes, and ask the minimap button to repaint when the state changes.
--
-- LoggingCombat (read and write) is UNSECURED -- safe to call in combat -- so the
-- auto-start path deliberately has NO InCombatLockdown guard; it should be able to
-- start a log mid-pull. It only ever stops a log it started itself.

local addonName, ns = ...

local UI = ns.UI
local theme = UI.theme

local M = {}
ns.CombatLog = M
ns:RegisterModule("combatLog", M)

M.name    = "Combat Log Status"
M.desc    = "Combat-logging indicator, with opt-in auto-start in raids / M+."
M.default = true
M.hasUI   = true   -- the auto-logging options window

-- Auto-logging settings (under ns.db.combatLog.autoLog). Master flag default OFF;
-- once opted in, raids/M+ just work. Profile-aware via M.defaults below.
M.defaults = {
    autoLog = {
        enabled       = false,   -- master switch (strict ==true; missing == off)
        logNormal     = true,
        logHeroic     = true,
        logMythic     = true,
        logLFR        = true,
        logMythicPlus = true,    -- Mythic+ keystone / mythic dungeon
        delaystop     = true,    -- keep logging 30s after leaving (external recorders)
    },
}

-- Status-dot colours reuse the shared theme (single source of truth).
local GREEN, RED = UI.Hex(theme.green), UI.Hex(theme.red)

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
-- Auto-logging
-- ---------------------------------------------------------------------------
-- Difficulty IDs (version-specific magic numbers, kept as named constants).
local RAID_DIFF = { [14] = "logNormal", [15] = "logHeroic", [16] = "logMythic", [233] = "logMythic" }
local LFR_DIFF  = { [7] = true, [17] = true }

-- Should logging be on for the instance we're standing in? Master-gated first, so
-- a disabled feature never calls a single instance API.
function M:ShouldLog()
    local c = self.db and self.db.autoLog
    if not (c and c.enabled == true) then return false end
    if not GetInstanceInfo then return false end
    local _, itype, diff = GetInstanceInfo()
    diff = tonumber(diff)
    if not diff then return false end       -- transitional/stale read: do nothing
    if LFR_DIFF[diff] then return c.logLFR and true or false end
    if itype == "raid" then
        local key = RAID_DIFF[diff]
        if key then return c[key] and true or false end
        return true                          -- unknown raid difficulty: log by default
    end
    if (diff == 23 or diff == 8) and itype == "party" then
        return c.logMythicPlus and true or false
    end
    return false
end

function M:EnsureAdvancedLogging()
    if GetCVar and SetCVar and GetCVar("advancedCombatLogging") ~= "1" then
        SetCVar("advancedCombatLogging", 1)   -- makes the log Warcraft-Logs-ready
    end
end

function M:CancelStopTimer()
    if self._stopTimer then self._stopTimer:Cancel(); self._stopTimer = nil end
end

-- Bring the live logging state in line with ShouldLog(). Idempotent, and it only
-- ever STOPS a log it started itself (never one the user or another addon owns).
function M:ApplyLoggingState()
    local should = self:ShouldLog()
    if should then
        self:CancelStopTimer()
        self:EnsureAdvancedLogging()
        if not LoggingCombat() then LoggingCombat(true) end
    elseif self._autoStarted and LoggingCombat() then
        if self.db.autoLog.delaystop then
            if not self._stopTimer and C_Timer and C_Timer.NewTimer then
                self._stopTimer = C_Timer.NewTimer(30, function()
                    self._stopTimer = nil
                    if LoggingCombat() then LoggingCombat(false) end
                end)
            elseif not (C_Timer and C_Timer.NewTimer) then
                LoggingCombat(false)
            end
        else
            LoggingCombat(false)
        end
    end
    self._autoStarted = should
    self:Check()   -- repaint the dot to match
end

-- Re-evaluate now (e.g. the user flipped a setting while standing in a raid).
function M:RecheckAutoLog()
    self:ApplyLoggingState()
end

-- ---------------------------------------------------------------------------
-- Events: an auto-logger may flip logging right around a zone/encounter change,
-- so re-check immediately and once more shortly after to catch the lag. Auto-
-- logging evaluation is deferred (GetInstanceInfo is stale the instant the event
-- fires) and only scheduled when the feature is enabled.
-- ---------------------------------------------------------------------------
local function recheck(self)
    self:Check()
    if C_Timer and C_Timer.After then
        C_Timer.After(1, function() self:Check() end)
    end
end

local function scheduleAuto(self, delay)
    if not (self.db and self.db.autoLog and self.db.autoLog.enabled == true) then return end
    if C_Timer and C_Timer.After then
        C_Timer.After(delay or 2, function() self:ApplyLoggingState() end)
    else
        self:ApplyLoggingState()
    end
end

function M:PLAYER_ENTERING_WORLD() recheck(self); scheduleAuto(self, 2) end
function M:ZONE_CHANGED_NEW_AREA() recheck(self); scheduleAuto(self, 2) end
function M:CHALLENGE_MODE_START()  scheduleAuto(self, 1) end  -- keystone difficulty change
function M:ENCOUNTER_START()       recheck(self) end
function M:ENCOUNTER_END()         recheck(self) end

local EVENTS = {
    "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "CHALLENGE_MODE_START",
    "ENCOUNTER_START", "ENCOUNTER_END",
}

-- ---------------------------------------------------------------------------
-- Options window (auto-logging)
-- ---------------------------------------------------------------------------
local optsFrame

local function BuildOptions(self)
    optsFrame = UI.CreatePanel({
        name = "OppositeQOLCombatLogFrame", width = 380, height = 360,
        title = "OppositeQOL", subtitle = "Combat Log", posKey = "combatLog",
    })
    local c = self.db.autoLog
    local function setter(key, recheck)
        return function(v) c[key] = v; if recheck then self:RecheckAutoLog() end end
    end

    local page = UI.Page(optsFrame, -48)
    page:Header("Auto-start logging")
    page:Check("Enable auto-start", function() return c.enabled == true end, setter("enabled", true),
        "Turn /combatlog on automatically when you enter a logged instance. Off by default.")
    page:Spacer()
    page:Header("Log in")
    page:Check("Normal raid",       function() return c.logNormal end,     setter("logNormal", true))
    page:Check("Heroic raid",       function() return c.logHeroic end,     setter("logHeroic", true))
    page:Check("Mythic raid",       function() return c.logMythic end,     setter("logMythic", true))
    page:Check("LFR",               function() return c.logLFR end,        setter("logLFR", true))
    page:Check("Mythic+ dungeons",  function() return c.logMythicPlus end, setter("logMythicPlus", true))
    page:Spacer()
    page:Header("Compatibility")
    page:Check("30s delayed stop (external recorders)", function() return c.delaystop end, setter("delaystop"),
        "Keep logging for 30s after you leave, so tools like Warcraft Recorder capture the end.")
end

function M:Open()
    if not self.enabled then
        ns:Print(self.name .. " is disabled - enable it with /oqol.")
        return
    end
    if not optsFrame then BuildOptions(self) end
    optsFrame:Show()
end

function M:Toggle()
    if not self.enabled then
        ns:Print(self.name .. " is disabled - enable it with /oqol.")
        return
    end
    if not optsFrame then BuildOptions(self) end
    if optsFrame:IsShown() then optsFrame:Hide() else optsFrame:Show() end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function M:OnInitialize()
    ns.db.combatLog = ns.db.combatLog or {}
    self.db = ns.db.combatLog
    ns.DeepMerge(self.db, self.defaults)   -- fills autoLog defaults, keeps saved values
    self.active = LoggingCombat() and true or false
end

-- Refill cached state when the active profile changes.
function M:OnProfileChanged()
    self.db = ns.db.combatLog
    ns.DeepMerge(self.db, self.defaults)
    if self.enabled then self:ApplyLoggingState() end
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
    self:Refresh()       -- paint even if the state did not change since init
    scheduleAuto(self, 1) -- in case auto-start is already on and we're in a raid
end

function M:OnDisable()
    if self.listener then self.listener:UnregisterAllEvents() end
    if self.ticker then self.ticker:Cancel(); self.ticker = nil end
    self:CancelStopTimer()
    self._autoStarted = false   -- we no longer "own" any running log
    self:Refresh()  -- module off -> minimap drops the dot back to neutral (hidden)
end
