-- OppositeQOL - Core
-- Shared namespace, the module framework (register / enable / disable /
-- persist), saved variables and slash commands.
--
-- A "module" is any table registered with ns:RegisterModule(key, module).
-- Recognised fields:
--   module.name        display name (string)
--   module.desc        short description (string)
--   module.default     start enabled? (boolean, defaults to true)
--   module.hasUI       does it have a window to Open()? (boolean)
-- Recognised methods (all optional):
--   module:OnInitialize()   once, after the DB is ready (enabled or not)
--   module:OnEnable()       when it becomes enabled (incl. on login)
--   module:OnDisable()      when it becomes disabled
--   module:Open()/Toggle()  open its window (used by the config "Open" button)

local addonName, ns = ...

ns.name = addonName
ns.modules = {}
ns.moduleOrder = {}   -- keeps registration order for stable display

-- `wipe` exists in-game; provide a fallback so the logic tests run under plain Lua.
local wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end return t end

-- ---------------------------------------------------------------------------
-- Table helpers (shared; used by the profile system and module defaults)
-- ---------------------------------------------------------------------------
-- Deep copy, skipping function/userdata so a frame reference can never poison a
-- serialized profile. Cycle-safe via the `seen` map.
function ns.DeepCopy(src, seen)
    if type(src) ~= "table" then return src end
    seen = seen or {}
    if seen[src] then return seen[src] end
    local t = {}
    seen[src] = t
    for k, v in pairs(src) do
        local tv = type(v)
        if tv ~= "function" and tv ~= "userdata" and tv ~= "thread" then
            t[k] = ns.DeepCopy(v, seen)
        end
    end
    return t
end

-- Overlay src onto dst, filling only missing keys (defaults / import merge).
function ns.DeepMerge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            ns.DeepMerge(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

-- ---------------------------------------------------------------------------
-- Module registry
-- ---------------------------------------------------------------------------
-- A module may set module.defaults = { ... }: a plain table of default settings
-- that is DeepMerge'd into its live DB on load and whenever a profile is applied,
-- so new keys appear automatically in old saved data.
function ns:RegisterModule(key, module)
    module.key = key
    self.modules[key] = module
    self.moduleOrder[#self.moduleOrder + 1] = key
    return module
end

function ns:IsModuleEnabled(key)
    local m = self.modules[key]
    return (m and m.enabled) or false
end

-- Flip a module on/off at runtime, persist it, and fire its lifecycle hook.
function ns:SetModuleEnabled(key, enabled)
    local m = self.modules[key]
    if not m then return false end
    enabled = not not enabled
    if m.enabled == enabled then return true end

    m.enabled = enabled
    self.db.modules[key] = { enabled = enabled }

    if enabled then
        if m.OnEnable then m:OnEnable() end
    else
        if m.OnDisable then m:OnDisable() end
    end

    if ns.Config and ns.Config.Refresh then ns.Config:Refresh() end
    return true
end

-- Resolve a user-typed module name to its key, case-insensitively.
function ns:ResolveModuleKey(name)
    if not name or name == "" then return nil end
    name = name:lower()
    for _, key in ipairs(self.moduleOrder) do
        if key:lower() == name then return key end
        local m = self.modules[key]
        if m.name and m.name:lower() == name then return key end
    end
    return nil
end

-- Small helper so every module prints with the same prefix. The accent colour is
-- read from the shared theme (UI.lua) so there's one source of truth -- no hexes
-- hard-coded here that could drift from the UI palette.
function ns:Print(msg)
    local accent = (self.UI and self.UI.Hex(self.UI.theme.accent)) or "ff33bce8"
    DEFAULT_CHAT_FRAME:AddMessage("|c" .. accent .. "OppositeQOL|r: " .. tostring(msg))
end

-- ---------------------------------------------------------------------------
-- Combat safety
-- Protected actions (changing secure frames, key bindings, etc.) are forbidden
-- while in combat. Queue them and flush on PLAYER_REGEN_ENABLED. LoggingCombat,
-- C_PartyInfo invites and chat are NOT protected, so they never need this -- it
-- exists for any future feature that touches a secure/protected frame.
-- ---------------------------------------------------------------------------
local combatQueue = {}
local combatWatcher
function ns:RunWhenOutOfCombat(fn)
    if type(fn) ~= "function" then return end
    if not (InCombatLockdown and InCombatLockdown()) then
        fn()
        return
    end
    combatQueue[#combatQueue + 1] = fn
    if not combatWatcher then
        combatWatcher = CreateFrame("Frame")
        combatWatcher:SetScript("OnEvent", function(self)
            self:UnregisterEvent("PLAYER_REGEN_ENABLED")
            local q = combatQueue
            combatQueue = {}
            for _, f in ipairs(q) do pcall(f) end
        end)
    end
    combatWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
end

-- ---------------------------------------------------------------------------
-- Profiles
-- The live working settings are the top-level per-module tables (ns.db[key]);
-- ns.db.profiles[name] holds named SNAPSHOTS you can switch between. Switching
-- wipes and refills the live tables IN PLACE, so module references (self.db) and
-- captured defaults stay valid; a module may implement :OnProfileChanged() to
-- re-sync any cached fields / open windows. Module enabled-state stays global
-- (ns.db.modules), so toggling a feature isn't tied to the active profile.
-- ---------------------------------------------------------------------------
local DEFAULT_PROFILE = "Default"

function ns:InitProfiles()
    local db = self.db
    db.profiles     = db.profiles or {}
    db.profileOrder = db.profileOrder or {}
    db.activeProfile = db.activeProfile or DEFAULT_PROFILE
    if not db.profiles[db.activeProfile] then
        db.profiles[db.activeProfile] = { modules = {} }
    end
    -- keep profileOrder in sync with the profiles table
    local present = {}
    for _, n in ipairs(db.profileOrder) do present[n] = true end
    for name in pairs(db.profiles) do
        if not present[name] then db.profileOrder[#db.profileOrder + 1] = name end
    end
end

function ns:ProfileList() return self.db and self.db.profileOrder or {} end
function ns:ActiveProfile() return self.db and self.db.activeProfile end

-- Snapshot the live settings into the active profile.
function ns:SaveActiveProfile()
    local db = self.db
    if not (db and db.profiles and db.activeProfile) then return end
    local p = db.profiles[db.activeProfile] or { modules = {} }
    p.modules = p.modules or {}
    for _, key in ipairs(self.moduleOrder) do
        if type(db[key]) == "table" then p.modules[key] = ns.DeepCopy(db[key]) end
    end
    db.profiles[db.activeProfile] = p
end

-- Refill the live settings from a profile's snapshot, in place. Re-applies each
-- module's defaults and fires :OnProfileChanged(). Sets the active profile.
function ns:LoadProfile(name)
    local db = self.db
    local p = db.profiles and db.profiles[name]
    if not p then return false end
    p.modules = p.modules or {}
    for _, key in ipairs(self.moduleOrder) do
        local live = db[key]
        if type(live) == "table" then
            wipe(live)
            if p.modules[key] then ns.DeepMerge(live, p.modules[key]) end
            local m = self.modules[key]
            if m and m.defaults then ns.DeepMerge(live, m.defaults) end
        end
    end
    db.activeProfile = name
    for _, key in ipairs(self.moduleOrder) do
        local m = self.modules[key]
        if m and m.OnProfileChanged then pcall(m.OnProfileChanged, m) end
    end
    if self.Config and self.Config.Refresh then self.Config:Refresh() end
    return true
end

local function ensureInOrder(db, name)
    for _, n in ipairs(db.profileOrder) do if n == name then return end end
    db.profileOrder[#db.profileOrder + 1] = name
end

-- Switch to (creating if needed) a named profile.
function ns:SwitchProfile(name)
    if not name or name == "" then return false end
    local db = self.db
    if name == db.activeProfile then return true end
    self:SaveActiveProfile()
    if not db.profiles[name] then db.profiles[name] = { modules = {} } end
    ensureInOrder(db, name)
    return self:LoadProfile(name)
end

-- Save the current settings as a new profile and make it active.
function ns:SaveProfileAs(name)
    if not name or name == "" then return false end
    local db = self.db
    if db.profiles[name] then return false, "a profile with that name already exists" end
    self:SaveActiveProfile()
    db.profiles[name] = ns.DeepCopy(db.profiles[db.activeProfile])
    ensureInOrder(db, name)
    db.activeProfile = name   -- live data already matches; no reload needed
    if self.Config and self.Config.Refresh then self.Config:Refresh() end
    return true
end

-- Overwrite the active profile's settings with a copy of another profile.
function ns:CopyProfileFrom(name)
    local db = self.db
    if name == db.activeProfile or not db.profiles[name] then return false end
    local src = db.profiles[name]
    src.modules = src.modules or {}
    for _, key in ipairs(self.moduleOrder) do
        local live = db[key]
        if type(live) == "table" then
            wipe(live)
            if src.modules[key] then ns.DeepMerge(live, src.modules[key]) end
            local m = self.modules[key]
            if m and m.defaults then ns.DeepMerge(live, m.defaults) end
        end
    end
    self:SaveActiveProfile()
    for _, key in ipairs(self.moduleOrder) do
        local m = self.modules[key]
        if m and m.OnProfileChanged then pcall(m.OnProfileChanged, m) end
    end
    if self.Config and self.Config.Refresh then self.Config:Refresh() end
    return true
end

function ns:DeleteProfile(name)
    local db = self.db
    if not db.profiles[name] then return false end
    if name == DEFAULT_PROFILE then return false, "the Default profile can't be deleted" end
    if name == db.activeProfile then
        if not db.profiles[DEFAULT_PROFILE] then db.profiles[DEFAULT_PROFILE] = { modules = {} } end
        ensureInOrder(db, DEFAULT_PROFILE)
        self:LoadProfile(DEFAULT_PROFILE)
    end
    db.profiles[name] = nil
    for i, n in ipairs(db.profileOrder) do
        if n == name then table.remove(db.profileOrder, i); break end
    end
    return true
end

function ns:RenameProfile(oldName, newName)
    local db = self.db
    if not db.profiles[oldName] or not newName or newName == "" then return false end
    if db.profiles[newName] then return false, "a profile with that name already exists" end
    db.profiles[newName] = db.profiles[oldName]
    db.profiles[oldName] = nil
    for i, n in ipairs(db.profileOrder) do
        if n == oldName then db.profileOrder[i] = newName; break end
    end
    if db.activeProfile == oldName then db.activeProfile = newName end
    if self.Config and self.Config.Refresh then self.Config:Refresh() end
    return true
end

-- Wipe the active profile back to module defaults.
function ns:ResetActiveProfile()
    local db = self.db
    for _, key in ipairs(self.moduleOrder) do
        local live = db[key]
        if type(live) == "table" then
            wipe(live)
            local m = self.modules[key]
            if m and m.defaults then ns.DeepMerge(live, m.defaults) end
        end
    end
    self:SaveActiveProfile()
    for _, key in ipairs(self.moduleOrder) do
        local m = self.modules[key]
        if m and m.OnProfileChanged then pcall(m.OnProfileChanged, m) end
    end
    if self.Config and self.Config.Refresh then self.Config:Refresh() end
    return true
end

-- ---------------------------------------------------------------------------
-- Schema migrations
-- Each step is { version = N, body = function(db) ... } and runs once, in order,
-- when db.schemaVersion < N. Bodies must be idempotent and touch only stored db
-- tables (never live game APIs -- spec/instance info isn't reliable this early).
-- A failed step is isolated with pcall and STOPS the runner (never half-migrates).
-- A fresh install jumps straight to the latest version.
-- ---------------------------------------------------------------------------
local MIGRATIONS = {}
ns.LATEST_SCHEMA = 0   -- highest registered version; exposed for /oqol migrations

-- Register an upgrade step. Call at file scope as the schema evolves, e.g.:
--   ns:RegisterMigration(1, function(db) db.new = db.old; db.old = nil end)
function ns:RegisterMigration(version, body)
    MIGRATIONS[#MIGRATIONS + 1] = { version = version, body = body }
    table.sort(MIGRATIONS, function(a, b) return a.version < b.version end)
    ns.LATEST_SCHEMA = MIGRATIONS[#MIGRATIONS].version
end

function ns:RunMigrations(db)
    db.schemaVersion = db.schemaVersion or 0
    -- Fresh install (no module data saved yet): nothing to migrate.
    if db.schemaVersion == 0 and next(db.modules or {}) == nil then
        db.schemaVersion = ns.LATEST_SCHEMA
        return
    end
    for _, step in ipairs(MIGRATIONS) do
        if step.version > db.schemaVersion then
            local okStep, err = pcall(step.body, db)
            if okStep then
                db.schemaVersion = step.version
            else
                ns._migErrors = ns._migErrors or {}
                ns._migErrors[#ns._migErrors + 1] = tostring(err)
                break   -- stop; do not advance onto half-migrated data
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Init (runs once the saved variables are available)
-- ---------------------------------------------------------------------------
function ns:Initialize()
    OppositeQOLDB = OppositeQOLDB or {}
    self.db = OppositeQOLDB
    self.db.modules = self.db.modules or {}
    self.db.inviteHelper = self.db.inviteHelper or {}  -- per-module storage

    -- Profiles + schema migrations run BEFORE modules touch any settings.
    self:InitProfiles()
    self:RunMigrations(self.db)

    for _, key in ipairs(self.moduleOrder) do
        local m = self.modules[key]

        local saved = self.db.modules[key]
        local enabled
        if saved and saved.enabled ~= nil then
            enabled = saved.enabled
        else
            enabled = (m.default ~= false)  -- default ON unless module opts out
        end

        m.enabled = enabled
        self.db.modules[key] = { enabled = enabled }

        if m.OnInitialize then m:OnInitialize() end
        if enabled and m.OnEnable then m:OnEnable() end
    end

    -- Capture the just-initialised settings into the active profile snapshot.
    self:SaveActiveProfile()
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGOUT")
loader:SetScript("OnEvent", function(self, event, loaded)
    if event == "PLAYER_LOGOUT" then
        ns:SaveActiveProfile()   -- keep the active snapshot current for next login
        return
    end
    if loaded ~= addonName then return end
    ns:Initialize()
    self:UnregisterEvent("ADDON_LOADED")
end)

-- ---------------------------------------------------------------------------
-- Slash commands:  /oqol   and   /invitehelper
-- ---------------------------------------------------------------------------
local function PrintHelp()
    ns:Print("commands:")
    ns:Print("  /oqol                  open the module list")
    ns:Print("  /oqol invite           open the Invite Helper")
    ns:Print("  /oqol pull             open the PrePull report")
    ns:Print("  /oqol log              show if combat logging is active")
    ns:Print("  /oqol list             show modules and their state")
    ns:Print("  /oqol enable <module>  enable a module")
    ns:Print("  /oqol disable <module> disable a module")
    ns:Print("  /oqol minimap          show/hide the minimap button")
    ns:Print("  /oqol profile          manage settings profiles")
end

SLASH_OPPOSITEQOL1 = "/oqol"
SLASH_OPPOSITEQOL2 = "/invitehelper"
SlashCmdList["OPPOSITEQOL"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    rest = rest or ""

    if cmd == "" then
        if ns.Config then ns.Config:Toggle() end

    elseif cmd == "invite" or cmd == "inv" then
        if ns.InviteHelper then ns.InviteHelper:Toggle() end

    elseif cmd == "pull" or cmd == "wp" or cmd == "whopulled" then
        if ns.WhoPulled then ns.WhoPulled:Toggle() end

    elseif cmd == "log" or cmd == "combatlog" or cmd == "cl" then
        if not ns.CombatLog then
            ns:Print("combat log status is unavailable.")
        elseif not ns:IsModuleEnabled("combatLog") then
            ns:Print("Combat Log Status is disabled - enable it with /oqol.")
        else
            ns.CombatLog:Check()  -- read live, also repaints the minimap dot
            ns:Print("combat logging is " .. ns.CombatLog:StatusText() .. ".")
        end

    elseif cmd == "minimap" then
        ns.db.minimap = ns.db.minimap or {}
        local show = ns.db.minimap.hide and true or false  -- show if currently hidden
        if ns.MinimapButton then ns.MinimapButton:SetShown(show) end
        ns:Print("minimap button " .. (show and "shown" or "hidden") .. ".")

    elseif cmd == "list" then
        local UI = ns.UI
        local on  = "|c" .. UI.Hex(UI.theme.green) .. "on|r"
        local off = "|c" .. UI.Hex(UI.theme.red) .. "off|r"
        ns:Print("modules:")
        for _, key in ipairs(ns.moduleOrder) do
            local m = ns.modules[key]
            ns:Print(("  |cffffffff%s|r [%s] - %s"):format(
                m.name or key, m.enabled and on or off, m.desc or ""))
        end

    elseif cmd == "enable" or cmd == "disable" then
        local key = ns:ResolveModuleKey(rest)
        if not key then
            ns:Print("unknown module: '" .. rest .. "'  (try /oqol list)")
        else
            ns:SetModuleEnabled(key, cmd == "enable")
            ns:Print((ns.modules[key].name or key) .. " is now " ..
                (ns:IsModuleEnabled(key) and "enabled" or "disabled") .. ".")
        end

    elseif cmd == "profile" or cmd == "profiles" then
        local sub, arg = rest:match("^(%S*)%s*(.-)$")
        sub = (sub or ""):lower()
        if sub == "" or sub == "open" then
            if ns.Profiles and ns.Profiles.Toggle then ns.Profiles:Toggle()
            else sub = "list" end
        end
        if sub == "list" then
            ns:Print("profiles (active marked *):")
            for _, name in ipairs(ns:ProfileList()) do
                ns:Print(("  %s%s"):format(name == ns:ActiveProfile() and "* " or "  ", name))
            end
        elseif sub == "use" or sub == "switch" then
            if ns:SwitchProfile(arg) then ns:Print("switched to profile '" .. arg .. "'.")
            else ns:Print("could not switch to '" .. arg .. "'.") end
        elseif sub == "new" or sub == "save" then
            local okp, err = ns:SaveProfileAs(arg)
            ns:Print(okp and ("saved current settings as profile '" .. arg .. "'.")
                or ("could not save: " .. (err or "invalid name") .. "."))
        elseif sub == "copy" then
            ns:Print(ns:CopyProfileFrom(arg) and ("copied '" .. arg .. "' into the active profile.")
                or ("could not copy from '" .. arg .. "'."))
        elseif sub == "delete" or sub == "remove" then
            local okp, err = ns:DeleteProfile(arg)
            ns:Print(okp and ("deleted profile '" .. arg .. "'.")
                or ("could not delete: " .. (err or "no such profile") .. "."))
        elseif sub == "reset" then
            ns:ResetActiveProfile()
            ns:Print("active profile reset to defaults.")
        elseif sub == "export" then
            if ns.Profiles and ns.Profiles.ExportToChat then ns.Profiles:ExportToChat(arg ~= "" and arg or nil)
            else ns:Print("profile export is unavailable.") end
        elseif sub == "import" then
            if ns.Profiles and ns.Profiles.ImportFromString then
                local okp, err = ns.Profiles:ImportFromString(arg)
                ns:Print(okp and "profile imported." or ("import failed: " .. (err or "?") .. "."))
            else ns:Print("profile import is unavailable.") end
        else
            ns:Print("usage: /oqol profile [list|use|new|copy|delete|reset|export|import] <name>")
        end

    elseif cmd == "migrations" then
        ns:Print(("schema version %d / %d."):format(ns.db.schemaVersion or 0, ns.LATEST_SCHEMA or 0))
        if ns._migErrors and #ns._migErrors > 0 then
            ns:Print("migration errors:")
            for _, e in ipairs(ns._migErrors) do ns:Print("  " .. e) end
        end

    else
        PrintHelp()
    end
end
