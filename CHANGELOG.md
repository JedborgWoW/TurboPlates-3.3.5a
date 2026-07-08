# Changelog

All notable fixes to the 3.3.5a backport of TurboPlates are documented here.
Original TurboPlates by Miko (esurm); 3.3.5a backport by Jedborg.

## [Unreleased]

### Performance (GC churn in hot paths)
- **Removed per-tick allocations from the compat engine's hot paths** — the
  same pattern that caused periodic ~1s GC stutters in Gladdy's TotemPlates
  scanner in arena. `ScanWorldFrame` built a fresh `{ WorldFrame:GetChildren() }`
  table on every throttled 0.1s rescan (and on every child-count change); it now
  fills a persistent buffer through a varargs `CollectWorldChildren(...)`
  collector, never touching the Lua heap. Also treated: the per-frame cast
  mirror re-lowered and re-hashed the Blizzard spell-icon texture path every
  frame while a cast rendered (now memoised per path); the `UNIT_TARGET`
  handler rebuilt `unit.."target"` on every event (now memoised — fires
  constantly in group combat); the arena targeting-me poll rebuilt
  `"arenaN"`/`"arenaNtarget"` tokens per plate per tick (now static tables,
  scoped in a do-block because Nameplates.lua's main chunk sits at Lua 5.1's
  200-local ceiling); and ThreatAggro allocated a fresh name-index table on
  EVERY swing/spell aimed at the player even when the entry already existed
  (now updated in place). Audited the remaining OnUpdate drivers (stacking,
  aura timers, castbars, debuff timers, highlight/targeting polls) — already
  allocation-free via pools and cached strings.

### Target glow (same-named mobs)
- **Fixed the blue target glow occasionally appearing on TWO same-named mobs at
  once.** Two defects combined. First, the compat `UnitIsUnit(plate, "target")`
  identified the target plate by scraped name + full opacity alone — a
  just-shown twin sits at full alpha for a frame before the engine dims it, so
  both same-named plates could answer "I am the target". It now resolves
  identity through the proper authority ladder: exact GUID via the plate's real
  `nameplateN` token on awesome_wotlk; the match-tracker binding on stock (and
  "bound to a different plate" is a definitive no); and only for a fully
  unbound plate the name+alpha heuristic — now requiring the full alpha to be
  UNIQUE among same-named plates (ambiguity suppresses instead of glowing the
  wrong twin, same gate the match tracker itself uses). Second,
  `FullPlateUpdate` could steal the `currentTargetPlate` reference without
  clearing the previous holder's glow — since every glow-clear path only
  touches `currentTargetPlate`, the old plate's glow was orphaned and stayed on
  until the plate recycled. Reassignment now strips the stale plate's
  glow/combo points/target scale first, so at most one plate can ever render
  the target border.

## [1.4.5] — 2026-07-04

### Compat (metatable shims)
- **Hardened the WotLK compat shims that add methods to Blizzard widget
  metatables so they can no longer be silently dropped.** On this client the
  Frame-type method table carries a `__newindex` guard that silently swallows a
  plain assignment for a *new* method — the method never gets installed and every
  call to it hits `nil`. The affected shims now install with `rawset`, which
  bypasses that guard: `Frame:SetSize` and `GameTooltip:SetSpellByID` (both new
  keys), plus `Texture:SetColorTexture`, `Texture:SetAtlas`,
  `Region:GetEffectiveScale` and the `GameTooltip:SetHyperlink` guard for
  uniformity. The bug was latent — the two frame-type shims only run when the
  method is genuinely absent (a stock 3.3.5a client without ClassicAPI /
  awesome_wotlk), where `SetSize` backs dozens of call sites and `SetSpellByID`
  backs the options spell tooltips, so a plain assignment would have left them
  nil and crashed. Clients that already provide these natively (awesome_wotlk /
  ClassicAPI) were never affected.

### Errors (awesome_wotlk)
- **Fixed a flood of Lua errors on the awesome_wotlk client** — `attempt to call
  field 'GetNumber'/'GetBool'/'Set' (a nil value)` from `Core.lua`,
  `Stacking.lua` and elsewhere, firing repeatedly (most visibly on every camera
  move). The client ships its own partial `C_CVar`, so TurboPlates' compat shim —
  which only filled `C_CVar` in when the whole table was absent — was skipped
  entirely, leaving its `Get`/`GetNumber`/`GetBool`/`Set` helpers undefined. The
  shim now adds each helper individually when missing, so it completes a partial
  `C_CVar` instead of giving up on it (the same fix already applied to
  `C_NamePlate`). Stock 3.3.5a was never affected.
- **Fixed a follow-on `attempt to index field 'hp'` error on the target glow.**
  When the errors above aborted a plate's setup partway, the target-glow/outline
  code could run against a half-built plate with no health bar and throw. It now
  bails cleanly on an unfinished plate and re-runs once the plate is whole.

### Nameplates (awesome_wotlk)
- **Fixed nameplates randomly not showing, especially after `/reload`.** On the
  awesome_wotlk client the DLL controls nameplate visibility itself, and
  TurboPlates' plate discovery (a stock-3.3.5a scan that recognises plates by
  their texture and shown state) could race with that: after a reload an
  already-visible plate was missed and never re-checked, so it stayed invisible
  until you toggled nameplates off and on to force it back. TurboPlates now
  listens to the DLL's own nameplate events (`NAME_PLATE_CREATED` /
  `NAME_PLATE_UNIT_ADDED`) and picks a plate up the instant the client says it's
  there, instead of waiting for the scan to notice — so plates appear reliably
  on login, on `/reload`, and when panning the camera. Stock 3.3.5a is
  unaffected (it has no such events and keeps using the scan).
- **WeakAuras anchored to nameplates settle faster (awesome_wotlk).** Because a
  plate is now finalised in the same instant the client announces it, a
  WeakAura anchored to that plate sees its final size/position immediately
  instead of lagging or repositioning a fraction of a second later.

## [1.4.5] — 2026-07-03

### Castbars
- **Channeled spells now show a cast bar on untargeted mobs (both stock 3.3.5a
  and awesome_wotlk).** Mobs channeling Drain Life, Arcane Missiles, Mind Flay,
  Blizzard, Hellfire and the like previously showed nothing unless you targeted
  them — the combat log has no "cast start" event for channels, so the
  untargeted-cast mirror never saw them. TurboPlates now ships a registry of
  every player channeled spell across Classic, TBC and WotLK (matched by name,
  so all ranks and the NPC variants sharing those names are covered on any
  locale), shows a draining bar with the spell's name and icon, and clears it
  the moment the channel ends, breaks early, is interrupted, or the caster
  dies. Channels not in the registry **teach themselves**: the first time
  anyone targets a mob channeling an unknown spell, its exact duration is
  learned and saved permanently, so encounter-specific channels work from then
  on.
- **Fixed an interrupted cast on an untargeted mob filling to completion.** The
  combat log names the *interrupter* first and the interrupted *caster* second;
  the mirror cleared the wrong side, so kicking a mob's cast left its bar
  running to the end instead of vanishing. (A dying caster's bar is also
  removed immediately now.)
- **Fixed no cast bar appearing on the mob your cursor is resting on (both stock
  3.3.5a and awesome_wotlk).** While the mouse hovered a mob, a cast it *started*
  during the hover never showed a bar — the game sends no cast events for the
  "mouseover" unit (that plate was wrongly treated as event-covered, the same
  dead zone as the party/raid-target fix from 2026-06-25). Hovered mobs now get
  their cast from the combat log by the mob's exact GUID, like party/raid
  targets.
- **Fixed an interrupted cast filling to completion on a hovered mob.** A cast
  already in progress when you moused over a mob was picked up correctly, but
  its end/interrupt events never arrived for the hovered unit, so the bar kept
  filling as if the cast finished. The combat-log path now tears the bar down
  the moment the cast ends or is interrupted.
- **Fixed a cast bar showing on the wrong same-named mob (stock 3.3.5a).** The
  cast display trusted a plate's remembered mob identity ("pin") by name alone.
  After targeting one of several identical full-health mobs, a neighbour could
  briefly keep a stale pin to the caster and draw its cast bar. The cast path
  now validates the pin exactly like the debuff-icon fix from 2026-06-24 (level
  must match, and the pin is rejected if another plate now owns that mob) — so
  the bar can no longer appear on a twin. awesome_wotlk resolves plates exactly
  and is unaffected.

### Threat/aggro colour
- **Fixed the aggro colour appearing on the wrong same-named mob (stock
  3.3.5a).** Same stale-pin root as above: a twin plate with a leftover pin to
  the mob that's hitting you could turn your aggro colour. The pin is now
  validated before use; an ambiguous twin shows the normal hostile colour.

### Under the hood
- **Fixed a latent error when a hidden nameplate was re-shown by the game via
  the Lua path.** An internal helper was referenced before it was defined, which
  would have thrown "attempt to call global 'IsNamePlate' (a nil value)" on that
  rarely-taken path.

## [1.4.5] — 2026-06-25

### Quest icons
- **Fixed a quest icon showing on the wrong mob.** A mob could get a quest icon
  even when you had no quest for it, as long as its name was part of a quest
  mob's longer name. For example, with a quest for "Frenzied Pterrordax", a
  plain "Pterrordax" wrongly showed the icon — and it stayed even when you
  moused over or targeted it. TurboPlates now matches the full creature name, so
  the icon only appears on the mob the quest is actually for.

### Castbars
- **Fixed missing cast bars on mobs you haven't targeted, in groups/raids (both
  stock 3.3.5a and awesome_wotlk).** A casting mob that you weren't targeting or
  mousing over often showed no cast bar — most noticeably in dungeons and raids.
  The cause: TurboPlates also tracks each party/raid member's target, and once a
  plate was bound to one of those, it was treated as "handled by the event path"
  — but the game never sends cast events for another player's target, so the bar
  appeared nowhere. Those plates now get their cast from the combat log by the
  mob's exact GUID, so the bar shows on the correct mob. Plates you target, focus
  or mouse over are unchanged (still driven by the normal cast events), and the
  exact, no-bleed behaviour on awesome_wotlk is preserved.

### Healer icons (PvP)
- **Fixed the PvP healer icon not refreshing on stock 3.3.5a.** When a healer was
  first detected mid-fight, the instant icon refresh looped over engine nameplate
  unit tokens that don't exist on stock, so the icon only appeared on the next
  plate update (health/aura change) instead of right away. The refresh now walks
  the addon's active plates directly, so a newly-detected healer is marked
  immediately on both stock and awesome_wotlk.

Fixes auto/smart **tank mode** detection on stock 3.3.5a (WOTLK), based on a
contributor PR from a tester (JulesPeace).

### Tank role auto-detection
- **Tank auras now recognised on stock WOTLK, not just Ascension.** The
  manual-group fallback that detects a tank by buff previously only knew the
  Ascension (Level 60 custom) spell IDs. Added the stock-WOTLK IDs alongside
  them: Druid Dire Bear Form (`9634`), Paladin Righteous Fury (`25780`) and
  Death Knight Frost Presence (`48263`).
- **Fixed warrior-tank detection via Vigilance on WOTLK.** The scan now accepts
  every Vigilance id that can appear across platforms — Ascension `1150720`, the
  stock-WOTLK 30-min aura `50720` that actually sits on the party member (what
  `UnitBuff` returns), and the `50725` proc id — so detection works regardless of
  platform and neither one loses Vigilance support.
- **Fixed non-warriors being auto-detected as tanks on stock 3.3.5a.** The
  player-is-tank check keyed off "most points in the 3rd talent tab" — which is
  Protection only for warriors. A Frost mage (and Ret paladin, Unholy DK, Resto
  druid, Shadow priest, Destro lock, Sub rogue) was therefore flagged as a tank,
  and since the stock threat fallback treats "a mob is hitting you" as full
  aggro, every incoming attack painted the tank "secure aggro" colour. The check
  now requires the WARRIOR class.
- **Fixed threat/tank colour appearing when solo on stock 3.3.5a.** A mob
  attacking you while solo turned the health bar a threat colour (magenta tank
  "secure aggro", or the DPS aggro colour), because the stock combat-log fallback
  forces full aggro for unbound plates even when there's no one to compete for
  threat. Threat colouring now only applies in a group/raid or when you have a
  pet — matching the threat *text* (already hidden solo) and awesome_wotlk. Solo
  with no pet, hostile mobs use the normal hostile colour again.

### Castbars
- **Fixed false cast bars on stock 3.3.5a** (no awesome_wotlk) where a mob
  appeared to be casting when it wasn't. An off-screen mob casting in combat-log
  range had its cast shown on a visible same-named mob that wasn't casting,
  because stock has no way to tie an untargeted cast to a specific plate by name.
  Untargeted casts on stock now show **only on a plate you've targeted or
  moused-over** (resolved exactly by GUID), so they can't bleed onto the wrong
  mob. **awesome_wotlk is unchanged** — it still shows untargeted casts on every
  plate, resolved exactly via the real `nameplateN` token.

### Same-named mobs (debuff icons no longer bleed)
- **Fixed a debuff icon (e.g. Polymorph, Sap) bleeding onto same-named mobs.**
  When several identical mobs stood together, a debuff on one could appear on the
  others. Two separate causes were fixed:
  - **awesome_wotlk:** the plate matcher could bind the wrong same-named mob when
    two shared a health value. It now binds **exactly by the real `nameplateN`
    token**, so two identical mobs (even at equal health) never cross-bind.
  - **stock 3.3.5a:** a plate could keep a stale internal link to a mob it no
    longer represented (after the game briefly bound the wrong twin to your
    target), making your target's debuff show on it. The link is now **validated
    against the live binding** before use, so a debuff only shows on the mob it
    actually belongs to.

### Misc
- Added **`/tp version`** (alias `/tp ver`) to print the installed version in
  chat on demand.

## [1.4.5] — 2026-06-24

A large stabilization pass focused on private-server (3.3.5a) behavior, the
optional **awesome_wotlk** client patch, same-named mob handling, castbars,
quest icons, and the options UI.

### Health & nameplate engine
- **Fixed health bars freezing at spawn value on awesome_wotlk.** A real
  `nameplateN` token leaking through an internal `"nameplate"` prefix check
  desynced Core from the compat layer, after which health updates were dropped.
  Health now flows reliably through the scrape/bridge regardless of the client.
- **Fixed the HP bar not always updating on private servers** — visible health
  is now driven from the per-tick scrape instead of relying only on an engine
  callback that the addon itself suppresses.
- **awesome_wotlk integration:** plates are pre-announced on
  `NAME_PLATE_UNIT_ADDED` so WeakAuras and other addons anchor correctly, and
  the addon now runs cleanly both **with and without** the DLL.
- Added configurable **nameplate X and Y position offsets** to move the whole
  plate off the mob — in the **General** tab, matching Ascension's layout.

### Same-named mobs (no more "bleed" between identical plates)
- **Fixed debuffs and health-bar colour bleeding onto a same-named neighbour.**
  Debuffs from the combat log are now pinned to a specific plate by GUID — and
  resolved to the exact mob via the real `nameplateN` token on awesome_wotlk.
- **Fixed aggro/threat colour bleeding onto same-named plates** via the
  name-fallback path.
- **Fixed Sap (and other CLEU debuffs) not showing / flickering** on a
  same-named target, and the target plate getting **stuck enlarged** — a
  full-HP target next to an identical twin is now bound by its unique alpha.

### Target visuals & threat
- **Fixed the wrong plate showing target visuals** (glow/scale) when the real
  target was out of nameplate range.
- **Fixed a plate staying enlarged / target state not resetting** by re-syncing
  all GUID-dependent state the instant a plate binds (`OnPlateBound`).
- **Fixed stale threat colour persisting** after a plate's match was released.
- **Restored Ascension-style threat coloring** for mobs attacking the player on
  unbound plates.

### Castbars
- **Untargeted casts now show on nameplates again.** On stock 3.3.5a the engine
  doesn't drive the Blizzard cast bar, so casts are now mirrored from the combat
  log — including the **spell name and icon** — instead of only showing on the
  current target.
- **Fixed the cast bar bleeding onto same-named neighbours.** When several
  identical mobs stood together, one casting showed the bar on all of them. The
  cast is now resolved to the **exact** caster: on **awesome_wotlk** via the real
  `nameplateN` token, and on **stock** by the pinned plate or, failing that, only
  when it's the unique visible plate of that name (otherwise nothing, rather than
  a wrong bar on every twin — target/mouseover the caster once to pin it).

### Quest icons
- Quest mobs are now learned from the tooltip (including item-drop quests) on
  mouseover/target, and the icon shows on all same-named plates.
- Fixed inconsistent quest-icon sizing so same-type mobs match (icon no longer
  forced to the atlas's native size).

### Options UI
- **Fixed the Bar Texture and Font dropdowns rendering as an empty black box.**
  These were the only lists built on a scroll frame inside a floating popup,
  which doesn't render on this client; they now use the same direct-row
  rendering as every other dropdown, with mouse-wheel + scrollbar support.
- Fixed dropdown option labels drawing behind the list background.
- Health % text now rounds up (ceil) to match the player's unit-frame rounding.

[1.4.5]: https://github.com/JedborgWoW/TurboPlates-3.3.5a
