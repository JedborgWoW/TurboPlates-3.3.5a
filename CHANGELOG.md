# Changelog

All notable fixes to the 3.3.5a backport of TurboPlates are documented here.
Original TurboPlates by Miko (esurm); 3.3.5a backport by Jedborg.

## [1.4.6] — 2026-06-25

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

## [1.4.6] — 2026-06-24

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

## [1.4.5-335] — 2026-06-24

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

[1.4.5-335]: https://github.com/JedborgWoW/TurboPlates-3.3.5a
