-- Standalone logic test for the Who Pulled module. Stubs the WoW API, loads the
-- real addon files into one shared namespace, runs init, and verifies the
-- timing classification, tank exemption, puller resolution from boss target,
-- the session/leaderboard history, and the module on/off framework.
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

-- boss target: a controllable fixture. nil name => no boss target this pull.
local bossTarget = nil
UnitExists = function(unit) return unit == "boss1target" and bossTarget ~= nil end
UnitIsPlayer = function(unit) return unit == "boss1target" and bossTarget ~= nil end
UnitName = function(unit)
    if unit == "player" then return "Me", "" end
    if unit == "boss1target" and bossTarget then return bossTarget.name, bossTarget.realm end
    return nil
end
GetUnitName = function(unit) return (UnitName(unit)) end
UnitClass = function(unit)
    if unit == "boss1target" and bossTarget then return bossTarget.class, bossTarget.class end
    return nil
end

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

-- run C_Timer.After synchronously so the poll chain resolves in-line
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
check("enabled by default", EP.enabled == true)
check("default persisted to DB", OppositeQOLDB.modules.whoPulled.enabled == true)
check("config defaults applied (sound + chat opt-in)",
    EP.onTimeWindow == 0.25 and EP.sound == false and EP.chatAnnounce == false)
check("sessions table created", type(EP.db.sessions) == "table")

-- ---- sound picker: built-ins (SOUNDKIT) + LibSharedMedia merge ----
check("soundName default is Raid Warning", EP.soundName == "Raid Warning")
local sl = EP:SoundList()
local function hasSound(n) for _, e in ipairs(sl) do if e.name == n then return true end end end
check("sound list has built-in Raid Warning", hasSound("Raid Warning"))
check("sound list has built-in Ready Check", hasSound("Ready Check"))
check("sound list merges LibSharedMedia sounds", hasSound("AddonX: Bibble"))
soundsPlayed = {}
EP:PlaySoundByName("Raid Warning")
check("built-in plays via PlaySound id", soundsPlayed[1] == "kit:8959")
soundsPlayed = {}
EP:PlaySoundByName("AddonX: Bibble")
check("LSM sound plays via PlaySoundFile", contains(soundsPlayed[1] or "", "bibble.ogg"))

-- ---- timing classification ----
local k1 = EP:Classify(nil);   check("untimed kind", k1 == "untimed")
local k2, d2 = EP:Classify(-1); check("early kind",   k2 == "early" and contains(d2, "1.00 seconds early"))
local k3 = EP:Classify(0.1);   check("on-time kind (inside window)", k3 == "ontime")
local k4, d4 = EP:Classify(2);  check("late kind",    k4 == "late" and contains(d4, "2.00 seconds late"))

-- ---- tank exemption in the message ----
local earlyCtx = { pullTimeDiff = -2, desc = "Boss pulled 2.00 seconds early", kind = "early" }
local tankMsg = EP:BuildMessage(earlyCtx, { name = "Tankzor", isTank = true })
local dpsMsg  = EP:BuildMessage(earlyCtx, { name = "Dpsy", isTank = false })
check("tank early pull drops the early flag", tankMsg == "Boss pulled by Tankzor.")
check("dps early pull keeps the early flag", contains(dpsMsg, "2.00 seconds early") and contains(dpsMsg, "Dpsy"))
check("nil actor -> [Unknown]", contains(EP:BuildMessage(earlyCtx, nil), "[Unknown]"))

-- ---- end-to-end: countdown then a 0.5s-early pull, boss target = tank ----
bossTarget = { name = "Tankzor", realm = "TarrenMill", class = nil }
EP:START_TIMER(TIMER_TYPE_PLAYER_COUNTDOWN, 5)  -- expected pull at clock+5
advance(4.5)                                    -- pull 0.5s early
prints = {}
EP:ENCOUNTER_START(111, "Test Boss")
check("pull recorded immediately from boss target", EP.pullContext.recorded == true)
check("classified early", EP.pullContext.kind == "early")
check("tank banner has no early flag", lastPrint() == "Boss pulled by Tankzor-TarrenMill.")
EP:ENCOUNTER_END()
check("context cleared on encounter end", EP.pullContext == nil)

-- ---- end-to-end: no countdown, no boss target -> [Unknown] after polls ----
bossTarget = nil
prints = {}
EP:ENCOUNTER_START(222, "Untimed Boss")
check("untimed + unknown puller still records", EP.pullContext.recorded == true)
check("untimed banner names [Unknown]", contains(lastPrint(), "[Unknown]") and not contains(lastPrint(), "seconds"))
EP:ENCOUNTER_END()

-- ---- history + leaderboard (tank hidden, non-tanks aggregated) ----
EP:RecordPull({ encounterName = "Boss A", pullTimeDiff = -1.5 }, { name = "Dpsy-TarrenMill", isTank = false })
EP:RecordPull({ encounterName = "Boss A", pullTimeDiff = 2.0 },  { name = "Dpsy-TarrenMill", isTank = false })
local board = EP:BuildLeaderboard()
check("leaderboard hides tank pulls", contains(board, "tank pulls hidden"))
check("leaderboard aggregates the dps puller", contains(board, "Dpsy-TarrenMill") and contains(board, "1 early") and contains(board, "1 late"))

-- ---- merge keys for the companion log parser (encounterID + local time) ----
EP:RecordPull({ encounterID = 3183, encounterName = "L'ura", pullTimeDiff = -2.34 },
    { name = "Torm-Drakthul", isTank = false })
local mergeSess = EP.db.sessions[#EP.db.sessions]
local mergeRec  = mergeSess.pulls[#mergeSess.pulls]
check("pull record carries encounterID for the log join", mergeRec.encounterID == 3183)
check("pull record carries a local wall-clock stamp", type(mergeRec.localTime) == "string"
    and mergeRec.localTime:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$") ~= nil)

-- ---- report posts the leaderboard to chat (out of combat) ----
sentLines = {}
EP:PostReport("RAID")
check("report posted lines to chat", #sentLines > 0)

-- ---- report window builds + refreshes without error (while enabled) ----
check("report window builds", pcall(function() EP:Open() end))

-- ---- chat call-out: prepull (early) only, deferred to combat end ----
EP.chatAnnounce, EP.chatChannel = true, "AUTO"

-- a late pull must NOT trigger the chat call-out
inCombat, sentLines, EP.chatQueue = true, {}, nil
EP:FirePull({ pullTimeDiff = 1.5, desc = "Boss pulled 1.50 seconds late", kind = "late" },
    { name = "Slowpoke", isTank = false })
check("late pull does not queue a chat call-out", EP.chatQueue == nil)

-- an early pull queues during combat, even for a boss-target (isTank) puller
inCombat, sentLines = true, {}
EP:FirePull({ pullTimeDiff = -1, desc = "Boss pulled 1.00 seconds early", kind = "early" },
    { name = "Prepuller-TarrenMill", isTank = true })
check("early pull queued during combat (not sent live)",
    #sentLines == 0 and EP.chatQueue ~= nil and #EP.chatQueue == 1)

inCombat = false
EP:PLAYER_REGEN_ENABLED()
check("chat call-out flushed when combat ends", #sentLines == 1)
check("uses the prepull format, names the culprit (no tank exemption)",
    contains(sentLines[1], "Prepulled the boss by 1.00sec")
    and contains(sentLines[1], "Who prepulled? Prepuller-TarrenMill"))
check("queue cleared after flush", EP.chatQueue == nil)
EP.chatAnnounce = false

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
SlashCmdList["OPPOSITEQOL"]("enable Who Pulled")
check("enabled via slash (by display name)", EP.enabled == true)

print(ok and "\nALL TESTS PASSED" or "\nSOME TESTS FAILED")
os.exit(ok and 0 or 1)
