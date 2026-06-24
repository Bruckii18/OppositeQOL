-- Standalone logic test for the Externals Tracker module (key/file: externals /
-- Externals.lua). Stubs the WoW API, loads the real addon files into one shared
-- namespace, runs init, and verifies the modern-API spell lookups, the baseline
-- tracking set, custom add/remove, the UNIT_AURA detection path (query-by-known-
-- spellId rising-edge detection, baseline/full-update suppression, the crucial
-- in-combat ALL-SECRET-fields case that the old addedAuras path failed,
-- self-cast exclusion, the per-spell throttle, falling-edge removal hiding the
-- alert), TTS + sound output, the options window construction, and the slash
-- command. The aura source (caster) is deliberately never named -- see the
-- module header.
-- Run from the project root:  luajit tests/test_externals.lua

-- ---- per-object widget mock that also stores script handlers (so click
--      callbacks can be invoked, like test_ui) ----
local function newWidget()
    local store = { scripts = {} }
    local w = {}
    setmetatable(w, { __index = function(_, k)
        return function(self, a, b)
            if k == "CreateFontString" or k == "CreateTexture"
                or k == "CreateMaskTexture" or k == "CreateAnimationGroup"
                or k == "CreateAnimation" then return newWidget()
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
            elseif k == "GetPoint" then return "CENTER", nil, "CENTER", 0, 0
            elseif k == "GetCenter" then return 0, 0
            elseif k == "GetObjectType" then return "Frame"
            else return self end
        end
    end })
    return w
end

-- ---- controllable clock + secret-value set ----
local clock = 1000
local secretVals = {}     -- values for which issecretvalue() returns true

-- ---- WoW global stubs ----
CreateFrame = function() return newWidget() end
UIParent = newWidget()
Minimap = newWidget()
GameTooltip = newWidget()
GetCursorPosition = function() return 75, 0 end
GetPhysicalScreenSize = function() return 2560, 1440 end
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
StaticPopupDialogs, UISpecialFrames, SlashCmdList = {}, {}, {}
tinsert = table.insert
format = string.format
abs = math.abs
time = os.time
date = os.date
GetTime = function() return clock end
issecretvalue = function(v) return secretVals[v] == true end

-- group / instance state (PrePull initialises alongside us for its sound picker)
IsInRaid = function() return true end
IsInGroup = function() return true end
IsInInstance = function() return true, "raid" end
UnitIsGroupLeader = function() return true end
UnitIsGroupAssistant = function() return true end
UnitGroupRolesAssigned = function() return "DAMAGER" end
GetNumGroupMembers = function() return 1 end
GetInstanceInfo = function() return "Test Raid", "raid", 16, "", 0, 0, 0, 9999 end
IsEncounterInProgress = function() return false end
InCombatLockdown = function() return false end
LE_PARTY_CATEGORY_INSTANCE = 2
TIMER_TYPE_PLAYER_COUNTDOWN = 3

-- unit stubs
UnitExists = function() return false end
UnitIsPlayer = function() return true end
UnitGUID = function(unit) return "GUID-" .. tostring(unit) end
UnitName = function(unit) if unit == "player" then return "Me", "" end return tostring(unit), "" end
UnitIsUnit = function(a, b) return a == b end

-- announce / sound sinks
RaidWarningFrame, RaidNotice_AddMessage, ChatTypeInfo = nil, nil, nil
SOUNDKIT = { RAID_WARNING = 8959, READY_CHECK = 8960, ALARM_CLOCK_WARNING_3 = 12867 }
local soundsPlayed = {}
PlaySound = function(id) soundsPlayed[#soundsPlayed + 1] = "kit:" .. tostring(id) end
PlaySoundFile = function(f) soundsPlayed[#soundsPlayed + 1] = "file:" .. tostring(f) end

-- C_Timer: After runs inline; NewTimer stores the fn (so the alert holds, not
-- fades, until we choose); NewTicker stored for safety.
local holdFn
C_Timer = {
    After     = function(_, fn) fn() end,
    NewTimer  = function(_, fn) holdFn = fn; return { Cancel = function() holdFn = nil end } end,
    NewTicker = function(_, fn) return { Cancel = function() end } end,
}

-- chat addon prefix (PrePull registers "D5")
C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
    SendChatMessage = function() end,
}
SendChatMessage = function() end

-- ---- modern spell / aura / TTS API ----
local KNOWN = { [999999] = "My Custom Buff", [123456] = "Another Buff" }  -- valid custom IDs
C_Spell = {
    GetSpellInfo = function(id)
        local name = KNOWN[id]
        if not name then return nil end                 -- nil for unknown IDs
        return { name = name, iconID = 100000 + id, spellID = id }
    end,
    GetSpellTexture = function(id) return 200000 + id end,
}
-- Detection queries by KNOWN spellId (the 12.0 secret-safe way), so the stub
-- exposes GetPlayerAuraBySpellID backed by `playerAuras` (spellId -> AuraData).
-- Tests set/clear that table then fire UNIT_AURA, mirroring how the game delivers
-- and drops buffs. Querying a known id returns the aura even with secret fields.
local playerAuras = {}
C_UnitAuras = {
    GetPlayerAuraBySpellID = function(id) return playerAuras[id] end,
}

-- C_Secrets (12.0.7) per-spell aura-secrecy probe; secrecyByID overrides per id
-- (default 2 = ContextuallySecret). Drives the detection-reliability self-check
-- (M:IsReliablyTracked) -- detection itself never reads it.
local secrecyByID = {}
C_Secrets = {
    GetSpellAuraSecrecy = function(id) return secrecyByID[id] or 2 end,
}

local spoken = {}
-- 12.0 signature: SpeakText(voiceID, text, rate, volume [, overlap]); voices via
-- C_VoiceChat.GetTtsVoices() -> { {voiceID, name}, ... }.
C_VoiceChat = {
    GetTtsVoices = function() return { { voiceID = 0, name = "Bob" }, { voiceID = 1, name = "Alice" } } end,
    SpeakText = function(voiceID, text, rate, volume, overlap)
        spoken[#spoken + 1] = { voiceID = voiceID, text = text, rate = rate, volume = volume, overlap = overlap }
    end,
}

-- ---- load the real files into ONE shared namespace ----
local ns = {}
local function load(path) assert(loadfile(path))("OppositeQOL", ns) end
load("Core.lua")
load("UI.lua")
load("WhoPulled.lua")   -- Externals reuses its sound picker
load("Externals.lua")
load("Config.lua")

-- capture chat output
local prints = {}
ns.Print = function(_, msg) prints[#prints + 1] = tostring(msg) end
local function lastPrint() return prints[#prints] or "" end
local function contains(s, sub) return type(s) == "string" and s:find(sub, 1, true) ~= nil end

OppositeQOLDB = nil
ns:Initialize()

-- ===========================================================================
local ok = true
local function check(name, cond)
    print((cond and "PASS " or "FAIL ") .. name)
    ok = ok and (cond and true or false)
end

local E = ns.Externals

-- helper: build an AuraData table as C_UnitAuras.GetPlayerAuraBySpellID returns
local function auraData(spellId, fields)
    local a = { spellId = spellId, sourceUnit = "raid2", isFromPlayerOrPlayerPet = false,
                icon = 555, auraInstanceID = 1 }
    if fields then for k, v in pairs(fields) do a[k] = v end end
    return a
end

-- Land a buff on the player and fire UNIT_AURA. Clears any prior instance of the
-- same spell first so every call is a genuine rising edge (a fresh application),
-- which is what the old addedAuras-driven `added()` helper used to guarantee.
local function land(spellId, fields)
    if playerAuras[spellId] then
        playerAuras[spellId] = nil
        E:UNIT_AURA("player", { isFullUpdate = false })   -- register the drop
    end
    playerAuras[spellId] = auraData(spellId, fields)
    E:UNIT_AURA("player", { isFullUpdate = false })       -- rising edge
end

-- Drop a buff off the player and fire UNIT_AURA (the falling edge).
local function drop(spellId)
    playerAuras[spellId] = nil
    E:UNIT_AURA("player", { isFullUpdate = false })
end

-- ---- module framework ----
check("module registered", ns.modules.externals ~= nil)
check("enabled by default", E.enabled == true)
check("default persisted to DB", OppositeQOLDB.modules.externals.enabled == true)
check("per-module DB created", type(E.db) == "table")
check("has options window", E.hasUI == true)

-- ---- defaults ----
check("fadeTime default 4",        E.db.fadeTime == 4)
check("throttle default 2",        E.db.throttle == 2)
check("spellSettings table",       type(E.db.spellSettings) == "table")
check("customSpells table",        type(E.db.customSpells) == "table")
check("no global tts/sound masters", E.db.tts == nil and E.db.sound == nil)

-- ---- baseline tracking set + lookups ----
check("baseline tracked (Pain Suppression)", E.tracked[33206] == true)
check("baseline tracked (BoP)",              E.tracked[1022] == true)
check("idList has 21 baseline spells",       #E.idList == 21)
check("SpellName from baseline table",       E:SpellName(1022) == "Blessing of Protection")
check("SpellCat from baseline table",        E:SpellCat(97462) == "Raid")
check("TtsText defaults to baseline phrase", E:TtsText(1022) == "BOP")
check("idList sorted External-category first", E:SpellCat(E.idList[1]) == "External")

-- ---- detection-reliability self-check (C_Secrets aura secrecy) ----
check("AuraSecrecy reads C_Secrets (contextual = 2 by default)", E:AuraSecrecy(33206) == 2)
check("contextual aura is reliably tracked", E:IsReliablyTracked(33206) == true)
secrecyByID[1022] = 0   -- NeverSecret
check("never-secret aura is reliably tracked", E:IsReliablyTracked(1022) == true)
secrecyByID[1022] = 1   -- AlwaysSecret -> presence detection can't see it land
check("always-secret aura flagged NOT reliably tracked", E:IsReliablyTracked(1022) == false)
secrecyByID[1022] = nil

-- ---- modern API only: SpellName for an unknown id falls back, never errors ----
check("SpellName falls back for unknown id", E:SpellName(7777777) == "Spell 7777777")
check("SpellIcon uses C_Spell.GetSpellTexture", E:SpellIcon(1022) == 201022)

-- ===========================================================================
-- Custom spells
-- ===========================================================================
check("add invalid id (nil) prints error",
    E:AddCustomSpell(nil) == false and contains(lastPrint(), "invalid spell id"))
check("add unknown id (C_Spell nil) prints error",
    E:AddCustomSpell(4040404) == false and contains(lastPrint(), "4040404"))
check("add already-tracked baseline refused",
    E:AddCustomSpell(1022) == false and contains(lastPrint(), "already tracked"))

check("add valid custom id succeeds", E:AddCustomSpell(999999) == true)
check("custom id stored as a set", E.db.customSpells[999999] == true)
check("custom id now tracked", E.tracked[999999] == true)
check("custom settings row materialised", type(E.db.spellSettings[999999]) == "table")
check("custom id name via C_Spell", E:SpellName(999999) == "My Custom Buff")
check("custom id category is Custom", E:SpellCat(999999) == "Custom")
check("idList grew by one", #E.idList == 22)
check("custom string id is coerced to number", E:AddCustomSpell("123456") == true and E.tracked[123456] == true)

check("remove custom id", E:RemoveCustomSpell(999999) == true)
check("removed id no longer tracked", E.tracked[999999] == nil)
check("removed id settings cleared", E.db.spellSettings[999999] == nil)
E:RemoveCustomSpell(123456)
check("idList back to 21", #E.idList == 21)

-- ===========================================================================
-- TTS phrase override
-- ===========================================================================
E:SetTtsText(1022, "  bubble incoming  ")
check("SetTtsText trims + stores override", E.db.spellSettings[1022].ttsText == "bubble incoming")
check("TtsText returns the override", E:TtsText(1022) == "bubble incoming")
E:SetTtsText(1022, "")
check("empty override clears back to default", E:TtsText(1022) == "BOP")

-- ===========================================================================
-- UNIT_AURA detection (per-spell default: text on + TTS)
-- ===========================================================================
-- a tracked buff from another player -> banner + TTS (the defaults)
spoken = {}
land(33206)
check("tracked buff shows the alert", E.alert and E.alert:IsShown() == true)
check("alert names the spell (no caster)", E.alert.nameFS:GetText() == "Pain Suppression")
check("alert shows the category", E.alert.catFS:GetText() == "External")
check("TTS spoke the phrase", #spoken == 1 and spoken[1].text == "Pain Suppression")
check("TTS uses 12.0 signature (rate 0, full volume)",
    spoken[1].rate == 0 and spoken[1].volume == 100)

-- a buff already present at baseline does NOT re-fire on an unrelated UNIT_AURA
-- (rising-edge only): 33206 is still on us from above.
spoken = {}
E:UNIT_AURA("player", { isFullUpdate = false })
check("already-present buff does not re-alert", #spoken == 0)

-- a full update (login / zone-in resends every aura) re-baselines, never alerts
spoken = {}
drop(33206)
playerAuras[6940] = auraData(6940)
E:UNIT_AURA("player", { isFullUpdate = true })
check("full update re-baselines without alerting", #spoken == 0)
playerAuras[6940] = nil

-- non-tracked spell is ignored (never even queried -- not in idList)
spoken = {}
land(424242)
check("untracked spell ignored", #spoken == 0)

-- self-cast (isFromPlayerOrPlayerPet) excluded
spoken = {}
clock = clock + 100
land(1044, { isFromPlayerOrPlayerPet = true })
check("self-cast (player/pet) excluded", #spoken == 0)

-- self-cast via sourceUnit == player excluded
spoken = {}
clock = clock + 100
land(1044, { sourceUnit = "player" })
check("self-cast (sourceUnit player) excluded", #spoken == 0)

-- ===========================================================================
-- THE in-combat "secret value" reality this module is built around. In a fight
-- EVERY field of an AuraData is secret -- the spellId INCLUDED. Detection must
-- NOT read the spellId back off the aura (that silently skips every external);
-- it queries by KNOWN id instead. A buff whose every field is secret must STILL
-- be detected and alert. (This is the exact case the old addedAuras path failed.)
-- ===========================================================================
local function secret() local s = setmetatable({}, {}); secretVals[s] = true; return s end
spoken = {}
clock = clock + 100
land(102342, { spellId = secret(), sourceUnit = secret(), isFromPlayerOrPlayerPet = secret(),
               icon = secret(), auraInstanceID = secret(),
               duration = secret(), expirationTime = secret() })
check("in-combat all-secret aura still detected (queried by known id)",
    #spoken == 1 and spoken[1].text == "Ironbark")
check("secret icon falls back to the known spell texture", E.alert.icon ~= nil)
check("secret timing falls back to the BASELINE dur (Ironbark = 12)",
    E.alert.cdFS:GetText() == "12")

-- a secret caster on a non-self-cast buff still alerts (caster simply unnamed)
local SECRET_SRC = secret()
spoken = {}
clock = clock + 100
land(6940, { sourceUnit = SECRET_SRC, isFromPlayerOrPlayerPet = SECRET_SRC })
check("secret sourceUnit still alerts (graceful)", #spoken == 1 and spoken[1].text == "SAC")

-- ===========================================================================
-- Per-spell throttle (db.throttle seconds). A re-land within the window (drop +
-- re-apply -- e.g. a second caster, or a flickering buff) is what the throttle
-- guards; a plain refresh isn't a rising edge and never reaches it.
-- ===========================================================================
spoken = {}
clock = clock + 100
land(6940)                              -- first time -> speaks
land(6940)                              -- drop + re-apply within 2s -> throttled
check("same spell throttled within window", #spoken == 1)
clock = clock + 3                       -- past the 2s throttle
land(6940)
check("same spell allowed after the cooldown", #spoken == 2)

-- throttle = 0 disables throttling
E.db.throttle = 0
spoken = {}
land(31821); land(31821)
check("throttle 0 lets repeats through", #spoken == 2)
E.db.throttle = 2

-- ===========================================================================
-- Per-spell output model: text on/off + audio (off / tts / a picked sound)
-- ===========================================================================
check("Resolve defaults to text on + TTS",
    (function() local c = E:Resolve(1022); return c.text == true and c.audio == "tts" end)())
check("GetAlertValue default is tts", E:GetAlertValue(1022) == "tts")
check("AlertOptions is Off, TTS, then sounds",
    (function() local o = E:AlertOptions(); return o[1].value == "off" and o[2].value == "tts" and #o >= 3 end)())

-- text off -> no banner, but still speaks (audio still defaults to tts)
E:SetSpellSetting(1044, "text", false)
E:HideAlert(); spoken = {}; clock = clock + 100
land(1044)
check("text off: no banner shown", E.alert:IsShown() == false)
check("text off: still speaks (audio tts)", #spoken == 1)
E.db.spellSettings[1044] = nil

-- audio = off -> banner only, fully silent
E:SetAlertValue(64901, "off")
check("SetAlertValue 'off' stores audio=off", E.db.spellSettings[64901].audio == "off")
E:HideAlert(); spoken = {}; soundsPlayed = {}; clock = clock + 100
land(64901)
check("audio off: banner shows", E.alert:IsShown() == true)
check("audio off: no speech and no sound", #spoken == 0 and #soundsPlayed == 0)
E.db.spellSettings[64901] = nil

-- audio = a picked sound -> plays that sound, no TTS
E:SetAlertValue(31821, "snd:Raid Warning")
check("SetAlertValue sound stores audio+sound",
    E.db.spellSettings[31821].audio == "sound" and E.db.spellSettings[31821].sound == "Raid Warning")
check("GetAlertValue round-trips the sound", E:GetAlertValue(31821) == "snd:Raid Warning")
spoken = {}; soundsPlayed = {}; clock = clock + 100
land(31821)
check("audio sound: plays a sound", #soundsPlayed >= 1)
check("audio sound: does not speak", #spoken == 0)
E.db.spellSettings[31821] = nil

-- text off + audio off -> nothing happens at all
E:SetSpellSetting(29166, "text", false)
E:SetAlertValue(29166, "off")
E:HideAlert(); spoken = {}; soundsPlayed = {}; clock = clock + 100
land(29166)
check("text off + audio off: silent and no banner",
    E.alert:IsShown() == false and #spoken == 0 and #soundsPlayed == 0)
E.db.spellSettings[29166] = nil

-- ===========================================================================
-- TTS voice selection
-- ===========================================================================
check("VoiceOptions lists installed voices", #E:VoiceOptions() == 2)
check("ResolveVoiceID defaults to the first installed voice", E:ResolveVoiceID() == 0)
E.db.ttsVoice = 1
check("ResolveVoiceID honours the saved voice", E:ResolveVoiceID() == 1)
spoken = {}
clock = clock + 100
land(33206)
check("Speak uses the selected voiceID", #spoken == 1 and spoken[1].voiceID == 1)
E.db.ttsVoice = 99    -- not installed
check("ResolveVoiceID falls back when the saved voice is gone", E:ResolveVoiceID() == 0)
E.db.ttsVoice = nil

-- the sound pool (shared with PrePull) is available for the Alert dropdown
check("SoundNames returns PrePull's pool", #E:SoundNames() >= 1)

-- ===========================================================================
-- Removal: the falling edge (buff no longer present) hides the showing alert
-- ===========================================================================
clock = clock + 100
land(414660)
check("alert showing before removal", E.alert:IsShown() == true)
drop(414660)
check("buff dropping hides the alert", E.alert:IsShown() == false)

-- an unrelated UNIT_AURA, with the shown buff still present, leaves it alone
clock = clock + 100
land(374227)
E:UNIT_AURA("player", { isFullUpdate = false })   -- 374227 still on us
check("unrelated update leaves the alert", E.alert:IsShown() == true)
drop(374227)

-- ===========================================================================
-- Live duration countdown (+ the in-combat secret-value fallback to the table)
-- ===========================================================================
-- ResolveExpiry contract: table dur for a baseline spell, nil when unknowable
check("ResolveExpiry uses the table dur for a baseline spell",
    (function() local e, t = E:ResolveExpiry({}, 33206); return t == 8 and e == GetTime() + 8 end)())
check("ResolveExpiry is nil for an unknown spell (custom, no table dur)",
    E:ResolveExpiry({}, 999999) == nil)

-- readable live data wins: count down from the aura's own expirationTime
E:HideAlert(); clock = clock + 100
land(33206, { duration = 8, expirationTime = clock + 6 })
check("countdown shows remaining from live expirationTime", E.alert.cdFS:GetText() == "6")
check("countdown alert is shown", E.alert:IsShown() == true)

-- the self-rescheduling loop re-paints a lower number as the clock advances
clock = clock + 2                       -- 4s remain now
if holdFn then holdFn() end
check("countdown re-paints lower as time passes", E.alert.cdFS:GetText() == "4")
clock = clock + 10                      -- past expiry
if holdFn then holdFn() end
check("countdown clears once the buff window elapses", E.alert.cdFS:GetText() == "")

-- in combat the live timing is SECRET -> fall back to the BASELINE dur table
E:HideAlert(); clock = clock + 100
local SECRET_EXP = setmetatable({}, {}); secretVals[SECRET_EXP] = true
local SECRET_DUR = setmetatable({}, {}); secretVals[SECRET_DUR] = true
land(102342, { duration = SECRET_DUR, expirationTime = SECRET_EXP })   -- Ironbark, table dur 12
check("secret live timing falls back to the table duration", E.alert.cdFS:GetText() == "12")
secretVals[SECRET_EXP] = nil; secretVals[SECRET_DUR] = nil

-- ground effects (AMZ, Darkness): the aura has NO buff timer (readable 0). We
-- must NOT invent a countdown -- show the banner, let removal clear it.
E:HideAlert(); clock = clock + 100
land(145629, { duration = 0, expirationTime = 0 })   -- Anti-Magic Zone standing-in aura
check("ground effect (duration 0) shows the banner", E.alert:IsShown() == true)
check("ground effect shows no countdown number", E.alert.cdFS:GetText() == "")
check("ResolveExpiry returns nil for a readable duration-0 aura",
    E:ResolveExpiry({ duration = 0, expirationTime = 0 }, 145629) == nil)
-- ...and in combat (timing secret) a ground effect still gets no table countdown,
-- because it carries no BASELINE dur
local S0 = setmetatable({}, {}); secretVals[S0] = true
check("ResolveExpiry nil for AMZ in combat (ground effects have no table dur)",
    E:ResolveExpiry({ duration = S0, expirationTime = S0 }, 145629) == nil)
secretVals[S0] = nil

-- a custom spell (no table dur, unreadable timing) keeps the fixed fadeTime hold
E:AddCustomSpell(999999); E:HideAlert(); clock = clock + 100
land(999999)
check("custom spell with no known duration still shows (fadeTime path)", E.alert:IsShown() == true)
check("custom spell shows no countdown number", E.alert.cdFS:GetText() == "")
E:RemoveCustomSpell(999999)

-- showCountdown = false suppresses the number but keeps the banner
E.db.showCountdown = false
E:HideAlert(); clock = clock + 100
land(33206)
check("showCountdown off hides the number", E.alert.cdFS:GetText() == "")
check("showCountdown off still shows the banner", E.alert:IsShown() == true)
E.db.showCountdown = true

-- ===========================================================================
-- Unlock-to-position placeholder
-- ===========================================================================
E:SetUnlocked(true)
check("unlock persists the flag", E.db.unlocked == true)
check("unlock shows the placeholder", E.alert:IsShown() == true)
check("placeholder names the module", E.alert.nameFS:GetText() == "Externals")
E:SetUnlocked(false)
check("lock clears the flag", E.db.unlocked == false)
check("lock hides the placeholder", E.alert:IsShown() == false)

-- ===========================================================================
-- Robustness: junk payloads never error
-- ===========================================================================
check("nil updateInfo is safe", pcall(function() E:UNIT_AURA("player", nil) end))
check("non-player unit is ignored", pcall(function() E:UNIT_AURA("target", {}) end))
check("incremental update with no changes is safe", pcall(function() E:UNIT_AURA("player", { isFullUpdate = false }) end))
check("full update (re-baseline) is safe", pcall(function() E:UNIT_AURA("player", { isFullUpdate = true }) end))

-- ===========================================================================
-- Options window + a driven toggle click + the slash command
-- ===========================================================================
check("options window builds", pcall(function() E:Open() end))
check("row pool populated", E._rows and #E._rows == #E.idList)

-- drive the first row's "text" toggle + "alert" dropdown and confirm they write
local row1 = E._rows[1]
local id1 = row1._id
local beforeText = E:Resolve(id1).text
row1.text:GetScript("OnClick")(row1.text)
check("row text toggle writes per-spell text", E:Resolve(id1).text ~= beforeText)
row1.dd.OnSelect("off")
check("row alert dropdown writes the audio mode", E.db.spellSettings[id1].audio == "off")
row1.dd.OnSelect("snd:Raid Warning")
check("row alert dropdown picks a sound",
    E.db.spellSettings[id1].audio == "sound" and E.db.spellSettings[id1].sound == "Raid Warning")

-- the icon hover builds without error, incl. the AlwaysSecret reliability note
secrecyByID[id1] = 1
check("spell-row icon hover builds for an always-secret spell",
    pcall(function() row1.iconHover:GetScript("OnEnter")(row1.iconHover) end))
secrecyByID[id1] = nil
check("spell-row icon hover builds for a normal spell",
    pcall(function() row1.iconHover:GetScript("OnEnter")(row1.iconHover) end))

check("TestAlert builds a preview without error", pcall(function() E:TestAlert() end))

-- slash command toggles the window
check("/oqol ext toggles without error", pcall(function() SlashCmdList["OPPOSITEQOL"]("ext") end))

-- ===========================================================================
-- Profile change re-syncs cached fields
-- ===========================================================================
E:AddCustomSpell(999999)
check("custom present before profile switch", E.tracked[999999] == true)
ns:SwitchProfile("Fresh")        -- new empty profile -> no custom spells
check("profile switch drops the custom (re-synced)", E.tracked[999999] == nil)
check("baseline survives profile switch", E.tracked[1022] == true)
ns:SwitchProfile("Default")
check("switching back restores the custom", E.tracked[999999] == true)

-- ===========================================================================
-- Disable/enable lifecycle
-- ===========================================================================
SlashCmdList["OPPOSITEQOL"]("disable externals")
check("disabled via slash", E.enabled == false)
check("disable hides any alert", E.alert:IsShown() == false)
SlashCmdList["OPPOSITEQOL"]("enable Externals Tracker")
check("re-enabled via display name", E.enabled == true)
check("tracked set rebuilt on re-enable", E.tracked[1022] == true)

print(ok and "\nALL TESTS PASSED" or "\nSOME TESTS FAILED")
os.exit(ok and 0 or 1)
