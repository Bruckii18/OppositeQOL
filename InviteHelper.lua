-- OppositeQOL - Invite Helper
-- Paste an invite string, compare it against the current raid/party, and see:
--   * MISSING   - on your list but not in the raid yet (need an invite)
--   * NOT ON LIST - in the raid but not on your list (extra / re-arrange)
--
-- Expected paste format (the "invitelist:" prefix and trailing ";" are optional):
--   invitelist:Alpha-GrimBatol Bravo-TarrenMill Charlie-Draenor ... ;

local addonName, ns = ...

local IH = {}
ns.InviteHelper = IH
ns:RegisterModule("inviteHelper", IH)

-- Module metadata (used by the config window / slash commands).
IH.name    = "Invite Helper"
IH.desc    = "Compare a pasted list to your raid; invite or remove per name."
IH.default = true   -- enabled on first run
IH.hasUI   = true   -- shows an "Open" button in /oqol

-- ===========================================================================
-- Name / realm helpers
-- ===========================================================================

-- Realms in the game API come "normalized" (no spaces, apostrophes or hyphens),
-- e.g. "Tarren Mill" -> "TarrenMill", "Mal'Ganis" -> "MalGanis". We strip the
-- same characters from whatever the user pasted so both sides line up.
local function StripRealm(realm)
    if not realm then return "" end
    return (realm:gsub("[ '%-]", ""))
end

-- The player's own realm, normalized. Used when an entry has no "-Realm" part.
local function OwnRealm()
    local r = GetNormalizedRealmName and GetNormalizedRealmName()
    if not r or r == "" then
        r = StripRealm(GetRealmName() or "")
    end
    return r
end

-- Build a display string ("Name-Realm") and a lowercase match key from a raw
-- name + realm. Lowercasing only touches ASCII, but since both the pasted list
-- and the game roster get the exact same treatment, special characters such as
-- "ì", "ä" or "ö" still match correctly.
local function MakeEntry(name, realm)
    name = name:gsub("^%s+", ""):gsub("%s+$", "")   -- trim
    realm = StripRealm(realm)
    if realm == "" then realm = OwnRealm() end
    local display = name .. "-" .. realm
    return display, display:lower()
end

-- ===========================================================================
-- Data: current group roster + parsing the pasted list
-- ===========================================================================

-- Returns a table:  key ("name-realm" lowercased) -> display ("Name-Realm").
-- Works in a raid, in a party, or solo (solo just returns you, for testing).
local function GetGroupRoster()
    local roster = {}

    local function add(unit)
        local name, realm = UnitName(unit)
        if name and name ~= "" and name ~= UNKNOWN then
            local display, key = MakeEntry(name, realm or "")
            roster[key] = display
        end
    end

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            add("raid" .. i)
        end
    elseif IsInGroup() then
        add("player")
        for i = 1, GetNumGroupMembers() - 1 do
            add("party" .. i)
        end
    else
        add("player")
    end

    return roster
end

-- Parse the pasted string into a list of { display, key } entries (de-duped).
local function ParseInviteList(text)
    local entries, seen = {}, {}
    if not text or text == "" then return entries end

    -- Drop an optional leading "invitelist:" prefix (case-insensitive).
    local lower = text:lower()
    local p = lower:find("invitelist%s*:")
    if p then
        local colon = text:find(":", p, true)
        if colon then text = text:sub(colon + 1) end
    end

    -- Split on whitespace AND semicolons, so the trailing ";" just falls away.
    for token in text:gmatch("[^%s;]+") do
        -- Character names never contain "-", so the first "-" separates the
        -- realm. Using byte search keeps UTF-8 names intact.
        local dash = token:find("-", 1, true)
        local name, realm
        if dash then
            name = token:sub(1, dash - 1)
            realm = token:sub(dash + 1)
        else
            name, realm = token, ""
        end

        if name ~= "" then
            local display, key = MakeEntry(name, realm)
            if not seen[key] then
                seen[key] = true
                entries[#entries + 1] = { display = display, key = key }
            end
        end
    end

    return entries
end

-- Compare the pasted list against the live roster. Returns a result table.
local function Compare(text)
    local listEntries = ParseInviteList(text)

    local listSet = {}
    for _, e in ipairs(listEntries) do
        listSet[e.key] = e.display
    end

    local roster = GetGroupRoster()

    local missing, extra = {}, {}

    -- On the list but not in the group -> need an invite.
    for key, display in pairs(listSet) do
        if not roster[key] then
            missing[#missing + 1] = display
        end
    end

    -- In the group but not on the list -> extra / re-arrange candidate.
    local raidCount = 0
    for key, display in pairs(roster) do
        raidCount = raidCount + 1
        if not listSet[key] then
            extra[#extra + 1] = display
        end
    end

    local function byName(a, b) return a:lower() < b:lower() end
    table.sort(missing, byName)
    table.sort(extra, byName)

    return {
        missing   = missing,
        extra     = extra,
        listCount = #listEntries,
        raidCount = raidCount,
    }
end

-- ===========================================================================
-- Group actions
-- ===========================================================================

local function DoInvite(fullName)
    if C_PartyInfo and C_PartyInfo.InviteUnit then
        C_PartyInfo.InviteUnit(fullName)
    elseif InviteUnit then
        InviteUnit(fullName)
    end
end

local function DoUninvite(fullName)
    if C_PartyInfo and C_PartyInfo.UninviteUnit then
        C_PartyInfo.UninviteUnit(fullName)
    elseif UninviteUnit then
        UninviteUnit(fullName)
    end
end

local function CanInvite()
    return (not IsInGroup()) or UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
end

-- ===========================================================================
-- UI  (shared theme + helpers come from ns.UI)
-- ===========================================================================

local UI             = ns.UI
local theme          = UI.theme
local StyleFont      = UI.StyleFont
local CreateFlatButton = UI.CreateFlatButton
local ApplyBackdrop  = UI.ApplyBackdrop
local ROW_H          = 22

local function MarkRowDone(row, text)
    row.done = true
    row.nameFS:SetTextColor(unpack(theme.textDim))
    row.actionBtn:SetLabel(text)
    row.actionBtn:SetDisabled(true)
    row.hl:Hide()
end

local function CreateRow(lv)
    local row = CreateFrame("Button", nil, lv.child)
    row:SetHeight(ROW_H)

    local hl = row:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints()
    hl:SetColorTexture(unpack(theme.rowHover))
    hl:Hide()
    row.hl = hl

    row:SetScript("OnEnter", function() if not row.done then hl:Show() end end)
    row:SetScript("OnLeave", function() hl:Hide() end)

    local name = row:CreateFontString(nil, "OVERLAY")
    StyleFont(name, 13, theme.text)
    name:SetJustifyH("LEFT")
    name:SetPoint("LEFT", 8, 0)
    row.nameFS = name

    local btn = CreateFlatButton(row, lv.actionLabel, 58, 16, lv.actionColor)
    btn:SetPoint("RIGHT", -6, 0)
    btn:SetScript("OnClick", function(self)
        if self._disabled then return end
        lv.actionFn(row.itemName, row)
    end)
    btn:HookScript("OnEnter", function() if not row.done then hl:Show() end end)
    btn:HookScript("OnLeave", function() hl:Hide() end)
    row.actionBtn = btn

    name:SetPoint("RIGHT", btn, "LEFT", -8, 0)
    return row
end

-- A scrolling list of name rows, each with an Invite/Remove button.
local function CreateListView(parent, w, h, kind)
    local lv = { rows = {} }
    if kind == "invite" then
        lv.actionLabel, lv.actionColor = "Invite", theme.green
        lv.actionFn = function(name, row) IH:InviteOne(name, row) end
    else
        lv.actionLabel, lv.actionColor = "Remove", theme.red
        lv.actionFn = function(name, row) IH:RemoveOne(name, row) end
    end

    local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    container:SetSize(w, h)
    ApplyBackdrop(container, theme.bgInput, theme.borderHi)
    lv.container = container

    local scroll = CreateFrame("ScrollFrame", nil, container)
    scroll:SetPoint("TOPLEFT", 3, -3)
    scroll:SetPoint("BOTTOMRIGHT", -3, 3)
    scroll:EnableMouseWheel(true)
    lv.scroll = scroll

    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(w - 6, h - 6)
    scroll:SetScrollChild(child)
    lv.child = child

    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = math.max(0, child:GetHeight() - self:GetHeight())
        local new = math.min(maxScroll, math.max(0, self:GetVerticalScroll() - delta * ROW_H * 2))
        self:SetVerticalScroll(new)
    end)

    local empty = scroll:CreateFontString(nil, "OVERLAY")
    StyleFont(empty, 12, theme.textDim)
    empty:SetPoint("CENTER", 0, 0)
    empty:SetText("— none —")
    lv.empty = empty

    function lv:SetData(names)
        for i, nm in ipairs(names) do
            local row = self.rows[i]
            if not row then
                row = CreateRow(self)
                self.rows[i] = row
            end
            row.itemName = nm
            row.done = false
            row.nameFS:SetText(nm)
            row.nameFS:SetTextColor(unpack(theme.text))
            row.actionBtn:SetLabel(self.actionLabel)
            row.actionBtn:SetDisabled(false)
            row.hl:Hide()
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
            row:SetPoint("TOPRIGHT", 0, -(i - 1) * ROW_H)
            row:Show()
        end
        for i = #names + 1, #self.rows do
            self.rows[i]:Hide()
        end
        self.empty:SetShown(#names == 0)
        self.child:SetWidth(self.scroll:GetWidth())
        self.child:SetHeight(math.max(#names * ROW_H, self.scroll:GetHeight()))
        self.scroll:SetVerticalScroll(0)
    end

    function lv:MarkAllDone(text)
        for _, row in ipairs(self.rows) do
            if row:IsShown() and not row.done then
                MarkRowDone(row, text)
            end
        end
    end

    return lv
end

-- Confirm dialog before mass-kicking people.
StaticPopupDialogs["OQOL_UNINVITE_CONFIRM"] = {
    text = "Remove %d player(s) that are NOT on your list from the group?",
    button1 = YES,
    button2 = NO,
    OnAccept = function() IH:UninviteExtras() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- ===========================================================================
-- Main window
-- ===========================================================================

local frame  -- built lazily on first open

local function BuildUI()
    frame = UI.CreatePanel({
        name     = "OppositeQOLInviteFrame",
        width    = 580,
        height   = 532,
        title    = "OppositeQOL",
        subtitle = "Invite Helper",
        posKey   = "inviteHelper",
    })

    -- Input label.
    local inputLabel = frame:CreateFontString(nil, "OVERLAY")
    StyleFont(inputLabel, 12, theme.textDim)
    inputLabel:SetPoint("TOPLEFT", 16, -42)
    inputLabel:SetText("PASTE INVITE LIST")

    -- Input box (multi-line, wheel-scrollable).
    local inputBox = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    inputBox:SetPoint("TOPLEFT", 16, -58)
    inputBox:SetPoint("TOPRIGHT", -16, -58)
    inputBox:SetHeight(54)
    ApplyBackdrop(inputBox, theme.bgInput, theme.borderHi)

    local inputScroll = CreateFrame("ScrollFrame", nil, inputBox)
    inputScroll:SetPoint("TOPLEFT", 4, -4)
    inputScroll:SetPoint("BOTTOMRIGHT", -4, 4)
    inputScroll:EnableMouseWheel(true)

    local editBox = CreateFrame("EditBox", nil, inputScroll)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    StyleFont(editBox, 13, theme.text)
    editBox:SetTextInsets(2, 2, 2, 2)
    editBox:SetWidth(540)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    inputScroll:SetScrollChild(editBox)
    frame.editBox = editBox

    inputScroll:SetScript("OnMouseWheel", function(self, delta)
        local eb = self:GetScrollChild()
        local maxScroll = math.max(0, eb:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.min(maxScroll, math.max(0, self:GetVerticalScroll() - delta * 16)))
    end)
    inputBox:SetScript("OnMouseDown", function() editBox:SetFocus() end)

    -- Compare / Clear + status line.
    local compareBtn = CreateFlatButton(frame, "Compare", 90, 22, theme.accent)
    compareBtn:SetPoint("TOPLEFT", 16, -122)
    compareBtn:SetScript("OnClick", function() IH:RunCompare() end)

    local clearBtn = CreateFlatButton(frame, "Clear", 60, 22, theme.textDim)
    clearBtn:SetPoint("LEFT", compareBtn, "RIGHT", 6, 0)
    clearBtn:SetScript("OnClick", function()
        editBox:SetText("")
        ns.db.inviteHelper.lastInput = ""
        IH:RenderResult(nil)
    end)

    local status = frame:CreateFontString(nil, "OVERLAY")
    StyleFont(status, 12, theme.textDim)
    status:SetPoint("LEFT", clearBtn, "RIGHT", 12, 0)
    status:SetWidth(380)
    status:SetJustifyH("RIGHT")
    frame.status = status

    -- Column headers.
    local missingHeader = frame:CreateFontString(nil, "OVERLAY")
    StyleFont(missingHeader, 13, theme.green)
    missingHeader:SetPoint("TOPLEFT", 16, -156)
    frame.missingHeader = missingHeader

    local extraHeader = frame:CreateFontString(nil, "OVERLAY")
    StyleFont(extraHeader, 13, theme.red)
    extraHeader:SetPoint("TOPLEFT", 297, -156)
    frame.extraHeader = extraHeader

    -- Two list columns.
    local colW, colH = 267, 298
    IH.missingLV = CreateListView(frame, colW, colH, "invite")
    IH.missingLV.container:SetPoint("TOPLEFT", 16, -174)

    IH.extraLV = CreateListView(frame, colW, colH, "remove")
    IH.extraLV.container:SetPoint("TOPLEFT", 297, -174)

    -- Bulk action buttons.
    local inviteAllBtn = CreateFlatButton(frame, "Invite Missing", colW, 24, theme.green)
    inviteAllBtn:SetPoint("TOPLEFT", 16, -478)
    inviteAllBtn:SetScript("OnClick", function() IH:InviteMissing() end)
    frame.inviteAllBtn = inviteAllBtn

    local removeAllBtn = CreateFlatButton(frame, "Remove Not-On-List", colW, 24, theme.red)
    removeAllBtn:SetPoint("TOPLEFT", 297, -478)
    removeAllBtn:SetScript("OnClick", function()
        local extra = IH.lastResult and IH.lastResult.extra
        if extra and #extra > 0 then
            StaticPopup_Show("OQOL_UNINVITE_CONFIRM", #extra)
        end
    end)
    frame.removeAllBtn = removeAllBtn

    if ns.db.inviteHelper.lastInput then
        editBox:SetText(ns.db.inviteHelper.lastInput)
    end

    IH:RenderResult(nil)
end

-- ===========================================================================
-- Behaviour
-- ===========================================================================

function IH:RenderResult(result)
    if not frame then return end
    self.lastResult = result

    if not result then
        frame.missingHeader:SetText("MISSING — invite")
        frame.extraHeader:SetText("NOT ON LIST")
        self.missingLV:SetData({})
        self.extraLV:SetData({})
        frame.status:SetText("paste a list, then Compare")
        frame.inviteAllBtn:SetLabel("Invite Missing")
        frame.inviteAllBtn:SetDisabled(true)
        frame.removeAllBtn:SetLabel("Remove Not-On-List")
        frame.removeAllBtn:SetDisabled(true)
        return
    end

    frame.missingHeader:SetText(("MISSING — invite (%d)"):format(#result.missing))
    frame.extraHeader:SetText(("NOT ON LIST (%d)"):format(#result.extra))
    self.missingLV:SetData(result.missing)
    self.extraLV:SetData(result.extra)
    frame.status:SetText(("in group %d  ·  on list %d"):format(result.raidCount, result.listCount))

    frame.inviteAllBtn:SetLabel(("Invite Missing (%d)"):format(#result.missing))
    frame.inviteAllBtn:SetDisabled(#result.missing == 0)
    frame.removeAllBtn:SetLabel(("Remove Not-On-List (%d)"):format(#result.extra))
    frame.removeAllBtn:SetDisabled(#result.extra == 0)
end

function IH:RunCompare()
    if not frame then return end
    local text = frame.editBox:GetText()
    ns.db.inviteHelper.lastInput = text
    self:RenderResult(Compare(text))
end

-- Single-name actions (called from a row button).
function IH:InviteOne(name, row)
    if not CanInvite() then
        ns:Print("you must be group leader or assistant to invite.")
        return
    end
    DoInvite(name)
    MarkRowDone(row, "Invited")
end

function IH:RemoveOne(name, row)
    if not UnitIsGroupLeader("player") then
        ns:Print("you must be group leader to remove players.")
        return
    end
    DoUninvite(name)
    MarkRowDone(row, "Removed")
end

-- Bulk actions.
function IH:InviteMissing()
    local result = self.lastResult
    if not result or #result.missing == 0 then return end
    if not CanInvite() then
        ns:Print("you must be group leader or assistant to invite.")
        return
    end
    for _, name in ipairs(result.missing) do
        DoInvite(name)
    end
    self.missingLV:MarkAllDone("Invited")
    ns:Print(("sent %d invite(s)."):format(#result.missing))
end

function IH:UninviteExtras()
    local result = self.lastResult
    if not result or #result.extra == 0 then return end
    if not UnitIsGroupLeader("player") then
        ns:Print("you must be group leader to remove players.")
        return
    end
    for _, name in ipairs(result.extra) do
        DoUninvite(name)
    end
    self.extraLV:MarkAllDone("Removed")
    ns:Print(("removed %d player(s) not on the list."):format(#result.extra))
end

-- ===========================================================================
-- Module lifecycle
-- ===========================================================================

function IH:Open()
    if not self.enabled then
        ns:Print(self.name .. " is disabled — enable it with /oqol.")
        return
    end
    if not frame then BuildUI() end
    frame:Show()
end

function IH:Toggle()
    if not self.enabled then
        ns:Print(self.name .. " is disabled — enable it with /oqol.")
        return
    end
    if not frame then BuildUI() end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end

function IH:OnDisable()
    if frame and frame:IsShown() then
        frame:Hide()
    end
end
