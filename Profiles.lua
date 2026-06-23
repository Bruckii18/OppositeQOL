-- OppositeQOL - Profiles UI + import/export
-- The profile DATA model (named snapshots, switch/copy/reset/migrate) lives in
-- Core.lua. This file adds the shareable string format and a small management
-- window opened from the Config hub or /oqol profile.
--
-- Export/import is self-contained: a hand-rolled, type-tagged serializer plus
-- base64, so it works with ZERO libraries. If LibDeflate happens to be loaded by
-- another addon we use it for a shorter, compressed string (the same "use it only
-- if present" idiom WhoPulled uses for LibSharedMedia). The prefix records which
-- path produced the string so import knows how to read it.

local addonName, ns = ...

local UI = ns.UI
local theme, StyleFont = UI.theme, UI.StyleFont

local Profiles = {}
ns.Profiles = Profiles

-- LibDeflate, only if some other addon already loaded it (never required/shipped).
local LibDeflate = LibStub and LibStub("LibDeflate", true)

local CURRENT_VERSION = 1
local PREFIX_DEFLATE  = "!OQOL1!"   -- LibDeflate-compressed payload
local PREFIX_RAW      = "!OQOL0!"   -- base64 of the raw serialized payload

-- ===========================================================================
-- Serializer (type-tagged; round-trips nested tables with string/number keys)
--   T/F boolean   n<num>;   s<len>:<bytes>   { <k><v> ... }
-- Length-prefixed strings mean payload bytes can never be confused for syntax.
-- ===========================================================================
local function encode(v, out)
    local t = type(v)
    if t == "boolean" then
        out[#out + 1] = v and "T" or "F"
    elseif t == "number" then
        out[#out + 1] = "n"; out[#out + 1] = string.format("%.17g", v); out[#out + 1] = ";"
    elseif t == "string" then
        out[#out + 1] = "s"; out[#out + 1] = tostring(#v); out[#out + 1] = ":"; out[#out + 1] = v
    elseif t == "table" then
        out[#out + 1] = "{"
        for k, val in pairs(v) do
            local tk, tv = type(k), type(val)
            if (tk == "string" or tk == "number")
                and tv ~= "function" and tv ~= "userdata" and tv ~= "thread" then
                encode(k, out); encode(val, out)
            end
        end
        out[#out + 1] = "}"
    end
end

local function decode(s, i)
    local tag = s:sub(i, i)
    if tag == "T" then return true, i + 1
    elseif tag == "F" then return false, i + 1
    elseif tag == "n" then
        local j = s:find(";", i + 1, true)
        if not j then error("number") end
        return tonumber(s:sub(i + 1, j - 1)), j + 1
    elseif tag == "s" then
        local colon = s:find(":", i + 1, true)
        if not colon then error("string") end
        local len = tonumber(s:sub(i + 1, colon - 1))
        if not len then error("string len") end
        return s:sub(colon + 1, colon + len), colon + 1 + len
    elseif tag == "{" then
        local t, p = {}, i + 1
        while s:sub(p, p) ~= "}" do
            if p > #s then error("truncated") end
            local k, v
            k, p = decode(s, p)
            v, p = decode(s, p)
            t[k] = v
        end
        return t, p + 1
    end
    error("bad tag")
end

function Profiles.Serialize(v)
    local out = {}; encode(v, out); return table.concat(out)
end

function Profiles.Deserialize(s)
    local ok, val = pcall(function() return (decode(s, 1)) end)
    if not ok then return nil, "the string is corrupt or incomplete" end
    return val
end

-- ---- base64 (arithmetic, no bit library) ----
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64DEC = {}
for k = 1, #B64 do B64DEC[B64:sub(k, k)] = k - 1 end

local function b64enc(data)
    local out, n, i = {}, #data, 1
    while i <= n do
        local b1 = data:byte(i)
        local b2 = data:byte(i + 1)
        local b3 = data:byte(i + 2)
        local c1 = math.floor(b1 / 4)
        local c2 = (b1 % 4) * 16 + (b2 and math.floor(b2 / 16) or 0)
        local c3 = b2 and ((b2 % 16) * 4 + (b3 and math.floor(b3 / 64) or 0)) or nil
        local c4 = b3 and (b3 % 64) or nil
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1)
        out[#out + 1] = B64:sub(c2 + 1, c2 + 1)
        out[#out + 1] = c3 and B64:sub(c3 + 1, c3 + 1) or "="
        out[#out + 1] = c4 and B64:sub(c4 + 1, c4 + 1) or "="
        i = i + 3
    end
    return table.concat(out)
end

local function b64dec(s)
    s = s:gsub("[^%w%+/=]", "")
    local out, n, i = {}, #s, 1
    while i <= n do
        local c1 = B64DEC[s:sub(i, i)]
        local c2 = B64DEC[s:sub(i + 1, i + 1)]
        local ch3, ch4 = s:sub(i + 2, i + 2), s:sub(i + 3, i + 3)
        local c3, c4 = B64DEC[ch3], B64DEC[ch4]
        if not c1 or not c2 then break end
        out[#out + 1] = string.char(c1 * 4 + math.floor(c2 / 16))
        if ch3 ~= "=" and c3 then
            out[#out + 1] = string.char((c2 % 16) * 16 + math.floor(c3 / 4))
            if ch4 ~= "=" and c4 then
                out[#out + 1] = string.char((c3 % 4) * 64 + c4)
            end
        end
        i = i + 4
    end
    return table.concat(out)
end

-- ===========================================================================
-- Export / import
-- ===========================================================================
-- Build a shareable string for a profile (defaults to the active one).
function Profiles:Export(name)
    name = name or ns:ActiveProfile()
    ns:SaveActiveProfile()   -- make sure the active snapshot is current
    local prof = ns.db.profiles[name]
    if not prof then return nil, "no such profile" end
    local payload = {
        v = CURRENT_VERSION, kind = "profile", name = name,
        modules = ns.DeepCopy(prof.modules or {}),
    }
    local raw = Profiles.Serialize(payload)
    if LibDeflate then
        return PREFIX_DEFLATE .. LibDeflate:EncodeForPrint(LibDeflate:CompressDeflate(raw))
    end
    return PREFIX_RAW .. b64enc(raw)
end

-- Parse a shareable string back to a payload table, or nil + a readable error.
function Profiles:Decode(str)
    if type(str) ~= "string" then return nil, "nothing to import" end
    str = str:gsub("%s", "")
    local raw
    if str:sub(1, #PREFIX_DEFLATE) == PREFIX_DEFLATE then
        if not LibDeflate then
            return nil, "this string needs LibDeflate; import it where LibDeflate is loaded, or re-export it on a client without LibDeflate"
        end
        local decoded = LibDeflate:DecodeForPrint(str:sub(#PREFIX_DEFLATE + 1))
        raw = decoded and LibDeflate:DecompressDeflate(decoded)
        if not raw then return nil, "could not decompress the string" end
    elseif str:sub(1, #PREFIX_RAW) == PREFIX_RAW then
        raw = b64dec(str:sub(#PREFIX_RAW + 1))
    else
        return nil, "not an OppositeQOL profile string"
    end
    local payload, err = Profiles.Deserialize(raw)
    if not payload then return nil, err end
    if type(payload) ~= "table" or payload.kind ~= "profile" then
        return nil, "not a profile string"
    end
    if (payload.v or 0) > CURRENT_VERSION then
        return nil, "this string was made with a newer version of OppositeQOL; please update"
    end
    return payload
end

-- Import a string into a named profile (the payload's name by default) and make
-- it active. Returns true, or false + a readable error.
function Profiles:ImportFromString(str, asName)
    local payload, err = self:Decode(str)
    if not payload then return false, err end
    local name = asName or payload.name or "Imported"
    ns:SaveActiveProfile()
    ns.db.profiles[name] = { modules = ns.DeepCopy(payload.modules or {}) }
    -- register in the display order if new
    local present = false
    for _, n in ipairs(ns.db.profileOrder) do if n == name then present = true break end end
    if not present then ns.db.profileOrder[#ns.db.profileOrder + 1] = name end
    ns.db.activeProfile = name
    ns:LoadProfile(name)
    if self.Refresh then self:Refresh() end
    return true, name
end

-- /oqol profile export: print the string to chat for copy-paste.
function Profiles:ExportToChat(name)
    local s, err = self:Export(name)
    if not s then ns:Print("export failed: " .. (err or "?") .. "."); return end
    ns:Print("profile string (select + copy):")
    DEFAULT_CHAT_FRAME:AddMessage(s)
end

-- ===========================================================================
-- Management window
-- ===========================================================================
local frame, selDD, nameEdit, shareEdit

local function selectedName()
    return (selDD and selDD:GetValue()) or ns:ActiveProfile()
end

local function refreshDropdown()
    if not selDD then return end
    selDD:SetOptions(ns:ProfileList())
    selDD:SetValue(ns:ActiveProfile())
end

function Profiles:Refresh()
    if not frame then return end
    refreshDropdown()
    if frame.activeFS then frame.activeFS:SetText("Active: |cff" .. UI.Hex(theme.accent) .. (ns:ActiveProfile() or "?") .. "|r") end
end

local function BuildUI()
    frame = UI.CreatePanel({
        name = "OppositeQOLProfilesFrame", width = 440, height = 360,
        title = "OppositeQOL", subtitle = "Profiles", posKey = "profiles",
    })

    local active = frame:CreateFontString(nil, "OVERLAY")
    StyleFont(active, 12, theme.text)
    active:SetPoint("TOPLEFT", 16, -44)
    frame.activeFS = active

    -- Profile picker + actions on the selected profile.
    local pickFS = frame:CreateFontString(nil, "OVERLAY")
    StyleFont(pickFS, 12, theme.textDim)
    pickFS:SetPoint("TOPLEFT", 16, -70)
    pickFS:SetText("Profile:")

    selDD = UI.CreateDropdown(frame, 200, 20)
    selDD:SetPoint("LEFT", pickFS, "RIGHT", 8, 0)

    local useBtn = UI.CreateFlatButton(frame, "Use", 60, 20, theme.accent)
    useBtn:SetPoint("LEFT", selDD, "RIGHT", 8, 0)
    useBtn:SetScript("OnClick", function()
        ns:SwitchProfile(selectedName()); Profiles:Refresh()
    end)

    local copyBtn = UI.CreateFlatButton(frame, "Copy into active", 130, 20, theme.text)
    copyBtn:SetPoint("TOPLEFT", 16, -100)
    copyBtn:SetScript("OnClick", function()
        ns:CopyProfileFrom(selectedName()); Profiles:Refresh()
    end)

    local delBtn = UI.CreateFlatButton(frame, "Delete", 90, 20, theme.red)
    delBtn:SetPoint("LEFT", copyBtn, "RIGHT", 6, 0)
    delBtn:SetScript("OnClick", function()
        local okp, err = ns:DeleteProfile(selectedName())
        if not okp then ns:Print("could not delete: " .. (err or "?") .. ".") end
        Profiles:Refresh()
    end)

    local resetBtn = UI.CreateFlatButton(frame, "Reset active", 100, 20, theme.text)
    resetBtn:SetPoint("LEFT", delBtn, "RIGHT", 6, 0)
    resetBtn:SetScript("OnClick", function() ns:ResetActiveProfile(); Profiles:Refresh() end)

    -- New / rename via a name field.
    nameEdit = CreateFrame("EditBox", nil, frame, "BackdropTemplate")
    nameEdit:SetSize(200, 22)
    nameEdit:SetPoint("TOPLEFT", 16, -134)
    nameEdit:SetAutoFocus(false)
    UI.ApplyBackdrop(nameEdit, theme.bgInput, theme.borderHi)
    nameEdit:SetTextInsets(6, 6, 0, 0)
    StyleFont(nameEdit, 12, theme.text)
    nameEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local saveAsBtn = UI.CreateFlatButton(frame, "Save current as", 130, 22, theme.accent)
    saveAsBtn:SetPoint("LEFT", nameEdit, "RIGHT", 8, 0)
    saveAsBtn:SetScript("OnClick", function()
        local n = nameEdit:GetText()
        if n and n ~= "" then
            local okp, err = ns:SaveProfileAs(n)
            if not okp then ns:Print("could not save: " .. (err or "?") .. ".") end
            nameEdit:SetText(""); Profiles:Refresh()
        end
    end)

    -- Share box.
    local shareLabel = frame:CreateFontString(nil, "OVERLAY")
    StyleFont(shareLabel, 11, theme.textDim)
    shareLabel:SetPoint("TOPLEFT", 16, -168)
    shareLabel:SetText("Share string (Export the selected profile, or paste one and Import):")

    local box = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    box:SetPoint("TOPLEFT", 16, -186)
    box:SetPoint("TOPRIGHT", -16, -186)
    box:SetHeight(96)
    UI.ApplyBackdrop(box, theme.bgInput, theme.borderHi)

    local scroll = CreateFrame("ScrollFrame", nil, box)
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -4, 4)
    scroll:EnableMouseWheel(true)
    shareEdit = CreateFrame("EditBox", nil, scroll)
    shareEdit:SetMultiLine(true)
    shareEdit:SetAutoFocus(false)
    StyleFont(shareEdit, 11, theme.text)
    shareEdit:SetWidth(390)
    shareEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(shareEdit)

    local exportBtn = UI.CreateFlatButton(frame, "Export selected", 130, 24, theme.accent)
    exportBtn:SetPoint("BOTTOMLEFT", 16, 16)
    exportBtn:SetScript("OnClick", function()
        local s, err = Profiles:Export(selectedName())
        shareEdit:SetText(s or ("export failed: " .. (err or "?")))
        shareEdit:HighlightText()
        shareEdit:SetFocus()
    end)

    local importBtn = UI.CreateFlatButton(frame, "Import", 90, 24, theme.green)
    importBtn:SetPoint("LEFT", exportBtn, "RIGHT", 6, 0)
    importBtn:SetScript("OnClick", function()
        local okp, err = Profiles:ImportFromString(shareEdit:GetText())
        ns:Print(okp and ("imported profile '" .. tostring(err) .. "'.")
            or ("import failed: " .. (err or "?") .. "."))
        Profiles:Refresh()
    end)

    Profiles:Refresh()
end

function Profiles:Open()
    if not frame then BuildUI() end
    self:Refresh()
    frame:Show()
end

function Profiles:Toggle()
    if not frame then BuildUI() end
    if frame:IsShown() then frame:Hide() else self:Open() end
end
