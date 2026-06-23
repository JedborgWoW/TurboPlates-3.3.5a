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
local _GetRaidTargetIndex = GetRaidTargetIndex

-- Some 3.3.5a cores don't expose every Unit* function natively; an API-shim
-- addon (e.g. ClassicAPI) provides them and may load AFTER TurboPlates, so a
-- capture taken at this point can be nil. The wrappers call these originals for
-- real (non-plate) units, so a nil one throws "attempt to call upvalue
-- '_UnitIsPet' (a nil value)" once a plate resolves to a real unit. Re-bind the
-- originals from the live globals once everything has loaded (PLAYER_LOGIN, which
-- fires before any nameplate is queried), and stub anything still missing so the
-- wrappers degrade gracefully instead of erroring.
local function _stubNil() return nil end
local function BindUnitOriginals()
    _UnitExists        = UnitExists        or _UnitExists        or _stubNil
    _UnitName          = UnitName          or _UnitName          or _stubNil
    _UnitGUID          = UnitGUID          or _UnitGUID          or _stubNil
    _UnitClass         = UnitClass         or _UnitClass         or _stubNil
    _UnitLevel         = UnitLevel         or _UnitLevel         or _stubNil
    _UnitHealth        = UnitHealth        or _UnitHealth        or _stubNil
    _UnitHealthMax     = UnitHealthMax     or _UnitHealthMax     or _stubNil
    _UnitIsPlayer      = UnitIsPlayer      or _UnitIsPlayer      or _stubNil
    _UnitIsUnit        = UnitIsUnit        or _UnitIsUnit        or _stubNil
    _UnitIsFriend      = UnitIsFriend      or _UnitIsFriend      or _stubNil
    _UnitReaction      = UnitReaction      or _UnitReaction      or _stubNil
    _UnitCanAttack     = UnitCanAttack     or _UnitCanAttack     or _stubNil
    _UnitCreatureType  = UnitCreatureType  or _UnitCreatureType  or _stubNil
    _UnitIsPet         = UnitIsPet         or _UnitIsPet         or _stubNil
    _UnitIsDead        = UnitIsDead        or _UnitIsDead        or _stubNil
    _UnitIsDeadOrGhost = UnitIsDeadOrGhost or _UnitIsDeadOrGhost or _stubNil
    _UnitClassification= UnitClassification or _UnitClassification or _stubNil
    _UnitIsTapped      = UnitIsTapped      or _UnitIsTapped
    _UnitAffectingCombat = UnitAffectingCombat or _UnitAffectingCombat
    _GetRaidTargetIndex = GetRaidTargetIndex or _GetRaidTargetIndex or _stubNil
end
BindUnitOriginals()
local _origBinder = CreateFrame("Frame")
_origBinder:RegisterEvent("PLAYER_LOGIN")
_origBinder:RegisterEvent("PLAYER_ENTERING_WORLD")
_origBinder:SetScript("OnEvent", BindUnitOriginals)

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

        -- Cache the value, then BLANK the Blizzard FontString. The engine re-shows
        -- suppressed regions C-side (bypassing Hide / Show hooks), so a plain Hide
        -- let the Blizzard name/level FLASH for ~0.1s on every (re-)show before the
        -- throttled scan re-hid them. But the engine fills these via SetText (the
        -- same call we hook to scrape), so emptying the text in the hook makes them
        -- render nothing no matter when the engine shows them - and re-empties every
        -- time the engine re-fills. The `txt ~= ""` guard stops the SetText("")
        -- recursion; we scrape from the cached _tpName/_tpLevel, never the live text.
        if nameText then
            blizzFrame._tpName = nameText:GetText()
            hooksecurefunc(nameText, "SetText", function(self, txt)
                if txt and txt ~= "" then
                    blizzFrame._tpName = txt
                    self:SetText("")
                end
            end)
            -- The engine may set name/level via SetFormattedText, not SetText (that's
            -- why blanking only SetText left the LEVEL number still flashing). Catch
            -- both: after SetFormattedText, read the result, cache it, and blank.
            if nameText.SetFormattedText then
                hooksecurefunc(nameText, "SetFormattedText", function(self)
                    local cur = self:GetText()
                    if cur and cur ~= "" then
                        blizzFrame._tpName = cur
                        self:SetText("")
                    end
                end)
            end
            nameText:SetText("")
        end
        if levelText then
            blizzFrame._tpLevel = tonumber(levelText:GetText())
            hooksecurefunc(levelText, "SetText", function(self, txt)
                if txt and txt ~= "" then
                    blizzFrame._tpLevel = tonumber(txt)
                    self:SetText("")
                end
            end)
            if levelText.SetFormattedText then
                hooksecurefunc(levelText, "SetFormattedText", function(self)
                    local cur = self:GetText()
                    if cur and cur ~= "" then
                        blizzFrame._tpLevel = tonumber(cur)
                        self:SetText("")
                    end
                end)
            end
            levelText:SetText("")
        end
        if healthBar and healthBar.GetValue then
            local cur = healthBar:GetValue()
            local _, max = healthBar:GetMinMaxValues()
            blizzFrame._tpHP, blizzFrame._tpHPMax = cur, max
            -- Remember the bar's texture path: we DROP it once the reaction colour
            -- is captured (RefreshPlateScrape) so the Blizzard bar can't leak into
            -- view, and re-add it for a recycled plate's new occupant (AcquirePlate).
            local _tex = healthBar.GetStatusBarTexture and healthBar:GetStatusBarTexture()
            blizzFrame._tpHealthTex = (_tex and _tex.GetTexture) and _tex:GetTexture() or nil
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
                -- Only overwrite the cached reaction with a RECOGNISED colour - a
                -- damage flash / odd tint can read as no-match and would otherwise
                -- nil a good value, which flickers the friendly verdict and makes the
                -- re-classify pass churn (full<->lite) on every health tick.
                local rk = ColorToReactionKey(bar:GetStatusBarColor())
                if rk then blizzFrame._tpReaction = rk end
                -- Push a health re-render to TurboPlates. Stock 3.3.5a has no
                -- UNIT_HEALTH for our synthetic plate tokens, and UNIT_HEALTH for
                -- real units is keyed wrong in Core (ns.unitToPlate uses the token),
                -- so without this the plate's HP is stuck at its first-render value.
                -- The Blizzard bar's OnValueChanged is the live "health changed"
                -- signal for every plate, matched or not.
                local token = blizzFrame._tpToken
                if token and blizzFrame._tpAnnounced and ns.UpdateNameplateHealth then
                    ns.UpdateNameplateHealth(token)
                    -- Level refresh: the level text is set once at announce and, on a
                    -- recycled plate, may be stale until corrected. Do it ONCE per
                    -- occupant, not on every health tick - UpdateLevelText allocates
                    -- (GetQuestDifficultyColor builds a table), so calling it on every
                    -- damage event churned garbage -> periodic GC freezes in dungeons
                    -- with several mobs under AoE.
                    if not blizzFrame._tpLevelRefreshed and ns.UpdateLevelText then
                        blizzFrame._tpLevelRefreshed = true
                        ns.UpdateLevelText(token)
                    end
                end
                if prevOVC then return prevOVC(bar, value, ...) end
            end)
            -- Colour can also change without a value change (e.g. tapping); catch
            -- it via a method hook as a cheap supplement. Same guard: never nil a
            -- known reaction with an unrecognised colour.
            hooksecurefunc(healthBar, "SetStatusBarColor", function(_, rr, gg, bb)
                local rk = ColorToReactionKey(rr, gg, bb)
                if rk then blizzFrame._tpReaction = rk end
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
        -- Spell icon for the cast bar (region 5 in the canonical WotLK order, same
        -- fixed-index approach as the raid icon above). Used to show WHICH spell an
        -- untargeted mob is casting (NotPlater does the same). A wrong index from a
        -- core with a different leading-texture count is harmless: it's suppressed
        -- either way, and the read-time "is this an Interface\Icons path" check
        -- rejects any non-icon texture so we never show garbage.
        local spellIcon = regions[5]
        if spellIcon and spellIcon.GetObjectType and spellIcon:GetObjectType() == "Texture" then
            blizzFrame._tpSpellIcon = spellIcon
        end
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

    -- Lenient "does this match STILL hold?" used only to decide whether to DROP an
    -- already-established match. The strict PlateMatchesUnit (name+level+EXACT
    -- health) is needed to ESTABLISH a unique match among same-named candidates,
    -- but it must NOT gate keeping one: the plate's scraped health (updated C-side
    -- via the bar's OnValueChanged hook) and the real unit's UnitHealth (the
    -- UNIT_HEALTH event) update on different signals and are briefly out of sync
    -- after every hit. Using the strict check to keep the match dropped the
    -- "target" binding for a tick on every damage event -> UnitGUID(token) fell
    -- back to the synthetic GUID -> currentTargetGUID stopped matching -> the
    -- target glow was removed and the plate shrank to non-target scale, then
    -- snapped back next tick. That one-frame flip is the "blink" on ability use.
    -- Keep the match while the unit exists and the name still matches; target/
    -- focus changes explicitly release it so it re-binds via the strict check.
    local function PlateStillMatchesUnit(blizzFrame, unit)
        if not _UnitExists(unit) or _UnitIsDeadOrGhost(unit) then return false end
        local name = PlateName(blizzFrame)
        return name ~= nil and name == _UnitName(unit)
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
            -- The plate just gained its real unit. Plates announce on show (before the
            -- match binds), so GUID-dependent state set at announce used the synthetic
            -- guid - re-sync it now: target dimming/glow/scale and the raid marker (a
            -- marker or target set before the plate existed is otherwise missed).
            if blizzFrame._tpAnnounced and ns.OnPlateBound then
                ns.OnPlateBound(blizzFrame, blizzFrame._tpMatchedGUID)
            end
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
            -- Enforce suppression: on a RE-acquired (recycled) plate
            -- HideBlizzPlateRegions is skipped, and the engine can re-show a
            -- suppressed FontString C-side (bypassing our Show hook), so the
            -- Blizzard name/level reappears at its native spot (a second "14"
            -- behind the name). Re-hide here every tick.
            if nt._tpSuppressed and nt:IsShown() then nt:Hide() end
        end
        local lt = frame._tpLevelText
        if lt then
            local n = tonumber(lt:GetText())
            if n then frame._tpLevel = n end
            if lt._tpSuppressed and lt:IsShown() then lt:Hide() end
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
                if key then
                    if key == frame._tpReaction then
                        frame._tpReactionStable = (frame._tpReactionStable or 0) + 1
                    else
                        frame._tpReaction = key
                        frame._tpReactionStable = 1
                    end
                    -- Once the reaction has held steady for a couple of reads, drop
                    -- the bar texture: the engine re-shows suppressed children C-side
                    -- (see the name/level re-hide above), bypassing our Hide hook, so
                    -- a kept-but-hidden bar leaked the Blizzard health bar into view;
                    -- a TEXTURELESS bar can't render at all. GetValue still works
                    -- (health scrape), only colour freezes (reaction is stable;
                    -- recycle re-arms the texture in AcquirePlate). The 2-read wait
                    -- stops a transient/too-early colour from freezing a WRONG value.
                    if frame._tpHealthTexLive and frame._tpReactionStable >= 2
                       and hb.SetStatusBarTexture then
                        hb:SetStatusBarTexture(nil)
                        frame._tpHealthTexLive = false
                    end
                end
            end
            -- While still reading the reaction (texture present) re-hide the bar each
            -- tick - the engine re-shows it C-side, bypassing the Show hook, same as
            -- the name/level FontStrings above.
            if frame._tpHealthTexLive then
                if hb.GetAlpha and hb:GetAlpha() ~= 0 then hb:SetAlpha(0) end
                if hb.IsShown and hb:IsShown() then hb:Hide() end
            end
        end
    end

    -- A plate's scraped name is briefly empty / "Unknown" on the first frame it
    -- appears (and right after login), before the engine fills it in. We must not
    -- announce it to TurboPlates yet: it would render with an "Unknown" name and a
    -- not-yet-sized health bar, and - because the name doesn't match the real unit
    -- yet - it also fails to bind to target/focus (so no auras, casts or raid
    -- marker). Wait until the name is real, then announce (see the driver).
    local function PlateDataReady(blizzFrame)
        local name = PlateName(blizzFrame)
        return name ~= nil and name ~= "" and name ~= UNKNOWN and name ~= "Unknown"
    end

    -- The health-bar COLOUR (reaction) lags the name by a frame or two on fresh /
    -- login plates - the engine writes it C-side and our scrape reads nil until
    -- then. Announcing on name-ready alone made Core classify friendly NPCs as
    -- HOSTILE (full red plate instead of green name-only), and it never re-checked,
    -- so they stayed wrong until /reload. So also wait for a known reaction before
    -- announcing. Fall back after a few ticks so a plate whose colour never maps to
    -- a known reaction key (odd server tint) still appears instead of staying
    -- invisible. Reaction-ready is the friendly/hostile gate; name-ready is the
    -- "don't render Unknown" gate above.
    local REACTION_WAIT_TICKS = 5
    local function PlateAnnounceReady(blizzFrame)
        if not PlateDataReady(blizzFrame) then return false end
        if PlateReaction(blizzFrame) ~= nil then return true end
        blizzFrame._tpReactionWait = (blizzFrame._tpReactionWait or 0) + 1
        return blizzFrame._tpReactionWait >= REACTION_WAIT_TICKS
    end

    -- Core decides friendly (lite green name-only) vs hostile (full plate) ONCE at
    -- OnNamePlateAdded and never re-checks. The reaction colour can still be
    -- wrong/unknown at announce (engine writes it C-side a frame or two later, and
    -- the announce fallback may fire), which left friendly NPCs stuck as full red
    -- plates until /reload. We watch the friendly verdict after announce and re-fire
    -- OnNamePlateAdded when it flips, which switches the plate lite<->full.
    local function PlateIsFriendly(blizzFrame)
        local rk = PlateReaction(blizzFrame)
        return rk == "friendly" or rk == "friendlyPlayer"
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
            if u and not PlateStillMatchesUnit(frame, u) then
                ReleaseMatch(frame)
            end
        end
        -- Correct a premature "target" binding: if the currently bound plate is
        -- dimmed by the engine (alpha < 0.99) while an unmatched same-named/same-
        -- level plate is at full alpha, we grabbed the wrong plate first (real
        -- target was out of nameplate range when the initial binding fired). Release
        -- the stale binding NOW, before candidate collection, so both plates enter
        -- the candidate pool and the existing alpha-disambiguation re-runs cleanly
        -- this cycle and binds the correct one.
        -- PlateStillMatchesUnit (name-only) would otherwise keep the wrong plate
        -- bound indefinitely because the name never changes.
        -- Safe when non-target dimming is OFF: all plates alpha >=0.99 -> outer
        -- condition fails -> no release -> status quo.
        local tf = matchUnitToPlate["target"]
        if tf and _UnitExists("target") and not _UnitIsDeadOrGhost("target")
           and tf.GetAlpha and tf:GetAlpha() < 0.99 then
            local tName = _UnitName("target")
            local tLvl  = _UnitLevel("target")
            for frame in pairs(managedPlates) do
                if frame:IsShown() and not frame._tpMatchedUnit then
                    local fn = PlateName(frame)
                    if fn == tName then
                        local fl = PlateLevel(frame)
                        if not (fl and tLvl and tLvl > 0 and fl ~= tLvl) then
                            if (frame.GetAlpha and frame:GetAlpha() or 1.0) >= 0.99 then
                                ReleaseMatch(tf)
                            end
                            break
                        end
                    end
                end
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
                -- A full-HP non-player can't be told apart from a same-named
                -- neighbour by health, so we can't bind it by an exact HP match.
                -- But if it's the ONLY same-named full-HP candidate (e.g. a single
                -- mob you just opened on) it's unambiguous, so remember it and bind
                -- after the scan. With two identical full-HP mobs we leave it
                -- unbound rather than risk binding (and glowing) the wrong one -
                -- health resolves it the instant either takes damage. (Raw alpha
                -- can't disambiguate the general case: with non-target dimming off
                -- every plate reads full alpha, so it would pick an arbitrary one -
                -- but see the UNIQUE-alpha "target" exception after the loop.)
                local fullHpFrame, fullHpAmbiguous = nil, false
                for c = 1, nCand do
                    local frame = candFrame[c]
                    if frame and not frame._tpMatchedUnit and candName[c]
                       and candName[c] == uName then
                        local lvl = candLvl[c]
                        if not (lvl and uLvl and uLvl > 0 and lvl ~= uLvl) then
                            local cur, max = candCur[c], candMax[c]
                            if cur ~= nil and cur ~= uHP then
                                -- health mismatch: not this plate
                            elseif cur ~= nil and not uIsPlr and max and cur == max then
                                if fullHpFrame then fullHpAmbiguous = true
                                else fullHpFrame = frame end
                            else
                                -- exact sub-max HP match (or no HP read): unambiguous
                                SetMatch(frame, unit)
                                fullHpFrame = nil
                                break
                            end
                        end
                    end
                end
                if fullHpFrame and not fullHpAmbiguous
                   and not matchUnitToPlate[unit] then
                    SetMatch(fullHpFrame, unit)
                end
                -- Same-named full-HP mobs are ambiguous by health (above), so left
                -- unbound. But for the TARGET the client renders the real target's
                -- plate at full alpha and dims the rest, so disambiguate by alpha
                -- when it's UNIQUE. Gate on uniqueness so non-target dimming OFF
                -- (every plate full alpha) still leaves it unbound rather than
                -- binding an arbitrary one (the reason raw alpha was rejected for the
                -- general full-HP case). Only "target" gets engine target-dimming, so
                -- restrict to it - focus/mouseover alpha is uniform. Binding the
                -- target here is what makes UnitAura (Sap timer), the pinned-GUID
                -- debuff path, target scale and glow all work for a sapped same-named
                -- twin instead of it staying unbound.
                if fullHpAmbiguous and unit == "target"
                   and not matchUnitToPlate[unit] then
                    local alphaFrame, alphaAmbiguous = nil, false
                    for c = 1, nCand do
                        local frame = candFrame[c]
                        if frame and not frame._tpMatchedUnit
                           and candName[c] == uName then
                            local lvl = candLvl[c]
                            if not (lvl and uLvl and uLvl > 0 and lvl ~= uLvl) then
                                local cur, max = candCur[c], candMax[c]
                                if cur ~= nil and not uIsPlr and max and cur == max
                                   and frame.GetAlpha and frame:GetAlpha() >= 0.99 then
                                    if alphaFrame then alphaAmbiguous = true
                                    else alphaFrame = frame end
                                end
                            end
                        end
                    end
                    if alphaFrame and not alphaAmbiguous then
                        SetMatch(alphaFrame, unit)
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

    -- Returns the real unit a plate token is bound to (target/focus/... ), or
    -- nil if the plate isn't matched. A real unit token passes straight back.
    -- Lets consumers tell "bound" plates (UnitAura works) from unbound ones.
    function ns.GetPlateRealUnit(unit)
        if isPlateToken(unit) then
            local _, real = ResolveToken(unit)
            return real
        end
        return unit
    end

    -- DISPLAY DATA IS SCRAPED, NOT TAKEN FROM THE MATCHED TOKEN.
    -- This follows how NotPlater works on real 3.3.5a: the plate's own regions
    -- (name/level FontStrings, health-bar value + colour) are the source of truth
    -- for everything visible. A matched real unit is only cross-referenced for
    -- token-only extras that can't be scraped (GUID, auras, casts, threat). The
    -- match heuristic (name+level+health) can bind to the WRONG unit - e.g. a
    -- recycled plate briefly stuck on a previous target ("Mogg" on a Sunscale,
    -- wrong colour/level) - so the visible data must never depend on it.
    function ns.UnitName(unit, ...)
        if isPlateToken(unit) then
            return PlateName(tokenToPlate[unit])
        end
        return _UnitName(unit, ...)
    end

    function ns.UnitGUID(unit, ...)
        if isPlateToken(unit) then
            -- token-only: real GUID if matched, else a stable synthetic one
            local f, real = ResolveToken(unit)
            if real then return _UnitGUID(real) end
            return f and f._tpSyntheticGUID or nil
        end
        return _UnitGUID(unit, ...)
    end

    function ns.UnitClass(unit, ...)
        if isPlateToken(unit) then
            local f, real = ResolveToken(unit)
            -- class is keyed by the scraped name first (only players need it)
            local name = PlateName(f)
            if name and classTokenCache[name] then
                return classCache[name], classTokenCache[name]
            end
            if real then return _UnitClass(real) end
            return (UNKNOWN or "Unknown"), nil
        end
        return _UnitClass(unit, ...)
    end

    function ns.UnitLevel(unit, ...)
        if isPlateToken(unit) then
            return PlateLevel(tokenToPlate[unit]) or -1
        end
        return _UnitLevel(unit, ...)
    end

    function ns.UnitHealth(unit, ...)
        if isPlateToken(unit) then
            return PlateHealth(tokenToPlate[unit]) or 0
        end
        return _UnitHealth(unit, ...)
    end

    function ns.UnitHealthMax(unit, ...)
        if isPlateToken(unit) then
            local _, max = PlateHealth(tokenToPlate[unit])
            return max or 0
        end
        return _UnitHealthMax(unit, ...)
    end

    function ns.UnitIsPlayer(unit, ...)
        if isPlateToken(unit) then
            local f = tokenToPlate[unit]
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
            -- Plate vs real unit: compare the SCRAPED plate name to the unit's
            -- name. Names collide (many mobs share one), so for the target the
            -- engine renders the matching plate at full alpha and dims the rest -
            -- disambiguate by opacity, exactly like NotPlater's IsTarget.
            local plateTok = aPlate and unitA or unitB
            local other    = aPlate and unitB or unitA
            local f = tokenToPlate[plateTok]
            local plateName = f and PlateName(f)
            if not plateName or not _UnitExists(other) then return false end
            if plateName ~= _UnitName(other) then return false end
            if other == "target" then
                return f:GetAlpha() >= 0.99
            end
            return true
        end
        return _UnitIsUnit(unitA, unitB, ...)
    end

    function ns.UnitIsFriend(unitA, unitB, ...)
        if isPlateToken(unitB) then
            local rk = PlateReaction(tokenToPlate[unitB])
            return rk == "friendly" or rk == "friendlyPlayer"
        end
        if isPlateToken(unitA) then
            local rk = PlateReaction(tokenToPlate[unitA])
            return rk == "friendly" or rk == "friendlyPlayer"
        end
        return _UnitIsFriend(unitA, unitB, ...)
    end

    function ns.UnitReaction(unitA, unitB, ...)
        local function reactFor(token)
            local rk = PlateReaction(tokenToPlate[token])
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
            local rk = PlateReaction(tokenToPlate[unitB])
            return rk == "hostile" or rk == "neutral" or rk == "tapped"
        end
        if isPlateToken(unitA) then
            local rk = PlateReaction(tokenToPlate[unitA])
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
            return PlateHealth(tokenToPlate[unit]) == 0
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

    -- Raid target marker. GetRaidTargetIndex(unit) is called with our synthetic
    -- plate token; the native C function doesn't understand it and returns garbage
    -- (every plate showed a "Star" marker). Resolution order:
    --   1. Matched real unit (target/focus/party member's target) - most reliable.
    --   2. The Blizzard nameplate's native "nameplateN" unit attribute. The stock
    --      3.3.5a client sets GetAttribute("unit") = "nameplate1" etc. on each
    --      plate frame, and GetRaidTargetIndex("nameplateN") works natively - the
    --      engine maps it to the mob C-side. This lets us show raid markers even
    --      for mobs that aren't currently targeted/tracked.
    -- (defined unconditionally; _GetRaidTargetIndex is captured at file scope and
    -- re-bound in BindUnitOriginals, since on some cores it's nil at load.)
    function ns.GetRaidTargetIndex(unit, ...)
        if isPlateToken(unit) then
            local f, real = ResolveToken(unit)
            if real then return _GetRaidTargetIndex(real) end
            if f then
                local blizzUnit = f.GetAttribute and f:GetAttribute("unit")
                if blizzUnit then return _GetRaidTargetIndex(blizzUnit) end
            end
            return nil
        end
        return _GetRaidTargetIndex(unit, ...)
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
                elseif child == healthBar then
                    -- The health bar is our REACTION-COLOUR source. Reparenting it
                    -- off the plate and clearing its StatusBar texture (as the else
                    -- branch does) froze GetStatusBarColor at the value it happened
                    -- to hold when we hid it: the C engine writes the bar by pointer
                    -- IN PLACE, but with no texture there is no vertex colour left to
                    -- read. So a friendly NPC whose reaction colour the engine only
                    -- set a frame or two AFTER we hid the bar stayed read as hostile
                    -- (full red plate) until /reload. Keep it parented WITH its
                    -- texture and just hide it (alpha 0 + Hide + Show-hook, same as
                    -- the FontStrings) so the colour stays live for PlateReaction.
                    -- RefreshPlateScrape then DROPS the texture once the reaction is
                    -- captured: the engine re-shows hidden children C-side (bypassing
                    -- the Show hook), so only a textureless bar hides reliably.
                    -- _tpHealthTexLive marks this brief readable window.
                    child:SetAlpha(0)
                    SuppressRegion(child)
                    blizzFrame._tpHealthTexLive = true
                elseif child == castBar then
                    -- Keep the cast bar PARENTED (do NOT reparent) so the engine
                    -- keeps driving its shown-state and value - that's the live
                    -- "this mob is casting" signal for plates we have no unitID for
                    -- (untargeted casters), which ProcessPlateCasts mirrors onto our
                    -- own castbar. Reparenting would freeze it exactly like the
                    -- health bar. We don't want the Blizzard cast ART though, so drop
                    -- the bar texture and its child regions (bg/border/spark). The
                    -- engine can re-apply the texture per cast, so ProcessPlateCasts
                    -- re-drops it each frame while the bar is shown.
                    if child.SetStatusBarTexture then child:SetStatusBarTexture(nil) end
                    local cregions = { child:GetRegions() }
                    for ci = 1, #cregions do
                        local cr = cregions[ci]
                        if cr then
                            if cr.SetTexture then cr:SetTexture() end
                            if cr.Hide then cr:Hide() end
                        end
                    end
                elseif child == blizzFrame._tpSpellIcon then
                    -- Keep the spell icon PARENTED (do NOT reparent/clear) so the
                    -- engine keeps writing the casting spell's texture into it in
                    -- place - that's what lets us show WHICH spell an untargeted mob
                    -- casts. Suppress it visually (Hide + Show-hook) so the Blizzard
                    -- icon never leaks; we only read its texture (ProcessPlateCasts).
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
        -- Reuse one stable token per pooled frame. Pooled frames are hidden and
        -- re-shown constantly, and minting a NEW token on every re-show churned
        -- Core's per-token state (ns.unitToPlate / currentTargetPlate), which made
        -- the target scale and other per-plate data flicker. Assign once; keep the
        -- token + tokenToPlate mapping across hide/show.
        local token = blizzFrame._tpToken
        if not token then
            tokenCounter = tokenCounter + 1
            token = "TurboPlate" .. tokenCounter
            blizzFrame._tpToken         = token
            blizzFrame._tpSyntheticGUID =
                string.format("0xF130%07X%05X", tokenCounter % 0xFFFFFFF, tokenCounter % 0xFFFFF)
            tokenToPlate[token] = blizzFrame
        end

        managedPlates[blizzFrame] = true
        blizzFrame._unit            = token
        -- New occupant: allow exactly one level-text refresh on its first health
        -- tick (see the OnValueChanged hook), in case the level was stale at announce.
        blizzFrame._tpLevelRefreshed = nil
        -- Drop the previous occupant's pinned aura-identity (CLEU debuff GUID) and
        -- aura colour override. Core clears these on OnNamePlateRemoved, but the
        -- engine can RECYCLE a plate frame for a new mob without a detected remove
        -- (C-side hide/show with no WorldFrame child-count change). When that mob
        -- shares the previous one's name AND level, PinSignatureValid (name+level
        -- only) still passes, so the recycled plate inherits the old mob's tracked
        -- debuffs and colour - they "bleed" onto a same-named neighbour. Acquire is
        -- the authoritative new-occupant signal, so reset here; a genuine re-bind
        -- re-pins immediately via OnPlateBound.
        local mp = blizzFrame.myPlate
        if mp then
            mp.pinnedGUID        = nil
            mp.pinnedName        = nil
            mp.pinnedLevel       = nil
            mp._auraColorOverride = nil
        end
        -- Pooled plates are hidden/re-shown without a WorldFrame child-count change,
        -- so a re-show is otherwise only noticed on the throttled scan (~0.1s) - long
        -- enough that the Blizzard name/level/bar flash at the Blizzard position
        -- before we re-hide and render our own. The FRAME's Show IS hookable (unlike
        -- the C-side region shows), so react to it immediately: re-acquire a released
        -- plate (suppress + announce now) or just re-hide a still-managed one.
        if not blizzFrame._tpShowHooked then
            blizzFrame._tpShowHooked = true
            hooksecurefunc(blizzFrame, "Show", function(self)
                if managedPlates[self] then
                    RefreshPlateScrape(self)
                elseif IsNamePlate(self) then
                    AcquirePlate(self)
                end
            end)
        end
        -- Re-arm reaction reading for the (possibly new) occupant: a recycled plate
        -- had its bar texture dropped after the previous mob's reaction was captured,
        -- so restore it (then RefreshPlateScrape re-captures and drops it again). On
        -- first acquire _tpHealthBar is still nil here; HideBlizzPlateRegions arms it.
        local rearmHB = blizzFrame._tpHealthBar
        if rearmHB and rearmHB.SetStatusBarTexture and blizzFrame._tpHealthTex
           and not blizzFrame._tpHealthTexLive then
            rearmHB:SetStatusBarTexture(blizzFrame._tpHealthTex)
            blizzFrame._tpHealthTexLive = true
            blizzFrame._tpReactionStable = nil  -- re-stabilise for the new occupant
        end

        CapturePlateRefs(blizzFrame)
        HideBlizzPlateRegions(blizzFrame)

        -- Pull fresh data from the live FontStrings/bar NOW, before PlateDataReady.
        -- By the time our OnUpdate fires, the engine has already written the new
        -- mob's name/level/health into the regions C-side. Without this call,
        -- recycled plates (where _tpSourcesHooked skips the HookPlateSources
        -- re-snapshot) keep _tpName/_tpLevel from the PREVIOUS mob and announce
        -- with wrong data.
        RefreshPlateScrape(blizzFrame)

        for i = 1, #trackedUnits do
            local unit = trackedUnits[i]
            if _UnitExists(unit) and not matchUnitToPlate[unit]
               and PlateMatchesUnit(blizzFrame, unit) then
                SetMatch(blizzFrame, unit)
                break
            end
        end

        -- Only announce once the scraped name is ready. If not (first frame /
        -- login), the driver re-checks each tick and announces when it becomes
        -- available, so Core never renders a half-initialized "Unknown" plate.
        if PlateAnnounceReady(blizzFrame) then
            blizzFrame._tpAnnounced = true
            blizzFrame._tpAnnouncedFriendly = PlateIsFriendly(blizzFrame)
            FireAdded(token, blizzFrame)
        else
            blizzFrame._tpAnnounced = false
        end
    end

    local function ReleasePlate(blizzFrame)
        local token = blizzFrame._tpToken
        ReleaseMatch(blizzFrame)
        managedPlates[blizzFrame] = nil
        if blizzFrame._tpAnnounced then
            FireRemoved(token, blizzFrame)
            blizzFrame._tpAnnounced = false
        end
        -- Recycled plate must re-wait for the NEW occupant's reaction colour, not
        -- inherit the previous mob's announce-wait state (see PlateAnnounceReady).
        -- Do NOT clear _tpReaction here: RefreshPlateScrape keeps it live, and
        -- clearing it opened a nil window on re-show (toggle friendly plates off/on,
        -- pan away/back) that the fallback then announced as HOSTILE. A genuinely
        -- changed reaction is caught by the re-classify pass in the driver tick.
        blizzFrame._tpReactionWait = nil
        blizzFrame._unit = nil
        -- Keep _tpToken + tokenToPlate[token] so the SAME token is reused when this
        -- pooled frame is shown again (see AcquirePlate). Visibility is gated by
        -- IsShown() / managedPlates elsewhere, so a kept-but-hidden token is inert.
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
    local knownPlates = {}   -- every WorldFrame child ever confirmed a nameplate (the pool)
    -- Untargeted-cast tracking, driven ENTIRELY from the combat log. Stock 3.3.5a
    -- (no awesome_wotlk) does NOT engine-drive the Blizzard nameplate cast bar, so
    -- there was nothing to scrape and only target/focus/mouseover casts (the event
    -- path) ever showed. SPELL_CAST_START fires for EVERY caster in range with no
    -- unitID, and GetSpellInfo gives the icon AND the base cast time - enough to
    -- render a self-animating bar with no unit and no Blizzard bar. Cached by GUID
    -- (pinned-plate path) and by name (unique-plate fallback), mirroring the debuff
    -- cache. entry = { name, icon, start, duration, srcName, guid }
    local castInfoByName = {}  -- [caster name] = entry  (last caster of that name)
    local castByGUID = {}      -- [caster GUID] = entry
    local lastCastSweep = 0    -- throttle for the stale-entry sweep below
    local CAST_GRACE = 0.5     -- keep the bar this long past the estimated cast time
                               -- (haste makes the real cast shorter; the end event
                               -- normally clears it first) before treating a missed
                               -- end event as stale.
    -- Fully remove a cast entry from both indices (entries are shared between them).
    local function ClearCastEntry(entry)
        if not entry then return end
        if entry.guid and castByGUID[entry.guid] == entry then castByGUID[entry.guid] = nil end
        if entry.srcName and castInfoByName[entry.srcName] == entry then
            castInfoByName[entry.srcName] = nil
        end
    end
    local function ScanWorldFrame()
        wipe(visible)
        local kids = { WorldFrame:GetChildren() }
        for i = 1, #kids do
            local frame = kids[i]
            if IsNamePlate(frame) then
                knownPlates[frame] = true   -- pooled frames are reused, never destroyed
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

    -- Per-frame, cheap (iterates the small persistent pool set, no allocation): act
    -- on a pooled plate's show/hide the instant it happens. The engine shows/hides
    -- pooled plates C-SIDE (bypassing Lua Show/Hide hooks), so otherwise a transition
    -- was only caught on the 0.1s scan - long enough for a stale/partial plate (e.g.
    -- just the level number, or the previous occupant's art) to flash before the real
    -- one renders, and for our own plate to linger after the mob is gone.
    local function ProcessPlateVisibility()
        for frame in pairs(knownPlates) do
            if frame:IsShown() then
                if not managedPlates[frame] then AcquirePlate(frame) end
            elseif managedPlates[frame] then
                ReleasePlate(frame)
            end
        end
    end

    -- Render untargeted casters' cast bars from the combat-log cache (built above).
    -- This is the ONLY source on stock 3.3.5a: UNIT_SPELLCAST_* / UnitCastingInfo
    -- answer only for target/focus/mouseover/party/raid (the event-driven path in
    -- Castbars.lua handles those), and the engine doesn't drive the Blizzard nameplate
    -- cast bar to scrape. We self-animate from start + base cast time; the real end
    -- event (or the grace cap) hides it. Identity: the plate's pinned GUID first
    -- (exact), else the caster name shown on every same-named plate (see the fallback
    -- comment below for why casts differ from debuffs here). Runs every frame.
    local function ProcessPlateCasts()
        if not (ns.ScrapeCastStart and ns.ScrapeCastUpdate and ns.ScrapeCastStop) then return end
        local now = GetTime()
        -- Periodically drop cast entries whose end event we never saw (caster cast
        -- out of nameplate range, then died/despawned): the per-plate stale check
        -- below only clears casters that currently have a visible plate.
        if now - lastCastSweep > 2 then
            lastCastSweep = now
            for _, e in pairs(castByGUID) do
                if now - e.start > e.duration + CAST_GRACE then ClearCastEntry(e) end
            end
        end
        for frame in pairs(knownPlates) do
            local token = frame._tpToken
            local active = frame:IsShown() and managedPlates[frame] and frame._tpAnnounced and token
            -- Defensive: if a core DOES drive the Blizzard cast bar, keep its texture
            -- dropped so no Blizzard cast art leaks next to our plate.
            local cb = frame._tpCastBar
            if cb and cb.IsShown and cb:IsShown() and cb.SetStatusBarTexture then
                cb:SetStatusBarTexture(nil)
            end
            local info
            if active and not frame._tpMatchedUnit then
                local mp = frame.myPlate
                local pname = PlateName(frame)
                -- PRIMARY: this plate's pinned GUID, when it still shows that mob -
                -- the exact caster, even if two same-named mobs cast different spells.
                local pg = mp and mp.pinnedGUID
                if pg and castByGUID[pg] and mp.pinnedName == pname then
                    info = castByGUID[pg]
                elseif pname then
                    -- FALLBACK: name. Unlike debuffs (persistent, so a wrong neighbour
                    -- is misleading), a cast is transient and the warning value of
                    -- "something here is casting X" matters more than pinning the exact
                    -- plate - so show it on EVERY same-named plate when we can't tell
                    -- which is the caster (no pinned GUID). The combat log gives no
                    -- plate->GUID for an unbound mob on stock 3.3.5a, so this is as
                    -- precise as it gets; the real end event clears all of them.
                    info = castInfoByName[pname]
                end
                -- Past the estimated cast time with no end event: treat as stale and
                -- drop it (bounds memory for a cast whose end we never saw).
                if info and (now - info.start) > info.duration + CAST_GRACE then
                    ClearCastEntry(info)
                    info = nil
                end
            end
            if info then
                -- Icon from the spell (combat log); fall back to the scraped Blizzard
                -- spell-icon region only if GetSpellInfo gave us none.
                local icon = info.icon
                if not icon then
                    local si = frame._tpSpellIcon
                    if si and si.GetTexture then
                        local tex = si:GetTexture()
                        if type(tex) == "string" and tex:lower():find("icons", 1, true) then
                            icon = tex
                        end
                    end
                end
                local fill = (now - info.start) / info.duration
                if fill < 0 then fill = 0 elseif fill > 1 then fill = 1 end
                if not frame._tpScraping then
                    frame._tpScraping = true
                    ns:ScrapeCastStart(token, false, icon, info.name)
                end
                ns:ScrapeCastUpdate(token, fill, false, icon, info.name)
            elseif frame._tpScraping then
                -- Cast ended, plate hidden/recycled, or it gained a real unit (event
                -- path takes over) - tear our mirror down. ScrapeCastStop no-ops if
                -- the event path has already claimed the castbar.
                frame._tpScraping = nil
                if token then ns:ScrapeCastStop(token) end
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
        -- Every frame: catch C-side show/hide of known pooled plates immediately,
        -- so appearance/disappearance is ~1 frame, not up to a throttled tick.
        ProcessPlateVisibility()
        -- Every frame: mirror engine-driven casts for untargeted mobs.
        ProcessPlateCasts()
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
            -- Announce any plate whose name only just became available (deferred in
            -- AcquirePlate). Done here because FireAdded is defined below the scan
            -- functions. UpdateMatches ran first, so a now-ready plate is already
            -- matched to its real unit when Core first renders it.
            for frame in pairs(managedPlates) do
                if frame:IsShown() then
                    if not frame._tpAnnounced then
                        if PlateAnnounceReady(frame) then
                            frame._tpAnnounced = true
                            frame._tpAnnouncedFriendly = PlateIsFriendly(frame)
                            FireAdded(frame._tpToken, frame)
                        end
                    else
                        -- Reaction settled to a different friendly verdict than at
                        -- announce: re-classify (full <-> lite). _tpReaction is sticky
                        -- once known, so this fires at most once per plate and never
                        -- thrashes.
                        local fr = PlateIsFriendly(frame)
                        if fr ~= frame._tpAnnouncedFriendly then
                            frame._tpAnnouncedFriendly = fr
                            FireAdded(frame._tpToken, frame)
                        end
                    end
                end
            end
        end
    end)

    driver:RegisterEvent("PLAYER_ENTERING_WORLD")
    driver:RegisterEvent("PARTY_MEMBERS_CHANGED")
    driver:RegisterEvent("RAID_ROSTER_UPDATE")
    driver:RegisterEvent("PLAYER_TARGET_CHANGED")
    driver:RegisterEvent("PLAYER_FOCUS_CHANGED")
    driver:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
    driver:RegisterEvent("UNIT_TARGET")
    driver:RegisterEvent("CVAR_UPDATE")
    driver:SetScript("OnEvent", function(_, event, arg1)
        if event == "CVAR_UPDATE" then
            -- Toggling friendly/enemy nameplates (nameplateShowFriends/Enemies) is a
            -- CVar change that bulk-shows the plates C-side, bypassing our per-frame
            -- Show hook - so they'd only be re-acquired on the throttled scan (~0.1s),
            -- leaving a brief gap where the plate is gone. Rescan now (synchronous
            -- show) AND force a full scan next frame (async show) to close the gap.
            ScanWorldFrame()
            matchElapsed = 1e9
            UpdateMatches()
            return
        end
        if event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE"
           or event == "PLAYER_ENTERING_WORLD" then
            RebuildTrackedUnits()
        elseif event == "UPDATE_MOUSEOVER_UNIT" then
            -- Same rationale as target/focus: release first so UpdateMatches
            -- re-binds "mouseover" to the hovered plate by strict health rather
            -- than letting the lenient keep-check hold a same-named neighbour.
            local f = matchUnitToPlate["mouseover"]
            if f then ReleaseMatch(f) end
            CacheUnitByName("mouseover")
        elseif event == "PLAYER_TARGET_CHANGED" then
            -- Drop the prior "target" binding so UpdateMatches re-establishes it
            -- against the correct plate via the strict health check. The lenient
            -- keep-check would otherwise let a same-named neighbouring plate stay
            -- bound to "target" when switching between two same-name mobs.
            local f = matchUnitToPlate["target"]
            if f then ReleaseMatch(f) end
            CacheUnitByName("target")
        elseif event == "PLAYER_FOCUS_CHANGED" then
            local f = matchUnitToPlate["focus"]
            if f then ReleaseMatch(f) end
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
    -- srcName, srcFlags, dstGUID, dstName, dstFlags (no raid flags on this core),
    -- then event-specific args. For SPELL_CAST_START: spellId, spellName, school.
    clog:SetScript("OnEvent", function(_, _, _, subevent, srcGUID, srcName, srcFlags, destGUID, destName, destFlags, spellId, spellName)
        if srcName and srcFlags then
            isPlayerCache[srcName] = (bit.band(srcFlags, COMBATLOG_OBJECT_TYPE_PLAYER) ~= 0)
        end
        if destName and destFlags then
            isPlayerCache[destName] = (bit.band(destFlags, COMBATLOG_OBJECT_TYPE_PLAYER) ~= 0)
        end
        -- Capture every in-range cast so untargeted nameplates can render it. This is
        -- the ONLY source for an untargeted cast on stock 3.3.5a (the engine doesn't
        -- drive the Blizzard nameplate cast bar to scrape).
        if subevent == "SPELL_CAST_START" and srcGUID and srcName then
            -- GetSpellInfo is nil-safe for unknown/private-server ids and never
            -- crashes (unlike SetSpellByID). On 3.3.5a it returns
            -- name, rank, icon, cost, isFunnel, powerType, castTime(ms), ... - so the
            -- 7th value is the base cast time we use to animate the bar.
            local giName, _, giIcon, _, _, _, giCastMs = GetSpellInfo(spellId)
            local dur = (type(giCastMs) == "number" and giCastMs > 0) and (giCastMs / 1000) or nil
            if dur then
                local now = GetTime()
                local entry = { name = giName or spellName, icon = giIcon,
                                start = now, duration = dur, srcName = srcName, guid = srcGUID }
                castByGUID[srcGUID] = entry
                castInfoByName[srcName] = entry
            end
        elseif subevent == "SPELL_CAST_SUCCESS" or subevent == "SPELL_CAST_FAILED"
               or subevent == "SPELL_INTERRUPT" then
            -- End of cast. Clear by GUID, and the name entry only if it's the SAME
            -- cast (don't wipe a newer same-named caster's entry).
            if srcGUID then ClearCastEntry(castByGUID[srcGUID]) end
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
            return (f and f:IsShown() and f._tpAnnounced) and f or nil
        end
        local f = matchUnitToPlate[unit]
        -- Trust an already-established match via the lenient check; the strict
        -- health compare here would intermittently return nil for the target on
        -- the post-hit sync gap (see PlateStillMatchesUnit) and flicker the glow.
        if f and f:IsShown() and f._tpAnnounced and PlateStillMatchesUnit(f, unit) then return f end
        if _UnitExists(unit) then
            for frame in pairs(managedPlates) do
                if frame:IsShown() and frame._tpAnnounced and PlateMatchesUnit(frame, unit) then
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
            if frame:IsShown() and frame._tpAnnounced then t[#t+1] = frame end
        end
        return t
    end
    _G.C_NamePlate = C_NamePlate

    C_NamePlateManager = {}
    -- Only enumerate ANNOUNCED plates (see PlateDataReady) so Core never iterates
    -- and renders a half-initialized plate before its name/size are ready.
    function C_NamePlateManager.EnumerateActiveNamePlates()
        local frame = nil
        return function()
            repeat frame = next(managedPlates, frame)
            until frame == nil or (frame:IsShown() and frame._tpAnnounced)
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
        print(string.format("  frame scale=%.3f effScale=%.3f size=%.0fx%.0f",
            frame:GetScale() or 0, frame:GetEffectiveScale() or 0,
            frame:GetWidth() or 0, frame:GetHeight() or 0))
        local mp = frame.myPlate
        if mp then
            print(string.format("  myPlate scale=%.3f effScale=%.3f size=%.0fx%.0f",
                mp:GetScale() or 0, mp:GetEffectiveScale() or 0,
                mp:GetWidth() or 0, mp:GetHeight() or 0))
        end
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
