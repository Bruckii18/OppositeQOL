-- Standalone logic test for the shared UI widget factory (UI.lua). Stubs the WoW
-- API with a chainable widget mock that also stores script handlers (so click and
-- drag callbacks can be invoked), then verifies the colour helper, the snap math,
-- the widget constructors' (frame, rowHeight) contract, the UI.Page y-cursor, and
-- a slider's get/set round-trip. Visual effects (pixel snapping, striping, scroll
-- clipping) are in-game only and are covered here only as "constructs without error".
-- Run from the project root:  luajit tests/test_ui.lua

-- ---- per-object widget mock with retrievable scripts ----
local function newWidget()
    local store = { scripts = {} }
    local w = {}
    setmetatable(w, { __index = function(_, k)
        return function(self, a, b)
            if k == "CreateFontString" or k == "CreateTexture"
                or k == "CreateMaskTexture" then return newWidget()
            elseif k == "SetText" then store.text = a; return
            elseif k == "GetText" then return store.text or ""
            elseif k == "SetHeight" then store.height = a; return
            elseif k == "GetHeight" then return store.height or 100
            elseif k == "SetWidth" then store.width = a; return
            elseif k == "GetWidth" then return store.width or 100
            elseif k == "GetLeft" then return store.left or 0
            elseif k == "GetEffectiveScale" then return 1
            elseif k == "GetVerticalScroll" then return store.vscroll or 0
            elseif k == "SetVerticalScroll" then store.vscroll = a; return
            elseif k == "SetChecked" then store.checked = a and true or false; return
            elseif k == "GetChecked" then return store.checked
            elseif k == "SetScript" then store.scripts[a] = b; return
            elseif k == "GetScript" then return store.scripts[a]
            elseif k == "Show" then store.shown = true; return
            elseif k == "Hide" then store.shown = false; return
            elseif k == "IsShown" then return store.shown
            elseif k == "GetObjectType" then return "Frame"
            else return self end
        end
    end })
    return w
end

CreateFrame = function() return newWidget() end
UIParent = newWidget()
GameTooltip = newWidget()
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
UISpecialFrames, SlashCmdList = {}, {}
tinsert = table.insert
GetPhysicalScreenSize = function() return 2560, 1440 end
GetCursorPosition = function() return 75, 0 end   -- maps to mid-track below

-- ---- load the real files into one shared namespace ----
local ns = {}
local function load(path) assert(loadfile(path))("OppositeQOL", ns) end
load("Core.lua")
load("UI.lua")

local UI = ns.UI
local theme = UI.theme

-- ===========================================================================
local ok = true
local function check(name, cond)
    print((cond and "PASS " or "FAIL ") .. name)
    ok = ok and (cond and true or false)
end

-- ---- colour helper: single source of truth, round-trips the theme hexes ----
check("Hex(accent) == ff2fe3c4 (teal default)", UI.Hex(theme.accent) == "ff2fe3c4")
check("Hex(green)  == ff66d977", UI.Hex(theme.green) == "ff66d977")
check("Hex(red)    == ffeb6161", UI.Hex(theme.red) == "ffeb6161")

-- ---- selectable colour palettes ----
check("palettes defined", type(UI.palettes) == "table" and #UI.palettes >= 2)
check("PaletteByKey finds cyan", UI.PaletteByKey("cyan") ~= nil)
check("ApplyPalette('cyan') recolours the accent",
    (function() UI.ApplyPalette("cyan"); return UI.Hex(theme.accent) == "ff33bce8" end)())
check("ApplyPalette sets a secondary accent", type(theme.accent2) == "table")
check("ApplyPalette unknown key falls back to first", UI.ApplyPalette("nope") == UI.palettes[1].key)
UI.ApplyPalette("teal")   -- restore default for the rest of the suite
check("ApplyPalette('teal') restores teal", UI.Hex(theme.accent) == "ff2fe3c4")

-- ---- snap math (pure) ----
check("Snap mid step",   UI.Snap(5.4, 0, 10, 1) == 5)
check("Snap clamps low",  UI.Snap(-3, 0, 10, 1) == 0)
check("Snap clamps high", UI.Snap(99, 0, 10, 1) == 10)
check("Snap quarter step", UI.Snap(0.30, 0, 1, 0.25) == 0.25)

-- ---- Px returns a positive number ----
check("Px positive", type(UI.Px(UIParent)) == "number" and UI.Px(UIParent) > 0)

-- ---- widget constructors return (frame, documented rowHeight) ----
local parent = newWidget()
local function second(_, h) return h end

local hdr, hH = UI.CreateSectionHeader(parent, "Section", -16)
check("SectionHeader returns frame+HEADER_H", hdr and hH == UI.HEADER_H)

local cval = false
local crow, cH = UI.CreateCheckRow(parent, "Check", -40, function() return cval end,
    function(v) cval = v end, "tip")
check("CheckRow returns frame+ROW_H", crow and cH == UI.ROW_H)

-- invoke the stored OnClick to confirm the get/set closure round-trips
local toggle = crow.control
toggle:GetScript("OnClick")(toggle)
check("CheckRow click flips bound value", cval == true)

local srow, sH = UI.CreateSlider(parent, "Slider", -68, 0, 10, 1,
    function() return 3 end, function(v) srow_value = v end)
check("Slider returns frame+ROW_H", srow and sH == UI.ROW_H)

-- drive a drag: OnDragStart installs OnUpdate=commit; run one commit tick.
local thumb = srow.control
thumb:GetScript("OnDragStart")(thumb)
thumb:GetScript("OnUpdate")(thumb)
check("Slider drag commits a snapped value (mid-track -> 5)", srow_value == 5)

local drow, dH = UI.CreateDropdownRow(parent, "Pick", -96, { "A", "B" },
    function() return "A" end, function() end)
check("DropdownRow returns frame+ROW_H", drow and dH == UI.ROW_H)

local clicked = false
local brow, bH = UI.CreateButtonRow(parent, "Go", -124, function() clicked = true end)
check("ButtonRow returns frame+ROW_H+4", brow and bH == UI.ROW_H + 4)
brow.control:GetScript("OnClick")(brow.control)
check("ButtonRow click fires callback", clicked == true)

local _, spH = UI.CreateSpacer(parent, -152, 12)
check("Spacer returns its height", spH == 12)

-- ---- UI.Page y-cursor advances by each row's height ----
local page = UI.Page(parent)             -- starts at -PAD
page:Header("A")                          -- -HEADER_H
page:Check("x", function() return false end, function() end)  -- -ROW_H
page:Spacer(10)                           -- -10
-- Height = top pad + content + bottom pad  (the documented -y + PAD formula)
local expected = UI.PAD + (UI.HEADER_H + UI.ROW_H + 10) + UI.PAD
check("Page:Height() sums rows + symmetric pad", page:Height() == expected)

-- ---- scroll area constructs and exposes its updater ----
check("CreateScrollArea returns scroll+child", (function()
    local s, c = UI.CreateScrollArea(newWidget(), 30, 10)
    return s ~= nil and c ~= nil and type(s.UpdateScrollBar) == "function"
end)())

-- The child starts at width 1; once the viewport has a real width the updater
-- must sync the child to it, or content anchored to the child's right edge (the
-- Externals spell rows) collapses to zero width and is clipped.
check("CreateScrollArea syncs child width to the viewport", (function()
    local s, c = UI.CreateScrollArea(newWidget(), 30, 10)
    s:SetWidth(321)            -- the laid-out viewport width
    s.UpdateScrollBar()        -- same path OnSizeChanged drives in game
    return c:GetWidth() == 321
end)())

-- ---- card primitive constructs (titled + untitled) ----
check("CreateCard with title constructs", UI.CreateCard(newWidget(), "Section") ~= nil)
check("CreateCard without title constructs", UI.CreateCard(newWidget()) ~= nil)

-- ---- rounded backdrop: flat path unchanged, rounded path constructs ----
check("ApplyBackdrop flat path runs", pcall(UI.ApplyBackdrop, newWidget(), theme.bg, theme.border))
check("ApplyBackdrop rounded path runs",
    pcall(UI.ApplyBackdrop, newWidget(), theme.bg, theme.borderHi, true))
check("ApplyRoundedBackdrop is idempotent (reuses textures)", (function()
    local f = newWidget()
    UI.ApplyRoundedBackdrop(f, theme.bgInput, theme.accent)
    return pcall(UI.ApplyRoundedBackdrop, f, theme.bgInput, theme.accent)
end)())

print(ok and "\nALL TESTS PASSED" or "\nSOME TESTS FAILED")
os.exit(ok and 0 or 1)
