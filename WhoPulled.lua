-- OppositeQOL - PrePull
-- Detects each raid boss pull and how early/late it was vs the DBM/BigWigs (or
-- Blizzard) pull timer, shows a local banner, plays an optional alarm, and keeps
-- a per-night timing log you can post to chat.
--
-- It deliberately does NOT try to name *who* pulled. In Midnight (12.0) addons
-- can't read the combat log live, so the puller could only ever be guessed (boss
-- target, then damage meter) -- which was wrong exactly for the interesting cases
-- (a pull set off by a totem, pet, trap or DoT). Naming the puller accurately is
-- the job of the companion log parser (tools/prepull_report.py, see the README),
-- which reads WoWCombatLog.txt after the session. This module records the pull
-- timing it lines up with.

local addonName, ns = ...

local M = {}
ns.WhoPulled = M
ns:RegisterModule("whoPulled", M)

M.name    = "PrePull"
M.desc    = "How early/late each boss was pulled vs the timer, with an alarm and a log."
M.default = true
M.hasUI   = true

-- ---------------------------------------------------------------------------
-- Config (persisted under ns.db.whoPulled)
-- ---------------------------------------------------------------------------
local DEFAULTS = {
    sound           = false,   -- opt-in: play an alarm on each announced pull
    soundName       = "Raid Warning",  -- which alarm (see M:SoundList)
    onTimeWindow    = 0.25,    -- +/- seconds around 0 still counts as "on time"
    maxPullTimeDiff = 10,      -- if |now - expected| exceeds this, treat as untimed
    decimals        = 2,       -- decimals shown in the seconds value
    announceEarly   = true,    -- show a banner for each timing class (recording
    announceOnTime  = true,    -- always happens regardless, so the log stays
    announceLate    = true,    -- complete even with banners off)
    announceUntimed = true,
}

local LSM  -- LibSharedMedia-3.0, resolved lazily; false once probed and absent

local kSessionGap = 30 * 60   -- start a new session after a 30-minute gap

local GROUP_CHANNELS = { PARTY = true, RAID = true, INSTANCE_CHAT = true }

-- ===========================================================================
-- Timing capture: DBM/BigWigs pull-timer message + Blizzard countdown
-- ===========================================================================
function M:MaySendPullTimer(sender)
    return UnitIsGroupLeader(sender) or UnitIsGroupAssistant(sender)
        or ((self.inInstanceGroup or not self.inRaid)
            and UnitGroupRolesAssigned(sender) == "TANK")
end

function M:CHAT_MSG_ADDON(prefix, message, channel, sender)
    -- DBM and BigWigs both broadcast a DBM-format pull timer (prefix "D5").
    if not (prefix and prefix:sub(1, 2) == "D5" and GROUP_CHANNELS[channel]) then
        return
    end
    local _, _, ty, duration = strsplit("\t", message)
    if ty ~= "PT" then return end
    duration = tonumber(duration or 0) or 0
    if IsEncounterInProgress()
        or (self.inParty and not self:MaySendPullTimer(sender))
        or (duration > 60 or (duration > 0 and duration < 3) or duration < 0) then
        return
    end
    self.expectedDBM = (duration == 0) and nil or (GetTime() + duration)
end

function M:START_TIMER(timerType, timeRemaining)
    if timerType == TIMER_TYPE_PLAYER_COUNTDOWN then
        self.expectedBlizz = GetTime() + timeRemaining
    end
end
function M:STOP_TIMER_OF_TYPE(timerType)
    if timerType == TIMER_TYPE_PLAYER_COUNTDOWN then self.expectedBlizz = nil end
end
function M:START_PLAYER_COUNTDOWN(_, timeRemaining)
    self.expectedBlizz = GetTime() + timeRemaining
end
function M:CANCEL_PLAYER_COUNTDOWN()
    self.expectedBlizz = nil
end

-- Returns kind ("early"|"ontime"|"late"|"untimed") and a human description.
function M:Classify(diff)
    if not diff then return "untimed", "Boss pulled" end
    if diff <= -self.onTimeWindow then
        return "early", format("Boss pulled %." .. self.decimals .. "f seconds early", -diff)
    elseif diff < self.onTimeWindow then
        return "ontime", "Boss pulled on time"
    end
    return "late", format("Boss pulled %." .. self.decimals .. "f seconds late", diff)
end

function M:ClassEnabled(kind)
    if kind == "early"  then return self.announceEarly end
    if kind == "ontime" then return self.announceOnTime end
    if kind == "late"   then return self.announceLate end
    return self.announceUntimed
end

-- ===========================================================================
-- Alarm sounds
-- ===========================================================================
-- Built-in game sounds (SOUNDKIT) -- always available, no library required.
local BUILTIN = {
    { "Raid Warning",    "RAID_WARNING" },
    { "Ready Check",     "READY_CHECK" },
    { "Alarm Clock",     "ALARM_CLOCK_WARNING_3" },
    { "Boss Whisper",    "UI_RAID_BOSS_WHISPER_WARNING" },
    { "Quest Complete",  "UI_AUTO_QUEST_COMPLETE" },
    { "Auction Open",    "AUCTION_WINDOW_OPEN" },
    { "PvP Queue Ready", "PVPTHROUGHQUEUE" },
}

-- The selectable alarm sounds: the built-ins above, plus every sound registered
-- with LibSharedMedia-3.0 (the shared pool DBM / WeakAuras / Details / ElvUI use)
-- when that library is loaded. Each entry is { name = display, play = fn }.
function M:SoundList()
    local list, seen = {}, {}
    local function add(name, play)
        if name and not seen[name] then
            seen[name] = true
            list[#list + 1] = { name = name, play = play }
        end
    end
    for _, b in ipairs(BUILTIN) do
        local id = SOUNDKIT and SOUNDKIT[b[2]]
        if id then add(b[1], function() pcall(PlaySound, id, "Master") end) end
    end
    if LSM == nil then LSM = (LibStub and LibStub("LibSharedMedia-3.0", true)) or false end
    if LSM then
        for _, name in ipairs(LSM:List("sound")) do
            local file = LSM:Fetch("sound", name, true)
            if file then add(name, function() pcall(PlaySoundFile, file, "Master") end) end
        end
    end
    return list
end

function M:FindSound(name)
    for _, e in ipairs(self:SoundList()) do
        if e.name == name then return e end
    end
end

-- Play a sound by display name; falls back to the first available one.
function M:PlaySoundByName(name)
    local e = self:FindSound(name) or self:SoundList()[1]
    if e then e.play() end
end

function M:PlayAlarm()
    self:PlaySoundByName(self.soundName)
end

-- Local banner (RaidWarningFrame) + optional alarm. No chat: Midnight blocks
-- addon chat in combat, and the shareable artifact is the log, posted manually.
function M:Announce(msg)
    if RaidNotice_AddMessage and RaidWarningFrame then
        local info = ChatTypeInfo and ChatTypeInfo["RAID_WARNING"]
        RaidNotice_AddMessage(RaidWarningFrame, msg, info or { r = 1, g = 0.3, b = 0.3 })
    else
        ns:Print(msg)
    end
    if self.sound then self:PlayAlarm() end
end

-- ===========================================================================
-- History: per-session timing log
-- ===========================================================================
function M:GetOrCreateSession(ts)
    local sessions = self.db.sessions
    local current = sessions[#sessions]
    local name, _, _, _, _, _, _, instanceID = GetInstanceInfo()
    if current and current.instanceID == instanceID
        and (ts - (current.lastPullTs or current.startTs or 0)) < kSessionGap then
        current.lastPullTs = ts
        return current
    end
    local s = {
        startTs = ts, lastPullTs = ts,
        instanceID = instanceID, instanceName = tostring(name or "?"),
        pulls = {},
    }
    sessions[#sessions + 1] = s
    while #sessions > 50 do table.remove(sessions, 1) end
    return s
end

function M:RecordPull(ctx)
    if not (self.db and ctx) then return end
    local record = {
        ts            = (GetServerTime and GetServerTime()) or time(),
        -- Local wall-clock stamp in the same shape WoWCombatLog.txt uses, so the
        -- companion log parser (tools/prepull_report.py) can line each recorded
        -- pull up with its ENCOUNTER_START line and add the real puller. encounterID
        -- is the primary join key; the timestamp disambiguates repeated pulls.
        localTime     = date and date("%Y-%m-%d %H:%M:%S") or nil,
        encounterID   = ctx.encounterID,
        encounterName = tostring(ctx.encounterName or "?"),
        pullTimeDiff  = ctx.pullTimeDiff,
    }
    local session = self:GetOrCreateSession(record.ts)
    session.pulls[#session.pulls + 1] = record
    while #session.pulls > 500 do table.remove(session.pulls, 1) end
end

local function classifyShort(diff, window)
    window = window or 0.005
    if not diff then return "untimed" end
    if diff <= -window then return format("%.2fs early", -diff) end
    if diff < window then return "on time" end
    return format("%.2fs late", diff)
end

-- Pick the session to show: most recent in the current instance, else latest.
local function resolveScope(sessions)
    if #sessions == 0 then return nil end
    local _, itype, _, _, _, _, _, instanceID = GetInstanceInfo()
    if instanceID and itype and itype ~= "none" then
        for i = #sessions, 1, -1 do
            if sessions[i].instanceID == instanceID then return sessions[i] end
        end
    end
    return sessions[#sessions]
end

function M:BuildReport()
    local sessions = self.db and self.db.sessions or {}
    local session = resolveScope(sessions)
    if not (session and session.pulls and #session.pulls > 0) then
        return "PrePull - no pulls recorded yet."
    end

    local pulls = session.pulls
    local early, ontime, late, untimed = 0, 0, 0, 0
    for _, p in ipairs(pulls) do
        if not p.pullTimeDiff then untimed = untimed + 1
        elseif p.pullTimeDiff <= -0.005 then early = early + 1
        elseif p.pullTimeDiff < 0.005 then ontime = ontime + 1
        else late = late + 1 end
    end
    local summary = {}
    if early   > 0 then summary[#summary + 1] = early   .. " early"    end
    if late    > 0 then summary[#summary + 1] = late    .. " late"     end
    if ontime  > 0 then summary[#summary + 1] = ontime  .. " on time"  end
    if untimed > 0 then summary[#summary + 1] = untimed .. " untimed"  end

    local lines = { format("PrePull - %s - %d pull%s%s",
        tostring(session.instanceName or "?"), #pulls, #pulls == 1 and "" or "s",
        #summary > 0 and (" (" .. table.concat(summary, ", ") .. ")") or "") }
    for i, p in ipairs(pulls) do
        local clock = p.localTime and p.localTime:match("(%d%d:%d%d:%d%d)$")
        lines[#lines + 1] = format("%2d. %s%s - %s", i,
            clock and (clock .. "  ") or "", tostring(p.encounterName or "?"),
            classifyShort(p.pullTimeDiff))
    end
    return table.concat(lines, "\n")
end

-- ===========================================================================
-- Encounter flow
-- ===========================================================================
function M:FirePull(ctx)
    ctx.recorded = true
    if self:ClassEnabled(ctx.kind) then
        self:Announce(ctx.desc .. ".")   -- local banner + optional alarm (timing only)
    end
    self:RecordPull(ctx)
end

function M:PLAYER_ENTERING_WORLD()
    self:GROUP_ROSTER_UPDATE()
    self:UPDATE_INSTANCE_INFO()
end
function M:GROUP_ROSTER_UPDATE()
    self.inParty = IsInGroup()
    self.inRaid  = IsInRaid()
    self.inInstanceGroup = IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
end
function M:UPDATE_INSTANCE_INFO()
    self.instanceID = select(8, GetInstanceInfo())
    self.inInstance = IsInInstance()
end

function M:ENCOUNTER_END()
    self.pullContext = nil
end

function M:ENCOUNTER_START(encounterID, encounterName)
    -- Raid encounters only.
    local _, instanceType = IsInInstance()
    if instanceType ~= "raid" then return end

    local now = GetTime()
    -- Some bosses re-fire ENCOUNTER_START on phase changes; skip duplicates.
    if self.pullContext and self.pullContext.encounterID == encounterID
        and (now - (self.pullContext.pullTime or 0)) < 60 then
        return
    end

    local expected = self.expectedDBM or self.expectedBlizz
    local diff = expected and abs(now - expected) <= self.maxPullTimeDiff
        and (now - expected) or nil
    self.expectedDBM, self.expectedBlizz = nil, nil

    local kind, desc = self:Classify(diff)
    self.pullContext = {
        pullTime = now, pullTimeDiff = diff, kind = kind, desc = desc,
        encounterID = encounterID, encounterName = encounterName,
    }
    self:FirePull(self.pullContext)
end

-- ===========================================================================
-- Report window (themed with ns.UI, like the other modules)
-- ===========================================================================
local UI = ns.UI
local theme, StyleFont = UI.theme, UI.StyleFont

local frame  -- built lazily

-- A labeled on/off toggle bound to ns.db.whoPulled[key] (and M[key]).
local function settingToggle(y, label, key)
    local t = UI.CreateToggle(frame)
    t:SetPoint("TOPLEFT", 16, y)
    t:SetChecked(M[key])
    t:SetScript("OnClick", function(self)
        local on = not self:GetChecked()
        self:SetChecked(on)
        M[key], ns.db.whoPulled[key] = on, on
    end)
    local fs = frame:CreateFontString(nil, "OVERLAY")
    StyleFont(fs, 12, theme.textDim)
    fs:SetPoint("LEFT", t, "RIGHT", 8, 0)
    fs:SetText(label)
    return t, fs
end

function M:PostReport(channel)
    if InCombatLockdown and InCombatLockdown() then
        ns:Print("can't post the report while in combat.")
        return
    end
    if not (self.db and self.db.sessions and #self.db.sessions > 0) then
        ns:Print("no pulls recorded yet.")
        return
    end
    local sender = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    local n = 0
    for line in self:BuildReport():gmatch("[^\n]+") do
        sender(line, channel)
        n = n + 1
    end
    ns:Print(format("posted %d line(s) to %s.", n, channel))
end

function M:RefreshReport()
    if frame then frame.edit:SetText(self:BuildReport()) end
end

function M:BuildOptions(parent)
    frame = parent   -- the shell's content pane; all `frame.*` refs below still hold

    -- Settings strip.
    local _, soundLabel = settingToggle(-44, "Alarm sound on pull", "sound")

    local soundDD = UI.CreateDropdown(frame, 150, 18)
    soundDD:SetPoint("LEFT", soundLabel, "RIGHT", 10, 0)
    local names = {}
    for _, e in ipairs(M:SoundList()) do names[#names + 1] = e.name end
    soundDD:SetOptions(names)
    soundDD:SetValue(M.soundName)
    soundDD.OnSelect = function(value)
        M.soundName, ns.db.whoPulled.soundName = value, value
        M:PlaySoundByName(value)   -- preview the pick
    end

    local previewBtn = UI.CreateFlatButton(frame, "Play", 44, 18, theme.accent)
    previewBtn:SetPoint("LEFT", soundDD, "RIGHT", 6, 0)
    previewBtn:SetScript("OnClick", function() M:PlaySoundByName(M.soundName) end)

    local hint = frame:CreateFontString(nil, "OVERLAY")
    StyleFont(hint, 11, theme.textDim)
    hint:SetPoint("TOPLEFT", 16, -78)
    hint:SetPoint("TOPRIGHT", -16, -78)
    hint:SetJustifyH("LEFT")
    hint:SetText("When each boss was pulled and how early/late vs the timer. For *who* "
        .. "pulled (incl. totem/pet pulls), run the companion log tool - see the README.")

    -- Copyable timing log. Fills the pane between the hint and the button row
    -- (the bulk buttons sit 16px up, are 24px tall; leave an 8px gutter -> 48).
    local box = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    box:SetPoint("TOPLEFT", 16, -114)
    box:SetPoint("TOPRIGHT", -16, -114)
    box:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 48)
    box:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, 48)
    UI.ApplyBackdrop(box, theme.bgInput, theme.borderHi)

    local scroll = CreateFrame("ScrollFrame", nil, box)
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -4, 4)
    scroll:EnableMouseWheel(true)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    StyleFont(edit, 13, theme.text)
    edit:SetWidth(400)   -- conservative start; snapped to the viewport below
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(edit)
    frame.edit = edit
    -- Match the edit box width to the visible scroll area so report lines wrap
    -- inside the box instead of overflowing the right edge.
    scroll:SetScript("OnSizeChanged", function(self, w)
        if w and w > 0 then edit:SetWidth(w) end
    end)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = math.max(0, edit:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.min(maxScroll, math.max(0, self:GetVerticalScroll() - delta * 24)))
    end)

    -- Buttons.
    local raidBtn = UI.CreateFlatButton(frame, "Report to Raid", 130, 24, theme.accent)
    raidBtn:SetPoint("BOTTOMLEFT", 16, 16)
    raidBtn:SetScript("OnClick", function() M:PostReport("RAID") end)

    local partyBtn = UI.CreateFlatButton(frame, "Report to Party", 130, 24, theme.accent)
    partyBtn:SetPoint("LEFT", raidBtn, "RIGHT", 6, 0)
    partyBtn:SetScript("OnClick", function() M:PostReport("PARTY") end)

    local refreshBtn = UI.CreateFlatButton(frame, "Refresh", 90, 24, theme.text)
    refreshBtn:SetPoint("LEFT", partyBtn, "RIGHT", 6, 0)
    refreshBtn:SetScript("OnClick", function() M:RefreshReport() end)

    local clearBtn = UI.CreateFlatButton(frame, "Clear", 90, 24, theme.red)
    clearBtn:SetPoint("LEFT", refreshBtn, "RIGHT", 6, 0)
    clearBtn:SetScript("OnClick", function()
        ns.db.whoPulled.sessions = {}
        M.db.sessions = ns.db.whoPulled.sessions
        M:RefreshReport()
    end)

    M:RefreshReport()
end

-- ===========================================================================
-- Module lifecycle
-- ===========================================================================
function M:OnInitialize()
    ns.db.whoPulled = ns.db.whoPulled or {}
    self.db = ns.db.whoPulled
    for k, v in pairs(DEFAULTS) do
        if self.db[k] == nil then self.db[k] = v end
        self[k] = self.db[k]
    end
    self.db.sessions = self.db.sessions or {}
end

-- The profile system refills ns.db.whoPulled in place when the active profile
-- changes; re-read our cached fields (M[k]) from it and ensure the session log
-- exists, then refresh the window if it's open.
function M:OnProfileChanged()
    self.db = ns.db.whoPulled
    for k in pairs(DEFAULTS) do self[k] = self.db[k] end
    self.db.sessions = self.db.sessions or {}
    if frame and frame:IsShown() then self:RefreshReport() end
end

local EVENTS = {
    "CHAT_MSG_ADDON", "START_TIMER", "STOP_TIMER_OF_TYPE",
    "START_PLAYER_COUNTDOWN", "CANCEL_PLAYER_COUNTDOWN",
    "PLAYER_ENTERING_WORLD", "GROUP_ROSTER_UPDATE", "UPDATE_INSTANCE_INFO",
    "ENCOUNTER_START", "ENCOUNTER_END",
}

function M:OnEnable()
    if not self.listener then
        self.listener = CreateFrame("Frame")
        self.listener:SetScript("OnEvent", function(_, event, ...)
            local handler = self[event]
            if handler then handler(self, ...) end
        end)
    end
    -- Receiving CHAT_MSG_ADDON requires the prefix be registered.
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, "D5")
    end
    for _, e in ipairs(EVENTS) do
        pcall(self.listener.RegisterEvent, self.listener, e)
    end
    self:PLAYER_ENTERING_WORLD()
end

function M:OnDisable()
    if self.listener then self.listener:UnregisterAllEvents() end
    if frame and frame:IsShown() then frame:Hide() end
end

function M:Open()
    if ns.Config then ns.Config:OpenModule(self.key); self:RefreshReport() end
end

function M:Toggle()
    if ns.Config then ns.Config:ToggleModule(self.key) end
end
