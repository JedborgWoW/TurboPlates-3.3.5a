--[[----------------------------------------------------------------------------
    TurboPlates - stock 3.3.5a nameplate engine (name-based data layer)
    (Backported by Jedborg)

    TurboPlates was written for Ascension's modern nameplate engine, where the
    client hands the addon a real per-plate UNIT TOKEN, and it calls
    UnitName(unit)/UnitGUID(unit)/UnitHealth(unit)/UnitIsFriend(unit)/
    UnitClass(unit)... on that token ~110 times. A stock, unpatched 3.3.5a
    client has NO nameplate unit tokens, so those calls return nil/false for any
    plate that isn't your current target.

    This rebuilds the data layer to be NAME/REGION based, the way NotPlater works
    on real 3.3.5a:
      * discover plates by polling WorldFrame:GetChildren() + texture fingerprint
      * read name/level from the plate's font-string regions
      * read health + REACTION (hostile/neutral/friendly/friendlyPlayer/tapped)
        from the plate's health-bar StatusBar value + colour
      * keep name-keyed class/faction caches fed from target/mouseover/group +
        combat log
      * match a plate to a real unit (target/focus/mouseover/partyNtarget/
        raidNtarget) confirmed by name+level+exact-health for things that truly
        need a token (GUID, auras, casts)

    Instead of editing 110 call sites, we WRAP the Unit* family: each plate gets
    a stable synthetic token "TurboPlateN"; Unit* calls with that token answer
    from scraped/cached/matched data, and real tokens pass straight through.

    Must load FIRST in the .toc (before Config.lua). Pure-API shims live in the
    WotlkCompat_*.lua helpers.
------------------------------------------------------------------------------]]

local addonName, ns = ...

local HAVE_NATIVE_ENGINE = (type(C_NamePlate) == "table"
    and type(C_NamePlate.GetNamePlateForUnit) == "function"
    and type(C_NamePlateManager) == "table")

local WorldFrame   = WorldFrame
local CreateFrame  = CreateFrame
local abs          = math.abs
local wipe         = wipe
local tonumber     = tonumber
local pairs, next  = pairs, next
local bit          = bit

local _UnitExists        = UnitExists
local _UnitName          = UnitName
local _UnitGUID          = UnitGUID
local _UnitClass         = UnitClass
local _UnitLevel         = UnitLevel
local _UnitHealth        = UnitHealth
local _UnitHealthMax     = UnitHealthMax
local _UnitIsPlayer      = UnitIsPlayer
local _UnitIsUnit        = UnitIsUnit
local _UnitIsFriend      = UnitIsFriend
local _UnitReaction      = UnitReaction
local _UnitCanAttack     = UnitCanAttack
local _UnitCreatureType  = UnitCreatureType
local _UnitIsPet         = UnitIsPet
local _UnitIsDead        = UnitIsDead
local _UnitIsDeadOrGhost = UnitIsDeadOrGhost
local _UnitClassification= UnitClassification
local _UnitIsTapped      = UnitIsTapped
local _UnitAffectingCombat = UnitAffectingCombat

local NAMEPLATE_COLORS = {
    hostile        = {1,   0,   0},
    neutral        = {1,   1,   0},
    friendly       = {0,   1,   0},
    friendlyPlayer = {0,   0.6, 1},
    tapped         = {0.5, 0.5, 0.5},
}
local function ColorToReactionKey(r, g, b)
    if not r then return nil end
    for key, c in pairs(NAMEPLATE_COLORS) do
        if abs(c[1]-r) <= 0.1 and abs(c[2]-g) <= 0.1 and abs(c[3]-b) <= 0.1 then
            return key
        end
    end
    if abs(r) <= 0.15 and abs(g-0.6) <= 0.25 and abs(b-1) <= 0.15 then
        return "friendlyPlayer"
    end
    return nil
end

local classCache      = {}
local classTokenCache = {}
local isPlayerCache   = {}
local levelCache      = {}
ns.npClassCache      = classCache
ns.npClassTokenCache = classTokenCache

local function CacheUnitByName(unit)
    if not _UnitExists(unit) then return end
    local name = _UnitName(unit)
    if not name then return end
    local isPlayer = _UnitIsPlayer(unit)
    isPlayerCache[name] = isPlayer
    if isPlayer then
        local localized, token = _UnitClass(unit)
        if token then
            classCache[name] = localized
            classTokenCache[name] = token
        end
    end
    local lvl = _UnitLevel(unit)
    if lvl and lvl > 0 then levelCache[name] = lvl end
end

if not HAVE_NATIVE_ENGINE then

    local managedPlates = {}
    local tokenToPlate  = {}
    local tokenCounter  = 0

    local NAMEPLATE_TEXTURES = {
        ["Interface\\TargetingFrame\\UI-TargetingFrame-Flash"] = true,
        ["Interface\\Tooltips\\Nameplate-Border"]              = true,
    }

    -- WotLK region order (confirmed against NotPlater):
    --   1 threatGlow  2 healthBorder  3 castBorder  4 castNoStop
    --   5 spellIcon   6 highlightTex  7 nameText    8 levelText
    --   9 bossIcon    10 raidIcon     11 eliteIcon
    -- children: 1 healthBar  2 castBar
    --
    -- IMPORTANT: TurboPlates' HideBlizzardElements REPARENTS the original health
    -- bar + regions onto a hidden frame. On a stock client a region reparented
    -- off the WorldFrame nameplate stops receiving engine updates, which would
    -- freeze anything we scrape from it. So, exactly like NotPlater, we hook the
    -- original bar/text WHILE they're still live (this runs before TurboPlates
    -- reparents them) and cache last-known values ON the plate. All readers use
    -- the cached values, immune to the later reparenting.
    local function HookPlateSources(blizzFrame, nameText, levelText, healthBar)
        if blizzFrame._tpSourcesHooked then return end
        blizzFrame._tpSourcesHooked = true

        if nameText then
            blizzFrame._tpName = nameText:GetText()
            hooksecurefunc(nameText, "SetText", function(_, txt)
                blizzFrame._tpName = txt
            end)
        end
        if levelText then
            blizzFrame._tpLevel = tonumber(levelText:GetText())
            hooksecurefunc(levelText, "SetText", function(_, txt)
                blizzFrame._tpLevel = tonumber(txt)
            end)
        end
        if healthBar and healthBar.GetValue then
            local cur = healthBar:GetValue()
            local _, max = healthBar:GetMinMaxValues()
            blizzFrame._tpHP, blizzFrame._tpHPMax = cur, max
            local r, g, b = healthBar:GetStatusBarColor()
            blizzFrame._tpReaction = ColorToReactionKey(r, g, b)

            -- The engine updates the nameplate health bar C-side, which fires the
            -- OnValueChanged *script* (not the Lua SetValue method). Hook the
            -- script so our cache tracks live values even after TurboPlates
            -- reparents the bar. We chain any pre-existing handler.
            local prevOVC = healthBar:GetScript("OnValueChanged")
            healthBar:SetScript("OnValueChanged", function(bar, value, ...)
                local _, mx = bar:GetMinMaxValues()
                blizzFrame._tpHP = value
                blizzFrame._tpHPMax = mx
                local rr, gg, bb = bar:GetStatusBarColor()
                blizzFrame._tpReaction = ColorToReactionKey(rr, gg, bb)
                if prevOVC then return prevOVC(bar, value, ...) end
            end)
            -- Colour can also change without a value change (e.g. tapping); catch
            -- it via a method hook as a cheap supplement.
            hooksecurefunc(healthBar, "SetStatusBarColor", function(bar, rr, gg, bb)
                blizzFrame._tpReaction = ColorToReactionKey(rr, gg, bb)
            end)
        end
    end

    local function CapturePlateRefs(blizzFrame)
        -- Capture ONCE per frame, and only the first time - before
        -- HideBlizzPlateRegions reparents the health/border/cast regions off the
        -- plate. The region indices (7=name, 8=level, 10=raidIcon) are only valid
        -- while the original WotLK region order is intact; after reparenting,
        -- GetRegions returns a reduced/reordered set and these indices grab the
        -- WRONG FontString. Pooled frames get RE-acquired (hidden then shown
        -- again), so without this guard a recycled plate would re-capture garbage
        -- refs -> wrong/blank name, inconsistent plates. The captured refs (and
        -- their SetText/OnValueChanged hooks) stay valid across reuse, so reusing
        -- them is correct.
        if blizzFrame._tpRefsCaptured then return end
        local regions = { blizzFrame:GetRegions() }
        local healthBar, castBar = blizzFrame:GetChildren()

        -- Identify name/level FontStrings by TYPE+ORDER, not by absolute region
        -- index. The canonical WotLK order is ...nameText(7), levelText(8)..., but
        -- the number of leading border/glow TEXTURES differs between 3.3.5a cores,
        -- which shifts those indices and makes us grab the wrong FontString: wrong
        -- scraped level, and the real level FontString left unsuppressed -> two
        -- level numbers on the plate. A stock plate has exactly two FontStrings in
        -- creation order: name first, then level. Pick those, with the canonical
        -- index as a fallback.
        local nameText, levelText
        for i = 1, #regions do
            local r = regions[i]
            if r and r.GetObjectType and r:GetObjectType() == "FontString" then
                if not nameText then
                    nameText = r
                elseif not levelText then
                    levelText = r
                    break
                end
            end
        end
        nameText  = nameText  or regions[7]
        levelText = levelText or regions[8]

        blizzFrame._tpNameText  = nameText
        blizzFrame._tpLevelText = levelText
        blizzFrame._tpRaidIcon  = regions[10]
        blizzFrame._tpHealthBar = healthBar
        blizzFrame._tpCastBar   = castBar
        HookPlateSources(blizzFrame, nameText, levelText, healthBar)
        blizzFrame._tpRefsCaptured = true
    end

    -- Readers prefer the cached (hook-fed) values; fall back to a live read in
    -- case the hook hasn't fired yet (first frame).
    local function PlateName(blizzFrame)
        if blizzFrame._tpName ~= nil then return blizzFrame._tpName end
        local t = blizzFrame._tpNameText
        return t and t:GetText() or nil
    end
    local function PlateLevel(blizzFrame)
        if blizzFrame._tpLevel ~= nil then return blizzFrame._tpLevel end
        local t = blizzFrame._tpLevelText
        local s = t and t:GetText()
        return s and tonumber(s) or nil
    end
    local function PlateHealth(blizzFrame)
        if blizzFrame._tpHP ~= nil then
            return blizzFrame._tpHP, blizzFrame._tpHPMax
        end
        local hb = blizzFrame._tpHealthBar
        if not hb or not hb.GetValue then return nil, nil end
        local cur = hb:GetValue()
        local _, max = hb:GetMinMaxValues()
        return cur, max
    end
    local function PlateReaction(blizzFrame)
        if blizzFrame._tpReaction ~= nil then return blizzFrame._tpReaction end
        local hb = blizzFrame._tpHealthBar
        if not hb or not hb.GetStatusBarColor then return nil end
        return ColorToReactionKey(hb:GetStatusBarColor())
    end

    local trackedUnits = {}
    local function RebuildTrackedUnits()
        wipe(trackedUnits)
        trackedUnits[#trackedUnits+1] = "target"
        trackedUnits[#trackedUnits+1] = "focus"
        trackedUnits[#trackedUnits+1] = "mouseover"
        local nRaid = (GetNumRaidMembers and GetNumRaidMembers()) or 0
        if nRaid > 0 then
            for i = 1, nRaid do trackedUnits[#trackedUnits+1] = "raid"..i.."target" end
        else
            local nParty = (GetNumPartyMembers and GetNumPartyMembers()) or 0
            for i = 1, nParty do trackedUnits[#trackedUnits+1] = "party"..i.."target" end
        end
    end
    RebuildTrackedUnits()

    local function PlateMatchesUnit(blizzFrame, unit)
        if not _UnitExists(unit) or _UnitIsDeadOrGhost(unit) then return false end
        local name = PlateName(blizzFrame)
        if not name or name ~= _UnitName(unit) then return false end
        local lvl = PlateLevel(blizzFrame)
        if lvl then
            local ulvl = _UnitLevel(unit)
            if ulvl and ulvl > 0 and lvl ~= ulvl then return false end
        end
        local cur, max = PlateHealth(blizzFrame)
        if cur ~= nil then
            if cur ~= _UnitHealth(unit) then return false end
            if not _UnitIsPlayer(unit) and max and cur == max then return false end
        end
        return true
    end

    local matchUnitToPlate = {}
    local function ReleaseMatch(blizzFrame)
        local u = blizzFrame._tpMatchedUnit
        if u and matchUnitToPlate[u] == blizzFrame then matchUnitToPlate[u] = nil end
        blizzFrame._tpMatchedUnit = nil
        blizzFrame._tpMatchedGUID = nil
    end
    local function SetMatch(blizzFrame, unit)
        if blizzFrame._tpMatchedUnit == unit then return end
        ReleaseMatch(blizzFrame)
        blizzFrame._tpMatchedUnit = unit
        blizzFrame._tpMatchedGUID = unit and _UnitGUID(unit) or nil
        if unit then
            matchUnitToPlate[unit] = blizzFrame
            CacheUnitByName(unit)
        end
    end

    -- Re-read the live regions/bar for a plate and refresh its cached scrape.
    -- The snapshot taken at acquire + the SetText/OnValueChanged hooks miss two
    -- cases: (1) Blizzard RECYCLES plate frames, and the _tpSourcesHooked guard
    -- skips re-snapshotting, so a reused plate keeps the previous mob's values
    -- until a hooked setter happens to fire again; (2) the engine sets the
    -- health-bar COLOUR C-side by pointer (not via the Lua SetStatusBarColor
    -- method), so the colour hook never fires for a full-health mob that never
    -- triggers OnValueChanged - leaving reaction stuck on the snapshot (hostile
    -- read as neutral -> "yellow instead of red"). The name/level FontStrings are
    -- kept live (not reparented) and the bar value/colour getters read the live
    -- pointer, so re-reading here is current. Guards only overwrite with valid
    -- (non-empty / parseable / known-reaction) reads so a frozen read can never
    -- clobber a good cached value.
    local function RefreshPlateScrape(frame)
        local nt = frame._tpNameText
        if nt then
            local txt = nt:GetText()
            if txt and txt ~= "" then frame._tpName = txt end
        end
        local lt = frame._tpLevelText
        if lt then
            local n = tonumber(lt:GetText())
            if n then frame._tpLevel = n end
        end
        local hb = frame._tpHealthBar
        if hb and hb.GetValue then
            local cur = hb:GetValue()
            if cur ~= nil then
                local _, mx = hb:GetMinMaxValues()
                frame._tpHP, frame._tpHPMax = cur, mx
            end
            if hb.GetStatusBarColor then
                local key = ColorToReactionKey(hb:GetStatusBarColor())
                if key then frame._tpReaction = key end
            end
        end
    end

    -- Scratch buffers reused across passes so each plate is scraped at most once
    -- per UpdateMatches call (instead of once per unmatched tracked unit).
    local candFrame, candName, candLvl, candCur, candMax = {}, {}, {}, {}, {}
    local function UpdateMatches()
        -- Refresh every managed plate from its live regions, then drop matches
        -- that no longer hold (few matched plates -> cheap).
        for frame in pairs(managedPlates) do
            RefreshPlateScrape(frame)
            local u = frame._tpMatchedUnit
            if u and (not _UnitExists(u) or not PlateMatchesUnit(frame, u)) then
                ReleaseMatch(frame)
            end
        end
        -- Collect unmatched, shown plates and scrape name/level/health ONCE each.
        local nCand = 0
        for frame in pairs(managedPlates) do
            if frame:IsShown() and not frame._tpMatchedUnit then
                nCand = nCand + 1
                candFrame[nCand] = frame
                candName[nCand]  = PlateName(frame)
                candLvl[nCand]   = PlateLevel(frame)
                local cur, max = PlateHealth(frame)
                candCur[nCand]   = cur
                candMax[nCand]   = max
            end
        end
        -- Match each unmatched tracked unit against the pre-scraped candidates
        -- using value comparisons only (no further region/bar scraping).
        for i = 1, #trackedUnits do
            local unit = trackedUnits[i]
            if _UnitExists(unit) and not matchUnitToPlate[unit]
               and not _UnitIsDeadOrGhost(unit) then
                local uName  = _UnitName(unit)
                local uLvl   = _UnitLevel(unit)
                local uHP    = _UnitHealth(unit)
                local uIsPlr = _UnitIsPlayer(unit)
                for c = 1, nCand do
                    local frame = candFrame[c]
                    if frame and not frame._tpMatchedUnit and candName[c]
                       and candName[c] == uName then
                        local lvl = candLvl[c]
                        if not (lvl and uLvl and uLvl > 0 and lvl ~= uLvl) then
                            local cur, max = candCur[c], candMax[c]
                            local hpOk = true
                            if cur ~= nil then
                                if cur ~= uHP then hpOk = false
                                elseif not uIsPlr and max and cur == max then hpOk = false end
                            end
                            if hpOk then
                                SetMatch(frame, unit)
                                break
                            end
                        end
                    end
                end
            end
        end
        -- Release frame references so hidden plates can be GC'd.
        for c = 1, nCand do candFrame[c] = nil end
    end

    local function ResolveToken(token)
        local frame = tokenToPlate[token]
        if not frame then return nil end
        return frame, frame._tpMatchedUnit
    end

    local function isPlateToken(unit)
        return type(unit) == "string" and tokenToPlate[unit] ~= nil
    end

    function ns.UnitExists(unit, ...)
        if isPlateToken(unit) then
            local f = tokenToPlate[unit]
            return f and f:IsShown() and true or false
        end
        return _UnitExists(unit, ...)
    end

    function ns.UnitName(unit, ...)
        if isPlateToken(unit) then
            local f, real = ResolveToken(unit)
            if real then return _UnitName(real) end
            return PlateName(f)
        end
        return _UnitName(unit, ...)
    end

    function ns.UnitGUID(unit, ...)
        if isPlateToken(unit) then
            local f, real = ResolveToken(unit)
            if real then return _UnitGUID(real) end
            return f and f._tpSyntheticGUID or nil
        end
        return _UnitGUID(unit, ...)
    end

    function ns.UnitClass(unit, ...)
        if isPlateToken(unit) then
            local f, real = ResolveToken(unit)
            if real then return _UnitClass(real) end
            local name = PlateName(f)
            if name and classCache[name] then
                return classCache[name], classTokenCache[name]
            end
            return (UNKNOWN or "Unknown"), nil
        end
        return _UnitClass(unit, ...)
    end

    function ns.UnitLevel(unit, ...)
        if isPlateToken(unit) then
            local f, real = ResolveToken(unit)
            if real then return _UnitLevel(real) end
            return PlateLevel(f) or -1
        end
        return _UnitLevel(unit, ...)
    end

    function ns.UnitHealth(unit, ...)
        if isPlateToken(unit) then
            local f, real = ResolveToken(unit)
            if real then return _UnitHealth(real) end
            local cur = PlateHealth(f)
            return cur or 0
        end
        return _UnitHealth(unit, ...)
    end

    function ns.UnitHealthMax(unit, ...)
        if isPlateToken(unit) then
            local f, real = ResolveToken(unit)
            if real then return _UnitHealthMax(real) end
            local _, max = PlateHealth(f)
            return max or 0
        end
        return _UnitHealthMax(unit, ...)
    end

    function ns.UnitIsPlayer(unit, ...)
        if isPlateToken(unit) then
            local f, real = ResolveToken(unit)
            if real then return _UnitIsPlayer(real) end
            local name = PlateName(f)
            if name and isPlayerCache[name] ~= nil then return isPlayerCache[name] end
            return PlateReaction(f) == "friendlyPlayer"
        end
        return _UnitIsPlayer(unit, ...)
    end

    function ns.UnitIsUnit(unitA, unitB, ...)
        local aPlate, bPlate = isPlateToken(unitA), isPlateToken(unitB)
        if aPlate or bPlate then
            if aPlate and bPlate then
                return tokenToPlate[unitA] == tokenToPlate[unitB]
            end
            if aPlate then
                local _, ra = ResolveToken(unitA)
                if ra then return _UnitIsUnit(ra, unitB) end
                local plateName = PlateName(tokenToPlate[unitA])
                if plateName and _UnitExists(unitB) then
                    return plateName == _UnitName(unitB)
                end
                return false
            end
            local _, rb = ResolveToken(unitB)
            if rb then return _UnitIsUnit(unitA, rb) end
            local plateName = PlateName(tokenToPlate[unitB])
            if plateName and _UnitExists(unitA) then
                return plateName == _UnitName(unitA)
            end
            return false
        end
        return _UnitIsUnit(unitA, unitB, ...)
    end

    function ns.UnitIsFriend(unitA, unitB, ...)
        if isPlateToken(unitB) then
            local f, real = ResolveToken(unitB)
            if real then return _UnitIsFriend(unitA, real) end
            local rk = PlateReaction(f)
            return rk == "friendly" or rk == "friendlyPlayer"
        end
        if isPlateToken(unitA) then
            local f, real = ResolveToken(unitA)
            if real then return _UnitIsFriend(real, unitB) end
            local rk = PlateReaction(f)
            return rk == "friendly" or rk == "friendlyPlayer"
        end
        return _UnitIsFriend(unitA, unitB, ...)
    end

    function ns.UnitReaction(unitA, unitB, ...)
        local function reactFor(token)
            local f, real = ResolveToken(token)
            if real then return _UnitReaction("player", real) end
            local rk = PlateReaction(f)
            if rk == "hostile"  then return 2 end
            if rk == "neutral"  then return 4 end
            if rk == "friendly" or rk == "friendlyPlayer" then return 6 end
            if rk == "tapped"   then return 2 end
            return nil
        end
        if isPlateToken(unitB) then return reactFor(unitB) end
        if isPlateToken(unitA) then return reactFor(unitA) end
        return _UnitReaction(unitA, unitB, ...)
    end

    function ns.UnitCanAttack(unitA, unitB, ...)
        if isPlateToken(unitB) then
            local f, real = ResolveToken(unitB)
            if real then return _UnitCanAttack(unitA, real) end
            local rk = PlateReaction(f)
            return rk == "hostile" or rk == "neutral" or rk == "tapped"
        end
        if isPlateToken(unitA) then
            local f, real = ResolveToken(unitA)
            if real then return _UnitCanAttack(real, unitB) end
            local rk = PlateReaction(f)
            return rk == "hostile" or rk == "neutral" or rk == "tapped"
        end
        return _UnitCanAttack(unitA, unitB, ...)
    end

    function ns.UnitCreatureType(unit, ...)
        if isPlateToken(unit) then
            local _, real = ResolveToken(unit)
            if real then return _UnitCreatureType(real) end
            return nil
        end
        return _UnitCreatureType(unit, ...)
    end

    function ns.UnitIsPet(unit, ...)
        if isPlateToken(unit) then
            local _, real = ResolveToken(unit)
            if real then return _UnitIsPet(real) end
            return false
        end
        return _UnitIsPet(unit, ...)
    end

    function ns.UnitIsDead(unit, ...)
        if isPlateToken(unit) then
            local f, real = ResolveToken(unit)
            if real then return _UnitIsDead(real) end
            local cur = PlateHealth(f)
            return cur == 0
        end
        return _UnitIsDead(unit, ...)
    end

    function ns.UnitClassification(unit, ...)
        if isPlateToken(unit) then
            local _, real = ResolveToken(unit)
            if real then return _UnitClassification(real) end
            return "normal"
        end
        return _UnitClassification(unit, ...)
    end

    if _UnitIsTapped then
        function ns.UnitIsTapped(unit, ...)
            if isPlateToken(unit) then
                local f, real = ResolveToken(unit)
                if real then return _UnitIsTapped(real) end
                return PlateReaction(f) == "tapped"
            end
            return _UnitIsTapped(unit, ...)
        end
    end

    if _UnitAffectingCombat then
        function ns.UnitAffectingCombat(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitAffectingCombat(real) end
                return false
            end
            return _UnitAffectingCombat(unit, ...)
        end
    end

    local _UnitPlayerControlled = UnitPlayerControlled
    if _UnitPlayerControlled then
        function ns.UnitPlayerControlled(unit, ...)
            if isPlateToken(unit) then
                local f, real = ResolveToken(unit)
                if real then return _UnitPlayerControlled(real) end
                -- friendlyPlayer bar colour implies player-controlled
                return PlateReaction(f) == "friendlyPlayer"
            end
            return _UnitPlayerControlled(unit, ...)
        end
    end

    local _UnitIsTappedByPlayer = UnitIsTappedByPlayer
    if _UnitIsTappedByPlayer then
        function ns.UnitIsTappedByPlayer(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitIsTappedByPlayer(real) end
                return false
            end
            return _UnitIsTappedByPlayer(unit, ...)
        end
    end

    -- UnitPower family: real on 3.3.5a and mostly called on "player". Only wrap
    -- the plate-token case (we have no power data for arbitrary plates -> 0).
    local _UnitPower    = UnitPower
    local _UnitPowerMax = UnitPowerMax
    local _UnitPowerType= UnitPowerType
    if _UnitPower then
        function ns.UnitPower(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitPower(real, ...) end
                return 0
            end
            return _UnitPower(unit, ...)
        end
    end
    if _UnitPowerMax then
        function ns.UnitPowerMax(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitPowerMax(real, ...) end
                return 0
            end
            return _UnitPowerMax(unit, ...)
        end
    end
    if _UnitPowerType then
        function ns.UnitPowerType(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitPowerType(real, ...) end
                return 0, "MANA"
            end
            return _UnitPowerType(unit, ...)
        end
    end

    -- UnitCastingInfo / UnitChannelInfo: cast bars need a real unit. For plate
    -- tokens, defer to the matched real unit; otherwise return nil (no cast),
    -- which TurboPlates handles as "not casting".
    local _UnitCastingInfo = UnitCastingInfo
    local _UnitChannelInfo = UnitChannelInfo
    if _UnitCastingInfo then
        function ns.UnitCastingInfo(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitCastingInfo(real) end
                return nil
            end
            return _UnitCastingInfo(unit, ...)
        end
    end
    if _UnitChannelInfo then
        function ns.UnitChannelInfo(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitChannelInfo(real) end
                return nil
            end
            return _UnitChannelInfo(unit, ...)
        end
    end

    -- Auras: a plate token only has auras when matched to a real unit.
    local _UnitBuff   = UnitBuff
    local _UnitDebuff = UnitDebuff
    local _UnitAura   = UnitAura
    if _UnitBuff then
        function ns.UnitBuff(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitBuff(real, ...) end
                return nil
            end
            return _UnitBuff(unit, ...)
        end
    end
    if _UnitDebuff then
        function ns.UnitDebuff(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitDebuff(real, ...) end
                return nil
            end
            return _UnitDebuff(unit, ...)
        end
    end
    if _UnitAura then
        function ns.UnitAura(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitAura(real, ...) end
                return nil
            end
            return _UnitAura(unit, ...)
        end
    end

    -- Threat: UnitDetailedThreatSituation(unit, mob) exists natively on 3.3.5a,
    -- but the native C function throws "Usage:" if either arg is one of our
    -- synthetic plate tokens. Resolve plate tokens to their matched real unit;
    -- if a token isn't bound to a real unit, return nil (no threat data) rather
    -- than erroring.
    local _UnitDetailedThreatSituation = UnitDetailedThreatSituation
    if _UnitDetailedThreatSituation then
        function ns.UnitDetailedThreatSituation(unit, mob, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if not real then return nil end
                unit = real
            end
            if isPlateToken(mob) then
                local _, real = ResolveToken(mob)
                if not real then return nil end
                mob = real
            end
            return _UnitDetailedThreatSituation(unit, mob, ...)
        end
    end

    -- Hide the stock Blizzard nameplate so only TurboPlates' own art shows. On a
    -- real Ascension/retail client DisableBlizzPlate just flips a secure
    -- attribute and the native engine hides the plate; stock 3.3.5a ignores that,
    -- so we hide the regions ourselves.
    --
    -- The name/level FontStrings are what we SCRAPE for unmatched plates, so they
    -- must keep receiving the engine's SetText. Reparenting a region off the
    -- WorldFrame plate stops those updates on this client (and alpha-0 alone is
    -- undone when the engine re-shows the region), so for those two we keep them
    -- parented and force them hidden via Hide() + a Show hook - the text keeps
    -- updating in place, our SetText hook keeps the cache live. Everything else
    -- (health bar, borders, cast bar, icons) is reparented + hidden; the health
    -- bar is scraped through its OnValueChanged hook, which survives reparenting
    -- because the C engine writes it by pointer.
    --
    -- Runs at AcquirePlate (before TurboPlates ever sees the plate) and sets the
    -- `_turboBlizzHidden` flag TurboPlates checks, so TP's own HideBlizzardElements
    -- (which would reparent the names and break scraping, incl. its in-combat
    -- path) no-ops on every plate.
    local blizzHiddenParent = CreateFrame("Frame")
    blizzHiddenParent:Hide()
    local function SuppressRegion(region)
        if not region then return end
        region:Hide()
        if not region._tpSuppressed then
            region._tpSuppressed = true
            hooksecurefunc(region, "Show", function(self)
                if self._tpSuppressed then self:Hide() end
            end)
        end
    end
    local function HideBlizzPlateRegions(blizzFrame)
        if blizzFrame._turboBlizzHidden then return end
        local elements = { blizzFrame:GetRegions() }
        local healthBar, castBar = blizzFrame:GetChildren()
        if healthBar then elements[#elements + 1] = healthBar end
        if castBar   then elements[#elements + 1] = castBar end
        for i = 1, #elements do
            local child = elements[i]
            if child then
                local isFontString = child.GetObjectType
                    and child:GetObjectType() == "FontString"
                if isFontString then
                    -- ALL FontStrings (name, level, and any extra text region)
                    -- get the Hide()+Show-hook treatment, not just name/level.
                    -- Reparenting a FontString off the plate is undone by the C
                    -- engine on this client - it re-shows the region in place - so
                    -- a reparented level text reappears as a stray floating number
                    -- ("14") next to our own plate. Suppressing keeps them parented
                    -- (so the name/level SetText hooks we scrape from keep firing)
                    -- and reliably hidden.
                    SuppressRegion(child)
                else
                    child:SetParent(blizzHiddenParent)
                    child:SetAlpha(0)
                    child:Hide()
                    if child.SetTexture then
                        child:SetTexture()
                    elseif child.SetStatusBarTexture then
                        child:SetStatusBarTexture(nil)
                    end
                end
            end
        end
        blizzFrame._turboBlizzHidden = true
    end

    local function FireAdded(token, blizzFrame)
        if EventRegistry and EventRegistry.TriggerEvent then
            EventRegistry:TriggerEvent("NamePlateManager.UnitAdded", token, blizzFrame)
        end
    end
    local function FireRemoved(token, blizzFrame)
        if EventRegistry and EventRegistry.TriggerEvent then
            EventRegistry:TriggerEvent("NamePlateManager.UnitRemoved", token, blizzFrame)
        end
    end

    local function AcquirePlate(blizzFrame)
        tokenCounter = tokenCounter + 1
        local token = "TurboPlate" .. tokenCounter
        local synthGUID = string.format("0xF130%07X%05X", tokenCounter % 0xFFFFFFF, tokenCounter % 0xFFFFF)

        managedPlates[blizzFrame] = true
        tokenToPlate[token] = blizzFrame
        blizzFrame._unit            = token
        blizzFrame._tpToken         = token
        blizzFrame._tpSyntheticGUID = synthGUID

        CapturePlateRefs(blizzFrame)
        HideBlizzPlateRegions(blizzFrame)

        for i = 1, #trackedUnits do
            local unit = trackedUnits[i]
            if _UnitExists(unit) and not matchUnitToPlate[unit]
               and PlateMatchesUnit(blizzFrame, unit) then
                SetMatch(blizzFrame, unit)
                break
            end
        end

        FireAdded(token, blizzFrame)
    end

    local function ReleasePlate(blizzFrame)
        local token = blizzFrame._tpToken
        ReleaseMatch(blizzFrame)
        managedPlates[blizzFrame] = nil
        if token then tokenToPlate[token] = nil end
        FireRemoved(token, blizzFrame)
        blizzFrame._unit = nil
        blizzFrame._tpToken = nil
    end

    local function IsNamePlate(frame)
        if managedPlates[frame] then return true end
        -- Once a pooled WorldFrame child has been confirmed as a nameplate it
        -- stays one for the session (the client recycles the same frames). We must
        -- remember it: HideBlizzPlateRegions reparents the border TEXTURE off the
        -- plate, destroying the fingerprint below, so a plate that's been hidden
        -- once would never be re-identified after the engine re-shows it - it would
        -- vanish for good when panned off-screen and back.
        if frame._tpIsNamePlate then return true end
        if frame:GetName() then return false end
        local region = frame:GetRegions()
        if not region or region:GetObjectType() ~= "Texture" then return false end
        local tex = region:GetTexture()
        if tex and NAMEPLATE_TEXTURES[tex] then
            frame._tpIsNamePlate = true
            return true
        end
        return false
    end

    local visible = {}
    local function ScanWorldFrame()
        wipe(visible)
        local kids = { WorldFrame:GetChildren() }
        for i = 1, #kids do
            local frame = kids[i]
            if IsNamePlate(frame) then
                visible[frame] = true
                if not managedPlates[frame] then
                    AcquirePlate(frame)
                end
            end
        end
        for frame in pairs(managedPlates) do
            if not visible[frame] or not frame:IsShown() then
                ReleasePlate(frame)
            end
        end
    end

    local lastChildCount = -1
    local matchElapsed = 0
    local driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", function(_, elapsed)
        -- Cheap fast-path: a change in WorldFrame's child count means the client
        -- grew its nameplate pool (a brand-new plate frame). Scan immediately so
        -- newly created plates pop in without waiting for the throttled tick.
        local n = WorldFrame:GetNumChildren()
        if n ~= lastChildCount then
            lastChildCount = n
            ScanWorldFrame()
        end
        matchElapsed = matchElapsed + elapsed
        if matchElapsed >= 0.1 * (ns.c_throttleMultiplier or 1) then
            matchElapsed = 0
            -- On stock 3.3.5a nameplate frames are POOLED: the client hides and
            -- re-shows persistent WorldFrame children, it doesn't add/remove them.
            -- Once the pool stops growing the child-count fast-path above never
            -- fires again, so a plate panned off-screen and back (or a pooled
            -- frame reused for a new mob) would never be released/re-acquired and
            -- its art would stay hidden ("plates disappear after looking away").
            -- Re-scan on the throttled tick to catch those show/hide transitions.
            ScanWorldFrame()
            UpdateMatches()
        end
    end)

    driver:RegisterEvent("PLAYER_ENTERING_WORLD")
    driver:RegisterEvent("PARTY_MEMBERS_CHANGED")
    driver:RegisterEvent("RAID_ROSTER_UPDATE")
    driver:RegisterEvent("PLAYER_TARGET_CHANGED")
    driver:RegisterEvent("PLAYER_FOCUS_CHANGED")
    driver:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
    driver:RegisterEvent("UNIT_TARGET")
    driver:SetScript("OnEvent", function(_, event, arg1)
        if event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE"
           or event == "PLAYER_ENTERING_WORLD" then
            RebuildTrackedUnits()
        elseif event == "UPDATE_MOUSEOVER_UNIT" then
            CacheUnitByName("mouseover")
        elseif event == "PLAYER_TARGET_CHANGED" then
            CacheUnitByName("target")
        elseif event == "PLAYER_FOCUS_CHANGED" then
            CacheUnitByName("focus")
        elseif event == "UNIT_TARGET" and arg1 then
            CacheUnitByName(arg1 .. "target")
        end
        UpdateMatches()
    end)

    -- 3.3.5a delivers COMBAT_LOG args as the event payload (not via a getter).
    local COMBATLOG_OBJECT_TYPE_PLAYER = 0x00000400
    local clog = CreateFrame("Frame")
    clog:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    -- 3.3.5a CLEU payload (after self,event): timestamp, subevent, srcGUID,
    -- srcName, srcFlags, dstGUID, dstName, dstFlags (no raid flags on this core).
    clog:SetScript("OnEvent", function(_, _, _, _, srcGUID, srcName, srcFlags, destGUID, destName, destFlags)
        if srcName and srcFlags then
            isPlayerCache[srcName] = (bit.band(srcFlags, COMBATLOG_OBJECT_TYPE_PLAYER) ~= 0)
        end
        if destName and destFlags then
            isPlayerCache[destName] = (bit.band(destFlags, COMBATLOG_OBJECT_TYPE_PLAYER) ~= 0)
        end
    end)

    -- Cast bar driver. On stock 3.3.5a, UNIT_SPELLCAST_* events fire with real
    -- unit tokens (target/focus/party/raid), never with our synthetic plate
    -- tokens - so TurboPlates' own castbar handler (which only acts on
    -- "nameplate"-prefixed units) never fires. Bridge it: when a real unit that
    -- the match tracker has bound to a plate casts, route the event to that
    -- plate's castbar via TurboPlates' public API, passing the PLATE TOKEN.
    -- CheckExistingCast/CleanupCastbar look the plate up in ns.unitToPlate (keyed
    -- by token, populated by Core.lua), and CastStart reads UnitCastingInfo(token)
    -- which our wrapper resolves back to the real unit. (Cast events only fire
    -- for units the client tracks - target/focus/party/raid - which covers the
    -- mob you're actually fighting; arbitrary unbound plates can't show casts.)
    local castDriver = CreateFrame("Frame")
    castDriver:RegisterEvent("UNIT_SPELLCAST_START")
    castDriver:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    castDriver:RegisterEvent("UNIT_SPELLCAST_STOP")
    castDriver:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
    castDriver:RegisterEvent("UNIT_SPELLCAST_FAILED")
    castDriver:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
    castDriver:RegisterEvent("UNIT_SPELLCAST_DELAYED")
    castDriver:RegisterEvent("UNIT_SPELLCAST_CHANNEL_UPDATE")
    castDriver:SetScript("OnEvent", function(_, event, unit)
        if not unit or isPlateToken(unit) then return end
        local blizzFrame = matchUnitToPlate[unit]
        local token = blizzFrame and blizzFrame._tpToken
        if not token then return end
        if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START"
           or event == "UNIT_SPELLCAST_DELAYED" or event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
            if ns.CheckExistingCast then ns:CheckExistingCast(token) end
        else
            if ns.CleanupCastbar then ns:CleanupCastbar(token) end
        end
    end)

    C_NamePlate = {}
    function C_NamePlate.GetNamePlateForUnit(unit)
        if not unit then return nil end
        if isPlateToken(unit) then
            local f = tokenToPlate[unit]
            return (f and f:IsShown()) and f or nil
        end
        local f = matchUnitToPlate[unit]
        if f and f:IsShown() and PlateMatchesUnit(f, unit) then return f end
        if _UnitExists(unit) then
            for frame in pairs(managedPlates) do
                if frame:IsShown() and PlateMatchesUnit(frame, unit) then
                    SetMatch(frame, unit)
                    return frame
                end
            end
        end
        return nil
    end
    function C_NamePlate.GetNamePlates()
        local t = {}
        for frame in pairs(managedPlates) do
            if frame:IsShown() then t[#t+1] = frame end
        end
        return t
    end
    _G.C_NamePlate = C_NamePlate

    C_NamePlateManager = {}
    function C_NamePlateManager.EnumerateActiveNamePlates()
        local frame = nil
        return function()
            repeat frame = next(managedPlates, frame)
            until frame == nil or frame:IsShown()
            return frame
        end
    end
    function C_NamePlateManager.GetNamePlateSize()
        for frame in pairs(managedPlates) do
            local hb = frame._tpHealthBar
            if hb and hb.GetWidth then
                local w, h = hb:GetWidth(), hb:GetHeight()
                if w and w > 0 then return w, h end
            end
        end
        return 110, 30
    end
    function C_NamePlateManager.DisableBlizzPlate(unit)
        local frame = C_NamePlate.GetNamePlateForUnit(unit)
        if not frame then return end
        if frame.SetAttribute then
            frame:SetAttribute("disabled-blizz-plate", true)
        end
        HideBlizzPlateRegions(frame)
    end
    function C_NamePlateManager.ApplyFPSIncrease() end
    function C_NamePlateManager.SetEnableResizeNamePlates() end
    _G.C_NamePlateManager = C_NamePlateManager

    function ns.GetResolvedNameplateUnit(blizzFrame)
        return blizzFrame and blizzFrame._unit or nil
    end
    function ns.GetPlateReaction(blizzFrame) return PlateReaction(blizzFrame) end

    -- Diagnostic: dump the raw region/child layout of the current target's plate.
    -- Reveals this core's actual region order/types so we can confirm name/level
    -- detection. Invoked via "/tp dumpplate".
    function ns.DebugDumpPlate()
        local frame = matchUnitToPlate["target"]
        if not frame then
            for f in pairs(managedPlates) do
                if f:IsShown() then frame = f break end
            end
        end
        if not frame then
            print("|cff4fa3ffTurboPlates|r: no managed plate found (target a mob first).")
            return
        end
        print("|cff4fa3ffTurboPlates|r plate dump  name="..tostring(PlateName(frame))
            .." level="..tostring(PlateLevel(frame)))
        local regions = { frame:GetRegions() }
        for i = 1, #regions do
            local r = regions[i]
            local t = r and r.GetObjectType and r:GetObjectType() or "?"
            local extra = ""
            if t == "FontString" then
                extra = " text='"..tostring(r:GetText()).."' shown="..tostring(r:IsShown())
            elseif t == "Texture" then
                extra = " tex='"..tostring(r:GetTexture()).."'"
            end
            print("  region["..i.."] "..t..extra)
        end
        local i = 0
        for _, c in ipairs({ frame:GetChildren() }) do
            i = i + 1
            print("  child["..i.."] "..(c.GetObjectType and c:GetObjectType() or "?"))
        end
    end
end

ns.IS_WOTLK_COMPAT = not HAVE_NATIVE_ENGINE
TurboPlatesWotlkCompat = {
    active = not HAVE_NATIVE_ENGINE,
    mode   = HAVE_NATIVE_ENGINE and "native" or "namebased-335",
    note   = "Backported to stock 3.3.5a by Jedborg",
}
