-- OppositeQOL - Config
-- The "hub" window: lists every registered module with an on/off toggle and an
-- Open button. Opened with /oqol. Always available (it is not itself a module).

local addonName, ns = ...

local UI = ns.UI
local theme = UI.theme

local Config = {}
ns.Config = Config

local ROW_H, ROW_GAP, TOP = 44, 6, 64

local function CreateRow(parent, key)
    local m = ns.modules[key]

    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetHeight(ROW_H)
    UI.ApplyBackdrop(row, theme.bgInput, theme.borderHi)

    local toggle = UI.CreateToggle(row)
    toggle:SetPoint("LEFT", 10, 0)
    toggle:SetScript("OnClick", function(self)
        ns:SetModuleEnabled(key, not self:GetChecked())
    end)
    row.toggle = toggle

    local nameFS = row:CreateFontString(nil, "OVERLAY")
    UI.StyleFont(nameFS, 14, theme.text)
    nameFS:SetPoint("TOPLEFT", 40, -7)
    nameFS:SetText(m.name or key)

    local descFS = row:CreateFontString(nil, "OVERLAY")
    UI.StyleFont(descFS, 11, theme.textDim)
    descFS:SetPoint("TOPLEFT", 40, -24)
    descFS:SetWidth(260)
    descFS:SetJustifyH("LEFT")
    descFS:SetText(m.desc or "")

    local openBtn = UI.CreateFlatButton(row, "Open", 60, 20, theme.accent)
    openBtn:SetPoint("RIGHT", -10, 0)
    openBtn:SetScript("OnClick", function()
        if m.Open then m:Open() elseif m.Toggle then m:Toggle() end
    end)
    row.openBtn = openBtn

    return row
end

function Config:Build()
    local f = UI.CreatePanel({
        name     = "OppositeQOLConfigFrame",
        width    = 440,
        height   = 200,
        title    = "OppositeQOL",
        subtitle = "Modules",
        posKey   = "config",
    })
    self.frame = f

    local intro = f:CreateFontString(nil, "OVERLAY")
    UI.StyleFont(intro, 12, theme.textDim)
    intro:SetPoint("TOPLEFT", 16, -42)
    intro:SetText("Toggle modules on or off. Changes apply immediately.")

    self.rows = {}
    self:Populate()
end

-- (Re)lay out one row per registered module.
function Config:Populate()
    local f = self.frame
    local y = -TOP
    local count = 0

    for _, key in ipairs(ns.moduleOrder) do
        count = count + 1
        local row = self.rows[key]
        if not row then
            row = CreateRow(f, key)
            self.rows[key] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 16, y)
        row:SetPoint("TOPRIGHT", -16, y)
        row:Show()
        y = y - (ROW_H + ROW_GAP)
    end

    f:SetHeight(TOP + count * (ROW_H + ROW_GAP) + 12)
    self:Refresh()
end

-- Sync toggle + open-button states with the live module flags.
function Config:Refresh()
    if not self.rows then return end
    for key, row in pairs(self.rows) do
        local m = ns.modules[key]
        row.toggle:SetChecked(m.enabled)
        if m.hasUI then
            row.openBtn:Show()
            row.openBtn:SetDisabled(not m.enabled)
        else
            row.openBtn:Hide()
        end
    end
end

function Config:Open()
    if not self.frame then self:Build() else self:Populate() end
    self.frame:Show()
end

function Config:Toggle()
    if not self.frame then
        self:Build()
        self.frame:Show()
    elseif self.frame:IsShown() then
        self.frame:Hide()
    else
        self:Open()
    end
end
