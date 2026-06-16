# TurboPlates — stock 3.3.5a backport (name-based rewrite)

TurboPlates for an **unpatched 3.3.5a (WotLK 30300)** client. **Backported by Jedborg.**

## The core problem

TurboPlates was written for Ascension's modern nameplate engine, where the
client gives the addon a real **unit token** per nameplate. It then calls
`UnitName(unit)`, `UnitGUID(unit)`, `UnitHealth(unit)`, `UnitIsFriend(unit)`,
`UnitClass(unit)`, … on that token in ~110 places.

A stock, unpatched 3.3.5a client has **no nameplate unit tokens at all** (those
only exist on patched clients running AwesomeWotLK, which Ascension effectively
bundles). So on a normal core, every one of those calls returns nil/false for
any plate that isn't your current target — the addon can't tell friend from foe,
read a name, a class, or health.

## The fix: a name-based data layer (the NotPlater model)

NotPlater works on stock 3.3.5a because it never uses unit tokens. It scrapes the
**name** as text from the plate's regions, reads **health** and **reaction**
(hostile/neutral/friendly/friendly-player/tapped) from the plate's health-bar
value + colour, and rebuilds class info from name-keyed caches fed by the combat
log and by your target/mouseover/group units. This backport rebuilds TurboPlates'
data layer the same way.

Rather than editing 110 call sites across 20,000 lines, the rewrite **wraps the
`Unit*` API family**. Each plate gets a stable synthetic token (`TurboPlateN`).
When TurboPlates calls a `Unit*` function with that token, the wrapper answers
from scraped regions / bars / caches; real unit tokens pass straight through
untouched, so the rest of the UI and other addons are unaffected.

Three load-first files contain the whole backport (TurboPlates source is
untouched):

- **`WotlkCompat_API.lua`** — pure API gap-fillers: `RunNextFrame`,
  `C_Timer`, `CreateColor`/`ColorMixin`, `WrapTextInColorCode`, `PixelUtil`,
  `Texture:SetColorTexture`, `C_CVar`, `EventRegistry`, `GetCreatureIDFromGUID`.
- **`WotlkCompat.lua`** — the name-based nameplate engine: WorldFrame
  polling + texture fingerprint discovery (NotPlater's method), region/bar
  scraping with hooks that survive TurboPlates reparenting the Blizzard bar, a
  match tracker that binds a plate to a real unit (target / focus / mouseover /
  partyNtarget / raidNtarget — confirmed by name + level + exact health), the
  wrapped `Unit*` family, and `C_NamePlate` / `C_NamePlateManager`.
- **`WotlkCompat_Auras.lua`** — `AuraUtil.ForEachAura` over `UnitAura`, plus
  `UnitAuras`, `UnitRole`, `UnitQuestInfo`, `UnitDetailedThreatSituation`,
  `UnitGetTotalAbsorbs`, `UnitGroupRolesAssigned(Key)`, `Ambiguate`, and the
  retail group APIs (`IsInGroup` / `IsInRaid` / `GetNumGroupMembers`).

All shims define a symbol only if it's missing, so the folder is harmless on a
patched client / Ascension (the native engine wins; `TurboPlatesWotlkCompat.mode`
reports `"native"` vs `"namebased-335"`).

## How reaction (friend/foe) is determined

Read from the default nameplate health-bar colour, like NotPlater:
hostile `{1,0,0}`, neutral `{1,1,0}`, friendly NPC `{0,1,0}`, friendly player
`{0,0.6,1}`, tapped `{0.5,0.5,0.5}`.

## What works, and the honest limits

Full data for every plate: name, level, current/max health, reaction (so
friendly/hostile/neutral colouring, name-only friendly mode, etc.), and class
colour for players once their class is learned (from a group/target/mouseover
sighting or the combat log).

Features that genuinely need a real unit token — per-plate **auras/debuffs**,
**cast bars**, **GUID/NPC-id** logic, threat-by-unit — work **fully on plates
the match tracker can bind to a real unit** (your target, focus, mouseover, and
group members' targets) and **degrade gracefully** (no auras/cast shown, rather
than erroring) on arbitrary plates that can't be bound. This is the same ceiling
every nameplate addon hits on a stock client; the rewrite pushes as much through
it as the client allows.

## Install

Drop the `TurboPlates` folder into `Interface\AddOns\`. `/tp` opens options.
If something errors in-game, the per-plate data path is the place to look first;
note the exact Lua error and we can iterate.
