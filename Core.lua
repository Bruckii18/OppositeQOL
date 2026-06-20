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

-- ---------------------------------------------------------------------------
-- Module registry
-- ---------------------------------------------------------------------------
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

-- Small helper so every module prints with the same prefix.
function ns:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33bce8OppositeQOL|r: " .. tostring(msg))
end

-- ---------------------------------------------------------------------------
-- Init (runs once the saved variables are available)
-- ---------------------------------------------------------------------------
function ns:Initialize()
    OppositeQOLDB = OppositeQOLDB or {}
    self.db = OppositeQOLDB
    self.db.modules = self.db.modules or {}
    self.db.inviteHelper = self.db.inviteHelper or {}  -- per-module storage

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
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, loaded)
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
        ns:Print("modules:")
        for _, key in ipairs(ns.moduleOrder) do
            local m = ns.modules[key]
            local state = m.enabled and "|cff66d977on|r" or "|cffeb6161off|r"
            ns:Print(("  |cffffffff%s|r [%s] - %s"):format(m.name or key, state, m.desc or ""))
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

    else
        PrintHelp()
    end
end
