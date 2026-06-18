-- OppositeQOL - Who Pulled
-- Calls out who pulled the boss, how early/late it was vs the DBM/BigWigs pull
-- timer, plays an optional alarm, and keeps a per-night leaderboard of pulls.
--
-- Midnight (12.0) reality this module is built around:
--   * COMBAT_LOG_EVENT_UNFILTERED errors on register and combat data is
--     "secret" during raid/M+ encounters, so "first hit via combat log" is NOT
--     possible at pull time. We resolve the puller from the two sanctioned
--     signals instead (boss target, then C_DamageMeter) -- see ResolvePuller.
--   * Addon-initiated chat is blocked in combat, so live pulls show a local
--     BANNER (RaidWarningFrame); the shareable artifact is the leaderboard,
--     posted to chat out of combat.

local addonName, ns = ...

local M = {}
ns.WhoPulled = M
ns:RegisterModule("whoPulled", M)

M.name    = "Who Pulled"
M.desc    = "Who pulled, how early/late vs the pull timer, with a leaderboard."
M.default = true
M.hasUI   = true

-- ---------------------------------------------------------------------------
-- Config (persisted under ns.db.whoPulled)
-- ---------------------------------------------------------------------------
local DEFAULTS = {
    sound           = false,   -- opt-in: play an alarm on each announced pull
    soundName       = "Raid Warning",  -- which alarm (see M:SoundList)
    chatAnnounce    = false,   -- opt-in: post the prepuller to chat (deferred)
    chatChannel     = "AUTO",  -- AUTO (group) | SAY | YELL
    onTimeWindow    = 0.25,    -- +/- seconds around 0 still counts as "on time"
    maxPullTimeDiff = 10,      -- if |now - expected| exceeds this, treat as untimed
    decimals        = 2,       -- decimals shown in the seconds value
    announceEarly   = true,    -- show a banner for each timing class (recording
    announceOnTime  = true,    -- always happens regardless, so the leaderboard
    announceLate    = true,    -- stays complete even with banners off)
    announceUntimed = true,
}

-- Midnight: some API returns "secret" values that throw on compare / table-key
-- use. Guard every name/class/GUID before touching it.
local issecretvalue = _G.issecretvalue or function() return false end

local LSM  -- LibSharedMedia-3.0, resolved lazily; false once probed and absent

local kPollDelays = { 0.2, 0.5, 1.0, 2.0, 4.0 }  -- snapshot retries after pull
local kSessionGap = 30 * 60                       -- new session after a 30m gap

local GROUP_CHANNELS = { PARTY = true, RAID = true, INSTANCE_CHAT = true }

-- ===========================================================================
-- Small helpers
-- ===========================================================================
local function safeStr(v)
    if type(v) ~= "string" or issecretvalue(v) or v == "" then return nil end
    return v
end

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
-- Who pulled: boss target (preferred) -> damage meter (fallback)
-- ===========================================================================

-- The boss targets whoever holds aggro; at pull that's the puller (typically
-- the tank). This is the most reliable signal and doubles as the isTank flag.
function M:GetPullerFromBossTarget()
    for i = 1, 8 do
        local unit = "boss" .. i .. "target"
        if UnitExists(unit) and UnitIsPlayer(unit) then
            local name, realm = UnitName(unit)
            name = safeStr(name)
            if name and name ~= UNKNOWN then
                local _, classFile = UnitClass(unit)
                realm = safeStr(realm)
                return {
                    name          = realm and (name .. "-" .. realm) or name,
                    classFilename = safeStr(classFile),
                    isTank        = true,  -- holding aggro == tank for this pull
                }
            end
        end
    end
end

-- Map a resolved name back to its assigned group role, so a tank picked up via
-- the damage-meter path (which doesn't expose roles) still gets exempted.
local function lookupRoleByName(playerName)
    -- issecretvalue MUST be checked before any string op including ==.
    if type(playerName) ~= "string" or issecretvalue(playerName) or playerName == "" then
        return nil
    end
    local short = playerName:match("^([^-]+)") or playerName
    local function matches(unit)
        local n = GetUnitName(unit, true) or UnitName(unit)
        if type(n) ~= "string" or issecretvalue(n) or n == "" then return false end
        return n == playerName or (n:match("^([^-]+)") or n) == short
    end
    local ok, role = pcall(function()
        if matches("player") then return UnitGroupRolesAssigned("player") end
        local prefix = IsInRaid() and "raid" or "party"
        for i = 1, (IsInRaid() and 40 or 4) do
            local unit = prefix .. i
            if UnitExists(unit) and matches(unit) then
                return UnitGroupRolesAssigned(unit)
            end
        end
    end)
    return ok and role or nil
end

function M:GetPullerFromDamageMeter()
    if not (C_DamageMeter and C_DamageMeter.GetCombatSessionFromType
            and Enum and Enum.DamageMeterSessionType and Enum.DamageMeterType) then
        return nil
    end
    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
        Enum.DamageMeterSessionType.Current, Enum.DamageMeterType.DamageDone)
    if not ok or not session or not session.combatSources then return nil end

    -- Highest damage so far. Damage values may be secret-wrapped, so guard the
    -- compare; if every compare throws, fall back to the first listed actor.
    local best, bestTotal = nil, 0
    for _, actor in ipairs(session.combatSources) do
        local total = actor.totalAmount or actor.total
        pcall(function()
            if total and total > bestTotal then best, bestTotal = actor, total end
        end)
    end
    if not best and #session.combatSources > 0 then best = session.combatSources[1] end

    if best and not best.isTank and lookupRoleByName(best.name) == "TANK" then
        best.isTank = true
    end
    return best
end

function M:ResolvePuller()
    return self:GetPullerFromBossTarget() or self:GetPullerFromDamageMeter()
end

-- ===========================================================================
-- Announce (local banner + optional alarm)
-- ===========================================================================
-- Bare name (no color), with class/Unknown fallbacks. Used for chat, which
-- doesn't render color escapes the way the banner does.
function M:PlainName(actor)
    if not actor then return "[Unknown]" end
    local name  = safeStr(actor.name)
    local class = safeStr(actor.classFilename)
    return name or (class and ("[Unknown " .. class .. "]")) or "[Unknown]"
end

function M:FormatName(actor)
    local display = self:PlainName(actor)
    local class = actor and safeStr(actor.classFilename)
    if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        local c = RAID_CLASS_COLORS[class]
        return format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, display)
    end
    return display
end

-- Tanks are supposed to pull -> drop the "early" flag for them.
function M:ComposeMessage(ctx, nameStr, actor)
    local namePart = " by " .. nameStr
    if actor and actor.isTank and ctx.pullTimeDiff and ctx.pullTimeDiff < -self.onTimeWindow then
        return "Boss pulled" .. namePart .. "."
    end
    return ctx.desc .. namePart .. "."
end

function M:BuildMessage(ctx, actor) return self:ComposeMessage(ctx, self:FormatName(actor), actor) end

-- Chat call-out for prepulls (early pulls only). Deliberately ignores the tank
-- exemption: the boss-target resolver marks every puller isTank, so exempting
-- tanks here would hide the actual culprit. An early pull is an early pull.
function M:BuildPrepullChat(ctx, actor)
    local secs = format("%." .. self.decimals .. "f", -(ctx.pullTimeDiff or 0))
    local name = actor and safeStr(actor.name)
    local culprit = name and ("Who prepulled? " .. name .. ".") or "Who prepulled? (couldn't identify)."
    return format("%s: Prepulled the boss by %ssec. %s", addonName, secs, culprit)
end

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

function M:Announce(msg)
    if RaidNotice_AddMessage and RaidWarningFrame then
        local info = ChatTypeInfo and ChatTypeInfo["RAID_WARNING"]
        RaidNotice_AddMessage(RaidWarningFrame, msg, info or { r = 1, g = 0.3, b = 0.3 })
    else
        ns:Print(msg)
    end
    if self.sound then self:PlayAlarm() end
end

function M:ResolveChatChannel()
    local ch = self.chatChannel or "AUTO"
    if ch == "SAY" or ch == "YELL" then return ch end
    if self.inRaid then return "RAID" elseif self.inParty then return "PARTY" end
end

function M:SendChat(msg)
    local channel = self:ResolveChatChannel()
    if not channel then return end
    local sender = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    pcall(sender, msg, channel)
end

-- Midnight blocks addon SendChatMessage during combat lockdown (it pops the
-- "action blocked" dialog and drops the line), so we can't call out the puller
-- live. Queue it and flush the instant the group leaves combat instead. Out of
-- combat we just send immediately.
function M:AnnounceChat(msg)
    if InCombatLockdown and InCombatLockdown() then
        self.chatQueue = self.chatQueue or {}
        if #self.chatQueue < 10 then self.chatQueue[#self.chatQueue + 1] = msg end
    else
        self:SendChat(msg)
    end
end

function M:PLAYER_REGEN_ENABLED()
    if not self.chatQueue then return end
    for _, msg in ipairs(self.chatQueue) do self:SendChat(msg) end
    self.chatQueue = nil
end

-- ===========================================================================
-- History: sessions + per-puller leaderboard
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

function M:RecordPull(ctx, actor)
    if not (self.db and ctx) then return end
    local record = {
        ts            = (GetServerTime and GetServerTime()) or time(),
        encounterName = tostring(ctx.encounterName or "?"),
        pullTimeDiff  = ctx.pullTimeDiff,
        pullerName    = actor and safeStr(actor.name) or nil,
        pullerClass   = actor and safeStr(actor.classFilename) or nil,
        pullerIsTank  = actor and actor.isTank or false,
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

-- Aggregate pulls per puller (tanks already filtered out by the caller).
local function aggregate(pulls)
    local agg, order = {}, {}
    for _, p in ipairs(pulls) do
        local key = safeStr(p.pullerName)
            or (safeStr(p.pullerClass) and ("[Unknown " .. p.pullerClass .. "]"))
            or "[Unknown]"
        local a = agg[key]
        if not a then
            a = { name = key, count = 0, early = 0, ontime = 0, late = 0, untimed = 0 }
            agg[key], order[#order + 1] = a, a
        end
        a.count = a.count + 1
        if not p.pullTimeDiff then a.untimed = a.untimed + 1
        elseif p.pullTimeDiff <= -0.005 then a.early = a.early + 1
        elseif p.pullTimeDiff < 0.005 then a.ontime = a.ontime + 1
        else a.late = a.late + 1 end
    end
    table.sort(order, function(a, b) return a.count > b.count end)
    return order
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

function M:BuildLeaderboard()
    local sessions = self.db and self.db.sessions or {}
    local session = resolveScope(sessions)
    if not session then return "Who Pulled - no pulls recorded yet." end

    local nonTank, tankHidden = {}, 0
    for _, p in ipairs(session.pulls or {}) do
        if p.pullerIsTank then tankHidden = tankHidden + 1 else nonTank[#nonTank + 1] = p end
    end

    local scope = tostring(session.instanceName or "?")
    if #nonTank == 0 then
        return format("Who Pulled - %s - no non-tank pulls recorded yet.", scope)
    end

    local lines = {}
    lines[#lines + 1] = format("Who Pulled - %s - %d non-tank pull%s%s",
        scope, #nonTank, #nonTank == 1 and "" or "s",
        tankHidden > 0 and format(" (%d tank pulls hidden)", tankHidden) or "")

    local agg = aggregate(nonTank)
    for i, a in ipairs(agg) do
        local parts = {}
        if a.early   > 0 then parts[#parts + 1] = a.early   .. " early"   end
        if a.late    > 0 then parts[#parts + 1] = a.late    .. " late"    end
        if a.ontime  > 0 then parts[#parts + 1] = a.ontime  .. " on time" end
        if a.untimed > 0 then parts[#parts + 1] = a.untimed .. " untimed" end
        lines[#lines + 1] = format("%2d. %s - %d (%s)", i, a.name, a.count,
            #parts > 0 and table.concat(parts, ", ") or "-")
    end
    return table.concat(lines, "\n")
end

-- ===========================================================================
-- Encounter flow
-- ===========================================================================
function M:FirePull(ctx, actor)
    ctx.recorded, ctx.puller = true, actor
    if self:ClassEnabled(ctx.kind) then
        self:Announce(self:BuildMessage(ctx, actor))            -- local banner + sound
    end
    if self.chatAnnounce and ctx.kind == "early" then
        self:AnnounceChat(self:BuildPrepullChat(ctx, actor))    -- deferred chat call-out
    end
    self:RecordPull(ctx, actor)
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

    -- Boss target is often already set at engage -> fire immediately. Otherwise
    -- the damage-meter event + polling resolve it over the next few seconds.
    local immediate = self:GetPullerFromBossTarget()
    if immediate then
        self:FirePull(self.pullContext, immediate)
    end
    C_Timer.After(kPollDelays[1], function() self:Poll(now, 1) end)
end

-- Fires the soonest the damage meter populates; usually beats the poll loop.
function M:DAMAGE_METER_COMBAT_SESSION_UPDATED()
    local ctx = self.pullContext
    if not ctx or ctx.recorded then return end
    local actor = self:ResolvePuller()
    if actor then self:FirePull(ctx, actor) end
end

function M:Poll(pullTime, index)
    local ctx = self.pullContext
    if not ctx or ctx.pullTime ~= pullTime or ctx.recorded then return end

    local actor = self:ResolvePuller()
    if actor then
        self:FirePull(ctx, actor)
    elseif kPollDelays[index + 1] then
        C_Timer.After(kPollDelays[index + 1] - kPollDelays[index],
            function() self:Poll(pullTime, index + 1) end)
    else
        self:FirePull(ctx, nil)  -- exhausted -> record as [Unknown]
    end
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
    for line in self:BuildLeaderboard():gmatch("[^\n]+") do
        sender(line, channel)
        n = n + 1
    end
    ns:Print(format("posted %d line(s) to %s.", n, channel))
end

function M:RefreshReport()
    if frame then frame.edit:SetText(self:BuildLeaderboard()) end
end

local function BuildUI()
    frame = UI.CreatePanel({
        name = "OppositeQOLWhoPulledFrame", width = 560, height = 470,
        title = "OppositeQOL", subtitle = "Who Pulled", posKey = "whoPulled",
    })

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

    local _, chatLabel = settingToggle(-70, "Announce puller in chat", "chatAnnounce")

    local CYCLE = { "AUTO", "SAY", "YELL" }
    local chanBtn = UI.CreateFlatButton(frame, M.chatChannel or "AUTO", 60, 18, theme.accent)
    chanBtn:SetPoint("LEFT", chatLabel, "RIGHT", 10, 0)
    chanBtn:SetScript("OnClick", function(self)
        local idx = 1
        for i, v in ipairs(CYCLE) do if v == (M.chatChannel or "AUTO") then idx = i break end end
        local nxt = CYCLE[(idx % #CYCLE) + 1]
        M.chatChannel, ns.db.whoPulled.chatChannel = nxt, nxt
        self:SetLabel(nxt)
    end)

    local hint = frame:CreateFontString(nil, "OVERLAY")
    StyleFont(hint, 11, theme.textDim)
    hint:SetPoint("TOPLEFT", 16, -92)
    hint:SetText("Midnight blocks addon chat mid-pull, so it posts when the group leaves combat.")

    -- Copyable leaderboard text.
    local box = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    box:SetPoint("TOPLEFT", 16, -114)
    box:SetPoint("TOPRIGHT", -16, -114)
    box:SetHeight(278)
    UI.ApplyBackdrop(box, theme.bgInput, theme.borderHi)

    local scroll = CreateFrame("ScrollFrame", nil, box)
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -4, 4)
    scroll:EnableMouseWheel(true)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    StyleFont(edit, 13, theme.text)
    edit:SetWidth(520)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(edit)
    frame.edit = edit
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

local EVENTS = {
    "CHAT_MSG_ADDON", "START_TIMER", "STOP_TIMER_OF_TYPE",
    "START_PLAYER_COUNTDOWN", "CANCEL_PLAYER_COUNTDOWN",
    "PLAYER_ENTERING_WORLD", "GROUP_ROSTER_UPDATE", "UPDATE_INSTANCE_INFO",
    "ENCOUNTER_START", "ENCOUNTER_END", "DAMAGE_METER_COMBAT_SESSION_UPDATED",
    "PLAYER_REGEN_ENABLED",
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
    if not self.enabled then
        ns:Print(self.name .. " is disabled - enable it with /oqol.")
        return
    end
    if not frame then BuildUI() end
    self:RefreshReport()
    frame:Show()
end

function M:Toggle()
    if not self.enabled then
        ns:Print(self.name .. " is disabled - enable it with /oqol.")
        return
    end
    if not frame then BuildUI() end
    if frame:IsShown() then frame:Hide() else self:Open() end
end
