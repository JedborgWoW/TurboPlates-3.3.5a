local addonName, ns = ...
local L = ns.L

local btn = CreateFrame("Button", "TurboPlatesMinimapBtn", Minimap)
btn:SetFrameStrata("MEDIUM")
btn:SetSize(31, 31)
btn:SetFrameLevel(8)
btn:RegisterForClicks("AnyUp")
btn:RegisterForDrag("LeftButton")
btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

-- Border ring. The MiniMap-TrackingBorder texture's transparent hole is NOT at
-- the geometric centre of the 53x53 texture - it sits offset toward the top-left.
-- Anchoring TOPLEFT(0,0) (the canonical LibDBIcon layout) lands that hole over
-- the button centre. Centring the overlay instead pushed the hole down-right and
-- left the OPAQUE ring over the icon, so the button looked empty/hollow.
local overlay = btn:CreateTexture(nil, "OVERLAY")
overlay:SetSize(53, 53)
overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
overlay:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)

-- Icon sits in the ARTWORK layer (below the OVERLAY border) and shows through the
-- ring's hole, centred in the 31x31 button (the clickable area) with a 1px upward
-- nudge to line up with where the border hole actually is.
local icon = btn:CreateTexture(nil, "ARTWORK")
icon:SetSize(19, 19)
icon:SetTexture("Interface\\Icons\\INV_Misc_Rune01")
icon:SetPoint("CENTER", btn, "CENTER", 0, 1)
icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

local function UpdatePosition()
    if not TurboPlatesDB then return end
    if type(TurboPlatesDB.minimap) ~= "table" then
        TurboPlatesDB.minimap = { hide = false, pos = 45 }
    end
    
    local db = TurboPlatesDB.minimap
    if db.hide then btn:Hide() else btn:Show() end
    
    local angle = math.rad(db.pos or 45)
    local x, y = math.cos(angle), math.sin(angle)
    -- Orbit just outside the minimap edge. Deriving the radius from the live
    -- minimap width keeps the button on the ring for any minimap size (a fixed
    -- radius leaves it floating off the edge on resized/custom minimaps).
    local mw = Minimap:GetWidth()
    local radius = (mw and mw > 0) and (mw * 0.5 + 6) or 80
    btn:SetPoint("CENTER", Minimap, "CENTER", x * radius, y * radius)
end

btn:SetMovable(true)
btn:SetScript("OnDragStart", function(self)
    local throttle = 0
    self:SetScript("OnUpdate", function(self, elapsed)
        throttle = throttle + elapsed
        if throttle < 0.016 then return end  -- ~60 FPS limit (prevents cursor lag)
        throttle = 0
        
        local x, y = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        local cx, cy = Minimap:GetCenter()
        x, y = x / scale, y / scale
        local angle = math.atan2(y - cy, x - cx)
        
        if not TurboPlatesDB then TurboPlatesDB = {} end
        if type(TurboPlatesDB.minimap) ~= "table" then TurboPlatesDB.minimap = {hide=false,pos=45} end
        
        TurboPlatesDB.minimap.pos = math.deg(angle)
        UpdatePosition()
    end)
end)
btn:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)

btn:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        ReloadUI()
    else
        if ns.ToggleGUI then ns:ToggleGUI() end
    end
end)

btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("TurboPlates")
    local l = (L.LeftClick or "L: ") .. (L.Settings or "Settings")
    local r = (L.Reload or "R: Reload")
    GameTooltip:AddLine(l, 1, 1, 1)
    GameTooltip:AddLine(r, 1, 1, 1)
    GameTooltip:Show()
end)
btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function() UpdatePosition() end)

ns.UpdateMinimapButton = UpdatePosition
