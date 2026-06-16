--[[----------------------------------------------------------------------------
    TurboPlates - stock 3.3.5a pure-API shims
    (Backported by Jedborg)

    Plain API gap-fillers that TurboPlates needs and that don't exist on a stock
    3.3.5a client: RunNextFrame, C_Timer, CreateColor/ColorMixin,
    WrapTextInColorCode, PixelUtil, Texture:SetColorTexture, C_CVar,
    EventRegistry, GetCreatureIDFromGUID.

    LOAD ORDER: this file must load FIRST of the three AscensionCompat files,
    because AscensionCompat.lua (the nameplate engine) uses EventRegistry and
    C_Timer, and TurboPlates captures these as file-scope locals. Each symbol is
    only defined if missing, so this is a no-op on a patched client / Ascension.
------------------------------------------------------------------------------]]

local addonName, ns = ...

---------------------------------------------------------------------------
-- RunNextFrame(callback)
---------------------------------------------------------------------------
if type(RunNextFrame) ~= "function" then
    local queue, count = {}, 0
    local driver = CreateFrame("Frame")
    driver:Hide()
    driver:SetScript("OnUpdate", function(self)
        local toRun, n = queue, count
        queue, count = {}, 0
        self:Hide()
        for i = 1, n do
            local cb = toRun[i]
            if cb then
                local ok, err = pcall(cb)
                if not ok and geterrorhandler then geterrorhandler()(err) end
            end
        end
    end)
    function RunNextFrame(callback)
        if type(callback) ~= "function" then return end
        count = count + 1
        queue[count] = callback
        driver:Show()
    end
    _G.RunNextFrame = RunNextFrame
end

---------------------------------------------------------------------------
-- C_Timer (After / NewTimer / NewTicker)
---------------------------------------------------------------------------
if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then
    local timers = {}
    local GetTime = GetTime
    local ticker = CreateFrame("Frame")
    ticker:SetScript("OnUpdate", function()
        if not timers[1] then return end
        local now = GetTime()
        local i = 1
        while timers[i] do
            local t = timers[i]
            if t.cancelled then
                table.remove(timers, i)
            elseif now >= t.expire then
                table.remove(timers, i)
                local ok, err = pcall(t.cb)
                if not ok and geterrorhandler then geterrorhandler()(err) end
            else
                i = i + 1
            end
        end
    end)
    C_Timer = C_Timer or {}
    function C_Timer.After(delay, cb)
        if type(cb) ~= "function" then return end
        timers[#timers + 1] = { expire = GetTime() + (delay or 0), cb = cb }
    end
    function C_Timer.NewTimer(delay, cb)
        local handle = { expire = GetTime() + (delay or 0), cb = cb }
        function handle:Cancel() self.cancelled = true end
        timers[#timers + 1] = handle
        return handle
    end
    function C_Timer.NewTicker(interval, cb, iterations)
        local handle = { cancelled = false }
        local count = 0
        local function step()
            if handle.cancelled then return end
            count = count + 1
            local ok, err = pcall(cb, handle)
            if not ok and geterrorhandler then geterrorhandler()(err) end
            if iterations and count >= iterations then return end
            C_Timer.After(interval, step)
        end
        function handle:Cancel() self.cancelled = true end
        C_Timer.After(interval, step)
        return handle
    end
    _G.C_Timer = C_Timer
end

---------------------------------------------------------------------------
-- CreateColor / ColorMixin / WrapTextInColorCode
---------------------------------------------------------------------------
if type(CreateColor) ~= "function" then
    local function hex(self)
        return string.format("ff%02x%02x%02x",
            math.floor((self.r or 0)*255+0.5),
            math.floor((self.g or 0)*255+0.5),
            math.floor((self.b or 0)*255+0.5))
    end
    local M = {}
    function M:GetRGB() return self.r, self.g, self.b end
    function M:GetRGBA() return self.r, self.g, self.b, self.a or 1 end
    function M:GetRGBAAsBytes()
        return math.floor((self.r or 0)*255+0.5), math.floor((self.g or 0)*255+0.5),
               math.floor((self.b or 0)*255+0.5), math.floor((self.a or 1)*255+0.5)
    end
    function M:SetRGBA(r,g,b,a) self.r,self.g,self.b,self.a = r,g,b,a end
    function M:SetRGB(r,g,b) self.r,self.g,self.b,self.a = r,g,b,1 end
    function M:GenerateHexColor() return hex(self) end
    function M:GenerateHexColorMarkup() return "|c"..hex(self) end
    function M:WrapTextInColorCode(text) return "|c"..hex(self)..(text or "").."|r" end
    function M:IsEqualTo(o)
        return o and self.r==o.r and self.g==o.g and self.b==o.b and self.a==o.a
    end
    function CreateColor(r,g,b,a)
        local c = { r=r, g=g, b=b, a=a or 1 }
        for k,v in pairs(M) do c[k]=v end
        return c
    end
    _G.CreateColor = CreateColor
    _G.ColorMixin = M
end

if type(WrapTextInColorCode) ~= "function" then
    function WrapTextInColorCode(text, hexString)
        return "|c"..(hexString or "ffffffff")..(text or "").."|r"
    end
    _G.WrapTextInColorCode = WrapTextInColorCode
end

---------------------------------------------------------------------------
-- PixelUtil (forward to ordinary frame methods; ignore snap hints)
---------------------------------------------------------------------------
if type(PixelUtil) ~= "table" then
    PixelUtil = {}
    function PixelUtil.SetPoint(region, point, relativeTo, relativePoint, x, y)
        region:SetPoint(point, relativeTo, relativePoint, x or 0, y or 0)
    end
    function PixelUtil.SetSize(region, w, h) region:SetSize(w, h) end
    function PixelUtil.SetWidth(region, w) region:SetWidth(w) end
    function PixelUtil.SetHeight(region, h) region:SetHeight(h) end
    function PixelUtil.GetNearestPixelSize(size) return size end
    function PixelUtil.GetPixelToUIUnitFactor() return 1 end
    _G.PixelUtil = PixelUtil
end

-- Ensure Frame:SetSize exists (some cores lack it)
do
    local probe = CreateFrame("Frame")
    if type(probe.SetSize) ~= "function" then
        local meta = getmetatable(probe).__index
        function meta:SetSize(w, h)
            if w then self:SetWidth(w) end
            if h then self:SetHeight(h) end
        end
    end
end

-- Texture:SetColorTexture -> SetTexture(r,g,b,a)
do
    local probeTex = UIParent:CreateTexture()
    if type(probeTex.SetColorTexture) ~= "function" then
        local texMeta = getmetatable(probeTex).__index
        function texMeta:SetColorTexture(r, g, b, a)
            self:SetTexture(r, g, b, a or 1)
        end
    end
end

---------------------------------------------------------------------------
-- C_CVar (Set / Get / GetBool / GetNumber)
---------------------------------------------------------------------------
if type(C_CVar) ~= "table" then
    local GetCVar, SetCVar, GetCVarBool = GetCVar, SetCVar, GetCVarBool
    C_CVar = {}
    function C_CVar.Set(name, value)
        if type(value) == "boolean" then value = value and "1" or "0" end
        pcall(SetCVar, name, value)   -- unknown CVars error; guard
    end
    function C_CVar.Get(name)
        local ok, v = pcall(GetCVar, name)
        return ok and v or nil
    end
    function C_CVar.GetBool(name)
        if GetCVarBool then
            local ok, v = pcall(GetCVarBool, name)
            if ok then return v and true or false end
        end
        local v = C_CVar.Get(name)
        return v == "1" or v == "true"
    end
    function C_CVar.GetNumber(name)
        local v = C_CVar.Get(name)
        return v and tonumber(v) or nil
    end
    _G.C_CVar = C_CVar
end

---------------------------------------------------------------------------
-- EventRegistry (callback bus). The nameplate engine fires
-- "NamePlateManager.UnitAdded"/"...UnitRemoved" through this.
---------------------------------------------------------------------------
if type(EventRegistry) ~= "table" then
    local callbacks = {}
    EventRegistry = {}
    function EventRegistry:RegisterCallback(event, fn, owner)
        callbacks[event] = callbacks[event] or {}
        table.insert(callbacks[event], { fn = fn, owner = owner })
    end
    function EventRegistry:UnregisterCallback(event, owner)
        local list = callbacks[event]
        if not list then return end
        for i = #list, 1, -1 do
            if list[i].owner == owner then table.remove(list, i) end
        end
    end
    function EventRegistry:TriggerEvent(event, ...)
        local list = callbacks[event]
        if not list then return end
        for i = 1, #list do
            local e = list[i]
            local ok, err = pcall(e.fn, e.owner, ...)
            if not ok and geterrorhandler then geterrorhandler()(err) end
        end
    end
    _G.EventRegistry = EventRegistry
end

---------------------------------------------------------------------------
-- GetCreatureIDFromGUID (WotLK GUID -> npc id)
---------------------------------------------------------------------------
if type(GetCreatureIDFromGUID) ~= "function" then
    function GetCreatureIDFromGUID(guid)
        if type(guid) ~= "string" then return nil end
        local hex = guid:gsub("^0[xX]", "")
        if #hex < 12 then return nil end
        local id = tonumber(hex:sub(5, 10), 16)
        if id and id > 0 then return id end
        return nil
    end
    _G.GetCreatureIDFromGUID = GetCreatureIDFromGUID
end
