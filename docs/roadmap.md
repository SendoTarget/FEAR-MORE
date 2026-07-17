# FearMore roadmap

## Fixed product decisions

1. The first working target is stock-compatible F.E.A.R. v1.08 on Win32.
2. The original GOAP/A* AI stays. We fix timing and observable defects before considering new behavior.
3. Enhanced Gore is the first major gameplay-facing feature.
4. Enhanced Gore is opt-in. Original gore and low-violence behavior remain available.
5. EchoPatch remains a separately built GPL runtime patch until the inherited source-license picture is resolved.
6. Retail archives, the Public Tools SDK, and derived assets remain local and are never required in Git history.
7. Gameplay must be Hor+ and usable at 3440 x 1440 and comparable ultrawide modes. Pre-rendered video may remain aspect-correct with black bars.

## M0 - reproducible stock game modules

Status on 2026-07-16: the compile baseline and representative isolated-runtime acceptance are complete; full export-surface comparison, campaign coverage, and clean-machine packaging remain open.

Completed:

- Added actual F.E.A.R. target ownership beneath `BUILD_FEAR`.
- Built the F.E.A.R.-specific GUI, client/server shared variants, ClientFX, ClientShell, and GameServer.
- Used the official Public Tools source and its exact F.E.A.R. platform, StdLith, assert, CRC, hook, and SDK inputs without committing them.
- Corrected configuration handling so Debug no longer inherits `_FINAL` and silently drops AI/assertion diagnostics.
- Serialized the generated MSBuild project graph while retaining `/MP` source compilation; multiprocess project mode fails in the legacy `ZERO_CHECK` graph without a diagnostic.
- Produced Debug and Release x86 artifacts:
  - `GameClient.dll`
  - `GameServer.dll`
  - `ClientFx.fxd`
- Verified PE32/x86 headers and the expected SDK module entry-point exports.
- Staged the rebuilt modules beside user-owned retail data without overwriting the original installation.
- Reached the menu and `ATC_Roof`, loaded existing and fresh quick saves, exercised active AI and ClientFX, and exited cleanly in representative D3D11 runs.

Remaining acceptance:

- Compare the rebuilt export surface with the user's original retail v1.08 modules.
- Broaden the representative menu, level, save, AI, ClientFX, and clean-exit passes to the full campaign and a wider legacy-save set.
- Record any retail ABI or database compatibility failures before changing gameplay.

The old engine executable and its hardcoded legacy DirectX SDK paths are a separate build lane; they are not dependencies of this milestone.

## M1 - modern presentation through EchoPatch and source-owned fixes

Status on 2026-07-16: the one-click Modern lane now combines rebuilt modules, dgVoodoo2 D3D11, the pinned engine-only EchoPatch derivative, optional Max 2x downsampling, and CAS while preserving an isolated native-D3D9 Stable fallback. Real 3440 x 1440 gameplay, Max 2x, focus restoration, startup/menu input, clean exit, representative AI caps, and bidirectional cross-cap saves have passed. Full resolution/campaign matrices, broad HUD/menu migration, sustained performance budgets, physical-controller acceptance, and clean-machine packaging remain open.

Modern consumes only the pinned engine-only EchoPatch derivative with retail game-module hooks disabled. The full stock profile remains a separate reference lane because its client, server, and ClientFX offsets cannot be presumed compatible with rebuilt modules; source-owned equivalents keep their existing game-module owners.

Work:

- Validate EchoPatch against the chosen retail executable and stock modules, keeping its `dinput8.dll`, configuration, notices, and source boundary intact.
- Test rebuilt game modules without EchoPatch first. Its client, server, and ClientFX hooks use retail signatures/offsets and cannot be presumed compatible with v141 binary layouts.
- Classify each desired EchoPatch fix as engine-only, game-module-owned, or mixed; keep verified engine hooks separate and independently port game-module behavior into source.
- Test 1920 x 1080, 2560 x 1080, **3440 x 1440**, 3840 x 1600, 5120 x 1440, 2560 x 1440, and 3840 x 2160 before duplicating any patch in game source.
- Preserve vertical FOV and expand horizontally for gameplay, zoom, and real-time cinematics. Keep important HUD elements within a usable 16:9 safe area at 32:9 and validate mouse hit regions independently from visual placement.
- Preserve the pre-rendered movie aspect ratio and center it with black bars when the output aspect differs. Do not stretch or crop FMVs to fill ultrawide screens.
- Migrate raw-positioned HUD and menu controls plus mouse hit testing to the shared safe-area transform; keep crosshair, world markers, and fullscreen effects on explicit full-viewport paths.
- Profile `SSAAScale` 1.0, 1.25, and 1.5 at 3440 x 1440 before treating 2.0 (four times native pixels) as a usable quality target.
- Treat EchoPatch's HUD exception lists and timing corrections as regression data.
- Where source ownership is beneficial, put shared HUD scaling in `InterfaceResMgr`/`HUDItem`/`LayoutDB` and world render scaling in `PlayerCamera` plus the renderer resolve path.
- Keep HUD/text at native resolution and make legacy MSAA mutually exclusive with SSAA initially.
- Keep the NVIDIA shadow-corruption and aspect-aware soft-shadow blur fixes enabled. Trace an Enhanced Shadows profile through the active retail Jupiter EX path and measure `Light_ShadowVolume`, `LODShadows`, `Light_ShadowBlur`, and volumetric-light occlusion independently; do not configure dormant generic-renderer variables as retail features.
- Add DXVK only as a separate experimental runtime lane after the native D3D9 baseline passes. Run one bounded RTX Remix geometry-capture spike with an early stop gate; never advertise Remix compatibility before stable world and character capture.
- Apply only measured high-FPS scheduler corrections; do not replace AI logic.

Acceptance:

- 4:3, 16:9, 16:10, 21:9, and 32:9 retain correct vertical FOV and usable UI; the named matrix above, especially 3440 x 1440, passes gameplay, HUD, menu, cinematic, post-effect, and movie checks.
- Pre-rendered movies remain centered and aspect-correct; black bars are accepted.
- A 2.0 world render scale creates the expected internal dimensions and resolves before HUD rendering.
- 60, 120, and 240 FPS produce equivalent AI reactions within defined tolerances.
- Stock saves and authored encounter behavior remain compatible.

## M2 - Enhanced Gore foundation

Status on 2026-07-16: the first opt-in postmortem sever slice persists location damage and detached-location state while reusing the stock sever pipeline, and a representative rebuilt combat pass accepted sever presentation plus quick-save/reload restoration. A separate source-owned corpse-persistence toggle provides bounded 4096/24/48 radius/level limits, while Off preserves the inherited performance-derived caps. Dense live corpse-budget pressure, the broader gore/save matrix, and the immutable exact-zone event planned below remain open.

Extend existing damage, sever, decal, ClientFX, attachment, ragdoll, and persistence primitives instead of creating a parallel damage system.

Work:

- Add an `EnhancedGore` mode while preserving existing gore-off, low-violence, and stock behavior.
- Add stable `DamageZoneId` and `SeverPieceId` values while retaining legacy broad `HitLocation` mappings.
- Carry the exact hit node/zone in an immutable damage event instead of consulting ambient last-hit state.
- Version sever messages and replicate the explicit piece identity.
- Persist per-zone accumulated damage, wound tier, detached state, and damage-type rules.
- Allow bounded postmortem wounds/dismemberment without changing health, kill credit, score, triggers, or invoking death twice.
- Continue replacing unlimited persistence with explicit distance-aware budgets. The corpse budget is implemented; model-decal, gib, shell, and debris budgets remain open.

The first vertical slice is one supported humanoid family, one wound-zone transition, one postmortem sever result, save/load, and stock-versus-enhanced comparison. Broader content follows only after that path is correct.

Initial behavior intentionally excludes live limb-loss gameplay. That would require new animations, weapon handling, locomotion, navigation constraints, AI world-state facts, and balance changes and must be approved as a separate behavior change.

Acceptance:

- Exact zone and sever-piece identity survives save/load and multiplayer replication.
- Corpse damage cannot duplicate death/scoring side effects.
- Original and low-violence modes remain bit-for-bit compatible where practical.
- Long levels stay within explicit object, physics, and memory budgets.

## M3 - Enhanced Gore content

- Author project-owned wound caps, separated surfaces, detached parts, materials, decals, particles, audio, rigid bodies, and LODs.
- Keep retail-derived source assets local; publish only assets with explicit redistribution rights.
- Validate every supported humanoid skeleton and armor/attachment combination.

## M4 - measured AI improvements

Only begin after timing correctness and repeatable encounter telemetry exist.

- Improve target-confidence memory, suppression, ally danger, blocked-route memory, cover reservations, grenade safety, and plan-failure recovery inside the existing GOAP architecture.
- Measure detection latency, cover contention, flank completion, grenade/friendly-fire incidents, navigation failures, and CPU time.
- Consider local crowd avoidance only if encounter data demonstrates a real congestion problem. Preserve authored traversal links and navmesh semantics.

## Deferred

- x64 conversion.
- HDR/10-bit presentation.
- Direct DLSS/DLAA, FSR 2/3, or frame generation until a modern renderer supplies depth, motion vectors, jitter, camera data, HUD-free color, and presentation integration.
- Replacing D3D9 rather than maintaining it; the isolated DXVK and RTX Remix probes do not count as a source renderer replacement.
- Replacing GOAP or authored navigation.
- A standalone engine executable built from the inherited Jupiter tree.
