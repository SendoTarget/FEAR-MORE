# FearMore roadmap

Last updated: 2026-07-18

## Status key

- **Done**: implemented and supported by automated checks or a recorded live game pass.
- **Incomplete**: implemented in a limited scope, but important runtime coverage or polish is still missing.
- **Not done**: planned work has not been implemented.
- **Parked**: research exists, but it is not part of the playable build and makes no feature claim.

## At a glance

| Area | Status | Short version |
| --- | --- | --- |
| M0: rebuilt F.E.A.R. modules | **Incomplete** | Debug and Release x86 modules build and run, but full campaign, save, export, ABI, and multiplayer coverage is missing. |
| M1: modern presentation | **Incomplete** | The 3440 x 1440 D3D11 Modern lane is playable; the complete resolution, HUD, campaign, effects, controller, and hardware-performance matrices are unfinished. |
| M2: Enhanced Gore and persistence | **Incomplete** | The first postmortem sever/save slice and bounded level-session persistence work, but the full gore/save/budget/multiplayer acceptance matrix is unfinished. |
| M3: new gore content | **Not done** | No new project-owned wound meshes, detached parts, materials, sounds, or effect pack has been shipped. |
| M4: AI work | **Incomplete** | High-FPS scheduling and profiling are implemented; new tactical behavior improvements have not started. |
| Public build and installer | **Incomplete** | The public bootstrap/build pipeline works; broader clean-PC testing, signing, and the v0.1.2 Release-page upload remain open. |
| RTX and owned modern renderer | **Parked** | Diagnostic work exists, but RTX, path tracing, DLSS, HDR, and a replacement renderer do not work as playable features. |

## Fixed project decisions

- Target stock-compatible F.E.A.R. v1.08 on Win32 first.
- Preserve the original GOAP/A* AI and authored navigation.
- Keep Enhanced Gore optional and preserve stock gore-off and low-violence behavior.
- Keep EchoPatch as a separate GPL component.
- Keep retail files, the Public Tools SDK, proprietary middleware, and third-party assets out of Git.
- Require usable Hor+ gameplay at 3440 x 1440 and comparable ultrawide modes.
- Keep pre-rendered videos aspect-correct; black bars are acceptable.
- Preserve the original installation, profiles, saves, and Stable fallback paths.

## M0: reproducible rebuilt game modules

### Done

- Built `GameClient.dll`, `GameServer.dll`, and `ClientFx.fxd` as PE32/x86 Debug and Release modules.
- Added focused CMake ownership for the F.E.A.R. client, server, ClientFX, GUI, and shared libraries.
- Built from a user-supplied F.E.A.R. Public Tools 1.08 SDK without committing the SDK.
- Corrected Debug/Release definitions and the legacy build ordering needed by Visual Studio 2022 with the v141 toolset.
- Validated required module entry points and x86 output identity.
- Staged rebuilt modules beside user-owned retail data without overwriting the retail installation.
- Reached the menu and `ATC_Roof`, loaded fresh and existing quick saves, exercised active AI and ClientFX, and exited cleanly in representative runs.

### Incomplete

- Compare every rebuilt export with the original retail v1.08 modules.
- Test every campaign level, transition, major effect family, and a wider collection of old saves.
- Audit every retail-engine interface that crosses incompatible VC7.1 C++ standard-library types.
- Prove rebuilt multiplayer startup, hosting, joining, content transfer, save/state behavior, and long-session stability.
- Prove compatibility on more Windows versions, GPUs, drivers, storefront editions, and clean PCs.

### Not done

- A compatible standalone executable built from the inherited Jupiter engine tree.
- x64 game modules or engine conversion.

## M1: modern display, rendering, controls, and packaging

### Done

- Added source-owned Hor+ gameplay and real-time camera handling.
- Added a centered 16:9 HUD safe-area option with a full-width fallback.
- Added aspect-preserving pre-rendered movie fitting.
- Live-tested 3440 x 1440 gameplay through the accepted dgVoodoo2 D3D9-to-D3D11 lane.
- Live-tested Native rendering and Max 2x at 3440 x 1440; Max 2x logged a 6880 x 2880 internal swapchain resolved to 3440 x 1440.
- Added optional ReShade/FidelityFX CAS sharpening with Off as the fallback.
- Added in-game renderer quality, effects-target, post-processing, HUD-placement, and remaster-quality controls.
- Added the focused High volumetric-light shadow target while leaving incompatible authored mirror/reflection targets at native size.
- Added an isolated engine-only EchoPatch build with retail game-module hooks disabled.
- Added isolated Modern and Stable presets, separate profiles/saves, focus recovery, guarded restaging, and clean shutdown behavior.
- Corrected AI scheduling across representative 60, 120, 144, and near-240 FPS combat runs while preserving GOAP/A* behavior.
- Added SDL3 controller input, mappings, in-game settings, keyboard/mouse coexistence, legacy fallback, and automated package/source checks.
- Added validated Stable Lite HD-texture mounting and passed the known Interval 01 to Interval 02 crash gate at 3440 x 1440.

### Incomplete

- Run the full live resolution matrix: 1920 x 1080, 2560 x 1080, 3440 x 1440, 3840 x 1600, 5120 x 1440, 2560 x 1440, and 3840 x 2160, plus representative 4:3 and 16:10 modes.
- Validate selection, apply, revert, restart, profile reload, gameplay, menus, HUD, mouse hit regions, cinematics, movies, loading screens, and post-effects at every target aspect.
- Migrate remaining raw-positioned HUD and menu elements to the shared safe-area path.
- Check scope geometry, viewmodel edges, subtitles, objectives, interaction prompts, damage indicators, and authored cinematics across the complete matrix.
- Repeat the corrected ATC helicopter composition in Native mode, ordinary campaign entry, skip/restart paths, and unrelated cinematics.
- Run full-campaign D3D9/D3D11 parity, save/load, effect, long-transition, alt-tab, and shutdown testing.
- Profile Native and Max 2x across more GPUs and define sustained frame-time and memory budgets.
- Test the stock EchoPatch `SSAAScale` 1.25, 1.5, and 2.0 paths separately.
- Complete a physical-controller gameplay matrix covering hotplug, menus, every mapped action, vibration, simultaneous mouse/keyboard, focus loss, save/load, clean exit, and aim consistency at 60/120/144/240 FPS.
- Run Stable Lite textures across the full campaign. Full v2.0.2 remains experimental because it reproducibly crashes at a tested level transition.
- Measure and improve active retail shadows beyond the existing NVIDIA fix, soft-shadow settings, and focused volumetric target.

### Not done

- True HDR/10-bit output or HDR-aware color grading.
- Temporal antialiasing, DLAA, DLSS, FSR 2/3, XeSS, ray reconstruction, or frame generation.
- A source-owned D3D11/D3D12/Vulkan renderer replacing the retail D3D9 renderer.
- A supported DXVK runtime lane.
- New high-resolution material, lighting, reflection, or shadow-map systems.
- Full controller remapping, controller glyphs, gyro, touchpad support, and multiple-controller selection.

## M2: Enhanced Gore and bounded world persistence

### Done

- Added an optional `Enhanced gore` in-game setting; stock gore and low-violence policy still take precedence.
- Added bounded postmortem location damage using the existing F.E.A.R. sever, ragdoll, attachment, ClientFX, database, and damage systems.
- Prevented postmortem damage from changing health, score, kills, death commands, or death broadcasts.
- Added per-location de-duplication, sever exclusions, a per-body limit, and fresh dispatch-scoped hit-node validation.
- Added save schema 283 for detached-location and postmortem-damage state while retaining isolated retail/FearMore save roots.
- Replayed persisted detached locations for local single-player without changing the stock multiplayer packet shape.
- Completed a representative combat pass with visible postmortem severing and quick-save/reload restoration.
- Added optional bounded level-session persistence for bodies, blood/bullet decals, model decals, selected debris, shell casings, and shattered groups.
- Enforced the current ceilings: 4096/24/48 bodies, 512 ClientFX decals, 256 selected debris keys, 256 model decals, 200 shell casings, and 16 shatter groups.
- Preserved original effect lifetimes and performance-derived body caps when World persistence is Off.
- Added static source/model tests for budgets, exclusions, save ordering, de-duplication, low-violence precedence, and disabled EchoPatch world hooks.

### Incomplete

- Complete the live stock-versus-enhanced comparison with gore disabled and low-violence behavior checked explicitly.
- Confirm exact same-location duplicate rejection after saving and reloading.
- Test per-body cap `1`, multiple detach locations, incompatible sever combinations, rapid fire, several nearby corpses, and the global sever-body cap.
- Test positional, collision, explosion, rejected/filtered, crouched, knocked-down, gibbed, death-effect, and player-corpse exclusions live.
- Exceed every body/effect ceiling in dense combat and measure frame time, physics use, memory, recycling order, and permanent-body exemptions.
- Test retail schema-282 save import more broadly and confirm FearMore saves remain isolated from retail.
- Complete multiplayer host/join/late-join checks proving Enhanced Gore cannot be remotely enabled and historical sever messages are not replayed.
- Validate the current mechanics across all relevant enemy humanoid model, skeleton, armor, and attachment combinations.
- Decide whether exact detached-part transforms should be serialized; they currently reconstruct at the configured source node.

### Not done

- Live nonlethal limb loss and the required animation, weapon, locomotion, navigation, AI, and balance changes.
- Player-corpse severing with respawn-safe restoration.
- Arbitrary world debris, glass, casing, and detached-part transforms serialized into saves.
- New network packets or incompatible multiplayer sever replication.

## M3: new Enhanced Gore content

### Done

- Documented free-asset, provenance, realism, and license-selection rules.
- Identified candidate creation tools and reusable asset sources.

### Not done

- Project-owned wound caps, separated surfaces, detached parts, gibs, materials, decals, particles, audio, rigid bodies, or LODs.
- A distributable gore asset pack with complete source and license records.
- Content validation across supported humanoid skeletons, armor, attachments, weapons, damage types, and quality levels.

## M4: AI correctness and measured behavior improvements

### Done

- Corrected the high-FPS scheduler so active AI can update every server frame.
- Preserved intentional sleep paths, the existing GOAP planner, goals, actions, sensors, squads, navigation, and authored traversal links.
- Added an opt-in server-frame AI profiler and read-only capture analyzers.
- Passed representative active-combat windows at measured 60.000, 119.909, 143.901, and 237.541 FPS with no AI-starvation frames.
- Passed bidirectional 60-to-240 and 240-to-60 quick-save restoration with active AI.

### Incomplete

- Repeat the encounter with retail-style `AIUpdateInterval 0.01` as a direct control.
- Test flame-pot traversal from a new game and restored save.
- Expand profiling to more encounters, enemy counts, levels, frame rates, CPUs, saves, and long sessions.
- Define acceptable CPU budgets for frame-synced AI at very high frame rates.
- Add behavior-level telemetry for detection, cover contention, flanking, grenades, friendly fire, navigation failures, and plan recovery.

### Not done

- Improved target-confidence memory, suppression response, ally-danger handling, blocked-route memory, cover reservations, grenade safety, or plan-failure recovery.
- Local crowd avoidance; add it only if measured congestion proves it is needed.
- A replacement planner, navigation system, or authored encounter redesign.

## Public repository, bootstrap, and installer

### Done

- Published the reviewed source/build-tooling boundary without retail files, SDK files, downloaded binaries, HD textures, compiled game modules, or playable installers.
- Added a component-scoped MIT license for clearly FearMore-owned work while retaining EchoPatch GPL and third-party/inherited boundaries.
- Added a scripts-only Project Installer Bootstrap that locates or offers exact public prerequisites, clones the tagged source and submodule, validates Public Tools, and builds the private playable installer locally.
- Added manual one-command project and private launcher-package builders with exact manifests and checksums.
- Built and verified the v0.1.2 bootstrap locally from the exact public tag.

### Incomplete

- Upload the already verified v0.1.2 bootstrap, manifest, and checksum files to the GitHub Releases page. The v0.1.2 source tag is public, but its Release-page assets are not yet published.
- Repeat the complete bootstrap-to-playable-install flow on independent clean Windows PCs owned by other legal F.E.A.R. users.
- Broaden failure recovery for interrupted prerequisite installation, SDK discovery, compilation, setup, and first launch based on real outside-user reports.
- Decide whether every locally compiled or combined artifact can legally be redistributed; current playable outputs remain local/private.
- Add commercial code signing if the project obtains an appropriate certificate. Current community installers remain unsigned.

## Parked research

- RTX Remix staging, camera diagnostics, and configuration experiments remain available for future investigation.
- The current RTX path has not proved complete scene capture, stable gameplay, path tracing, DLSS, ray reconstruction, or acceptable performance.
- The observed RTX/driver crash and incomplete camera/geometry bridge keep this outside the playable Modern build.
- No RTX, HDR, DLSS, ray-tracing, or replacement-renderer claim should be made unless a future implementation passes representative gameplay and full acceptance gates.

## Definition of a complete remaster release

FearMore is not complete until all of the following are true:

- the supported campaign and save matrix passes with rebuilt modules;
- the supported resolution/aspect matrix passes gameplay, UI, movies, effects, and restart checks;
- Modern and Stable renderer paths pass long-session compatibility and performance budgets on multiple systems;
- AI correctness passes broader encounters and frame-rate transitions without unacceptable CPU cost;
- Enhanced Gore and World persistence pass their full live correctness, budget, save, and multiplayer-preservation matrices;
- controller support passes a physical gameplay matrix;
- the public bootstrap succeeds on independent clean PCs; and
- every distributed component has a confirmed provenance, license, notice, and redistribution path.
