-- Throwaway test harness: stubs the WoW API, loads the REAL addon files
-- (Core + UI + InviteHelper + Config) into one shared namespace, runs init,
-- and verifies both the invite-compare logic and the module on/off framework.
-- Run from the project root:  luajit tests/test_invitehelper.lua

-- ---- per-object widget mock (each frame/fontstring has its own storage) ----
local function newWidget()
    local store = {}
    local w = {}
    setmetatable(w, { __index = function(_, k)
        return function(self, a)
            if k == "CreateFontString" or k == "CreateTexture" then return newWidget()
            elseif k == "GetText" then return store.text or ""
            elseif k == "SetText" then store.text = a; return
            elseif k == "GetStringHeight" then return 10
            elseif k == "GetFrameLevel" then return 1
            elseif k == "GetHeight" then return store.height or 100
            elseif k == "SetHeight" then store.height = a; return
            elseif k == "IsShown" then return store.shown
            elseif k == "Show" then store.shown = true; return
            elseif k == "Hide" then store.shown = false; return
            elseif k == "GetPoint" then return "CENTER", nil, "CENTER", 0, 0
            else return self end -- chainable no-op
        end
    end })
    return w
end

-- ---- WoW global stubs ----
CreateFrame = function() return newWidget() end
UIParent = newWidget()
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
StaticPopupDialogs = {}
UISpecialFrames = {}
SlashCmdList = {}
tinsert = table.insert
UNKNOWN = "Unknown"
YES, NO = "Yes", "No"
GetNormalizedRealmName = function() return "TarrenMill" end
GetRealmName = function() return "Tarren Mill" end
IsInRaid = function() return true end
IsInGroup = function() return true end
UnitIsGroupLeader = function() return true end
UnitIsGroupAssistant = function() return true end

-- Placeholder fixtures (no real player names). Deliberately exercises:
--   * own-realm fallback (empty realm -> normalized realm)
--   * realm normalization ("Tarren Mill" -> "TarrenMill")
--   * case-insensitive matching ("hotel" vs "Hotel")
--   * non-ASCII names (Növember, Ìquebec)
local raidData = {
    { "Alpha", "GrimBatol" }, { "Bravo", "" }, { "Charlie", "Draenor" },
    { "Delta", "Ravencrest" }, { "Echo", "Nazjatar" }, { "Foxtrot", "Thrall" },
    { "Golf", "Ravencrest" }, { "hotel", "Tarren Mill" }, { "India", "Ravencrest" },
    { "Juliett", "" }, { "Kilo", "TarrenMill" }, { "Lima", "Silvermoon" },
    { "Mike", "Ragnaros" }, { "Növember", "Ragnaros" }, { "Oscar", "Silvermoon" },
    { "Papa", "TarrenMill" }, { "Ìquebec", "Silvermoon" }, { "Romeo", "Stormscale" },
}
GetNumGroupMembers = function() return #raidData end
UnitName = function(unit)
    if unit == "player" then return "Me", "" end
    local i = tonumber(tostring(unit):match("^raid(%d+)$"))
    if i and raidData[i] then return raidData[i][1], raidData[i][2] end
    return nil
end

-- ---- load the real files into ONE shared namespace (like the game does) ----
local ns = {}
local function load(path) assert(loadfile(path))("OppositeQOL", ns) end
load("Core.lua")
load("UI.lua")
load("InviteHelper.lua")
load("Config.lua")

-- Capture chat output.
local prints = {}
ns.Print = function(_, msg) prints[#prints + 1] = tostring(msg) end
local function printed(substr)
    for _, m in ipairs(prints) do if m:find(substr, 1, true) then return true end end
    return false
end

-- ---- run init (saved vars start empty) ----
OppositeQOLDB = nil
ns:Initialize()

-- ===========================================================================
local ok = true
local function check(name, cond)
    print((cond and "PASS " or "FAIL ") .. name)
    ok = ok and (cond and true or false)
end

-- ---- module framework ----
check("module registered", ns.modules.inviteHelper ~= nil)
check("enabled by default", ns.InviteHelper.enabled == true)
check("default persisted to DB", OppositeQOLDB.modules.inviteHelper.enabled == true)

-- ---- invite-compare logic (window must work while enabled) ----
ns.db.inviteHelper.lastInput =
    "invitelist:Alpha-GrimBatol Bravo-TarrenMill Charlie-Draenor Delta-Ravencrest Echo-Nazjatar Foxtrot-Thrall Golf-Ravencrest Hotel-TarrenMill India-Ravencrest Sierra-Kazzak Juliett-TarrenMill Kilo-TarrenMill Lima-Silvermoon Mike-Ragnaros Növember-Ragnaros Oscar-Silvermoon Papa-TarrenMill Tango-Draenor Ìquebec-Silvermoon Uniform-TarrenMill;"

local okToggle = pcall(function() ns.InviteHelper:Toggle() end)
check("window opened without error", okToggle)
ns.InviteHelper:RunCompare()

local r = ns.InviteHelper.lastResult
check("listCount==20", r.listCount == 20)
check("raidCount==18", r.raidCount == 18)
check("3 missing", #r.missing == 3)
check("1 extra", #r.extra == 1)
check("missing #1 Sierra-Kazzak", r.missing[1] == "Sierra-Kazzak")
check("missing #2 Tango-Draenor", r.missing[2] == "Tango-Draenor")
check("missing #3 Uniform-TarrenMill", r.missing[3] == "Uniform-TarrenMill")
check("extra Romeo-Stormscale", r.extra[1] == "Romeo-Stormscale")

-- ---- config window builds + refreshes without error ----
local okCfg = pcall(function() ns.Config:Open() end)
check("config window builds", okCfg)

-- ---- enable/disable via slash (case-insensitive, by key and by name) ----
SlashCmdList["OPPOSITEQOL"]("disable invitehelper")
check("disabled via slash (by key)", ns.InviteHelper.enabled == false)
check("disable persisted", OppositeQOLDB.modules.inviteHelper.enabled == false)

prints = {}
local okGuard = pcall(function() ns.InviteHelper:Toggle() end)
check("toggle while disabled is safe", okGuard)
check("toggle while disabled warns user", printed("disabled"))

SlashCmdList["OPPOSITEQOL"]("enable Invite Helper")
check("enabled via slash (by display name)", ns.InviteHelper.enabled == true)
check("enable persisted", OppositeQOLDB.modules.inviteHelper.enabled == true)

print(ok and "\nALL TESTS PASSED" or "\nSOME TESTS FAILED")
os.exit(ok and 0 or 1)
