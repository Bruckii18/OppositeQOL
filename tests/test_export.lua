-- Standalone test for profile export/import (Profiles.lua): the type-tagged
-- serializer, base64, the raw (no-library) round-trip, the LibDeflate-present
-- branch (via a fake lib), the version gate, and the readable error paths.
-- Run from the project root:  luajit tests/test_export.lua

CreateFrame = function()
    return setmetatable({}, { __index = function() return function() end end })
end
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
UIParent = setmetatable({}, { __index = function() return function() end end })
GameTooltip = UIParent
UISpecialFrames, SlashCmdList = {}, {}
tinsert = table.insert

-- Build a fresh addon namespace with Core+UI+Profiles loaded and one fake module.
-- `libstub` is installed as the global LibStub BEFORE Profiles loads, so the
-- LibDeflate probe (file scope) picks it up or not, per path under test.
local function setup(libstub)
    LibStub = libstub
    local ns = {}
    local function load(p) assert(loadfile(p))("OppositeQOL", ns) end
    load("Core.lua"); load("UI.lua"); load("Profiles.lua")
    local mod = { name = "A", default = true, defaults = { level = 1 } }
    function mod:OnInitialize() ns.db.a = ns.db.a or {}; self.db = ns.db.a; ns.DeepMerge(self.db, self.defaults) end
    ns:RegisterModule("a", mod)
    OppositeQOLDB = nil
    ns:Initialize()
    return ns
end

local ok = true
local function check(name, cond)
    print((cond and "PASS " or "FAIL ") .. name)
    ok = ok and (cond and true or false)
end

-- ===========================================================================
-- Raw path (no LibDeflate)
-- ===========================================================================
local ns = setup(nil)
local P = ns.Profiles

-- serializer round-trips nested tables incl. strings with spaces / delimiters
local sample = { a = 1, b = "has space and }:{ chars", c = true, d = { 1, 2, x = 0.25 } }
local round = P.Deserialize(P.Serialize(sample))
check("serialize round-trips numbers/strings/bools/nesting",
    round.a == 1 and round.b == "has space and }:{ chars" and round.c == true
    and round.d[1] == 1 and round.d[2] == 2 and round.d.x == 0.25)

-- set a distinctive value, save as a named profile, export it
ns.db.a.level = 7
ns:SaveProfileAs("My Raid")          -- name with a space exercises the string codec
local str = P:Export("My Raid")
check("raw export carries the !OQOL0! prefix", str:sub(1, 7) == "!OQOL0!")
check("raw export has no whitespace (chat-paste safe)", not str:find("%s"))

local payload = P:Decode(str)
check("decode returns the profile payload",
    payload and payload.kind == "profile" and payload.name == "My Raid"
    and payload.modules.a.level == 7)

-- import into a different name and confirm it becomes active with the values
ns:SwitchProfile("Default")
local imok, imname = P:ImportFromString(str, "Imported")
check("import succeeds", imok == true and imname == "Imported")
check("imported profile is active with imported values",
    ns:ActiveProfile() == "Imported" and ns.db.a.level == 7)

-- ---- error paths ----
check("bad prefix rejected", (function()
    local res, err = P:Decode("not-a-real-string")
    return res == nil and type(err) == "string"
end)())

-- deflate-tagged string with LibDeflate absent -> helpful error
check("deflate string without LibDeflate gives guidance",
    (function()
        local _, err = P:Decode("!OQOL1!whatever")
        return type(err) == "string" and err:find("LibDeflate")
    end)())

-- ===========================================================================
-- LibDeflate-present branch (fake, print-safe hex codec so no whitespace leaks)
-- ===========================================================================
local fake = {
    CompressDeflate   = function(_, s) return "C" .. s end,
    DecompressDeflate = function(_, s) return (s:gsub("^C", "")) end,
    EncodeForPrint    = function(_, s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end,
    DecodeForPrint    = function(_, s) return (s:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)) end,
}
local nsD = setup(function(name) if name == "LibDeflate" then return fake end end)
local PD = nsD.Profiles
nsD.db.a.level = 5
nsD:SaveProfileAs("Compressed")
local dstr = PD:Export("Compressed")
check("deflate export carries the !OQOL1! prefix", dstr:sub(1, 7) == "!OQOL1!")
check("deflate export has no whitespace", not dstr:find("%s"))
nsD:SwitchProfile("Default")
local dok = PD:ImportFromString(dstr, "FromCompressed")
check("deflate round-trip imports the values",
    dok == true and nsD:ActiveProfile() == "FromCompressed" and nsD.db.a.level == 5)

-- version gate: a payload claiming a newer version is refused with a clear message
local future = "!OQOL1!" .. fake:EncodeForPrint(fake:CompressDeflate(
    PD.Serialize({ v = 999, kind = "profile", name = "X", modules = {} })))
check("newer-version string is refused", (function()
    local pres, err = PD:Decode(future)
    return pres == nil and type(err) == "string" and err:find("newer version")
end)())

print(ok and "\nALL TESTS PASSED" or "\nSOME TESTS FAILED")
os.exit(ok and 0 or 1)
