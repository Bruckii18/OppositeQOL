-- OppositeQOL - UI
-- Shared dark/flat theme and widget helpers (ElvUI / NaowhUI tone) used by all
-- modules so the suite looks consistent. Tweak `theme` to match your accent.

local addonName, ns = ...

local UI = {}
ns.UI = UI

-- Bundled logo (Media\...tga). Texture paths drop the extension; WoW resolves
-- .tga/.blp. Shared by the window headers, the minimap button and the .toc icon.
UI.LOGO = "Interface\\AddOns\\OppositeQOL\\Media\\Opposite_HB_Discord_128x128"

UI.theme = {
    bg         = { 0.05, 0.05, 0.06, 0.96 }, -- main panel
    bgInput    = { 0.09, 0.09, 0.10, 1 },    -- input box / list cells
    bgButton   = { 0.11, 0.11, 0.12, 1 },    -- button rest
    bgButtonHi = { 0.17, 0.17, 0.19, 1 },    -- button hover
    border     = { 0, 0, 0, 1 },             -- 1px ElvUI-style black border
    borderHi   = { 0.18, 0.18, 0.20, 1 },    -- subtle inner border on cells
    text       = { 0.86, 0.86, 0.88, 1 },
    textDim    = { 0.46, 0.46, 0.50, 1 },
    accent     = { 0.20, 0.74, 0.92, 1 },    -- cool cyan accent
    green      = { 0.40, 0.85, 0.47, 1 },    -- on / invite
    red        = { 0.92, 0.38, 0.38, 1 },    -- off / remove
    rowHover   = { 1, 1, 1, 0.05 },
}
local theme = UI.theme

UI.FONT     = "Fonts\\ARIALN.TTF"  -- condensed, clean (ElvUI default vibe)
UI.BACKDROP = {
    bgFile   = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
}
local FONT     = UI.FONT
local BACKDROP = UI.BACKDROP

function UI.ApplyBackdrop(f, bg, border)
    f:SetBackdrop(BACKDROP)
    f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
    f:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
end

function UI.StyleFont(fs, size, color, flags)
    pcall(fs.SetFont, fs, FONT, size, flags or "")
    if not fs:GetFont() then fs:SetFontObject("GameFontNormal") end
    if color then fs:SetTextColor(color[1], color[2], color[3], color[4] or 1) end
end
local StyleFont = UI.StyleFont

-- Flat, dark, hover-highlighting button. Uses SetLabel/SetDisabled so it does
-- not collide with the frame's native methods.
function UI.CreateFlatButton(parent, text, w, h, accent)
    accent = accent or theme.text
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w, h)
    b:SetBackdrop(BACKDROP)
    b:SetBackdropColor(unpack(theme.bgButton))
    b:SetBackdropBorderColor(unpack(theme.border))

    local fs = b:CreateFontString(nil, "OVERLAY")
    StyleFont(fs, 12, accent)
    fs:SetPoint("CENTER")
    fs:SetText(text)
    b._fs = fs
    b._accent = accent

    b:SetScript("OnEnter", function(self)
        if self._disabled then return end
        self:SetBackdropColor(unpack(theme.bgButtonHi))
        self:SetBackdropBorderColor(self._accent[1], self._accent[2], self._accent[3], 0.9)
    end)
    b:SetScript("OnLeave", function(self)
        self:SetBackdropColor(unpack(theme.bgButton))
        self:SetBackdropBorderColor(unpack(theme.border))
    end)

    b.SetLabel = function(self, t) self._fs:SetText(t) end
    b.SetDisabled = function(self, dis)
        self._disabled = dis and true or false
        self:SetAlpha(dis and 0.4 or 1)
        self:EnableMouse(not dis)
    end
    return b
end

-- Small checkbox-style toggle. Filled accent square when checked.
-- Use :SetChecked(bool) / :GetChecked(); attach your own OnClick.
function UI.CreateToggle(parent)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(18, 18)
    b:SetBackdrop(BACKDROP)
    b:SetBackdropColor(unpack(theme.bgInput))
    b:SetBackdropBorderColor(unpack(theme.borderHi))

    local fill = b:CreateTexture(nil, "OVERLAY")
    fill:SetPoint("TOPLEFT", 4, -4)
    fill:SetPoint("BOTTOMRIGHT", -4, 4)
    fill:SetColorTexture(unpack(theme.accent))
    fill:Hide()

    b.SetChecked = function(self, c)
        self._checked = c and true or false
        if self._checked then fill:Show() else fill:Hide() end
    end
    b.GetChecked = function(self) return self._checked end

    b:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(theme.accent[1], theme.accent[2], theme.accent[3], 0.9)
    end)
    b:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(unpack(theme.borderHi))
    end)
    return b
end

-- Themed dropdown. A flat button showing the current selection; clicking opens
-- a scrollable popup of options that closes on pick or on a click anywhere else.
--   dd:SetOptions({ "A", "B" } or { {value=1,text="A"}, ... })
--   dd:SetValue(v) / dd:GetValue()
--   dd.OnSelect = function(value) end   -- fired on user pick (not on SetValue)
function UI.CreateDropdown(parent, width, height)
    local ROWH, MAXROWS = 18, 10
    local dd = UI.CreateFlatButton(parent, "", width, height or 20, theme.text)
    dd._fs:ClearAllPoints()
    dd._fs:SetPoint("LEFT", 8, 0)
    dd._fs:SetJustifyH("LEFT")

    local arrow = dd:CreateFontString(nil, "OVERLAY")
    StyleFont(arrow, 9, theme.textDim)
    arrow:SetPoint("RIGHT", -6, 0)
    arrow:SetText("v")
    dd._fs:SetPoint("RIGHT", arrow, "LEFT", -4, 0)

    -- Full-screen catcher so a click outside the popup closes it.
    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:Hide()

    local pop = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    pop:SetFrameStrata("TOOLTIP")
    pop:SetWidth(width)
    pop:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -2)
    UI.ApplyBackdrop(pop, theme.bgInput, theme.borderHi)
    pop:Hide()
    catcher:SetScript("OnClick", function() pop:Hide() end)
    pop:SetScript("OnShow", function() catcher:Show(); pop:Raise() end)
    pop:SetScript("OnHide", function() catcher:Hide() end)
    if parent.HookScript then parent:HookScript("OnHide", function() pop:Hide() end) end

    local scroll = CreateFrame("ScrollFrame", nil, pop)
    scroll:SetPoint("TOPLEFT", 3, -3)
    scroll:SetPoint("BOTTOMRIGHT", -3, 3)
    scroll:EnableMouseWheel(true)
    local child = CreateFrame("Frame", nil, scroll)
    scroll:SetScrollChild(child)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxS = math.max(0, child:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.min(maxS, math.max(0, self:GetVerticalScroll() - delta * ROWH * 2)))
    end)

    dd._rows, dd._opts = {}, {}

    local function optValue(o) return type(o) == "table" and o.value or o end
    local function optText(o)  return type(o) == "table" and (o.text or o.value) or o end

    local function pick(value, text, fire)
        dd._value = value
        dd._fs:SetText(text or tostring(value))
        pop:Hide()
        if fire and dd.OnSelect then dd.OnSelect(value) end
    end

    function dd:SetOptions(opts)
        self._opts = opts or {}
        for i, o in ipairs(self._opts) do
            local row = self._rows[i]
            if not row then
                row = CreateFrame("Button", nil, child)
                row:SetHeight(ROWH)
                local hl = row:CreateTexture(nil, "BACKGROUND")
                hl:SetAllPoints(); hl:SetColorTexture(unpack(theme.rowHover)); hl:Hide()
                row:SetScript("OnEnter", function() hl:Show() end)
                row:SetScript("OnLeave", function() hl:Hide() end)
                local fs = row:CreateFontString(nil, "OVERLAY")
                StyleFont(fs, 12, theme.text)
                fs:SetPoint("LEFT", 6, 0); fs:SetPoint("RIGHT", -6, 0); fs:SetJustifyH("LEFT")
                row._fs = fs
                self._rows[i] = row
            end
            row._val, row._txt = optValue(o), optText(o)
            row._fs:SetText(row._txt)
            row:SetScript("OnClick", function() pick(row._val, row._txt, true) end)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -(i - 1) * ROWH)
            row:SetPoint("TOPRIGHT", 0, -(i - 1) * ROWH)
            row:Show()
        end
        for i = #self._opts + 1, #self._rows do self._rows[i]:Hide() end
        pop:SetHeight(math.min(#self._opts, MAXROWS) * ROWH + 6)
        child:SetSize(width - 6, #self._opts * ROWH)
    end

    function dd:SetValue(value)
        for _, o in ipairs(self._opts) do
            if optValue(o) == value then pick(optValue(o), optText(o), false); return end
        end
        dd._value = value
        dd._fs:SetText(tostring(value))
    end
    function dd:GetValue() return dd._value end

    dd:SetScript("OnClick", function()
        if pop:IsShown() then pop:Hide() else pop:Show() end
    end)
    return dd
end

-- Build a themed, draggable, closable window with a title + accent subtitle +
-- divider. opts: { name, width, height, title, subtitle, posKey }
-- posKey persists position under ns.db[posKey].pos.
function UI.CreatePanel(opts)
    local f = CreateFrame("Frame", opts.name, UIParent, "BackdropTemplate")
    f:SetSize(opts.width, opts.height)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    UI.ApplyBackdrop(f, theme.bg, theme.border)

    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    local posKey = opts.posKey
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if posKey then
            local point, _, relPoint, x, y = self:GetPoint()
            ns.db[posKey] = ns.db[posKey] or {}
            ns.db[posKey].pos = { point, relPoint, x, y }
        end
    end)

    local saved = posKey and ns.db[posKey] and ns.db[posKey].pos
    if saved then
        f:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
    else
        f:SetPoint("CENTER")
    end

    if opts.name then tinsert(UISpecialFrames, opts.name) end  -- close with Escape

    local logo = f:CreateTexture(nil, "OVERLAY")
    logo:SetSize(20, 20)
    logo:SetPoint("TOPLEFT", 12, -10)
    logo:SetTexture(UI.LOGO)
    f.logo = logo

    local title = f:CreateFontString(nil, "OVERLAY")
    StyleFont(title, 15, theme.text)
    title:SetPoint("LEFT", logo, "RIGHT", 6, 0)
    title:SetText(opts.title or "OppositeQOL")
    f.titleFS = title

    if opts.subtitle then
        local sub = f:CreateFontString(nil, "OVERLAY")
        StyleFont(sub, 15, theme.accent)
        sub:SetPoint("LEFT", title, "RIGHT", 7, 0)
        sub:SetText(opts.subtitle)
    end

    local close = UI.CreateFlatButton(f, "X", 22, 18, theme.red)
    close:SetPoint("TOPRIGHT", -8, -10)
    close:SetScript("OnClick", function() f:Hide() end)

    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(theme.accent[1], theme.accent[2], theme.accent[3], 0.5)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", 14, -34)
    divider:SetPoint("TOPRIGHT", -14, -34)

    return f
end
