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
    -- accent / accent2 are the THEMED pair (see UI.palettes); ApplyPalette swaps
    -- them at login. The greys above + the semantic green/red below stay constant.
    accent     = { 0x2f/255, 0xe3/255, 0xc4/255, 1 },  -- primary accent (default: Ellesmere teal)
    accent2    = { 0x18/255, 0xb3/255, 0x9a/255, 1 },  -- secondary accent (glows / gradients)
    green      = { 0x66/255, 0xd9/255, 0x77/255, 1 },  -- on / invite (#66d977)
    red        = { 0xeb/255, 0x61/255, 0x61/255, 1 },  -- off / remove (#eb6161)
    rowHover   = { 1, 1, 1, 0.05 },
}
local theme = UI.theme

-- Selectable colour palettes. Each is a pair of accent colours that recolour the
-- whole suite: everything chromatic reads theme.accent / theme.accent2 (through
-- UI.Hex for chat). The greys and the semantic green/red (on/off) never change.
-- The active choice lives in ns.db.theme and is applied once at login, BEFORE any
-- window is built (Core:Initialize); switching at runtime takes full effect on a
-- /reload, since WoW bakes colours into frames when they are created.
UI.palettes = {
    { key = "teal",    name = "Teal",           accent = { 0x2f/255, 0xe3/255, 0xc4/255 }, accent2 = { 0x18/255, 0xb3/255, 0x9a/255 } },
    { key = "cyan",    name = "Cyan",           accent = { 0x33/255, 0xbc/255, 0xe8/255 }, accent2 = { 0x24/255, 0x86/255, 0xad/255 } },
    { key = "emerald", name = "Emerald",        accent = { 0x46/255, 0xd9/255, 0x8a/255 }, accent2 = { 0x1f/255, 0x9d/255, 0x63/255 } },
    { key = "amber",   name = "Amber",          accent = { 0xf0/255, 0xb4/255, 0x3c/255 }, accent2 = { 0xb0/255, 0x7d/255, 0x18/255 } },
    { key = "violet",  name = "Violet",         accent = { 0xa8/255, 0x84/255, 0xf0/255 }, accent2 = { 0x6f/255, 0x54/255, 0xc0/255 } },
    { key = "rose",    name = "Rose",           accent = { 0xe0/255, 0x52/255, 0x6c/255 }, accent2 = { 0x9c/255, 0x35/255, 0x51/255 } },
}

function UI.PaletteByKey(key)
    for _, p in ipairs(UI.palettes) do if p.key == key then return p end end
end

-- Recolour the live theme IN PLACE (so the same theme table every file localised
-- keeps working). Unknown key falls back to the first palette. Returns the key
-- actually applied.
function UI.ApplyPalette(key)
    local p = UI.PaletteByKey(key) or UI.palettes[1]
    theme.accent  = { p.accent[1],  p.accent[2],  p.accent[3],  1 }
    theme.accent2 = { p.accent2[1], p.accent2[2], p.accent2[3], 1 }
    UI.activePalette = p.key
    return p.key
end

-- "ffRRGGBB" colour-escape body from a theme colour table {r,g,b}. The single
-- source of truth for chat-text colours, so Core/CombatLog never hard-code hexes
-- that can drift from the theme (e.g. ns:Print(... UI.Hex(theme.accent) ...)).
function UI.Hex(c)
    local function b(x) return math.floor((x or 0) * 255 + 0.5) end
    return string.format("ff%02x%02x%02x", b(c[1]), b(c[2]), b(c[3]))
end

-- Layout scale shared by the widget factory below. One rhythm everywhere is most
-- of what reads as "polish": PAD insets content, ROW_H is one control row.
UI.PAD      = 16    -- left/right content inset
UI.ROW_H    = 28    -- one control row
UI.HEADER_H = 24    -- section header
UI.GAP      = 8     -- spacer between sections

-- State is expressed by mutating ALPHA, never by swapping textures: hover lifts
-- the border alpha (accent-tinted), disabled dims the whole control. Keeps the
-- look coherent and a re-theme down to a single `theme.accent` change.
UI.A = { brdHover = 0.9, disabled = 0.4, rowStripe = 0.04 }

UI.FONT     = "Fonts\\ARIALN.TTF"  -- condensed, clean (ElvUI default vibe)
UI.BACKDROP = {
    bgFile   = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
}
local FONT     = UI.FONT
local BACKDROP = UI.BACKDROP

-- Rounded-corner backdrop (self-authored 9-slice textures; see
-- tools/gen_round_texture.py). SetBackdrop only rounds via baked edge art, so the
-- modern path is a sliced Texture instead: one white rounded-rect fill + one
-- rounded outline, tinted to the theme via SetVertexColor. Extension dropped, as
-- with UI.LOGO. ROUND_MARGIN is the 9-slice corner size in the texture's NATIVE
-- pixels (>= the authored 24px radius); tune alongside the asset.
UI.ROUND_FILL   = "Interface\\AddOns\\OppositeQOL\\Media\\Opposite_RoundFill_128"
UI.ROUND_EDGE   = "Interface\\AddOns\\OppositeQOL\\Media\\Opposite_RoundEdge_128"
UI.ROUND_MARGIN = 28

-- Per-frame round textures kept in a weak-keyed side table (never new keys on the
-- frame itself -- the taint-safe pattern, and it keeps reads plain-nil).
local roundTex = setmetatable({}, { __mode = "k" })

local function sliced(f, layer, file)
    local t = f:CreateTexture(nil, layer)
    t:SetAllPoints(f)
    t:SetTexture(file)
    t:SetTextureSliceMargins(UI.ROUND_MARGIN, UI.ROUND_MARGIN, UI.ROUND_MARGIN, UI.ROUND_MARGIN)
    if Enum and Enum.UITextureSliceMode then          -- Stretched is the default; guard for tests
        t:SetTextureSliceMode(Enum.UITextureSliceMode.Stretched)
    end
    return t
end

-- Rounded fill (+ optional rounded border), recoloured from the theme each call.
function UI.ApplyRoundedBackdrop(f, bg, border)
    local t = roundTex[f]
    if not t then
        t = { fill = sliced(f, "BACKGROUND", UI.ROUND_FILL) }
        roundTex[f] = t
    end
    t.fill:SetVertexColor(bg[1], bg[2], bg[3], bg[4] or 1)
    if border then
        if not t.edge then t.edge = sliced(f, "BORDER", UI.ROUND_EDGE) end
        t.edge:SetVertexColor(border[1], border[2], border[3], border[4] or 1)
    end
end

-- Flat 1px ElvUI-style backdrop, or (rounded=true) the 9-slice rounded one. The
-- flat path is unchanged, so every existing caller keeps its look.
function UI.ApplyBackdrop(f, bg, border, rounded)
    if rounded then
        return UI.ApplyRoundedBackdrop(f, bg, border)
    end
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
    UI.ApplyBackdrop(f, theme.bg, theme.borderHi, true)   -- rounded window

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
    StyleFont(title, 17, theme.text)
    title:SetPoint("LEFT", logo, "RIGHT", 8, 1)
    title:SetText(opts.title or "OppositeQOL")
    f.titleFS = title

    if opts.subtitle then
        local sub = f:CreateFontString(nil, "OVERLAY")
        StyleFont(sub, 17, theme.accent)
        sub:SetPoint("LEFT", title, "RIGHT", 8, 0)
        sub:SetText(opts.subtitle)
    end

    local close = UI.CreateFlatButton(f, "X", 22, 18, theme.red)
    close:SetPoint("TOPRIGHT", -8, -10)
    close:SetScript("OnClick", function() f:Hide() end)

    -- Header base: a bright accent line with a soft glow fading up into the band
    -- (the EllesmereUI "aurora" cue). The gradient is guarded so the logic tests
    -- (no CreateColor) simply fall back to a faint flat tint.
    local line = UI.Sharp(f:CreateTexture(nil, "ARTWORK"))
    line:SetColorTexture(theme.accent[1], theme.accent[2], theme.accent[3], 0.85)
    line:SetHeight(2)
    line:SetPoint("TOPLEFT", 14, -34)
    line:SetPoint("TOPRIGHT", -14, -34)
    f.headerLine = line

    local glow = f:CreateTexture(nil, "ARTWORK")
    glow:SetPoint("BOTTOMLEFT", line, "TOPLEFT", 0, 0)
    glow:SetPoint("BOTTOMRIGHT", line, "TOPRIGHT", 0, 0)
    glow:SetHeight(20)
    if CreateColor and glow.SetGradient then
        glow:SetColorTexture(1, 1, 1, 1)
        glow:SetGradient("VERTICAL",
            CreateColor(theme.accent[1], theme.accent[2], theme.accent[3], 0.22),  -- bottom (at the line)
            CreateColor(theme.accent[1], theme.accent[2], theme.accent[3], 0.0))   -- top (fades out)
    else
        glow:SetColorTexture(theme.accent[1], theme.accent[2], theme.accent[3], 0.05)
    end

    return f
end

-- A lifted, bordered section card (EllesmereUI-style grouping). Pass a title for
-- an accent caps label at the top-left; size/anchor the card yourself and place
-- content inside (offset titled content ~28px down). Returns the card frame.
function UI.CreateCard(parent, title)
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card._oqolStripe = 0   -- a fresh row container: row striping starts from zero
    UI.ApplyBackdrop(card, theme.bgInput, { theme.accent[1], theme.accent[2], theme.accent[3], 0.30 }, true)  -- rounded, faint accent edge
    if title then
        local fs = card:CreateFontString(nil, "OVERLAY")
        StyleFont(fs, 11, theme.accent)
        fs:SetPoint("TOPLEFT", 12, -10)
        fs:SetText(tostring(title):upper())
        card.titleFS = fs
    end
    return card
end

-- ===========================================================================
-- Pixel snapping
-- A cyan hairline that doesn't fall on a physical pixel boundary blurs. Px gives
-- the size of one physical pixel in a frame's coordinate space; Sharp tells a 1px
-- texture not to interpolate. (Distilled from ElvUI/EllesmereUI's pixel engine --
-- no scale-watcher; our windows don't rescale at runtime.)
-- ===========================================================================
function UI.Px(frame)
    local gp = _G.GetPhysicalScreenSize
    local screenH = (gp and select(2, gp())) or 768
    local scale = (frame and frame.GetEffectiveScale and frame:GetEffectiveScale()) or 1
    return (768 / screenH) / scale
end

function UI.Sharp(tex)
    if tex.SetSnapToPixelGrid then tex:SetSnapToPixelGrid(false) end
    if tex.SetTexelSnappingBias then tex:SetTexelSnappingBias(0) end
    return tex
end

-- Snap a value to [min,max] on a step grid. Pure arithmetic, exposed for tests.
function UI.Snap(value, minVal, maxVal, step)
    if step and step > 0 then value = math.floor((value - minVal) / step + 0.5) * step + minVal end
    if value < minVal then value = minVal elseif value > maxVal then value = maxVal end
    return value
end

-- ===========================================================================
-- Widget factory
-- Every constructor takes (parent, ..., y) and returns `frame, rowHeight`, so an
-- options page assembles on a descending y-cursor (see UI.Page). Controls read
-- live values through caller-supplied get/set closures (the EllesmereUI contract).
-- ===========================================================================
local function rowFrame(parent, y, h)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(h)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", UI.PAD, y)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -UI.PAD, y)
    return row
end

-- Subtle alternating stripe so long lists stay readable. SectionHeader resets the
-- counter so each section stripes from its own top.
local function stripe(parent, row)
    parent._oqolStripe = (parent._oqolStripe or 0) + 1
    if parent._oqolStripe % 2 == 0 then
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, UI.A.rowStripe)
        if bg.SetIgnoreParentAlpha then bg:SetIgnoreParentAlpha(true) end
    end
end

local function attachTooltip(frame, text)
    if not text then return end
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(text, theme.text[1], theme.text[2], theme.text[3], true)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Dim caps label + 1px accent underline. Resets row striping for the section.
function UI.CreateSectionHeader(parent, text, y)
    parent._oqolStripe = 0
    local row = rowFrame(parent, y, UI.HEADER_H)

    local fs = row:CreateFontString(nil, "OVERLAY")
    StyleFont(fs, 11, theme.textDim)
    fs:SetPoint("BOTTOMLEFT", 0, 4)
    fs:SetText((text or ""):upper())

    local line = UI.Sharp(row:CreateTexture(nil, "ARTWORK"))
    line:SetColorTexture(theme.accent[1], theme.accent[2], theme.accent[3], 0.5)
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT", 0, 0)
    line:SetPoint("BOTTOMRIGHT", 0, 0)
    return row, UI.HEADER_H
end

-- Labelled checkbox row. get() -> bool, set(bool) on click.
function UI.CreateCheckRow(parent, label, y, getValue, setValue, tooltip)
    local row = rowFrame(parent, y, UI.ROW_H)
    stripe(parent, row)

    local toggle = UI.CreateToggle(row)
    toggle:SetPoint("LEFT", 2, 0)
    toggle:SetChecked(getValue and getValue() or false)
    toggle:SetScript("OnClick", function(self)
        local on = not self:GetChecked()
        self:SetChecked(on)
        if setValue then setValue(on) end
    end)
    row.control = toggle

    local fs = row:CreateFontString(nil, "OVERLAY")
    StyleFont(fs, 12, theme.text)
    fs:SetPoint("LEFT", toggle, "RIGHT", 8, 0)
    fs:SetText(label or "")
    attachTooltip(row, tooltip)
    return row, UI.ROW_H
end

-- Labelled slider with an accent fill and a right-hand numeric value.
function UI.CreateSlider(parent, label, y, minVal, maxVal, step, getValue, setValue, tooltip)
    local row = rowFrame(parent, y, UI.ROW_H)
    stripe(parent, row)

    local fs = row:CreateFontString(nil, "OVERLAY")
    StyleFont(fs, 12, theme.text)
    fs:SetPoint("LEFT", 2, 0)
    fs:SetText(label or "")

    local valFS = row:CreateFontString(nil, "OVERLAY")
    StyleFont(valFS, 12, theme.accent)
    valFS:SetPoint("RIGHT", -2, 0)
    valFS:SetJustifyH("RIGHT")

    -- Track + fill occupy the right ~45% of the row.
    local track = UI.Sharp(row:CreateTexture(nil, "BACKGROUND"))
    track:SetColorTexture(theme.text[1], theme.text[2], theme.text[3], 0.16)
    track:SetHeight(2)
    track:SetPoint("RIGHT", valFS, "LEFT", -10, 0)
    track:SetWidth(150)

    local fill = UI.Sharp(row:CreateTexture(nil, "BORDER"))
    fill:SetColorTexture(theme.accent[1], theme.accent[2], theme.accent[3], 0.75)
    fill:SetHeight(2)
    fill:SetPoint("LEFT", track, "LEFT", 0, 0)

    local thumb = CreateFrame("Button", nil, row)
    thumb:SetSize(12, 12)
    local th = thumb:CreateTexture(nil, "OVERLAY")
    th:SetAllPoints()
    th:SetColorTexture(theme.accent[1], theme.accent[2], theme.accent[3], 1)

    local function layout(v)
        local ratio = (maxVal > minVal) and ((v - minVal) / (maxVal - minVal)) or 0
        if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end
        local w = track:GetWidth() or 150
        fill:SetWidth(math.max(1, w * ratio))
        thumb:ClearAllPoints()
        thumb:SetPoint("CENTER", track, "LEFT", w * ratio, 0)
        local dec = (step and step < 1) and 2 or 0
        valFS:SetText(string.format("%." .. dec .. "f", v))
    end
    layout(getValue and getValue() or minVal)

    local function commit()
        local mx, _ = GetCursorPosition()
        local scale = track:GetEffectiveScale() or 1
        local left = track:GetLeft() or 0
        local w = track:GetWidth() or 150
        local ratio = w > 0 and (((mx / scale) - left) / w) or 0
        local v = UI.Snap(minVal + ratio * (maxVal - minVal), minVal, maxVal, step)
        layout(v)
        if setValue then setValue(v) end
    end
    thumb:RegisterForDrag("LeftButton")
    thumb:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", commit) end)
    thumb:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil); commit() end)
    row.control, row.SetSliderValue = thumb, layout
    attachTooltip(row, tooltip)
    return row, UI.ROW_H
end

-- Labelled dropdown row. options as for UI.CreateDropdown:SetOptions.
function UI.CreateDropdownRow(parent, label, y, options, getValue, setValue, tooltip)
    local row = rowFrame(parent, y, UI.ROW_H)
    stripe(parent, row)

    local fs = row:CreateFontString(nil, "OVERLAY")
    StyleFont(fs, 12, theme.text)
    fs:SetPoint("LEFT", 2, 0)
    fs:SetText(label or "")

    local dd = UI.CreateDropdown(row, 160, 20)
    dd:SetPoint("RIGHT", -2, 0)
    dd:SetOptions(options or {})
    if getValue then dd:SetValue(getValue()) end
    dd.OnSelect = function(value) if setValue then setValue(value) end end
    row.control = dd
    attachTooltip(row, tooltip)
    return row, UI.ROW_H
end

-- Full-width action button row.
function UI.CreateButtonRow(parent, label, y, onClick, accent)
    local row = rowFrame(parent, y, UI.ROW_H + 4)
    local b = UI.CreateFlatButton(row, label, 120, 22, accent or theme.accent)
    b:SetPoint("LEFT", 2, 0)
    b:SetScript("OnClick", function() if onClick then onClick() end end)
    row.control = b
    return row, UI.ROW_H + 4
end

function UI.CreateSpacer(parent, y, height)
    local h = height or UI.GAP
    local row = rowFrame(parent, y, h)
    return row, h
end

-- A builder bound to a parent + a mutable y cursor. Each :Method forwards to the
-- matching UI.Create* and advances the cursor by the returned row height, so a
-- page reads top-to-bottom and reorders trivially.
function UI.Page(parent, startY)
    local y = startY or -UI.PAD
    local P = { parent = parent }
    local function step(_, h) y = y - h end
    function P:Header(t)                                   step(UI.CreateSectionHeader(parent, t, y)); return self end
    function P:Check(l, get, set, tip)                     step(UI.CreateCheckRow(parent, l, y, get, set, tip)); return self end
    function P:Slider(l, mn, mx, st, get, set, tip)        step(UI.CreateSlider(parent, l, y, mn, mx, st, get, set, tip)); return self end
    function P:Dropdown(l, opts, get, set, tip)            step(UI.CreateDropdownRow(parent, l, y, opts, get, set, tip)); return self end
    function P:Button(l, fn, accent)                       step(UI.CreateButtonRow(parent, l, y, fn, accent)); return self end
    function P:Spacer(h)                                   step(UI.CreateSpacer(parent, y, h)); return self end
    function P:Y() return y end
    function P:Height() return -y + UI.PAD end
    return P
end

-- A clipped, wheel-scrollable region with a thin overlay scrollbar. Returns the
-- scroll frame and its child; fill the child with UI.Page and set its height.
function UI.CreateScrollArea(parent, topInset, bottomInset)
    topInset, bottomInset = topInset or 0, bottomInset or 0

    local scroll = CreateFrame("ScrollFrame", nil, parent)
    scroll:SetPoint("TOPLEFT", UI.PAD, -topInset)
    scroll:SetPoint("BOTTOMRIGHT", -UI.PAD, bottomInset)
    scroll:EnableMouseWheel(true)
    if scroll.SetClipsChildren then scroll:SetClipsChildren(true) end

    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(1)
    child:SetHeight(1)
    scroll:SetScrollChild(child)

    -- Thin overlay track + draggable thumb on the right edge.
    local track = scroll:CreateTexture(nil, "OVERLAY")
    track:SetColorTexture(theme.text[1], theme.text[2], theme.text[3], 0.02)
    track:SetWidth(4)
    track:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", UI.PAD - 4, 0)
    track:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", UI.PAD - 4, 0)

    local thumb = scroll:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(theme.text[1], theme.text[2], theme.text[3], 0.27)
    thumb:SetWidth(4)
    thumb:SetPoint("TOP", track, "TOP", 0, 0)
    thumb:SetHeight(30)

    local function update()
        -- Keep the scroll child as wide as the viewport. It is created at width 1
        -- (before layout the real width is unknown); without this, anything in the
        -- child anchored to its right edge collapses to zero width and is clipped
        -- (e.g. the Externals spell-row name + Alert/TTS/remove controls).
        local w = scroll:GetWidth()
        if w and w > 1 then child:SetWidth(w) end
        local viewH = scroll:GetHeight() or 1
        local contentH = child:GetHeight() or 1
        local maxScroll = math.max(0, contentH - viewH)
        local shown = maxScroll > 0.5
        track:SetShown(shown); thumb:SetShown(shown)
        if shown then
            local ratio = viewH / contentH
            thumb:SetHeight(math.max(30, viewH * ratio))
            local cur = scroll:GetVerticalScroll() or 0
            local frac = maxScroll > 0 and (cur / maxScroll) or 0
            thumb:SetPoint("TOP", track, "TOP", 0, -frac * (viewH - thumb:GetHeight()))
        end
        return maxScroll
    end

    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = math.max(0, (child:GetHeight() or 1) - (self:GetHeight() or 1))
        local v = math.min(maxScroll, math.max(0, (self:GetVerticalScroll() or 0) - delta * 40))
        self:SetVerticalScroll(v)
        update()
    end)
    scroll:SetScript("OnSizeChanged", update)
    scroll.UpdateScrollBar = update
    return scroll, child
end
