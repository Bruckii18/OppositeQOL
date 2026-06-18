-- OppositeQOL - Minimap button
-- A small, dependency-free button on the minimap edge (no LibDBIcon/LibDataBroker
-- needed, keeping the addon self-contained). Left-click opens the module list,
-- right-click opens Who Pulled, drag moves it around the edge. The position
-- (angle) and visibility persist in ns.db.minimap.
--
-- The logo is the bundled Media\Opposite_HB_Discord_128x128.tga, shared via
-- ns.UI.LOGO (UI.lua loads first, so the constant is set by the time we load).

local addonName, ns = ...

local ICON = ns.UI.LOGO

local MB = {}
ns.MinimapButton = MB

local button  -- created once, on login

local function UpdatePosition()
    if not button then return end
    local angle = math.rad(ns.db.minimap.angle or 220)
    local r = (Minimap:GetWidth() / 2) + 8
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

-- While dragging, follow the cursor as an angle around the minimap centre.
local function OnDrag()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local px, py = GetCursorPosition()
    ns.db.minimap.angle = math.deg(math.atan2((py / scale) - my, (px / scale) - mx))
    UpdatePosition()
end

function MB:Create()
    if button or not Minimap or not ns.db then return end
    ns.db.minimap = ns.db.minimap or {}

    button = CreateFrame("Button", "OppositeQOLMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON)
    icon:SetSize(19, 19)
    icon:SetPoint("CENTER", 0, 1)
    -- Circular crop so the square logo sits cleanly inside the round ring.
    local mask = button:CreateMaskTexture()
    mask:SetAllPoints(icon)
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
        "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    icon:AddMaskTexture(mask)
    button.icon = icon

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", OnDrag) end)
    button:SetScript("OnDragStop",  function(self) self:SetScript("OnUpdate", nil) end)

    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            if ns.WhoPulled then ns.WhoPulled:Toggle() end
        else
            if ns.Config then ns.Config:Toggle() end
        end
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("OppositeQOL")
        GameTooltip:AddLine("|cffffffffLeft-click|r  open the module list")
        GameTooltip:AddLine("|cffffffffRight-click|r  open Who Pulled")
        GameTooltip:AddLine("|cff999999Drag|r  move around the minimap")
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UpdatePosition()
    button:SetShown(not ns.db.minimap.hide)
end

function MB:SetShown(show)
    ns.db.minimap = ns.db.minimap or {}
    ns.db.minimap.hide = not show
    if button then button:SetShown(show) end
end

function MB:IsShown()
    return button ~= nil and button:IsShown()
end

-- Build after login; ns.db is already populated from ADDON_LOADED by then.
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    MB:Create()
end)
