--[[----------------------------------------------------------------------------
    TurboPlates - pure 3.3.5a backport, part 3: aura / threat API shims
    (Backported by Jedborg)

    Maps retail aura/threat unit APIs onto WotLK. These operate on unit tokens;
    for plates bound to a real unit (target/focus/mouseover/group target) they
    return real data via the wrapped Unit* functions. For unbound plates the
    underlying UnitAura simply returns nothing, so auras quietly don't show --
    which is the expected limit on a pure client.

    Loaded after the engine, before any module that consumes auras.
------------------------------------------------------------------------------]]

local addonName, ns = ...
if ns.Compat and ns.Compat.HAS_NATIVE_ENGINE then return end

local UnitAura = UnitAura   -- exists on 3.3.5a (singular); wrapped? no - aura
                            -- data can't be scraped, so this stays the raw fn.

---------------------------------------------------------------------------
-- AuraUtil.ForEachAura(unit, filter, maxCount, callback)
---------------------------------------------------------------------------
if type(AuraUtil) ~= "table" or type(AuraUtil.ForEachAura) ~= "function" then
    AuraUtil = AuraUtil or {}
    function AuraUtil.ForEachAura(unit, filter, maxCount, callback)
        if not unit or not UnitExists(unit) or type(callback) ~= "function" then return end
        filter = filter or "HELPFUL"
        local auraFilter = (filter:find("HARMFUL") and "HARMFUL" or "HELPFUL")
        if filter:find("PLAYER") then auraFilter = auraFilter .. "|PLAYER" end
        local limit = maxCount or 40
        for i = 1, limit do
            local name, rank, icon, count, debuffType, duration, expires,
                  caster, isStealable, shouldConsolidate, spellID,
                  canApplyAura, isBossDebuff, castByPlayer = UnitAura(unit, i, auraFilter)
            if not name then break end
            local stop = callback(name, rank, icon, count, debuffType, duration,
                expires, caster, isStealable, shouldConsolidate, spellID,
                canApplyAura, isBossDebuff, castByPlayer)
            if stop then break end
        end
    end
    function AuraUtil.FindAuraByName(name, unit, filter)
        if not unit or not UnitExists(unit) then return nil end
        filter = filter or "HELPFUL"
        for i = 1, 40 do
            local n = UnitAura(unit, i, filter)
            if not n then break end
            if n == name then return UnitAura(unit, i, filter) end
        end
        return nil
    end
    _G.AuraUtil = AuraUtil
end

---------------------------------------------------------------------------
-- UnitAuras alias
---------------------------------------------------------------------------
if type(UnitAuras) ~= "function" then
    UnitAuras = UnitAura
    _G.UnitAuras = UnitAuras
end

---------------------------------------------------------------------------
-- UnitRole
---------------------------------------------------------------------------
if type(UnitRole) ~= "function" then
    function UnitRole(unit)
        if not unit or not UnitExists(unit) then return nil end
        if GetPartyAssignment then
            if GetPartyAssignment("MAINTANK", unit) then return "TANK" end
            if GetPartyAssignment("MAINASSIST", unit) then return "DAMAGER" end
        end
        if UnitGroupRolesAssigned then
            local r = UnitGroupRolesAssigned(unit)
            if r and r ~= "NONE" then return r end
        end
        return nil
    end
    _G.UnitRole = UnitRole
end

---------------------------------------------------------------------------
-- UnitDetailedThreatSituation (exists on most 3.3.5a cores; fallback anyway)
---------------------------------------------------------------------------
if type(UnitDetailedThreatSituation) ~= "function" then
    function UnitDetailedThreatSituation(unit, mob)
        if not unit or not mob then return nil end
        local status = UnitThreatSituation and UnitThreatSituation(unit, mob) or nil
        if not status then return nil end
        local isTanking = (status == 2 or status == 3)
        return isTanking, status, isTanking and 100 or 0, isTanking and 100 or 0, 0
    end
    _G.UnitDetailedThreatSituation = UnitDetailedThreatSituation
end

---------------------------------------------------------------------------
-- UnitQuestInfo stub (no 3.3.5a equivalent)
---------------------------------------------------------------------------
if type(UnitQuestInfo) ~= "function" then
    function UnitQuestInfo() return nil end
    _G.UnitQuestInfo = UnitQuestInfo
end

---------------------------------------------------------------------------
-- Ambiguate (strip realm from "Name-Realm").
---------------------------------------------------------------------------
if type(Ambiguate) ~= "function" then
    function Ambiguate(name)
        if type(name) ~= "string" then return name end
        return name:match("^([^%-]+)") or name
    end
    _G.Ambiguate = Ambiguate
end

---------------------------------------------------------------------------
-- Group APIs: retail IsInGroup / IsInRaid / GetNumGroupMembers don't exist on
-- 3.3.5a. TurboPlates uses GetNumGroupMembers with retail semantics:
--   in a raid  -> total raid members, iterate raid1..N
--   in a party -> party members + player, iterate party1..(N-1)
---------------------------------------------------------------------------
local _GetNumRaidMembers  = GetNumRaidMembers
local _GetNumPartyMembers = GetNumPartyMembers

if type(IsInRaid) ~= "function" then
    function IsInRaid() return (_GetNumRaidMembers() or 0) > 0 end
    _G.IsInRaid = IsInRaid
end
if type(IsInGroup) ~= "function" then
    function IsInGroup()
        return (_GetNumRaidMembers() or 0) > 0 or (_GetNumPartyMembers() or 0) > 0
    end
    _G.IsInGroup = IsInGroup
end
if type(GetNumGroupMembers) ~= "function" then
    function GetNumGroupMembers()
        local nRaid = _GetNumRaidMembers() or 0
        if nRaid > 0 then return nRaid end
        local nParty = _GetNumPartyMembers() or 0
        if nParty > 0 then return nParty + 1 end
        return 0
    end
    _G.GetNumGroupMembers = GetNumGroupMembers
end

---------------------------------------------------------------------------
-- UnitGetTotalAbsorbs (retail absorb shields). No 3.3.5a equivalent.
---------------------------------------------------------------------------
if type(UnitGetTotalAbsorbs) ~= "function" then
    function UnitGetTotalAbsorbs() return 0 end
    _G.UnitGetTotalAbsorbs = UnitGetTotalAbsorbs
end

---------------------------------------------------------------------------
-- UnitGroupRolesAssigned / ...Key (retail / Ascension role helpers).
---------------------------------------------------------------------------
if type(UnitGroupRolesAssigned) ~= "function" then
    function UnitGroupRolesAssigned() return "NONE" end
    _G.UnitGroupRolesAssigned = UnitGroupRolesAssigned
end
if type(UnitGroupRolesAssignedKey) ~= "function" then
    function UnitGroupRolesAssignedKey(unit)
        return (UnitRole and UnitRole(unit)) or "NONE"
    end
    _G.UnitGroupRolesAssignedKey = UnitGroupRolesAssignedKey
end
