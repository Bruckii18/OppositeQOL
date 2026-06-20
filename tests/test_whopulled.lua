-- Standalone logic test for the PrePull module (internal key/file: whoPulled
-- / WhoPulled.lua). Stubs the WoW API, loads the real addon files into one shared
-- namespace, runs init, and verifies the pull-timer capture + early/late
-- classification, the timing-only banner (no puller name), the recorded log and
-- the merge keys for the companion tool, and the module on/off framework.
-- Run from the project root:  luajit tests/test_whopulled.lua

-- ---- per-object widget mock (each frame/fontstring has its own storage) ----
local function newWidget()
    local store = {}
    local w = {}
    setmetatable(w, { __index = function(_, k)
        return function(self, a)
            if k == "CreateFontString" or k == "CreateTexture" then return newWidget()
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

-- ---- controllable clock + combat state ----
local clock = 1000
local function advance(t) clock = clock + t end
local inCombat = false

-- ---- WoW global stubs ----
CreateFrame = function() return newWidget() end
UIParent = newWidget()
Minimap = newWidget()
GameTooltip = newWidget()
GetCursorPosition = function() return 100, 100 end
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
StaticPopupDialogs, UISpecialFrames, SlashCmdList = {}, {}, {}
tinsert = table.insert
UNKNOWN = "Unknown"
YES, NO = "Yes", "No"
format = string.format
abs = math.abs
time = os.time
date = os.date
GetTime = function() return clock end
strsplit = function(sep, s)
    local out = {}
    for part in (s .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = part end
    return table.unpack(out)
end

-- realm helpers (InviteHelper loads alongside)
GetNormalizedRealmName = function() return "TarrenMill" end
GetRealmName = function() return "Tarren Mill" end

-- group / instance state
IsInRaid = function() return true end
IsInGroup = function() return true end
IsInInstance = function() return true, "raid" end
UnitIsGroupLeader = function() return true end
UnitIsGroupAssistant = function() return true end
UnitGroupRolesAssigned = function() return "DAMAGER" end
GetNumGroupMembers = function() return 1 end
GetInstanceInfo = function() return "Test Raid", "raid", 0, "", 0, 0, 0, 9999 end
IsEncounterInProgress = function() return false end
InCombatLockdown = function() return inCombat end
LE_PARTY_CATEGORY_INSTANCE = 2
TIMER_TYPE_PLAYER_COUNTDOWN = 3

-- minimal unit stubs (still needed by other modules loaded alongside)
UnitExists = function() return false end
UnitIsPlayer = function() return false end
UnitName = function(unit) if unit == "player" then return "Me", "" end end
GetUnitName = function(unit) return (UnitName(unit)) end
UnitClass = function() return nil end

-- announce sink: RaidWarningFrame nil => Announce falls back to ns:Print
RaidWarningFrame, RaidNotice_AddMessage, ChatTypeInfo = nil, nil, nil
RAID_CLASS_COLORS = {}
SOUNDKIT = { RAID_WARNING = 8959, READY_CHECK = 8960, ALARM_CLOCK_WARNING_3 = 12867 }
local soundsPlayed = {}
PlaySound = function(id) soundsPlayed[#soundsPlayed + 1] = "kit:" .. tostring(id) end
PlaySoundFile = function(f) soundsPlayed[#soundsPlayed + 1] = "file:" .. tostring(f) end

-- minimal LibSharedMedia-3.0 stub, as if DBM/WeakAuras had registered a sound
local lsmFetch = { ["AddonX: Bibble"] = "Interface\\Z\\bibble.ogg" }
LibStub = function(name)
    if name == "LibSharedMedia-3.0" then
        return {
            List  = function() return { "AddonX: Bibble" } end,
            Fetch = function(_, _, key) return lsmFetch[key] end,
        }
    end
end

-- run C_Timer.After synchronously (a couple of modules schedule with it)
C_Timer = { After = function(_, fn) fn() end }

-- chat capture for PostReport
local sentLines = {}
C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
    SendChatMessage = function(line) sentLines[#sentLines + 1] = line end,
}
SendChatMessage = C_ChatInfo.SendChatMessage

-- ---- load the real files into ONE shared namespace (like the game does) ----
local ns = {}
local function load(path) assert(loadfile(path))("OppositeQOL", ns) end
load("Core.lua")
load("UI.lua")
load("InviteHelper.lua")
load("WhoPulled.lua")
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

local EP = ns.WhoPulled

-- ---- module framework ----
check("module registered", ns.modules.whoPulled ~= nil)
check("display name is PrePull", EP.name == "PrePull")
check("enabled by default", EP.enabled == true)
check("default persisted to DB", OppositeQOLDB.modules.whoPulled.enabled == true)
check("config defaults applied", EP.onTimeWindow == 0.25 and EP.sound == false)
check("chat call-out config dropped", EP.chatAnnounce == nil and ns.db.whoPulled.chatAnnounce == nil)
check("sessions table created", type(EP.db.sessions) == "table")

-- ---- sound picker: built-ins (SOUNDKIT) + LibSharedMedia merge ----
check("soundName default is Raid Warning", EP.soundName == "Raid Warning")
local sl = EP:SoundList()
local function hasSound(n) for _, e in ipairs(sl) do if e.name == n then return true end end end
check("sound list has built-in Raid Warning", hasSound("Raid Warning"))
check("sound list merges LibSharedMedia sounds", hasSound("AddonX: Bibble"))
soundsPlayed = {}
EP:PlaySoundByName("Raid Warning")
check("built-in plays via PlaySound id", soundsPlayed[1] == "kit:8959")
soundsPlayed = {}
EP:PlaySoundByName("AddonX: Bibble")
check("LSM sound plays via PlaySoundFile", contains(soundsPlayed[1] or "", "bibble.ogg"))

-- ---- timing classification ----
local k1 = EP:Classify(nil);    check("untimed kind", k1 == "untimed")
local k2, d2 = EP:Classify(-1);  check("early kind", k2 == "early" and contains(d2, "1.00 seconds early"))
local k3 = EP:Classify(0.1);    check("on-time kind (inside window)", k3 == "ontime")
local k4, d4 = EP:Classify(2);   check("late kind", k4 == "late" and contains(d4, "2.00 seconds late"))

-- ---- end-to-end: countdown then a 0.5s-early pull (timing-only banner) ----
EP:START_TIMER(TIMER_TYPE_PLAYER_COUNTDOWN, 5)  -- expected pull at clock+5
advance(4.5)                                    -- pull 0.5s early
prints = {}
EP:ENCOUNTER_START(111, "Test Boss")
check("pull recorded", EP.pullContext and EP.pullContext.recorded == true)
check("classified early", EP.pullContext.kind == "early")
check("banner shows timing only, no puller name",
    lastPrint() == "Boss pulled 0.50 seconds early." and not contains(lastPrint(), " by "))

-- a phase re-fire of the same ENCOUNTER_START is ignored (no duplicate record)
local n1 = #EP.db.sessions[#EP.db.sessions].pulls
EP:ENCOUNTER_START(111, "Test Boss")
check("duplicate ENCOUNTER_START ignored", #EP.db.sessions[#EP.db.sessions].pulls == n1)
EP:ENCOUNTER_END()
check("context cleared on encounter end", EP.pullContext == nil)

-- ---- untimed pull (no timer) still records + plain banner ----
prints = {}
EP:ENCOUNTER_START(222, "Untimed Boss")
check("untimed pull records", EP.pullContext.recorded == true)
check("untimed banner is plain 'Boss pulled.'",
    lastPrint() == "Boss pulled." and not contains(lastPrint(), "seconds"))
EP:ENCOUNTER_END()

-- ---- recorded log: timing only, no puller fields; merge keys present ----
EP:RecordPull({ encounterID = 3183, encounterName = "L'ura", pullTimeDiff = -2.34 })
local sess = EP.db.sessions[#EP.db.sessions]
local rec  = sess.pulls[#sess.pulls]
check("record carries encounterID for the log join", rec.encounterID == 3183)
check("record carries a local wall-clock stamp", type(rec.localTime) == "string"
    and rec.localTime:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$") ~= nil)
check("record carries the timing", rec.pullTimeDiff == -2.34)
check("record has NO puller fields", rec.pullerName == nil and rec.pullerIsTank == nil)

-- ---- BuildReport: per-pull timing history (no names) ----
local report = EP:BuildReport()
check("report titled PrePull", contains(report, "PrePull"))
check("report lists the boss and its timing",
    contains(report, "L'ura") and contains(report, "2.34s early"))

-- ---- report posts the timing log to chat (out of combat) ----
sentLines = {}
EP:PostReport("RAID")
check("report posted lines to chat", #sentLines > 0 and contains(sentLines[1], "PrePull"))

-- ---- non-raid ENCOUNTER_START is ignored ----
local savedIsInInstance = IsInInstance
IsInInstance = function() return true, "party" end
EP.pullContext = nil
EP:ENCOUNTER_START(999, "Dungeon Boss")
check("non-raid pull is ignored", EP.pullContext == nil)
IsInInstance = savedIsInInstance

-- ---- report window builds + refreshes without error (while enabled) ----
check("report window builds", pcall(function() EP:Open() end))

-- ---- minimap button: builds + toggles without error ----
check("minimap button creates", pcall(function() ns.MinimapButton:Create() end))
check("minimap hide/show is safe", pcall(function()
    ns.MinimapButton:SetShown(false)
    ns.MinimapButton:SetShown(true)
end))
check("minimap visibility persists to DB", OppositeQOLDB.minimap ~= nil)

-- ---- enable/disable via slash, and disabled guard ----
SlashCmdList["OPPOSITEQOL"]("disable whoPulled")
check("disabled via slash (by key)", EP.enabled == false)
prints = {}
local okGuard = pcall(function() EP:Toggle() end)
check("toggle while disabled is safe", okGuard)
check("toggle while disabled warns", contains(lastPrint(), "disabled"))
SlashCmdList["OPPOSITEQOL"]("enable PrePull")
check("enabled via slash (by display name)", EP.enabled == true)

print(ok and "\nALL TESTS PASSED" or "\nSOME TESTS FAILED")
os.exit(ok and 0 or 1)
