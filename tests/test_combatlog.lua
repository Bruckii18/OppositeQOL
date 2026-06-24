-- Standalone logic test for the Combat Log Status module. Stubs the WoW API,
-- loads the real addon files into one shared namespace, runs init, and verifies
-- state detection (LoggingCombat), the colored status text, the poll/event
-- refresh paths, the minimap repaint hook, the /oqol log command, and the
-- module on/off framework.
-- Run from the project root:  luajit tests/test_combatlog.lua

-- ---- per-object widget mock (each frame/fontstring has its own storage) ----
local function newWidget()
    local store = {}
    local w = {}
    setmetatable(w, { __index = function(_, k)
        return function(self, a)
            if k == "CreateFontString" or k == "CreateTexture"
                or k == "CreateMaskTexture" then return newWidget()
            elseif k == "GetText" then return store.text or ""
            elseif k == "SetText" then store.text = a; return
            elseif k == "GetHeight" then return store.height or 100
            elseif k == "SetHeight" then store.height = a; return
            elseif k == "GetWidth" then return store.width or 100
            elseif k == "GetCenter" then return 0, 0
            elseif k == "GetEffectiveScale" then return 1
            elseif k == "IsShown" then return store.shown
            elseif k == "Show" then store.shown = true; return
            elseif k == "Hide" then store.shown = false; return
            elseif k == "GetChecked" then return store.checked
            elseif k == "SetChecked" then store.checked = a; return
            elseif k == "GetPoint" then return "CENTER", nil, "CENTER", 0, 0
            else return self end
        end
    end })
    return w
end

-- ---- controllable combat-logging state + poll/timer capture ----
local logging = false                   -- what LoggingCombat() returns
local tickerFn                          -- the function NewTicker is driving
local tickerCancelled = false
local stopTimerFn                       -- the function the delayed-stop NewTimer drives
local instanceType, difficulty = "none", 0     -- what GetInstanceInfo() returns
local cvars = { advancedCombatLogging = "0" }

CreateFrame = function() return newWidget() end
UIParent = newWidget()
Minimap = newWidget()
GameTooltip = newWidget()
GetCursorPosition = function() return 100, 100 end
GetPhysicalScreenSize = function() return 2560, 1440 end
GetInstanceInfo = function() return "Zone", instanceType, difficulty end
GetCVar = function(k) return cvars[k] end
SetCVar = function(k, v) cvars[k] = tostring(v) end
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
UISpecialFrames, SlashCmdList = {}, {}
tinsert = table.insert
-- getter/setter, like the real API: LoggingCombat() reads, LoggingCombat(b) sets.
LoggingCombat = function(v)
    if v ~= nil then logging = v and true or false end
    return logging
end
-- C_ChatInfo.IsLoggingCombat() (12.0.7+) -> (enabled, advanced). Reads the same
-- `logging` var so the existing assertions hold, plus a settable advanced flag.
local advancedLog = false
C_ChatInfo = { IsLoggingCombat = function() return logging, advancedLog end }
C_Timer = {
    After     = function(_, fn) fn() end,                       -- run inline
    NewTicker = function(_, fn)
        tickerFn = fn
        return { Cancel = function() tickerCancelled = true end }
    end,
    NewTimer  = function(_, fn)
        stopTimerFn = fn
        return { Cancel = function() stopTimerFn = nil end }
    end,
}

-- ---- load the real files into ONE shared namespace (like the game does) ----
local ns = {}
local function load(path) assert(loadfile(path))("OppositeQOL", ns) end
load("Core.lua")
load("UI.lua")
load("CombatLog.lua")
load("Config.lua")
load("Minimap.lua")

-- capture chat output
local prints = {}
ns.Print = function(_, msg) prints[#prints + 1] = tostring(msg) end
local function lastPrint() return prints[#prints] or "" end

OppositeQOLDB = nil
ns:Initialize()

-- ===========================================================================
local ok = true
local function check(name, cond)
    print((cond and "PASS " or "FAIL ") .. name)
    ok = ok and (cond and true or false)
end
local function contains(s, sub) return type(s) == "string" and s:find(sub, 1, true) ~= nil end

local CL = ns.CombatLog

-- ---- module framework ----
check("module registered", ns.modules.combatLog ~= nil)
check("enabled by default", CL.enabled == true)
check("default persisted to DB", OppositeQOLDB.modules.combatLog.enabled == true)
check("per-module DB created", type(CL.db) == "table")
check("has options window", CL.hasUI == true)
check("auto-log master defaults OFF", CL.db.autoLog and CL.db.autoLog.enabled == false)

-- ---- colour theme: default applied at init, switchable via slash ----
check("default theme applied at init",
    OppositeQOLDB.theme == "teal" and ns.UI.Hex(ns.UI.theme.accent) == "ff2fe3c4")
SlashCmdList["OPPOSITEQOL"]("theme cyan")
check("/oqol theme switches the palette",
    OppositeQOLDB.theme == "cyan" and ns.UI.Hex(ns.UI.theme.accent) == "ff33bce8")
prints = {}
SlashCmdList["OPPOSITEQOL"]("theme list")
check("/oqol theme list prints without error", #prints > 0)
SlashCmdList["OPPOSITEQOL"]("theme teal")   -- restore

-- ---- initial state read from LoggingCombat (off at init) ----
check("inactive at init", CL:IsActive() == false)
check("status text shows 'not active' in red",
    contains(CL:StatusText(), "not active") and contains(CL:StatusText(), "ffeb6161"))

-- ---- state change is detected by Check() ----
logging = true
check("Check() returns true when logging on", CL:Check() == true)
check("IsActive reflects on", CL:IsActive() == true)
check("status text shows 'active' in green",
    contains(CL:StatusText(), "active") and contains(CL:StatusText(), "ff66d977")
    and not contains(CL:StatusText(), "not active"))

logging = false
check("Check() returns false when logging off", CL:Check() == false)

-- ---- the light poll (NewTicker) catches a manual /combatlog (fires no event) ----
check("ticker installed on enable", type(tickerFn) == "function")
logging = true
tickerFn()                                  -- simulate one poll tick
check("poll tick detects manual /combatlog", CL:IsActive() == true)

-- ---- first-party read + event-driven refresh (12.0.7) ----
logging, advancedLog = true, true
check("ReadLoggingState reads C_ChatInfo (enabled, advanced)",
    (function() local e, a = CL:ReadLoggingState(); return e == true and a == true end)())
advancedLog = false
logging = false; CL:Check()
logging = true
check("CHAT_LOGGING_CHANGED refreshes immediately (no poll wait)",
    pcall(function() CL:CHAT_LOGGING_CHANGED() end) and CL:IsActive() == true)

-- ---- zone / encounter events refresh without error ----
logging = false
check("PLAYER_ENTERING_WORLD refreshes",
    pcall(function() CL:PLAYER_ENTERING_WORLD() end) and CL:IsActive() == false)
logging = true
check("ENCOUNTER_START refreshes",
    pcall(function() CL:ENCOUNTER_START() end) and CL:IsActive() == true)
check("ZONE_CHANGED_NEW_AREA / ENCOUNTER_END safe",
    pcall(function() CL:ZONE_CHANGED_NEW_AREA(); CL:ENCOUNTER_END() end))

-- ---- minimap button: builds, repaints, all without error ----
check("minimap button creates", pcall(function() ns.MinimapButton:Create() end))
check("RefreshStatus safe while logging on",
    pcall(function() ns.MinimapButton:RefreshStatus() end))
check("RefreshStatus safe while logging off",
    pcall(function() logging = false; CL:Check(); ns.MinimapButton:RefreshStatus() end))

-- ---- /oqol log prints the live status (and repaints) ----
logging = true
prints = {}
SlashCmdList["OPPOSITEQOL"]("log")
check("/oqol log reports active",
    contains(lastPrint(), "active") and not contains(lastPrint(), "not active"))
logging = false
prints = {}
SlashCmdList["OPPOSITEQOL"]("cl")
check("/oqol cl alias reports not active", contains(lastPrint(), "not active"))

-- ---- enable/disable lifecycle ----
SlashCmdList["OPPOSITEQOL"]("disable combatLog")
check("disabled via slash (by key)", CL.enabled == false)
check("ticker cancelled on disable", tickerCancelled == true)
check("RefreshStatus safe while module disabled",
    pcall(function() ns.MinimapButton:RefreshStatus() end))
prints = {}
SlashCmdList["OPPOSITEQOL"]("log")
check("/oqol log notes the module is disabled", contains(lastPrint(), "disabled"))

tickerFn = nil
SlashCmdList["OPPOSITEQOL"]("enable Combat Log Status")
check("enabled via slash (by display name)", CL.enabled == true)
check("ticker reinstalled on re-enable", type(tickerFn) == "function")

-- ===========================================================================
-- Auto-logging (opt-in, default OFF)
-- ===========================================================================
local c = CL.db.autoLog
check("ShouldLog false while master disabled", CL:ShouldLog() == false)

c.enabled = true
instanceType, difficulty = "raid", 15            -- heroic raid
check("heroic raid logs when logHeroic on", CL:ShouldLog() == true)
c.logHeroic = false
check("that difficulty off -> no log", CL:ShouldLog() == false)
c.logHeroic = true

instanceType, difficulty = "raid", 17            -- LFR
check("LFR respects its toggle (on)", CL:ShouldLog() == true)
c.logLFR = false
check("LFR off -> no log", CL:ShouldLog() == false)
c.logLFR = true

instanceType, difficulty = "party", 23           -- Mythic+ keystone
check("M+ keystone logs when logMythicPlus on", CL:ShouldLog() == true)
c.logMythicPlus = false
check("M+ off -> no log", CL:ShouldLog() == false)
c.logMythicPlus = true

instanceType, difficulty = "raid", nil
check("nil/stale difficulty -> no log", CL:ShouldLog() == false)
instanceType, difficulty = "none", 0
check("open world -> no log", CL:ShouldLog() == false)

-- flip: entering a logged raid starts logging + sets the advanced-logging CVar
logging = false
cvars.advancedCombatLogging = "0"
instanceType, difficulty = "raid", 16            -- mythic
CL:ApplyLoggingState()
check("auto-start turns logging ON", logging == true)
check("advancedCombatLogging CVar enabled", cvars.advancedCombatLogging == "1")

-- leaving: with delayed-stop, schedule a timer but keep logging until it fires
instanceType, difficulty = "none", 0
c.delaystop = true
stopTimerFn = nil
CL:ApplyLoggingState()
check("delayed-stop timer scheduled", type(stopTimerFn) == "function")
check("still logging until the timer fires", logging == true)
stopTimerFn()
check("logging stops after the delayed-stop timer", logging == false)

-- with delayed-stop off, leaving stops immediately
logging = false
instanceType, difficulty = "raid", 16
CL:ApplyLoggingState()                            -- start (we own it)
c.delaystop = false
instanceType, difficulty = "none", 0
CL:ApplyLoggingState()
check("immediate stop when delayed-stop off", logging == false)

-- never stops a log the addon didn't start
logging = true
CL._autoStarted = false
CL:ApplyLoggingState()
check("does not stop a user-started log", logging == true)

-- event path: a deferred recheck via ZONE_CHANGED_NEW_AREA evaluates auto-logging
logging = false
c.enabled = true
instanceType, difficulty = "raid", 16
CL:ZONE_CHANGED_NEW_AREA()                        -- C_Timer.After runs inline in the mock
check("zone change evaluates auto-logging", logging == true)

-- options window builds without error
c.delaystop = true
check("auto-logging options window builds", pcall(function() CL:Open() end))

-- ---- app shell (Config): module Open routes into the shell pane ----
check("shell built on module Open", ns.Config.frame ~= nil)
check("OpenModule selects the module", ns.Config.current == "combatLog")
check("module page cached in the shell", ns.Config.pages.combatLog ~= nil)
check("sidebar nav row exists for the module", ns.Config.navRows.combatLog ~= nil)
ns.Config:Refresh()
check("nav toggle reflects enabled state",
    ns.Config.navRows.combatLog._toggle:GetChecked() == CL.enabled)
check("ToggleModule hides when already shown on that module",
    pcall(function() ns.Config:ToggleModule("combatLog") end)
    and ns.Config.frame:IsShown() == false)

print(ok and "\nALL TESTS PASSED" or "\nSOME TESTS FAILED")
os.exit(ok and 0 or 1)
