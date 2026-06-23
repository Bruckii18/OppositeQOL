-- OppositeQOL - Config / app shell
-- The single EllesmereUI-style window: a left sidebar that lists every module
-- (name + enable toggle), and a right content pane that hosts the selected
-- module's options. Opened with /oqol. Not itself a module.
--
-- Each module renders into the pane via module:BuildOptions(parent) instead of
-- creating its own window: the shell draws the module's name as the pane header
-- (where UI.CreatePanel used to put the title + divider), so a module's option
-- layout keeps the exact y-offsets it used as a standalone window. The shell owns
-- the window chrome (drag, close, Escape, rounded backdrop) once, for all modules.

local addonName, ns = ...

local UI = ns.UI
local theme = UI.theme
local StyleFont = UI.StyleFont

local Shell = {}
ns.Config = Shell

local WIN_W, WIN_H = 880, 620
local SIDEBAR_W    = 188          -- left nav width
local CONTENT_LEFT = SIDEBAR_W + 12
local HEADER_Y     = 44           -- below the window's own title bar
local NAV_TOP      = 54           -- first nav row
local NAV_H        = 30

-- ---------------------------------------------------------------------------
-- Sidebar nav row: click the row to select the module; the toggle enables it.
-- ---------------------------------------------------------------------------
local function CreateNavRow(shell, key, y)
    local m = ns.modules[key]
    local row = CreateFrame("Button", nil, shell.frame)
    row:SetHeight(NAV_H)
    row:SetPoint("TOPLEFT", 12, y)
    row:SetWidth(SIDEBAR_W - 24)

    local hl = row:CreateTexture(nil, "BACKGROUND")     -- hover / selected fill
    hl:SetAllPoints()
    hl:SetColorTexture(theme.accent[1], theme.accent[2], theme.accent[3], 0.12)
    hl:Hide()

    local sel = UI.Sharp(row:CreateTexture(nil, "ARTWORK"))  -- selected left bar
    sel:SetWidth(2)
    sel:SetPoint("TOPLEFT", 0, 0)
    sel:SetPoint("BOTTOMLEFT", 0, 0)
    sel:SetColorTexture(theme.accent[1], theme.accent[2], theme.accent[3], 1)
    sel:Hide()

    local name = row:CreateFontString(nil, "OVERLAY")
    StyleFont(name, 13, theme.text)
    name:SetPoint("LEFT", 12, 0)
    name:SetText(m.name or key)

    local toggle = UI.CreateToggle(row)
    toggle:SetPoint("RIGHT", -4, 0)
    toggle:SetScript("OnClick", function(self)
        ns:SetModuleEnabled(key, not self:GetChecked())   -- Refresh() repaints the check
    end)

    row:SetScript("OnEnter", function() if not row._selected then hl:Show() end end)
    row:SetScript("OnLeave", function() if not row._selected then hl:Hide() end end)
    row:SetScript("OnClick", function() shell:Select(key) end)

    row._hl, row._sel, row._name, row._toggle = hl, sel, name, toggle
    return row
end

-- Build the content host for one module (lazily). The shell paints the module
-- name + accent divider at the top (mirroring the old window header), then asks
-- the module to fill the rest.
function Shell:EnsurePage(key)
    if self.pages[key] then return self.pages[key] end
    local m = ns.modules[key]

    local host = CreateFrame("Frame", nil, self.frame)
    host:SetPoint("TOPLEFT", self.frame, "TOPLEFT", CONTENT_LEFT, -HEADER_Y)
    host:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -16, 14)

    local title = host:CreateFontString(nil, "OVERLAY")
    StyleFont(title, 16, theme.text)
    title:SetPoint("TOPLEFT", 4, -10)
    title:SetText(m.name or key)

    local div = UI.Sharp(host:CreateTexture(nil, "ARTWORK"))
    div:SetColorTexture(theme.accent[1], theme.accent[2], theme.accent[3], 0.5)
    div:SetHeight(1)
    div:SetPoint("TOPLEFT", 4, -34)
    div:SetPoint("TOPRIGHT", -4, -34)

    -- "module is off" notice, shown instead of options when disabled.
    local off = host:CreateFontString(nil, "OVERLAY")
    StyleFont(off, 13, theme.textDim)
    off:SetPoint("TOPLEFT", 4, -52)
    off:SetText("This module is disabled. Enable it with the switch on the left.")
    off:Hide()
    host._offNotice = off

    -- The module builds its own options into `host` at its usual offsets (~-42+),
    -- below the header divider. Built once; reused on later selections.
    if m.BuildOptions then m:BuildOptions(host) end
    self.pages[key] = host
    return host
end

-- ---------------------------------------------------------------------------
-- Selection / show
-- ---------------------------------------------------------------------------
function Shell:Select(key)
    if not self.frame then self:Build() end
    self:EnsurePage(key)
    for k, host in pairs(self.pages) do host:SetShown(k == key) end
    for k, row in pairs(self.navRows) do
        local on = (k == key)
        row._selected = on
        row._sel:SetShown(on)
        row._hl:SetShown(on)
    end
    -- show the "disabled" notice over a module that's off (its options stay built)
    local host = self.pages[key]
    if host._offNotice then host._offNotice:SetShown(not ns:IsModuleEnabled(key)) end
    self.current = key
end

function Shell:Build()
    local f = UI.CreatePanel({
        name = "OppositeQOLConfigFrame", width = WIN_W, height = WIN_H,
        title = "OppositeQOL", subtitle = "Settings", posKey = "config",
    })
    self.frame = f
    self.pages, self.navRows = {}, {}

    local navHdr = f:CreateFontString(nil, "OVERLAY")
    StyleFont(navHdr, 11, theme.textDim)
    navHdr:SetPoint("TOPLEFT", 16, -(NAV_TOP - 18))
    navHdr:SetText("MODULES")

    local vdiv = UI.Sharp(f:CreateTexture(nil, "ARTWORK"))
    vdiv:SetColorTexture(theme.borderHi[1], theme.borderHi[2], theme.borderHi[3], 1)
    vdiv:SetWidth(1)
    vdiv:SetPoint("TOPLEFT", SIDEBAR_W, -HEADER_Y)
    vdiv:SetPoint("BOTTOMLEFT", SIDEBAR_W, 14)

    local y = -NAV_TOP
    for _, key in ipairs(ns.moduleOrder) do
        self.navRows[key] = CreateNavRow(self, key, y)
        y = y - NAV_H
    end

    -- Settings profiles open in their own manager (Profiles.lua).
    local profBtn = UI.CreateFlatButton(f, "Profiles", SIDEBAR_W - 24, 22, theme.accent)
    profBtn:SetPoint("BOTTOMLEFT", 12, 14)
    profBtn:SetScript("OnClick", function() if ns.Profiles then ns.Profiles:Toggle() end end)

    self:Refresh()
end

-- ---------------------------------------------------------------------------
-- Public API (slash + minimap + module Open/Toggle delegation)
-- ---------------------------------------------------------------------------
function Shell:Open()
    if not self.frame then self:Build() end
    if not self.current then self:Select(ns.moduleOrder[1]) end
    self.frame:Show()
end

function Shell:Toggle()
    if not self.frame then self:Build(); self:Open(); return end
    if self.frame:IsShown() then self.frame:Hide() else self:Open() end
end

-- A module asks the shell to show its page (its :Open()/:Toggle() delegate here).
function Shell:OpenModule(key)
    self:Select(key)
    self.frame:Show()
end

function Shell:ToggleModule(key)
    if not self.frame then self:Build() end
    if self.frame:IsShown() and self.current == key then
        self.frame:Hide()
    else
        self:OpenModule(key)
    end
end

-- Sync the sidebar with live module-enabled flags (Core calls this on toggle /
-- profile change). Safe before the window is built.
function Shell:Refresh()
    if not self.navRows then return end
    for key, row in pairs(self.navRows) do
        local m = ns.modules[key]
        row._toggle:SetChecked(m.enabled)
        local c = m.enabled and theme.text or theme.textDim
        row._name:SetTextColor(c[1], c[2], c[3])
    end
    if self.current and self.pages[self.current] and self.pages[self.current]._offNotice then
        self.pages[self.current]._offNotice:SetShown(not ns:IsModuleEnabled(self.current))
    end
end
