# Enhanced Gore vertical slice

## What this slice does

The first Enhanced Gore slice extends the existing F.E.A.R. sever pipeline instead of adding a second damage or corpse system. A dedicated postmortem `DamageTracker` preserves location damage across server updates, so verified node hits on a dead non-player character can accumulate against the stock sever thresholds and detach the matching body region.

The server continues to use the existing model database records, replacement sever body, hidden model pieces, attachment removal, `CFX_SEVER` message, detached rigid body, ClientFX, collision properties, and global sever-body cap.

This slice does not add new art. It exercises the existing private game assets first so that later external asset candidates can be evaluated against a working, grounded baseline.

## Runtime controls

The server compatibility default remains off:

```text
EnhancedGore 0
```

The accepted `Modern` one-click preset treats a fresh profile, or an existing
profile with no `EnhancedGore` field, as enabled. A freshly seeded Modern
`settings.cfg` therefore contains `EnhancedGore 1`; the other launcher presets
retain the off default when the field is missing. An explicit saved `0` or `1`
is preserved and honored.

The player-facing authority is the **Enhanced gore** toggle on the in-game
Gameplay options screen. It reuses the stock toggle and profile-save paths,
persists to `settings.cfg`, and takes effect when the next world loads. Standard
**Gore** must also be enabled, and the game's low-violence policy remains
authoritative. No file edit is required for normal play.

Direct developer stages can still enable the first slice with:

```text
EnhancedGore 1
```

Rebuilt game modules accept these controls on the executable command line for the local single-player server:

```text
+EnhancedGore 1 +EnhancedGoreMaxSeversPerBody 3 +BodySeverTest 1 +BodyGibTest 0
```

The retail engine initially creates those `+` variables in the client console context. When the local single-player client finishes loading a world, FearMore forwards those four gore controls as part of the shared six-name runtime-control allowlist; the other two names control the opt-in AI profiler and its update interval. The values travel through the existing console-command channel to the in-process server. The server accepts only a fully consumed, finite value inside the float range and applies the allowlist only for a local client in a single-player game. Remote clients and multiplayer hosts cannot use this bridge to change server policy. Omitting a variable leaves its normal server default intact.

For non-RTX rebuilt presets, `Start-FearMore.ps1` owns the exact
`+EnhancedGore 0/1` launch pair derived from the saved selection and rejects a
free-form override. The parked RTX presets use their separate retail launch path
and are not part of this player-facing Enhanced Gore integration.

The postmortem path stops adding locations once the corpse already has three detached locations by default. This threshold is clamped to the number of supported non-unknown hit locations. It does not undo or suppress pieces detached by the stock death-time sever pass, which can already have reached or exceeded the configured threshold:

```text
EnhancedGoreMaxSeversPerBody 3
```

## Bounded corpse persistence

FearMore now exposes a separate **Corpse persistence** toggle on the Gameplay
screen. This is a source-owned corpse budget, not EchoPatch persistent world
state. It does not retain decals, shell casings, debris, detached-client-part
transforms, or arbitrary level changes.

Off is the compatibility path: the rebuilt client forwards F.E.A.R.'s original
performance-derived `BodyCapRadius`, `BodyCapRadiusCount`, and
`BodyCapTotalCount` values without changing them. On substitutes a bounded
single-player budget through the same existing performance-settings message:

```text
FearMoreCorpsePersistence 1
BodyCapRadius 4096
BodyCapRadiusCount 24
BodyCapTotalCount 48
```

The radius pass fades the farthest bodies first until at most 24 eligible,
non-permanent corpses remain within 4096 world units. The total pass then keeps
at most 48 across the level. Bodies already selected by the radius pass are
excluded from the total pass's removal count, so an overlap cannot under-evict.
Permanent bodies and bodies already fading retain their stock exclusions.

A genuinely new Modern profile seeds this option On. Other new presets seed it
Off. Existing `settings.cfg` files are never rewritten by the launcher: an
explicit saved `0` or `1` wins, while an older existing profile with no field
uses conservative Off until the player changes and saves the in-game option.
Changes reach the local server on the next world load. The engine-only
EchoPatch lane continues to use `PatchGameModules=0` and
`EnablePersistentWorldState=0`.

## Preservation and safety rules

- With `EnhancedGore 0`, stock damage, death, sever decisions, and the visible sever pipeline remain unchanged. FearMore still writes save schema `283`, and a severed AI still receives the documented one-shot `0.01` scheduler update needed by the frame-synced AI correction.
- The existing single-player gore/low-violence setting takes precedence over `EnhancedGore`.
- The existing client gore filter still handles the stock `CFX_SEVER` message and gore-tagged ClientFX.
- Postmortem processing does not alter hit points, call destructible death handling, award score, increment kills, run death commands, or replay the player `Messy` broadcast.
- One hit location can detach at most once per corpse.
- Existing sever-piece exclusion records are honored across separate postmortem hits.
- Existing global sever-body limits and first-sever frequency pacing are honored, in addition to the per-corpse cap.
- Only damage accepted by the registered character damage filter is accumulated; any filtered damage scaling is preserved.
- A hit must supply fresh model-node context in the same damage dispatch. Direct damage consumes it in the character damage handler; impulse-only, area-only, and deferred-progressive projectile paths clear the pending flag at the end of the impact dispatch. Positional, collision, and later unrelated damage therefore cannot reuse a node left by an older projectile.
- Stock crouch and knockdown sever guards remain in force.
- Player corpses are excluded from this first slice so multiplayer and respawn model/list invariants remain unchanged.
- `ProcessEnhancedGoreDamage` rejects multiplayer before consulting or mutating postmortem damage state, even if a nonstandard caller creates the server cvar directly.
- Persisted detached-part replay is local single-player only; multiplayer late joins retain the stock behavior and receive no historical sever replay from this slice.
- Gibbed characters and characters using a mutually exclusive death-effect model are not processed.

## Save compatibility

FearMore save schema `283` adds version-gated severed-location and postmortem damage state to `CCharacter` serialization. Loading a retail v1.08 schema `282` save leaves both additions empty for an unsevered body. A retail save records that a body was severed but does not identify every detached non-head location, so a loaded legacy body already marked severed is conservatively made ineligible for additional postmortem severs rather than risking a duplicate limb. The existing decapitated flag still reconstructs the head bit. The network handshake and exported engine build number are not changed by the save-schema increment.

Compatibility is one-way: retail `282` does not know how to skip the additional `283` character fields and must not load a FearMore save. The runtime staging lanes therefore keep stock and rebuilt profiles/saves in separate user directories. Do not manually copy FearMore saves into a retail profile.

Detached rigid-body pieces are client-only objects, so the engine does not serialize them. After the local single-player client finishes rebuilding its world and character effects, the server now replays every precise persisted severed location to that client through the unchanged stock `CFX_SEVER` message. Replayed parts use zero linear sever impulse and client-side location de-duplication; normal gravity and stock angular velocity still apply, while live sever messages keep their original direction and force. Location remains the packet's sever-piece identity: the client resolves the first database piece with that location, so duplicate live/replay messages are idempotent rather than requests for a second piece. The client commits that de-duplication state only after both the sever-body record and a matching piece resolve, so a malformed or incompatible replay cannot poison a later valid message or dereference a missing record. The low-violence branch still deliberately consumes the valid sever location through its existing hidden-body behavior. The reconstructed part starts again at its configured source node rather than preserving its exact pre-save resting transform. A retail-format save whose non-head sever location is unknowable keeps its conservative de-duplication mask but is deliberately not replayed as six exact locations. Multiplayer late joins receive no historical replay from this slice. The accepted current-build cold-load visually preserved the severed corpse state and reconstructed detached parts; exact same-location rejection after reload remains open.

## 2026-07-14 and 2026-07-16 live vertical-slice evidence

An isolated rebuilt single-player stage reached a real combat target with `EnhancedGore` enabled. After death, additional fire produced a visibly bloodied/severed corpse through the existing F.E.A.R. body and ClientFX pipeline. F5 created a quicksave, F9 completed the confirmation/load path, and the loaded scene still showed the severed corpse state and detached parts. The process also closed normally during that gore pass.

On 2026-07-16, the current Release modules at 3440 x 1440 cold-loaded a complete single-player quick-save tree written by the prior FearMore schema-283 build without a disconnect. The severed corpse state and reconstructed detached parts were present after load. F5 was unavailable during that scripted sequence and did not update the quick-save file, so this pass deliberately does not claim a new current-build save/write round trip.

This is a playable vertical-slice and save/reload result, not the complete acceptance matrix below. The camera was no longer aimed at the original wound after reload, so that run did not visually prove an exact same-location duplicate count. Per-body cap `1`, gore disabled, rapid multi-projectile/global-cap pressure, every damage exclusion, a retail legacy save, and multiplayer late join remain live gates. The static source suite separately proves same-location packet idempotence, local-single-player-only replay, and preservation of the stock multiplayer packet shape, but it does not replace those runtime checks.

## Required runtime acceptance pass

Test on a user-owned F.E.A.R. v1.08 installation with rebuilt modules and without EchoPatch hooks:

1. Confirm stock death, score, mission statistics, triggers, and AI cleanup with `EnhancedGore 0`.
2. Enable **Enhanced gore** in the Gameplay options, load the world again, kill one supported non-player humanoid, and shoot a configured arm or leg across several server updates until its stock threshold is reached.
3. Confirm exactly one detached part and no additional kill, score, death sound, death command, or broadcast.
4. Repeat damage at the detached location and confirm no duplicate part.
5. Detach a second compatible location and confirm database exclusions reject incompatible torso/limb combinations.
6. On a corpse that did not sever during the stock death pass, set `EnhancedGoreMaxSeversPerBody 1` and confirm that the postmortem path adds at most one detached location.
7. Disable gore in single-player and confirm no postmortem model mutation occurs.
8. Save before and after a detach, reload both saves, and confirm the after-detach save reconstructs exactly one detached client object without the original linear sever impulse, retains the replacement corpse model/hidden piece, and still rejects another hit at that location.
9. Exercise rapid multi-projectile fire and several nearby corpses while watching frame time and the existing global cap.
10. With **Corpse persistence** Off, confirm the original performance-derived body caps are unchanged. Enable it, load a new world, exceed both the local-radius and level-wide budgets, and confirm distinct farthest bodies fade until no more than 24/48 eligible corpses remain; permanent bodies must remain exempt.
11. Verify positional, collision, explosion, rejected/filtered, crouched, knocked-down, and player-corpse damage cannot trigger the postmortem path.
12. Confirm the rebuilt and stock lanes write to different profile/save directories and that neither lane sees the other's saves.
13. Join an existing multiplayer match after a stock sever and confirm the joining client receives no historical `CFX_SEVER` replay and direct `EnhancedGore 1` cannot enable postmortem severing on the server.

## Deferred deliberately

- Live nonlethal limb loss and its animation, navigation, weapon, and AI consequences.
- A new network packet or incompatible `CFX_SEVER` payload.
- New gibs, wound meshes, materials, decals, sounds, or ClientFX definitions.
- Per-client server-side gore geometry in multiplayer; the stock client filter remains the authority there.
- Player-corpse severing; it requires explicit respawn restoration for model, sever-list, and sever-state invariants.
- Changes to stock sever probabilities or damage database records.
