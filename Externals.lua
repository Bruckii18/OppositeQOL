-- OppositeQOL - Externals Tracker
-- Alerts you when ANOTHER player lands a key buff on you: external defensives
-- (Pain Suppression, Blessing of Protection, ...), raid defensives / utility
-- (Rallying Cry, Aura Mastery, Power Infusion, ...) and movement buffs (Freedom,
-- Stampeding Roar, Wind Rush, ...). Shows a transient on-screen icon + name and,
-- optionally, speaks the buff via the game's text-to-speech and/or plays a sound.
-- You can toggle each spell, override its spoken phrase, and add your own by ID.
--
-- DETECTION, the Midnight (12.0) way -- NOT the combat log:
--   In 12.0 the combat log is unreadable (CLEU yields nothing usable -- the
--   project's core constraint, see CLAUDE.md), so this module does the same thing
--   EllesmereUI does: it listens to UNIT_AURA scoped to the player and reads the
--   buff straight off the C_UnitAuras AuraData (updateInfo.addedAuras) -- spellId,
--   icon, sourceUnit, isFromPlayerOrPlayerPet.
--
--   One hard limitation falls out of that: an aura's sourceUnit (its caster) is a
--   SECRET VALUE while in combat -- Lua can't even branch on it (issecretvalue()
--   is true). Since externals are cast mid-pull, the caster is usually unknowable
--   exactly when it matters, so we deliberately DON'T try to name the caster; the
--   alert announces the spell only. spellId / icon stay readable, so the "which
--   buff landed" alert + TTS work reliably. Every combat-time read is wrapped in
--   the same isSecret() guard EllesmereUI uses, and self-cast exclusion is
--   best-effort (it too is secret in combat; most tracked externals aren't
--   self-castable anyway).
--
-- COUNTDOWN: the banner counts down the buff's remaining time on its icon. Out
--   of combat we read aura.expirationTime / duration straight off the AuraData;
--   in combat both are secret values, so we fall back to a per-spell known-
--   duration table (BASELINE `dur`) counted from GetTime() -- the same hardcoded-
--   duration trick NaowhQOL's Time Spiral tracker uses. Ground effects (AMZ,
--   Darkness) carry no buff timer (duration 0) -- those show the banner with no
--   countdown and clear on removal. An "unlock" mode shows a draggable sample
--   banner so the alert can be positioned without a real cast.

local addonName, ns = ...

local UI = ns.UI
local theme = UI.theme
local StyleFont = UI.StyleFont

local M = {}
ns.Externals = M
ns:RegisterModule("externals", M)

M.name    = "Externals Tracker"
M.desc    = "Alerts when other players cast key defensives / utilities on you."
M.default = true
M.hasUI   = true

-- Defaults DeepMerge'd into ns.db.externals on load + every profile switch (never
-- overwrites saved values). The module on/off switch (ns.db.modules.externals) is
-- the real master; these are output preferences. The baseline spell list lives in
-- code (BASELINE below), so spellSettings only ever stores user OVERRIDES and old
-- profiles pick up new baseline spells for free -- no migration needed.
M.defaults = {
    ttsVoice      = nil,             -- chosen TTS voiceID (global, all spells); nil = first installed
    fadeTime      = 4,               -- fallback hold (sec) for buffs whose duration can't be read
    throttle      = 2,               -- ignore the same spell if it re-lands within Ns
    showCountdown = true,            -- paint the remaining-time number on the alert icon
    unlocked      = false,           -- show a draggable placeholder so the banner can be positioned
    -- Per-spell output, keyed by spellID. Each is the OVERRIDE of the defaults:
    --   text  = show the on-screen banner (default true)
    --   audio = "off" | "tts" | "sound"  (default "tts")
    --   sound = sound name when audio == "sound"
    --   ttsText = spoken phrase override when audio == "tts"
    spellSettings = {},
    customSpells  = {},              -- [spellID] = true  (user-added IDs; a set)
}

-- ---------------------------------------------------------------------------
-- Modern API handles + the in-combat "secret value" guard (see header).
-- ---------------------------------------------------------------------------
-- C_Spell.GetSpellInfo(id) -> table { name, iconID, ... } or nil. We must always
-- nil-check before indexing it; the legacy GetSpellInfo/GetSpellTexture globals
-- are intentionally NOT used (forbidden on 12.0+).
local C_Spell = _G.C_Spell
local C_UnitAuras = _G.C_UnitAuras
-- issecretvalue() may be absent on older clients; treat "not secret" as the
-- default so the guard is a harmless no-op there.
local isSecret = _G.issecretvalue or function() return false end

local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local DEFAULT_SOUND = "Raid Warning"   -- sound a spell uses when first set to "sound"

-- ---------------------------------------------------------------------------
-- Baseline tracked spells (code, not saved data). Each: name, category, default
-- spoken phrase, and `dur` = the buff's at-application length in seconds.
--
-- `dur` is ONLY the in-combat fallback for the on-screen countdown: mid-pull the
-- aura's expirationTime / duration come back as SECRET VALUES (unbranchable), so
-- we count down from this known length instead. Whenever the live value IS
-- readable (out of combat) it always wins -- see M:ResolveExpiry. So an off-by-a-
-- second here only ever shows in combat; values are the live tooltip durations.
--
-- Ground effects (Anti-Magic Zone, Darkness) have NO buff timer -- you hold the
-- aura only while standing in them -- so they OMIT `dur`: the alert shows the
-- banner with no countdown. (Out of combat a readable duration of 0 makes
-- ResolveExpiry do this automatically; omitting `dur` keeps it banner-only in
-- combat too.) Categories order the list; "Custom" user-added IDs likewise have
-- no `dur`, so they fall back to the fixed fadeTime hold.
-- ---------------------------------------------------------------------------
local BASELINE = {
    -- External defensives
    [33206]  = { name = "Pain Suppression",         cat = "External", tts = "Pain Suppression", dur = 8 },
    [47788]  = { name = "Guardian Spirit",          cat = "External", tts = "Guardian Spirit",  dur = 10 },
    [102342] = { name = "Ironbark",                 cat = "External", tts = "Ironbark",         dur = 12 },
    [116849] = { name = "Life Cocoon",              cat = "External", tts = "Cocoon",           dur = 12 },
    [1022]   = { name = "Blessing of Protection",   cat = "External", tts = "BOP",              dur = 10 },
    [6940]   = { name = "Blessing of Sacrifice",    cat = "External", tts = "SAC",              dur = 12 },
    [204018] = { name = "Blessing of Spellwarding", cat = "External", tts = "Spellwarding",     dur = 10 },
    [357170] = { name = "Time Dilation",            cat = "External", tts = "Time Dilation",    dur = 8 },
    [53480]  = { name = "Roar of Sacrifice",        cat = "External", tts = "Pet Sac",          dur = 12 },

    -- Raid defensives & utility (buff auras)
    [97462]  = { name = "Rallying Cry",             cat = "Raid",     tts = "Rallying Cry",     dur = 10 },
    [31821]  = { name = "Aura Mastery",             cat = "Raid",     tts = "Aura Mastery",     dur = 8 },
    [145629] = { name = "Anti-Magic Zone",          cat = "Raid",     tts = "AMZ" },   -- ground effect: no buff timer -> no countdown
    [374227] = { name = "Zephyr",                   cat = "Raid",     tts = "Zephyr",           dur = 8 },
    [414660] = { name = "Mass Barrier",             cat = "Raid",     tts = "Mass Barrier",     dur = 10 },
    [29166]  = { name = "Innervate",                cat = "Raid",     tts = "Innervate",        dur = 10 },
    [64901]  = { name = "Symbol of Hope",           cat = "Raid",     tts = "Symbol of Hope",   dur = 5 },
    [265314] = { name = "Power Infusion",           cat = "Raid",     tts = "Power Infusion",   dur = 20 },

    -- Movement utilities
    [1044]   = { name = "Blessing of Freedom",      cat = "Movement", tts = "Freedom on you",   dur = 8 },
    [116841] = { name = "Tiger's Lust",             cat = "Movement", tts = "Tigers Lust",      dur = 6 },
    [106898] = { name = "Stampeding Roar",          cat = "Movement", tts = "Roar",             dur = 8 },
    [201627] = { name = "Wind Rush Totem",          cat = "Movement", tts = "Wind Rush",        dur = 5 },
}

local CAT_ORDER = { External = 1, Raid = 2, Movement = 3, Custom = 4 }

-- ---------------------------------------------------------------------------
-- Spell lookups (baseline overlaid with custom; effective settings).
-- ---------------------------------------------------------------------------
function M:SpellName(id)
    local b = BASELINE[id]
    if b then return b.name end
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
    if info and info.name then return info.name end   -- always nil-check the table
    return "Spell " .. tostring(id)
end

function M:SpellCat(id)
    local b = BASELINE[id]
    return (b and b.cat) or "Custom"
end

function M:SpellIcon(id)
    -- Prefer the live texture; fall back to the info table's iconID.
    if C_Spell and C_Spell.GetSpellTexture then
        local tex = C_Spell.GetSpellTexture(id)
        if tex then return tex end
    end
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
    return info and info.iconID or nil
end

-- The phrase TTS speaks: per-spell override, else the baseline default, else name.
function M:TtsText(id)
    local s = self.db.spellSettings[id]
    if s and s.ttsText and s.ttsText ~= "" then return s.ttsText end
    local b = BASELINE[id]
    if b and b.tts then return b.tts end
    return self:SpellName(id)
end

-- The live override table for a spell, created on demand.
function M:Setting(id)
    self.db.spellSettings[id] = self.db.spellSettings[id] or {}
    return self.db.spellSettings[id]
end

function M:SetSpellSetting(id, key, value)
    self:Setting(id)[key] = value
end

function M:SetTtsText(id, text)
    text = text and text:gsub("^%s+", ""):gsub("%s+$", "") or ""
    self:Setting(id).ttsText = (text ~= "" and text) or nil
end

-- Rebuild the O(1) tracked set + the display-ordered id list. Called on enable,
-- on add/remove, and after a profile switch.
function M:RebuildTracked()
    local tracked, list = {}, {}
    for id in pairs(BASELINE) do tracked[id] = true; list[#list + 1] = id end
    for id in pairs(self.db.customSpells) do
        if not tracked[id] then tracked[id] = true; list[#list + 1] = id end
    end
    table.sort(list, function(a, b)
        local ca, cb = CAT_ORDER[self:SpellCat(a)] or 9, CAT_ORDER[self:SpellCat(b)] or 9
        if ca ~= cb then return ca < cb end
        local na, nb = self:SpellName(a), self:SpellName(b)
        if na ~= nb then return na < nb end
        return a < b
    end)
    self.tracked, self.idList = tracked, list
end

-- ---------------------------------------------------------------------------
-- Custom spells (add / remove by ID)
-- ---------------------------------------------------------------------------
function M:AddCustomSpell(id)
    id = tonumber(id)
    if not id then
        ns:Print("invalid spell id.")
        return false
    end
    if BASELINE[id] then
        ns:Print(("%s is already tracked."):format(self:SpellName(id)))
        return false
    end
    -- Validate via the modern API; nil table == no such spell.
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
    if not info then
        ns:Print(("invalid spell id: %d"):format(id))
        return false
    end
    self.db.customSpells[id] = true
    self:Setting(id)   -- materialise its (default-on) settings row
    self:RebuildTracked()
    ns:Print(("now tracking %s (%d)."):format(info.name or ("spell " .. id), id))
    return true
end

function M:RemoveCustomSpell(id)
    id = tonumber(id)
    if not id or not self.db.customSpells[id] then return false end
    self.db.customSpells[id] = nil
    self.db.spellSettings[id] = nil   -- drop its overrides too
    self:RebuildTracked()
    return true
end

-- ---------------------------------------------------------------------------
-- Outputs: text-to-speech + optional sound + the per-spell throttle
-- ---------------------------------------------------------------------------
-- Per-spell time gate (seconds = db.throttle, 0 = never throttle). Modelled on
-- PrePull's duplicate-pull guard -- there's no shared throttle util in the repo.
function M:Allowed(id)
    local gap = self.db.throttle or 0
    if gap <= 0 then return true end
    local now = (GetTime and GetTime()) or 0
    self._last = self._last or {}
    if (self._last[id] or -1e9) + gap > now then return false end
    self._last[id] = now
    return true
end

-- Installed local TTS voices (12.0: C_VoiceChat.GetTtsVoices() -> array of
-- { voiceID = number, name = string }). Remote voices are a separate pool we
-- don't use. The voiceID feeds SpeakText's first argument.
function M:Voices()
    if not (C_VoiceChat and C_VoiceChat.GetTtsVoices) then return {} end
    return C_VoiceChat.GetTtsVoices() or {}
end

-- Dropdown options: { value = voiceID, text = name }.
function M:VoiceOptions()
    local opts = {}
    for _, v in ipairs(self:Voices()) do
        opts[#opts + 1] = { value = v.voiceID, text = v.name or ("Voice " .. tostring(v.voiceID)) }
    end
    return opts
end

-- Which voiceID to speak with: the saved choice if still installed, else the
-- first installed voice, else 0 (the client's default) so TTS never silently
-- targets a voice that's gone.
function M:ResolveVoiceID()
    local want = self.db.ttsVoice
    local voices = self:Voices()
    if want ~= nil then
        for _, v in ipairs(voices) do if v.voiceID == want then return want end end
    end
    if voices[1] then return voices[1].voiceID end
    return want or 0
end

function M:Speak(text)
    if not (text and C_VoiceChat and C_VoiceChat.SpeakText) then return end
    -- 12.0 signature: SpeakText(voiceID, text, rate, volume [, overlap]). The
    -- pre-12.0 `destination` (Enum.VoiceTtsDestination) argument was removed in
    -- 12.0.0, so we pass the chosen voiceID, rate 0 (normal), volume 100. pcall
    -- so a missing TTS voice or bad arg never breaks the aura path.
    pcall(C_VoiceChat.SpeakText, self:ResolveVoiceID(), text, 0, 100)
end

-- Reuse PrePull's sound pool + player so there's one sound picker in the addon
-- (built-in SOUNDKIT entries, plus LibSharedMedia if some other addon loaded it).
function M:SoundNames()
    local names = {}
    local wp = ns.WhoPulled
    if wp and wp.SoundList then
        for _, e in ipairs(wp:SoundList()) do names[#names + 1] = e.name end
    end
    return names
end

function M:PlaySound(name)
    local wp = ns.WhoPulled
    if wp and wp.PlaySoundByName then wp:PlaySoundByName(name or DEFAULT_SOUND) end
end

-- ---------------------------------------------------------------------------
-- Per-spell output model: a spell shows a banner (text) and/or an audio cue
-- (audio = "off" | "tts" | "sound"). The TTS voice is global (ResolveVoiceID).
-- ---------------------------------------------------------------------------
-- Effective output for a spell: its saved override merged over the defaults.
function M:Resolve(id)
    local s = self.db.spellSettings[id] or {}
    return {
        text  = s.text ~= false,        -- banner on by default
        audio = s.audio or "tts",       -- speak by default
        sound = s.sound or DEFAULT_SOUND,
    }
end

-- The per-spell "Alert" dropdown encodes mode + chosen sound in one value:
--   "off" | "tts" | "snd:<sound name>".
function M:AlertOptions()
    local opts = { { value = "off", text = "Off" }, { value = "tts", text = "Text-to-Speech" } }
    for _, name in ipairs(self:SoundNames()) do
        opts[#opts + 1] = { value = "snd:" .. name, text = name }
    end
    return opts
end

function M:GetAlertValue(id)
    local s = self.db.spellSettings[id] or {}
    local a = s.audio or "tts"
    if a == "sound" then return "snd:" .. (s.sound or DEFAULT_SOUND) end
    return a
end

function M:SetAlertValue(id, value)
    local s = self:Setting(id)
    local snd = type(value) == "string" and value:match("^snd:(.+)$")
    if snd then
        s.audio, s.sound = "sound", snd
    elseif value == "off" then
        s.audio = "off"
    else
        s.audio = "tts"
    end
end

-- Play the spell's configured audio once, for the dropdown's pick-preview.
function M:PreviewAlertOutput(id)
    local s = self.db.spellSettings[id] or {}
    local a = s.audio or "tts"
    if a == "tts" then self:Speak(self:TtsText(id))
    elseif a == "sound" then self:PlaySound(s.sound) end
end

-- ---------------------------------------------------------------------------
-- The on-screen alert frame (one reusable frame, movable, fades after fadeTime)
-- ---------------------------------------------------------------------------
function M:EnsureAlert()
    if self.alert then return self.alert end

    local a = CreateFrame("Frame", "OppositeQOLExternalsAlert", UIParent, "BackdropTemplate")
    a:SetSize(248, 54)
    a:SetFrameStrata("HIGH")
    UI.ApplyBackdrop(a, theme.bg, theme.borderHi)

    -- Accent top strip (the same recipe the panels use), pixel-snapped.
    local strip = UI.Sharp(a:CreateTexture(nil, "ARTWORK"))
    strip:SetColorTexture(theme.accent[1], theme.accent[2], theme.accent[3], 1)
    strip:SetHeight(2)
    strip:SetPoint("TOPLEFT", 0, 0)
    strip:SetPoint("TOPRIGHT", 0, 0)

    local icon = a:CreateTexture(nil, "ARTWORK")
    icon:SetSize(38, 38)
    icon:SetPoint("LEFT", 9, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)   -- trim the default icon border
    a.icon = icon

    -- Cooldown sweep over the icon -- only driven when the buff's full length is
    -- known (see StartCountdown). We hide Blizzard's built-in numbers and paint
    -- our own readable one on top so the remaining time is always legible.
    local cd = CreateFrame("Cooldown", nil, a, "CooldownFrameTemplate")
    cd:SetAllPoints(icon)
    if cd.SetDrawEdge then cd:SetDrawEdge(false) end
    if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(true) end
    a.cd = cd

    -- The number lives ON the cooldown frame (a child of `a`) so it paints above
    -- the sweep -- a fontstring on `a` itself would render beneath the child.
    local cdFS = cd:CreateFontString(nil, "OVERLAY")
    StyleFont(cdFS, 16, theme.accent, "OUTLINE")
    cdFS:SetPoint("CENTER", icon, "CENTER", 0, 0)
    a.cdFS = cdFS

    local nameFS = a:CreateFontString(nil, "OVERLAY")
    StyleFont(nameFS, 15, theme.text)
    nameFS:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, -2)
    nameFS:SetPoint("RIGHT", -10, 0)
    nameFS:SetJustifyH("LEFT")
    a.nameFS = nameFS

    local catFS = a:CreateFontString(nil, "OVERLAY")
    StyleFont(catFS, 11, theme.textDim)
    catFS:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 10, 2)
    catFS:SetJustifyH("LEFT")
    a.catFS = catFS

    -- Drag to reposition; remember it under ns.db.externalsAlert.pos.
    a:SetMovable(true)
    a:EnableMouse(true)
    a:RegisterForDrag("LeftButton")
    a:SetClampedToScreen(true)
    a:SetScript("OnDragStart", a.StartMoving)
    a:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        ns.db.externalsAlert = ns.db.externalsAlert or {}
        ns.db.externalsAlert.pos = { point, relPoint, x, y }
    end)
    local saved = ns.db.externalsAlert and ns.db.externalsAlert.pos
    if saved then
        a:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
    else
        a:SetPoint("CENTER", 0, 170)
    end

    -- Smooth fade-out animation; replays from full alpha on each new alert. The
    -- transient state (anim group, hold timer, shown aura instance) lives on the
    -- module, not the frame, so it's plain-nil before first use.
    local ag = a:CreateAnimationGroup()
    local fade = ag:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0)
    fade:SetDuration(0.6)
    ag:SetScript("OnFinished", function()
        a:Hide()
        -- While unlocked, the frame is a positioning aid: snap back to the
        -- placeholder rather than leaving an empty hole on screen.
        if self.db and self.db.unlocked then self:ShowPlaceholder() end
    end)
    self._alertAG = ag

    a:Hide()
    self.alert = a
    return a
end

function M:HideAlert()
    local a = self.alert
    if not a then return end
    if self._alertHold then self._alertHold:Cancel(); self._alertHold = nil end
    if self._alertAG then self._alertAG:Stop() end
    self:CancelCountdown()
    if a.cdFS then a.cdFS:SetText("") end
    if a.cd and a.cd.Clear then a.cd:Clear() end
    self._alertIid = nil
    a:Hide()
end

-- ---------------------------------------------------------------------------
-- Live countdown (Time Spiral's pattern: GetTime() math + a self-rescheduling
-- C_Timer loop). _cdExpiry is the GetTime()-relative moment the buff's known
-- window runs out; we re-paint the on-icon number ~10x/sec until then.
-- ---------------------------------------------------------------------------
-- Whole seconds while there's a comfortable margin, one decimal in the final
-- stretch -- the readable convention timers use.
local function fmtRemaining(rem)
    if rem >= 3 then return tostring(math.ceil(rem - 0.001)) end
    return string.format("%.1f", rem)
end

function M:CancelCountdown()
    if self._cdTimer then self._cdTimer:Cancel(); self._cdTimer = nil end
    self._cdExpiry = nil
end

function M:UpdateCountdown()
    local a = self.alert
    if not a or not self._cdExpiry then return end
    local rem = self._cdExpiry - ((GetTime and GetTime()) or 0)
    if rem > 0 then
        a.cdFS:SetText(self.db.showCountdown == false and "" or fmtRemaining(rem))
        a:Show()
        if C_Timer and C_Timer.NewTimer then
            self._cdTimer = C_Timer.NewTimer(0.1, function() self:UpdateCountdown() end)
        end
    else
        -- The buff's known window elapsed. Fade out -- or, while unlocked, fall
        -- back to the positioning placeholder rather than vanishing.
        self._cdExpiry = nil
        a.cdFS:SetText("")
        if self.db and self.db.unlocked then
            self:ShowPlaceholder()
        elseif self._alertAG then
            self._alertAG:Play()
        else
            a:Hide()
        end
    end
end

-- Begin counting down to `expiry`; `total` (full length) drives the sweep arc
-- when known. Mirrors Time Spiral's StartTimeSpiralCountdown.
function M:StartCountdown(expiry, total)
    local a = self.alert
    if not a then return end
    self:CancelCountdown()
    self._cdExpiry = expiry
    if total and a.cd and a.cd.SetCooldown then
        a.cd:SetCooldown(expiry - total, total)
    elseif a.cd and a.cd.Clear then
        a.cd:Clear()
    end
    self:UpdateCountdown()
end

-- Show (or replace in place) the alert for a spell. When we know how long the
-- buff lasts (expiry, from M:ResolveExpiry) we count it down on the icon;
-- otherwise we keep the old fixed fadeTime hold (custom spells mid-combat).
function M:ShowAlert(name, icon, cat, iid, expiry, total)
    local a = self:EnsureAlert()
    if self._alertAG then self._alertAG:Stop() end
    if self._alertHold then self._alertHold:Cancel(); self._alertHold = nil end
    self:CancelCountdown()

    a.icon:SetTexture(icon or UNKNOWN_ICON)
    a.nameFS:SetText(name or "")
    a.catFS:SetText(cat or "")
    self._alertIid = iid     -- so a matching removal can hide it early
    a:SetAlpha(1)
    a:Show()

    if expiry then
        self:StartCountdown(expiry, total)   -- live, ticking remaining time
        return
    end

    -- Unknown duration: no countdown, just hold for fadeTime then fade.
    a.cdFS:SetText("")
    if a.cd and a.cd.Clear then a.cd:Clear() end
    local hold = self.db.fadeTime or 4
    local function startFade()
        self._alertHold = nil
        if self._alertAG then self._alertAG:Play() else a:Hide() end
    end
    -- Keep a cancellable handle (C_Timer.NewTimer is always present on 12.0) so
    -- HideAlert or a replacing alert can stop a pending fade.
    if C_Timer and C_Timer.NewTimer then
        self._alertHold = C_Timer.NewTimer(hold, startFade)
    else
        a:Hide()
    end
end

-- Preview button: shows a representative banner AND speaks, so you can position
-- the frame and confirm the chosen TTS voice works on your machine.
function M:TestAlert()
    -- Preview with BoP's known length so you see the countdown + sweep, too.
    local expiry, total = self:ResolveExpiry({}, 1022)
    self:ShowAlert(self:SpellName(1022), self:SpellIcon(1022), self:SpellCat(1022), nil, expiry, total)
    self:Speak("Test alert")
end

-- ---------------------------------------------------------------------------
-- Unlock-to-position: a persistent sample banner you can drag into place
-- without waiting for a real external to land (Time Spiral's tsUnlock idea).
-- ---------------------------------------------------------------------------
function M:ShowPlaceholder()
    local a = self:EnsureAlert()
    self:CancelCountdown()
    if self._alertHold then self._alertHold:Cancel(); self._alertHold = nil end
    if self._alertAG then self._alertAG:Stop() end
    self._alertIid = nil
    -- A representative sample so size + position read true to a real alert.
    a.icon:SetTexture(self:SpellIcon(1022) or UNKNOWN_ICON)
    a.nameFS:SetText("Externals")
    a.catFS:SetText("drag to move - unlock off to hide")
    a.cdFS:SetText(self.db.showCountdown == false and "" or "8")
    if a.cd and a.cd.Clear then a.cd:Clear() end
    a:SetAlpha(1)
    a:Show()
end

-- Turn unlock mode on/off and reflect it on screen immediately.
function M:SetUnlocked(on)
    self.db.unlocked = on and true or false
    self:RefreshUnlock()
end

-- Bring the on-screen state in line with db.unlocked (placeholder while
-- unlocked, hidden otherwise). Safe to call whenever the state may have changed
-- (login, profile switch, toggle).
function M:RefreshUnlock()
    if self.db and self.db.unlocked then
        self:ShowPlaceholder()
    else
        self:HideAlert()
    end
end

-- ---------------------------------------------------------------------------
-- Aura detection (UNIT_AURA, player-scoped). See the file header for the 12.0
-- "secret value" reality this is built around.
-- ---------------------------------------------------------------------------
-- Best-effort self-cast test. In combat sourceUnit / isFromPlayerOrPlayerPet are
-- secret (unbranchable), so we can only filter when they're readable; otherwise
-- we let the alert through (most tracked externals can't be self-cast anyway).
function M:IsSelfCast(aura)
    local fromMe = aura.isFromPlayerOrPlayerPet
    if fromMe ~= nil and not isSecret(fromMe) and fromMe == true then return true end
    local src = aura.sourceUnit
    if src and not isSecret(src) and UnitIsUnit and UnitIsUnit(src, "player") then return true end
    return false
end

-- Work out the countdown target for a freshly-applied aura. Returns
-- (expiry, total): `expiry` is a GetTime()-relative timestamp to count down to,
-- `total` is the buff's full length (drives the cooldown sweep) -- or nil when
-- nothing is knowable (a custom spell mid-combat), in which case ShowAlert keeps
-- the old fixed fadeTime hold. Every live read is isSecret-guarded: in combat the
-- aura's expirationTime / duration are SECRET (unbranchable), so we drop to the
-- BASELINE `dur` table (the in-combat path); out of combat the live values win.
function M:ResolveExpiry(aura, sid)
    local now = (GetTime and GetTime()) or 0
    local exp = aura and aura.expirationTime
    local dur = aura and aura.duration
    local expReadable = exp ~= nil and not isSecret(exp)
    local durReadable = dur ~= nil and not isSecret(dur)

    -- Out of combat the live timing is readable. A positive value is a real
    -- timer -> count down from it (always beats the table).
    if expReadable and exp > 0 then
        return exp, (durReadable and dur > 0) and dur or nil
    end
    if durReadable and dur > 0 then
        return now + dur, dur
    end

    -- A readable ZERO is the game telling us this aura has NO buff timer -- a
    -- ground effect like Anti-Magic Zone or Darkness that lasts only as long as
    -- you stand in it. Show the banner, but never invent a countdown for it; the
    -- removedAuraInstanceIDs path hides it the moment you step out / it fades.
    if (expReadable and exp == 0) or (durReadable and dur == 0) then
        return nil, nil
    end

    -- Live timing unreadable (in combat = secret values): fall back to the known
    -- duration table -- but only for spells that actually have a fixed timer.
    -- Ground effects carry no `dur` (below), so they stay banner-only here too.
    local b = BASELINE[sid]
    if b and b.dur and b.dur > 0 then
        return now + b.dur, b.dur
    end
    return nil, nil
end

-- Decide on a single freshly-applied aura.
function M:Consider(aura)
    if not aura then return end
    local sid = aura.spellId
    if not sid or isSecret(sid) then return end
    if not (self.tracked and self.tracked[sid]) then return end

    if self:IsSelfCast(aura) then return end

    local cfg = self:Resolve(sid)
    if not (cfg.text or cfg.audio ~= "off") then return end   -- nothing to output
    if not self:Allowed(sid) then return end                  -- re-applied too soon: skip

    if cfg.text then
        local icon = aura.icon
        if not icon or isSecret(icon) then icon = self:SpellIcon(sid) end
        local iid = aura.auraInstanceID
        if isSecret(iid) then iid = nil end
        local expiry, total = self:ResolveExpiry(aura, sid)
        self:ShowAlert(self:SpellName(sid), icon, self:SpellCat(sid), iid, expiry, total)
    end
    if cfg.audio == "tts" then
        self:Speak(self:TtsText(sid))
    elseif cfg.audio == "sound" then
        self:PlaySound(cfg.sound)
    end
end

function M:UNIT_AURA(unit, updateInfo)
    if unit ~= "player" or not updateInfo then return end

    -- Only react to freshly ADDED auras: a full snapshot (login / zone-in) or a
    -- refresh would re-fire alerts for buffs you already have. addedAuras carries
    -- the full AuraData; updated/removed carry only instance IDs.
    local added = updateInfo.addedAuras
    if added then
        for _, aura in ipairs(added) do self:Consider(aura) end
    end

    -- If the buff we're currently showing was removed, fade it out now.
    local removed = updateInfo.removedAuraInstanceIDs
    if removed and self.alert and self._alertIid then
        for _, iid in ipairs(removed) do
            if not isSecret(iid) and iid == self._alertIid then
                self:HideAlert()
                break
            end
        end
    end
end

-- ===========================================================================
-- Options page (built into the shell's content pane)
-- ===========================================================================

-- Per-spell TTS-phrase editor (in-game popup; the save path is M:SetTtsText so
-- it stays testable). Guarded so a stripped environment never errors on load.
if StaticPopupDialogs then
    StaticPopupDialogs["OPPOSITEQOL_EXTERNALS_TTS"] = {
        text = "Spoken phrase for %s:",
        button1 = OKAY or "Set",
        button2 = CANCEL or "Cancel",
        hasEditBox = true,
        maxLetters = 60,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        OnShow = function(self, data)
            local eb = self.editBox or (self.GetEditBox and self:GetEditBox())
            if eb and data then eb:SetText(data.text or ""); eb:HighlightText() end
        end,
        OnAccept = function(self, data)
            local eb = self.editBox or (self.GetEditBox and self:GetEditBox())
            if eb and data and data.id then M:SetTtsText(data.id, eb:GetText()) end
        end,
        EditBoxOnEnterPressed = function(self)
            local parent = self:GetParent()
            local data = parent and parent.data
            if data and data.id then M:SetTtsText(data.id, self:GetText()) end
            if parent then parent:Hide() end
        end,
    }
end

local function openTtsEditor(id)
    if StaticPopup_Show and StaticPopupDialogs and StaticPopupDialogs["OPPOSITEQOL_EXTERNALS_TTS"] then
        StaticPopup_Show("OPPOSITEQOL_EXTERNALS_TTS", M:SpellName(id), nil, { id = id, text = M:TtsText(id) })
    else
        ns:Print("editing the spoken phrase needs the in-game UI.")
    end
end

-- Row layout: a "text" toggle on the left, then icon + name, then the per-spell
-- "Alert" dropdown + TTS-phrase-edit + remove on the right. COL holds the right-
-- edge offsets so the static column labels above the list line up with the row
-- controls regardless of window width.
local DD_W = 150
local COL = { remove = 2, edit = 24, dd = 58 }

-- One spell row, built once and rebound to a new id on refresh (pooled).
function M:CreateSpellRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(UI.ROW_H)

    -- "Text" toggle: show the on-screen banner for this spell.
    local text = UI.CreateToggle(row)
    text:SetPoint("LEFT", 2, 0)
    text:SetScript("OnClick", function(self)
        local on = not self:GetChecked()
        self:SetChecked(on)
        M:SetSpellSetting(row._id, "text", on)
    end)
    row.text = text

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", text, "RIGHT", 8, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon = icon

    local nameFS = row:CreateFontString(nil, "OVERLAY")
    StyleFont(nameFS, 12, theme.text)
    nameFS:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    nameFS:SetPoint("RIGHT", row, "RIGHT", -(COL.dd + DD_W + 8), 0)
    nameFS:SetJustifyH("LEFT")
    row.nameFS = nameFS

    -- "Alert" dropdown: Off / Text-to-Speech / <a sound>.
    local dd = UI.CreateDropdown(row, DD_W, 20)
    dd:SetPoint("RIGHT", -COL.dd, 0)
    dd:SetOptions(self:AlertOptions())
    dd.OnSelect = function(value)
        M:SetAlertValue(row._id, value)
        M:PreviewAlertOutput(row._id)   -- hear/see the pick
        M:UpdateRowEdit(row)            -- the phrase editor only matters for TTS
    end
    row.dd = dd

    -- Edit the spoken phrase (only meaningful when this spell uses TTS).
    local edit = UI.CreateFlatButton(row, "TTS", 28, 18, theme.text)
    edit:SetPoint("RIGHT", -COL.edit, 0)
    edit:SetScript("OnClick", function() openTtsEditor(row._id) end)
    row.edit = edit

    local remove = UI.CreateFlatButton(row, "x", 18, 18, theme.red)
    remove:SetPoint("RIGHT", -COL.remove, 0)
    remove:SetScript("OnClick", function()
        if M:RemoveCustomSpell(row._id) then M:RefreshList() end
    end)
    row.remove = remove

    return row
end

-- The phrase-edit button is shown only when the spell's audio is TTS.
function M:UpdateRowEdit(row)
    local s = self.db.spellSettings[row._id] or {}
    if (s.audio or "tts") == "tts" then row.edit:Show() else row.edit:Hide() end
end

function M:BindSpellRow(row, id)
    row._id = id
    row.icon:SetTexture(self:SpellIcon(id) or UNKNOWN_ICON)
    row.nameFS:SetText(self:SpellName(id))
    local s = self.db.spellSettings[id] or {}
    row.text:SetChecked(s.text ~= false)
    row.dd:SetValue(self:GetAlertValue(id))
    self:UpdateRowEdit(row)
    if self.db.customSpells[id] then row.remove:Show() else row.remove:Hide() end
end

-- (Re)lay out one pooled row per tracked spell into the scroll child.
function M:RefreshList()
    local child = self._listChild
    if not child then return end
    self._rows = self._rows or {}
    local list = self.idList or {}

    local y = -4
    for i, id in ipairs(list) do
        local row = self._rows[i]
        if not row then row = self:CreateSpellRow(child); self._rows[i] = row end
        self:BindSpellRow(row, id)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, y)
        row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, y)
        row:Show()
        y = y - UI.ROW_H
    end
    for i = #list + 1, #self._rows do self._rows[i]:Hide() end

    child:SetHeight(math.max(1, -y + 4))
    if self._listScroll and self._listScroll.UpdateScrollBar then
        self._listScroll.UpdateScrollBar()
    end
end

function M:BuildOptions(parent)
    local db = self.db

    -- Card 1: global output settings (shared TTS voice + timing). Per-spell
    -- text/audio choices live in the list card below.
    local card1 = UI.CreateCard(parent, "Alert output")
    card1:SetPoint("TOPLEFT", UI.PAD, -52)
    card1:SetPoint("TOPRIGHT", -UI.PAD, -52)
    local p1 = UI.Page(card1, -32)
    p1:Dropdown("TTS voice", self:VoiceOptions(),
        function() return self:ResolveVoiceID() end,
        function(v) db.ttsVoice = v; self:Speak("Voice selected") end,
        "The voice used wherever a spell's alert is set to Text-to-Speech (previews on pick).")
    p1:Slider("Fallback hold (seconds)", 2, 10, 1,
        function() return db.fadeTime end,
        function(v) db.fadeTime = v end,
        "Hold time for buffs whose duration can't be read (custom spells, or in combat with no known length). Buffs with a known duration count down instead.")
    p1:Slider("Re-alert cooldown (sec)", 0, 10, 1,
        function() return db.throttle end,
        function(v) db.throttle = v end,
        "Ignore the same spell if it re-lands within this many seconds. 0 = always.")
    p1:Check("Show countdown number",
        function() return db.showCountdown ~= false end,
        function(v) db.showCountdown = v and true or false end,
        "Paint the buff's remaining seconds on the alert icon.")
    p1:Check("Unlock (position the alert)",
        function() return self.db.unlocked == true end,
        function(v) self:SetUnlocked(v) end,
        "Show a draggable sample banner so you can place it on screen; turn off to hide it.")
    p1:Button("Test alert", function() self:TestAlert() end)
    card1:SetHeight(p1:Height())

    -- Card 2: add a spell by ID (hand-rolled EditBox; UI.lua has no text input).
    local card2 = UI.CreateCard(parent, "Add a spell by ID")
    card2:SetPoint("TOPLEFT", card1, "BOTTOMLEFT", 0, -UI.GAP)
    card2:SetPoint("TOPRIGHT", card1, "BOTTOMRIGHT", 0, -UI.GAP)
    card2:SetHeight(62)

    local idEdit = CreateFrame("EditBox", nil, card2, "BackdropTemplate")
    idEdit:SetSize(110, 24)
    idEdit:SetAutoFocus(false)
    idEdit:SetNumeric(true)              -- spell IDs are integers; digits only
    UI.ApplyBackdrop(idEdit, theme.bgInput, theme.borderHi)
    idEdit:SetTextInsets(6, 6, 0, 0)
    StyleFont(idEdit, 13, theme.text)
    idEdit:SetPoint("TOPLEFT", UI.PAD, -28)
    idEdit:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    parent.idEdit = idEdit

    local addBtn = UI.CreateFlatButton(card2, "Add", 70, 24, theme.accent)
    addBtn:SetPoint("LEFT", idEdit, "RIGHT", 8, 0)
    local function submit()
        local id = tonumber(idEdit:GetText())
        idEdit:SetText("")
        idEdit:ClearFocus()
        if self:AddCustomSpell(id) then self:RefreshList() end
    end
    addBtn:SetScript("OnClick", submit)
    idEdit:SetScript("OnEnterPressed", function(s) s:ClearFocus(); submit() end)
    parent.addBtn = addBtn

    local hint = card2:CreateFontString(nil, "OVERLAY")
    StyleFont(hint, 11, theme.textDim)
    hint:SetPoint("LEFT", addBtn, "RIGHT", 10, 0)
    hint:SetText("e.g. 1022")

    -- Card 3: the tracked-spell list, filling the rest of the window. Column
    -- labels (TEXT / ALERT) sit under the card title, aligned to the row controls.
    local card3 = UI.CreateCard(parent, "Tracked spells")
    card3:SetPoint("TOPLEFT", card2, "BOTTOMLEFT", 0, -UI.GAP)
    card3:SetPoint("TOPRIGHT", card2, "BOTTOMRIGHT", 0, -UI.GAP)
    card3:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -UI.PAD, UI.PAD)

    local textHdr = card3:CreateFontString(nil, "OVERLAY")
    StyleFont(textHdr, 9, theme.textDim)
    textHdr:SetPoint("TOPLEFT", UI.PAD, -30)
    textHdr:SetText("TEXT")

    local alertHdr = card3:CreateFontString(nil, "OVERLAY")
    StyleFont(alertHdr, 9, theme.textDim)
    alertHdr:SetPoint("TOPRIGHT", card3, "TOPRIGHT", -(UI.PAD + COL.dd), -30)
    alertHdr:SetJustifyH("RIGHT")
    alertHdr:SetText("ALERT")

    local scroll, child = UI.CreateScrollArea(card3, 44, 10)
    self._listScroll, self._listChild = scroll, child
    self:RefreshList()
end

function M:Open()
    if ns.Config then ns.Config:OpenModule(self.key) end
end

function M:Toggle()
    if ns.Config then ns.Config:ToggleModule(self.key) end
end

-- ===========================================================================
-- Module lifecycle
-- ===========================================================================
function M:OnInitialize()
    ns.db.externals = ns.db.externals or {}
    self.db = ns.db.externals
    ns.DeepMerge(self.db, self.defaults)
    self.db.spellSettings = self.db.spellSettings or {}
    self.db.customSpells  = self.db.customSpells or {}
    self._last = {}
    self:RebuildTracked()
end

-- The profile system refills ns.db.externals in place when the active profile
-- changes; re-point self.db, re-merge defaults, rebuild the tracked set and the
-- open list.
function M:OnProfileChanged()
    self.db = ns.db.externals
    ns.DeepMerge(self.db, self.defaults)
    self.db.spellSettings = self.db.spellSettings or {}
    self.db.customSpells  = self.db.customSpells or {}
    self._last = {}
    self:RebuildTracked()
    self:RefreshUnlock()   -- dismiss any live alert; re-show the placeholder if the new profile is unlocked
    if self._listChild then self:RefreshList() end
end

function M:OnEnable()
    if not self.listener then
        self.listener = CreateFrame("Frame")
        self.listener:SetScript("OnEvent", function(_, event, ...)
            local handler = self[event]
            if handler then handler(self, ...) end
        end)
    end
    -- UNIT_AURA scoped to the player only (cheap, and all we ever care about).
    -- pcall keeps us forward-compatible if the event name ever changes.
    pcall(self.listener.RegisterUnitEvent, self.listener, "UNIT_AURA", "player")
    self:RebuildTracked()
    self:RefreshUnlock()   -- re-show the positioning placeholder if it was left unlocked
end

function M:OnDisable()
    if self.listener then self.listener:UnregisterAllEvents() end
    self:HideAlert()
    self._last = {}
end
