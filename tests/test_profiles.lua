-- Standalone logic test for the profile system + migration runner (Core.lua).
-- Registers two fake modules, runs init, then exercises DeepCopy/DeepMerge, profile
-- switch/save/copy/reset/rename/delete (incl. live-setting isolation and the
-- :OnProfileChanged re-sync), and the schemaVersion migration runner (fresh-install
-- fast-path, ordered apply, stop-on-failure).
-- Run from the project root:  luajit tests/test_profiles.lua

CreateFrame = function()
    return setmetatable({}, { __index = function() return function() end end })
end
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
UISpecialFrames, SlashCmdList = {}, {}
tinsert = table.insert

local ns = {}
assert(loadfile("Core.lua"))("OppositeQOL", ns)

-- ---- two fake modules; "a" caches a field to prove OnProfileChanged re-syncs ----
local modA = { name = "A", default = true, defaults = { level = 1, label = "x" } }
function modA:OnInitialize()
    ns.db.a = ns.db.a or {}
    self.db = ns.db.a
    ns.DeepMerge(self.db, self.defaults)
    self.level = self.db.level
end
function modA:OnProfileChanged() self.level = self.db.level end
ns:RegisterModule("a", modA)

local modB = { name = "B", default = true, defaults = { on = true } }
function modB:OnInitialize()
    ns.db.b = ns.db.b or {}
    self.db = ns.db.b
    ns.DeepMerge(self.db, self.defaults)
end
ns:RegisterModule("b", modB)

OppositeQOLDB = nil
ns:Initialize()

-- ===========================================================================
local ok = true
local function check(name, cond)
    print((cond and "PASS " or "FAIL ") .. name)
    ok = ok and (cond and true or false)
end

-- ---- table helpers ----
local src = { a = 1, nested = { x = 1 }, fn = function() end }
local copy = ns.DeepCopy(src)
check("DeepCopy copies values", copy.a == 1 and copy.nested.x == 1)
check("DeepCopy is independent", (function() copy.nested.x = 9; return src.nested.x == 1 end)())
check("DeepCopy skips functions", copy.fn == nil)
local dst = { a = 1, nested = { keep = true } }
ns.DeepMerge(dst, { a = 99, b = 2, nested = { keep = false, add = 1 } })
check("DeepMerge fills only missing", dst.a == 1 and dst.b == 2 and dst.nested.keep == true and dst.nested.add == 1)

-- ---- init created the Default profile + applied defaults ----
check("Default profile exists", ns.db.profiles.Default ~= nil)
check("active profile is Default", ns:ActiveProfile() == "Default")
check("schemaVersion set on fresh install", ns.db.schemaVersion == ns.LATEST_SCHEMA)
check("module default applied", ns.db.a.level == 1 and modA.level == 1)
check("active snapshot captured", ns.db.profiles.Default.modules.a.level == 1)

-- ---- SaveProfileAs: snapshot current, make new profile active ----
check("SaveProfileAs creates + activates", ns:SaveProfileAs("Raid") == true
    and ns:ActiveProfile() == "Raid" and ns.db.profiles.Raid ~= nil)
check("SaveProfileAs rejects duplicate", select(1, ns:SaveProfileAs("Raid")) == false)

-- ---- live-setting isolation across a switch + OnProfileChanged re-sync ----
ns.db.a.level = 9; modA.level = 9          -- change settings while in "Raid"
ns:SwitchProfile("Default")
check("switch restores other profile's live value", ns.db.a.level == 1)
check("OnProfileChanged re-synced cached field", modA.level == 1)
ns:SwitchProfile("Raid")
check("switch back restores this profile's value", ns.db.a.level == 9 and modA.level == 9)

-- ---- copy + reset ----
ns:SwitchProfile("Default")
check("CopyProfileFrom overwrites active", ns:CopyProfileFrom("Raid") == true and ns.db.a.level == 9)
ns:ResetActiveProfile()
check("reset restores defaults", ns.db.a.level == 1 and modA.level == 1)

-- ---- rename + delete ----
ns:SwitchProfile("Raid")
check("rename moves the active profile", ns:RenameProfile("Raid", "Mythic") == true
    and ns.db.profiles.Mythic ~= nil and ns.db.profiles.Raid == nil and ns:ActiveProfile() == "Mythic")
check("delete active falls back to Default", ns:DeleteProfile("Mythic") == true
    and ns.db.profiles.Mythic == nil and ns:ActiveProfile() == "Default")
check("Default profile can't be deleted", select(1, ns:DeleteProfile("Default")) == false)

-- ---- migration runner ----
local latestBefore = ns.LATEST_SCHEMA
check("fresh DB jumps to latest (no migrations yet)",
    (function() local d = { modules = {} }; ns:RunMigrations(d); return d.schemaVersion == latestBefore end)())

ns:RegisterMigration(1, function(db) db.v1 = true end)
ns:RegisterMigration(3, function(db) db.v3 = true end)
ns:RegisterMigration(2, function() error("boom") end)   -- registered out of order on purpose
check("LATEST_SCHEMA tracks highest version", ns.LATEST_SCHEMA == 3)

ns._migErrors = nil
local existing = { modules = { x = true }, schemaVersion = 0 }   -- not fresh
ns:RunMigrations(existing)
check("ordered apply runs v1 first", existing.v1 == true)
check("stops at the failing step (v2)", existing.schemaVersion == 1)
check("does not run steps past the failure", existing.v3 == nil)
check("records the migration error", ns._migErrors and #ns._migErrors == 1)

check("fresh install skips registered migrations",
    (function() local d = { modules = {} }; ns:RunMigrations(d)
        return d.schemaVersion == 3 and d.v1 == nil end)())

print(ok and "\nALL TESTS PASSED" or "\nSOME TESTS FAILED")
os.exit(ok and 0 or 1)
