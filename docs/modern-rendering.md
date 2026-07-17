# Modern display and rendering plan

This document is the acceptance contract for modern resolutions, the accepted dgVoodoo2 D3D11 remaster lane, and the boundary between wrapper-safe upgrades and features that require an owned renderer.

## Non-negotiable display behavior

Gameplay must be usable at every resolution in this matrix:

| Resolution | Aspect class | Purpose |
| --- | --- | --- |
| 1920 x 1080 | 16:9 | reference baseline |
| 2560 x 1080 | 21:9 | common ultrawide |
| **3440 x 1440** | 21:9 | required primary ultrawide target |
| 3840 x 1600 | 24:10 | high-resolution ultrawide |
| 5120 x 1440 | 32:9 | super-ultrawide stress case |

Gameplay and `CT_FULLSCREEN` real-time cinematics are **Hor+**: vertical FOV is preserved and wider outputs reveal more horizontally. The existing source computes horizontal FOV from the current render-target aspect ratio in `CInterfaceResMgr::GetScreenFOV`; `CPlayerCamera` uses that shared path for ordinary gameplay, zoom transitions, and every real-time camera. Authored `CT_LETTERBOX` CameraFX can retain a centered composition without capping ordinary gameplay. Scripted camera substitutes must be handled at their actual owner: the opening ATC helicopter shot is a `PlayerLure` sequence that animates `Heli_Sit`, disables the crosshair, and follows the lure, not a `CT_LETTERBOX` CameraFX.

The HUD, crosshair, weapon overlays, subtitles, objectives, interaction prompts, damage indicators, menus, loading screens, pause screen, and mouse hit regions must remain readable and correctly aligned. At 32:9, important HUD information must stay in a 16:9 safe area unless the original layout deliberately anchors it to a screen edge. HUD geometry and text remain at output resolution while SSAA applies only to the world render. A shared centered 16:9 transform now exists for `CHUDItem` edge alignment, with `HUDSafeAreaFullWidth = 1` restoring legacy full-width placement; broad HUD and menu migration remains open.

Pre-rendered videos may use black bars. `CInterfaceMgr::UpdateMovieState` already fits a movie by width or height, preserves its source aspect ratio, and centers the result. Do not stretch or crop FMVs to fill ultrawide screens. Intentional letterboxing in authored `CT_LETTERBOX` CameraFX remains enabled by default, and `LetterBoxDisabled` retains the legacy opt-out; scripted `PlayerLure` compositions are a separate source-owned path.

The existing display menu accepts every 32-bit, hardware-compatible renderer-reported mode at or above 640 x 480 and does not filter nonstandard aspects. The available generic D3D9 source enumerates adapter modes, but the active retail renderer is closed, so live testing must prove which modes it reports. Do not add a resolution allowlist. Profile persistence reapplies an exact width/height/depth match, so the acceptance pass must cover selection, apply, revert, restart, and profile reload at each target. Add a desktop-mode fallback only if a live driver test proves that a valid mode is missing.

## Known source gaps

- Scope/crosshair vertical radius and gap now use the established vertical scale instead of the horizontal scale. Debug/Release builds pass; every matrix aspect still needs live geometry acceptance.
- The shared safe-area primitive and `CHUDItem` edge-alignment path are source-complete, but raw-positioned HUD and menu controls still use the entire viewport. They must migrate with matching cursor/hit-test coordinates; fullscreen backgrounds, crosshair, damage/static effects, and world-space markers retain explicit full-width behavior.
- 32:9 can still reveal viewmodel edges during gameplay. The 3440 x 1440 ATC helicopter shot exposed invalid off-stage actors because its scripted `PlayerLure` path was treated like ordinary Hor+ gameplay. The narrow source correction passed a Modern 3440 x 1440 composition/teardown replay; Native, ordinary campaign entry, skip/restart, and unrelated-cinematic coverage remain open. Never cap ordinary gameplay to hide an asset defect.
- EchoPatch SSAA multiplies render-target dimensions without a documented device/VRAM guard. Reject unsupported internal sizes cleanly or fall back to native before claiming supersampling support at a resolution.

## Current stock-retail baseline

Pinned EchoPatch is the shared primitive for the first playable stock-retail pass. The `StockEchoPatch` lane preserves these settings in its staged copy of `EchoPatch.ini`:

```ini
FixNvidiaShadowCorruption = 1
FixAspectRatioBlur = 1
HighResolutionReflections = 1
SSAAScale = 1.0
HUDScaling = 1
AutoResolution = 1
DisableLetterbox = 0
```

The runtime tool changes only `SSAAScale` when explicitly requested. This baseline provides automatic desktop-resolution selection, HUD scaling, the modern-NVIDIA shadow correction, an aspect-aware soft-shadow/screen-blur correction, high-resolution reflections, and optional supersampling. Configuration is not gameplay acceptance: every matrix resolution still needs an in-game capture and interaction pass.

The rebuilt-module lane never loads the full stock EchoPatch profile because its game-module hooks target retail machine-code layouts. The lower-level stage builder retains Native/no-patch defaults, while the one-click Modern preset uses the pinned engine-only derivative with `PatchGameModules=0` and every module-dependent hook disabled. Rebuilt source owns Hor+ cameras, aspect-preserving FMVs, the HUD placement choice, effects-target scaling, and the in-game remaster controls; dgVoodoo2 and optional CAS own the translated output and final color pass. The complete resolution matrix still has to prove those boundaries beyond the accepted 3440 x 1440 runs.

| Runtime lane | Proven/configured rendering capability | Unproven or deliberately disabled |
| --- | --- | --- |
| Stock retail + full EchoPatch | NVIDIA world-shadow load fix, aspect-aware blur replacement, high-resolution render-target groups, SSAA, auto-resolution, HUD scaling | Live resolution matrix and performance acceptance |
| Rebuilt game modules | Source-owned Hor+ gameplay/fullscreen cameras, aspect-preserving FMV path, scope-axis correction, centered 16:9/full-width HUD choice, in-game renderer/effects/post-process controls, a remaster quality action, and a Modern-live-checked ATC `PlayerLure` composition mask | Native/campaign-entry cinematic coverage, broad raw-positioned HUD/menu migration, and the complete resolution matrix remain open |
| Rebuilt + dgVoodoo2 D3D11 + engine-only EchoPatch | Live 3440 x 1440 gameplay passed at Native and Max 2x; Max 2x produced a logged 6880 x 2880 D3D11 swapchain downsampled to 3440 x 1440; optional CAS compiled; three alt-tabs and clean shutdown passed | Full-campaign parity, the complete resolution matrix, performance budgets across hardware, and every authored effect remain open |

### In-game remaster controls

The rebuilt Display screen owns the settings a player should not need to edit in a file:

- **Renderer quality:** Native or Max 2x, applied on the next launch.
- **Effects target:** Native or High, applied on the next launch. High doubles only the proven volumetric-light shadow depth target, with a native retry on allocation failure. The volumetric target pool tracks the requested High size, the authored native size, and the size that was actually allocated as separate state. A fallback is therefore reused only at its real dimensions, and a requested/native-size change flushes that allocation before the next use. Authored mirror/reflection targets deliberately stay at their native LOD dimensions: live Interval 02 testing showed that resizing only their allocations broke the materials' projection/sampling contract and produced persistent black/white scene corruption. After that scaling was removed, the same 3440 x 1440 Stable Lite + Max 2x + CAS replay crossed into Interval 02 and remained correctly rendered through live container-yard gameplay and its scripted fade cycle with High enabled.
- **Post-processing:** Off or CAS, applied on the next launch.
- **HUD placement:** Centered 16:9 or Full width, applied immediately.

The Performance screen's **Apply remaster quality** action queues existing retail-authored maximum-detail values through the established performance manager. Its owned set is trilinear and anisotropic filtering, soft shadows, texture resolution, world detail, render-target detail, and light LOD. It deliberately leaves resolution and unrelated options alone. Native effects, Native renderer quality, Post-processing Off, and the explicit `Stable` native-D3D9 launcher preset remain fallbacks.

## Supersampling budget

The stock EchoPatch lane uses `SSAAScale`; the accepted D3D11 lane exposes the simpler **Renderer quality** choice. Native maps to dgVoodoo2 `Resolution = unforced`. Max 2x maps to `Resolution = max_2x`, which chooses dgVoodoo's largest desktop-based resolution with the app aspect ratio and then doubles each axis; it is not universally twice whichever lower mode is selected inside the game. Both profiles use `lanczos-3` resampling. At a 3440 x 1440 desktop/output, the comparable pixel budgets are:

| Mode / scale | Internal dimensions | Pixels | Workload versus native |
| --- | --- | ---: | ---: |
| Native / 1.0 | 3440 x 1440 | 4,953,600 | 1.00x |
| Stock EchoPatch 1.25 | 4300 x 1800 | 7,740,000 | 1.56x |
| Stock EchoPatch 1.5 | 5160 x 2160 | 11,145,600 | 2.25x |
| D3D11 Max 2x / stock EchoPatch 2.0 | 6880 x 2880 | 19,814,400 | 4.00x |

The live D3D11 Max 2x pass on the 3440 x 1440 desktop logged the 6880 x 2880 swapchain and its 3440 x 1440 downsample, so this mode is no longer configuration-only. In that accepted configuration it is an optional 4x pixel-work quality ceiling; Native is the performance and compatibility fallback. The stock lane should still profile 1.25 and 1.5 before 2.0 because its independent EchoPatch path has a different allocation and compatibility surface.

On a 5120 x 1440 desktop/output, Max 2x can request 10240 x 2880. That is a stress case, not a mandatory supersampling target; the mandatory requirement is native-resolution gameplay with a clean fallback when the requested internal target exceeds device or performance limits.

## Shadow upgrade path

The remaster path keeps F.E.A.R.'s active shadow-volume/blur design and raises only proven existing quality controls:

1. Keep EchoPatch's NVIDIA corruption fix and aspect-aware soft-shadow blur enabled in the stock lane.
2. **Apply remaster quality** queues the retail-authored maximum soft-shadow value together with the related texture, world, render-target, filtering, and light-LOD records. It does not invent dormant shadow variables.
3. **Effects target: High** raises the supported volumetric-light shadow depth target from 128 to 256 and retries the authored native allocation if the larger target fails. The resource manager records the actual fallback allocation, invalidates on either requested or native-size changes, and clears that metadata with the render-target pool; a prior native fallback cannot be mislabeled and reused as a later High allocation. That target owns volumetric-light occlusion, not all character or world shadows.
4. Trace any further quality change to the active Jupiter EX retail path before editing it. The similarly named `ModelShadow_Proj_*` controls in the dormant generic `runtime/render_a` tree are archaeological evidence only: the current F.E.A.R. preset disables that engine target, so they are not a valid remaster control without runtime proof.
5. Treat higher shadow-map or material redesign as a separate source/renderer feature with representative-scene and performance evidence, not as part of the accepted wrapper preset.

The accepted ReShade layer is color-only CAS sharpening. Screen-space ambient occlusion can still be evaluated later as a separate optional preset, but it must be labelled as screen-space contact shading, not ray tracing or a replacement for shadow maps, and every shader needs its own depth-compatibility and license review.

## Texture, lighting, and material boundary

The remaster quality action raises the existing texture-resolution, world-detail, render-target, and light-LOD records; it does not replace F.E.A.R.'s material system. Optional user-supplied HD Textures remain local, exact-package-validated, restart-bound, and mounted through the disposable stage. The earlier Full smoke and F5/F9 round trip did not predict a later deterministic `d3dx9_27.dll` level-transition crash, so Full is now explicitly experimental. The supported path derives and validates Stable Lite from Rivarez's Full v2.0.2 tree plus the author's official reduced overlay. Neither installer, either texture download, the derived tree, any retail archive, nor extracted game assets are redistributed.

Further lighting or material improvement should be selective and source-owned: identify the active record/shader path, preserve the original restrained art direction, and compare representative scenes against Native before widening the change. The current stack does not provide PBR materials, true HDR lighting, ray-traced illumination, or temporal reconstruction.

## Modern renderer feasibility

F.E.A.R. remains a 32-bit D3D9 game in every wrapper experiment below. A translation layer can change which modern API and driver path presents the existing draw calls, while leaving game-module behavior such as AI, weapons, damage, gore, scripting, saves, and mission logic above the renderer intact. That separation is valuable for risk control, but it is also the limit of the approach: selecting a D3D11, D3D12, or Vulkan wrapper does **not** make the game a native modern renderer and does not create ray tracing, motion vectors, DLSS, temporal FSR, or new lighting data.

### Proxy ownership rule

Only one component may own the `d3d9.dll` proxy position beside the 32-bit game executable. The x86 builds of [dgVoodoo2](https://www.dege.freeweb.hu/dgVoodoo2/ReadmeGeneral/), [DXVK](https://github.com/doitsujin/dxvk), [RTX Remix](https://docs.omniverse.nvidia.com/kit/docs/rtx_remix/latest/docs/installation/install-runtime.html), direct-D3D9 ReShade, and local D3D9 Special K are therefore mutually exclusive in a simple installation. EchoPatch uses `dinput8.dll`, so it can coexist by filename with one renderer proxy, but every such pairing still requires an A/B test for hook order, device creation, reset, alt-tab, and clean shutdown.

Do not chain unaccepted proxies merely to bypass this rule. The accepted Modern stack has explicit ownership: dgVoodoo2 owns `d3d9.dll`, engine-only EchoPatch owns `dinput8.dll`, and optional ReShade owns `dxgi.dll` at the translated D3D11 output. Each component is validated separately, and selecting Post-processing Off removes the ReShade layer on the next launch. Special K and other injectors remain separate experiments. [Magpie](https://github.com/Blinue/Magpie) is an external window scaler and owns no game DLL. Microsoft's [D3D9On12](https://github.com/microsoft/D3D9On12) is an operating-system translation component selected through source-level D3D9On12 device creation, not a replacement proxy to drop beside the executable.

### Implemented D3D11 staging slice

`tools/runtime/New-FearRuntimeStage.ps1 -Lane Rebuilt -RendererMode DgVoodooD3D11` creates a disposable stage using the exact official dgVoodoo2 2.87.3 archive (SHA-256 `6FB954BED55BF70E948C5045A663A9DF31EA206FAF105E327BAFE46C318F867F`). A read-only package validator checks the complete archive, required entry sizes/hashes, config version, and x86 PE32 identity before the stage script extracts `MS/x86/D3D9.dll` as `d3d9.dll`. Both checked-in configs select `d3d11_fl11_0` and Lanczos-3 resampling; Native leaves resolution unforced, while Max 2x requests the desktop-derived `max_2x`. Filtering, presentation, VSync, and the game's authored effects remain app-driven.

Renderer, engine-patch, and post-process choice are independent manifest fields with a fail-closed compatibility matrix. `-EnginePatchMode EngineOnlyEchoPatch` may coexist with dgVoodoo2 because it owns `dinput8.dll`; optional ReShade CAS owns the translated D3D11 `dxgi.dll` position. Every managed payload and config is exact-manifest-owned, while ReShade's user config/log/cache remain explicitly mutable. Existing Rebuilt restages use one preimage journal for present and absent files, directories, and exact junction targets, so Native/Max 2x and Off/CAS transitions either commit together or restore the previous stage. The package statuses `LiveAcceptedDgVoodooD3D11` and `LiveAcceptedDgVoodooDxgiChain` record the representative project-level pass, while each staging result keeps `AcceptanceTested` and `PostProcessAcceptanceTested` false because staging alone is not a new gameplay test. `Stable` native D3D9 remains an explicit separate rollback/control preset.

The representative live gate covers process startup, the in-game controls, main-menu presentation, rooftop gameplay, shadows and lighting, renderer identity, focus recovery, and clean shutdown at 3440 x 1440. The complete resolution matrix, long campaign transitions, save/load, effect parity, and per-hardware performance budgets remain broader acceptance work.

The live checkpoint passed Native and Max 2x at an actual 3440 x 1440 output. Native reached `ATC_Roof` gameplay through the staged x86 D3D9-to-D3D11 proxy. The Max 2x + CAS run logged a 6880 x 2880 D3D11 swapchain downsampled to 3440 x 1440, compiled `FearMoreCAS`, rendered rooftop gameplay, survived three alt-tab cycles, and shut down cleanly. This is real wrapper, supersampling, and conservative post-process evidence, not a claim of native D3D11, true HDR, DLSS, ray tracing, PBR, or complete image parity.

That pass also exposed a source-owned defect in the opening helicopter composition: full-width Hor+ revealed nearby off-stage character geometry. Inspection corrected the technical owner. This shot is the scripted `PlayerLure` sequence that animates `Heli_Sit`, disables the crosshair, and follows the lure; it is not a `CT_LETTERBOX` CameraFX and should not be repaired by globally changing CameraFX letterboxing. The narrow lure-owned fix passed its 3440 x 1440 Modern Max 2x + CAS replay: the active image stayed centered at 2560 pixels with 440-pixel side masks, duplicate off-stage actors stayed hidden, and the masks cleared before full-width checkpoint gameplay. The later death was ordinary hostile damage to an unattended player after the level had created its valid checkpoint, not a lure, renderer, `Max2x`, or CAS failure. Native, ordinary campaign-entry, skip/restart, and unrelated-cinematic checks remain open.

### Implemented CAS presentation slice

The optional [ReShade](https://reshade.me/) lane consumes an exact user-supplied signed x86 6.7.3 installer, extracts the pinned binary locally, and stages it only for dgVoodoo2 D3D11. No ReShade binary or downloaded shader collection is committed or redistributed. The project shader applies [AMD FidelityFX CAS](https://gpuopen.com/fidelityfx-cas/) logic to the final color frame with a conservative default sharpness of 0.25. Home is configured as ReShade's overlay shortcut and Scroll Lock as its effects toggle; the live pass confirmed shader compilation and effect toggling, but not reliable visibility of the overlay UI. The supported player-facing control is the in-game Off / CAS option. Because the shader has no depth, motion, exposure, or scaling input, it is correctly described as color sharpening only: it is not HDR tonemapping, antialiasing, upscaling, temporal reconstruction, or a material/lighting replacement.

### Parked RTX Remix compatibility probe

`-RendererMode RtxRemixProbe -EnginePatchMode CameraDiagnosticEchoPatch` creates the deterministic `fearmore-rebuilt-<configuration>-rtx-remix-probe-1-5-2-camera-diagnostics` stage from the official RTX Remix 1.5.2 runtime archive (231,778,218 bytes; SHA-256 `CC424BE4DD1A0C6FD922BC6A7F8E5F6582BAEA7043A38AFA6686D8B6FAABAD01`) plus the separately pinned query-light companion. NVIDIA's [runtime installation contract](https://docs.omniverse.nvidia.com/kit/docs/rtx_remix/latest/docs/installation/install-runtime.html) requires the root bridge `d3d9.dll` and the complete `.trex` runtime beside the game executable, so this mode validates and stages all 165 files instead of selecting a single DLL. Validation covers the complete archive identity, every Windows/ZIP path, duplicate/colliding paths, required notices, x86 PE32 root bridge/launcher files, x64 PE32+ renderer/bridge files, and the hash/size of every staged package/diagnostic file. The older synchronous `RemixDiagnosticEchoPatch` remains available only as a lower-level historical/developer lane.

The schema-9 stage manifest separates immutable package ownership from runtime-created state and also records the rebuilt SDL controller runtime/license identity. It records all 165 NVIDIA package files, the exact query-light EchoPatch identity, and a separately validated project-owned `.trex\bridge.conf`; the Bridge profile is not miscounted as package file 166. On a brand-new RTX stage only, the guarded stage owner copies the exact project seed `rtx.graphicsPreset = 4`, `rtx.integrateIndirectMode = 1`, and `rtx.dlfg.enable = False` into runtime-owned `rtx.conf`. Custom is required to stop a stock quality preset from overwriting the explicit ReSTIR integrator; DLSS Frame Generation remains off because its live initialization produced repeated NGX `InvalidParameter`. A later restage preserves `rtx.conf` byte-for-byte and respects deliberate deletion rather than silently recreating it. The manifest records seed provenance and `NewStageOnly` policy without claiming immutable ownership of the live config. Steam launch planning separately allows unrelated edited settings, resolves the higher-priority `user.conf` layer written by Remix's in-game Save Settings action, semantically requires an effective Custom/ReSTIR/DLSSG-off triple, and fingerprints both configuration layers again immediately before dispatch. `rtx-remix` and bounded trace paths are likewise runtime-owned. An altered or missing immutable package/diagnostic/Bridge file, an unowned file inside immutable `.trex`, a legacy/inconsistent manifest, a reparse point, or a file/directory type swap fails before retail files or rebuilt modules are updated. Native D3D9 and dgVoodoo stages reject RTX payload markers; RTX accepts only the query-light or deep diagnostic companion, rejecting no-patch, ordinary engine-only, and unrelated proxy combinations.

This mode is deliberately labelled `RendererCompatibilityStatus = UnverifiedProbe`; staging does not claim path tracing, capture completeness, stability, performance, or a usable game image. NVIDIA's [compatibility guidance](https://docs.omniverse.nvidia.com/kit/docs/rtx_remix/latest/docs/introduction/intro-compatibility.html) targets fixed-function D3D8/9 rendering and warns that shader-heavy D3D9.0c games probably will not work. F.E.A.R. relies heavily on programmable shaders, so partial or incorrect scene capture remains plausible even after the current crash is cleared. The lab must never replace the native or dgVoodoo fallback.

The query-light control resolves the earlier two-frame ambiguity. A native CameraLab paired capture completed 3,600 normal-gameplay frames at 3440 x 1440 and 59.959 FPS while the source camera travelled 26,256.13 engine units and rotated through 395.58 degrees. It observed 39 unique vertex shaders and 2,811 constant samples, all recoverable. All 24 eligible source projection samples matched numeric D3D9 transforms; one of 24 view samples matched under the strict raw-matrix comparison, with the remaining engine-space handedness/offset difference retained as evidence rather than normalized away. This proves the rebuilt source seam and query-light D3D9 telemetry can run through representative camera motion without the deep probe's per-draw query stall.

The 2026-07-15 RTX query-light run then rendered the legal screen, frontend, and load screen through a genuinely windowed 3440 x 1440 Vulkan swapchain. At mission entry the source seam armed the D3D9 capture, which preserved the first gameplay frame: 92 shader draws, 54,342 primitives, 29 shader records covering 26 unique shaders, 201 constant writes / 56,816 payload bytes, and three transform records. That is a materially later and less-perturbed interception result than the old two-frame startup traces. The fault occurred during this first gameplay rendering independently of alt-tab. It is still not evidence of a complete ray-traced scene because representative gameplay could not be inspected.

The preserved x64 Bridge minidump localizes the immediate fault to an access violation in `nvoglv64.dll`, with `NRC_Vulkan.dll` active on the exception stack. The final Remix log line before the fault was Neural Radiance Cache loading its default network configuration. The pinned 1.5.2 [`RtxOptions.md`](https://github.com/NVIDIAGameWorks/dxvk-remix/blob/remix-1.5.2/RtxOptions.md) maps indirect mode `1` to ReSTIR GI and `2` to NRC, while logs and pinned source showed that Auto selected High and overwrote the explicit ReSTIR value with NRC. The corrected Custom + ReSTIR + DLSSG-off stage remains preserved as future diagnostic evidence, but it has not passed mission entry and is not part of the active remaster plan.

If RTX work is revisited, mission-entry stability must precede scene-completeness and camera-classification work. The captured source projection, submitted transforms, shader CTAB/register maps, and exact constant payloads remain a source-owned basis for that future investigation. Geometry capture or an owned renderer remains necessary if shader vertex capture cannot reconstruct F.E.A.R.'s scene. Packaged DLSS, ray-reconstruction, and frame-generation binaries being present or loaded is initialization evidence only; none is claimed active.

RTX Remix remains isolated, explicitly unverified, and nondefault. Current dumps, logs, and captures stay under ignored `local-runtime` evidence paths and are never packaged as a working RTX or DLSS feature.

### Current and deferred off-the-shelf plan

Each numbered item is a separate runtime configuration with its own staged directory, manifest, logs, screenshots, and rollback path. Advancing one lane does not replace the stock baseline.

| Rank | Runtime lane | Exact role and acceptance gate |
| ---: | --- | --- |
| 0 | [dgVoodoo2](https://www.dege.freeweb.hu/dgVoodoo2/ReadmeGeneral/) x86 D3D9 -> D3D11 FL11 + optional CAS | **Accepted one-click remaster direction.** Native and Max 2x 3440 x 1440 rooftop gameplay, CAS compilation, three focus cycles, and clean shutdown passed. Native/Off remain exact fallbacks; full-campaign and complete resolution-matrix acceptance continue. dgVoodoo2 is freeware with custom terms rather than project source, and ReShade remains a user-supplied ignored prerequisite. |
| 1 | Stock retail D3D9 + pinned EchoPatch / rebuilt `Stable` | Renderer controls and rollback references. Keep these separate profiles available when diagnosing wrapper, post-process, or source regressions. |
| 2 | dgVoodoo2 x86 D3D9 -> D3D12 | A distinct variant after the D3D11 lane passes. Test the available D3D12 feature-level outputs independently. This remains D3D9 translated at runtime, not an owned D3D12 renderer; reject it if shader output, device resets, capture tools, or frame pacing regress even when average performance improves. |
| 3 | [DXVK](https://github.com/doitsujin/dxvk) x32 D3D9 -> Vulkan | A separate free/zlib Vulkan comparison, never installed over a dgVoodoo lane. The project publishes 32-bit builds, but its own [Windows guidance](https://github.com/doitsujin/dxvk/wiki/Windows) says native Windows is unsupported and documents DLL loading, overlay/hook, driver, fullscreen, and alt-tab caveats. FearMore must separately measure VRR/HDR behavior, latency, and frame pacing. Treat success as hardware/driver-specific evidence, not a universal Windows recommendation. |
| 4 | Additional [ReShade](https://reshade.me/) effects beyond CAS | CAS is implemented and accepted as optional color sharpening. AO, DOF, SSR, tone curves, and other effects remain separate experiments because depth access, authored-image changes, soft-shadow interaction, and shader licensing each need their own gate. No effect may be described as HDR or ray tracing without the required underlying data and proof. |
| 5 | [Magpie](https://github.com/Blinue/Magpie) external spatial scaling | Optional free/GPL performance or compatibility fallback using FSR-, NIS-, or other spatial filters. It can scale a window without entering the game's 32-bit DLL chain. Native 3440 x 1440 remains the primary requirement: Magpie does not supply temporal reconstruction, motion data, higher-resolution shadows, or a substitute for correct HUD/FOV behavior. Test capture latency, cursor confinement, alt-tab, and frame pacing. |
| 6 | [Special K](https://github.com/SpecialKO/SpecialK) diagnostics/HDR lab | Optional free/GPL x86 experiment, not a core dependency. Its useful roles are frame-time diagnostics, presentation control, and a possible HDR retrofit after dgVoodoo2 produces a proven D3D11 output. Follow Special K's official [dgVoodoo compatibility path](https://wiki.special-k.info/en/SpecialK/dgVoodoo) and use a separately named global-injection lane; do not stack it merely to duplicate EchoPatch's frame-rate or resolution behavior. |
| 7 | [D3D9On12](https://github.com/microsoft/D3D9On12) source integration | Research lane only. D3D9On12 maps D3D9 calls to D3D12 and offers resource interop, but the game must deliberately create a D3D9On12 device; Microsoft's repository says custom builds are for local testing and applications should use the Windows component. It can test a source-owned translation seam, but it adds no ray tracing, DLSS, or visual upgrade by itself and is not an off-the-shelf retail drop-in. |
| 8 | [RTX Remix](https://github.com/NVIDIAGameWorks/rtx-remix) bounded capture probe | **Parked for a possible future revisit.** The preserved query-light lane reached the frontend/load and captured the first mission frame before the x64 Bridge faulted on the NRC path. Its exact package, diagnostics, and evidence remain isolated and nondefault; it does not establish a playable ray-traced scene, DLSS, or stability. |

### Spatial and temporal feature boundary

| Feature | Earliest credible lane | Required evidence |
| --- | --- | --- |
| External spatial scaling | Magpie after native-output acceptance | A measurable performance use case with acceptable latency, HUD clarity, cursor behavior, and frame pacing. |
| Source-owned FSR 1-class spatial scaling | D3D9 or later owned renderer | A correctly isolated world render, high-quality scaler integration, native-resolution HUD composition, and a benefit over existing SSAA/native modes. |
| DLSS SR/DLAA or temporal FSR | Owned modern renderer | Depth, per-pixel motion vectors, jittered projection, exposure, render- and output-resolution color, reactive/transparency handling, and HUD-free inputs. A wrapper cannot reliably invent these engine signals. Streamline's documented build/package output is x64, so the current Win32 process also needs a 64-bit engine migration or another explicitly supported integration before it is a viable DLSS host. |
| Frame generation | Mature owned modern renderer | Stable temporal inputs plus swapchain/presentation integration, latency management, and reliable UI separation. It is not a wrapper-only feature. |

### Owned-renderer sequence

If wrapper experiments cannot deliver the desired shadows, HDR, temporal reconstruction, or material upgrades, preserve the existing D3D9 path as the visual and behavioral reference and introduce a narrow renderer boundary around device creation, resources, shaders, render targets, draw submission, and presentation. Keep AI, gore, damage, physics, scripting, saves, and other game systems above that boundary; renderer work must not become a gameplay rewrite.

No owned F.E.A.R. renderer is built today. The active CMake lane rebuilds game modules and still loads the closed retail engine/renderer; `runtime/render_a` is dormant generic LithTech archaeology, not a drop-in F.E.A.R. 1.08 backend. Before D3D11 implementation can begin, a separate full-engine lane must revive or replace the compatible client, server, renderer, sound, UI, and content-loading boundaries and prove F.E.A.R. 1.08 asset, interface, gameplay, and presentation parity. That is an engine-port milestone, not a game-module patch.

Once that full-engine lane exists, D3D11 is the first owned-renderer target. It is close enough to D3D9's resource-and-draw model to make parity work tractable while providing modern shader models, debugging/profiling tools, larger-format render targets, compute support, and clean integration points for later post-processing. Driver-managed synchronization and residency also let the project prove its backend boundary, asset/shader conversion, device-loss behavior, and frame equivalence before taking on explicit GPU scheduling.

D3D12 comes only after the D3D11 backend reaches feature and content parity. Starting directly with D3D12 would combine the renderer migration with descriptor heaps, resource barriers, fences, queue ownership, memory residency, pipeline-state management, and multiframe lifetime bugs. Those responsibilities can improve performance when the renderer already has trustworthy tests and ownership boundaries, but they do not improve F.E.A.R.'s image by themselves. A later D3D12 backend must earn its place through measured capability or performance, with D3D9 and D3D11 retained as fallbacks until the full acceptance matrix passes.

## Acceptance evidence

For each matrix resolution, record the launcher preset, renderer quality, effects target, post-process mode, EchoPatch scale where applicable, refresh rate, GPU/driver, and screenshots of:

- ordinary combat and weapon view;
- zoom/slow-motion and full-screen post effects;
- HUD, subtitles, objectives, and damage indicators;
- pause/options menus with correct mouse hit regions;
- a real-time cinematic with intentional letterbox behavior;
- a pre-rendered video with aspect-preserving black bars;
- reflective surfaces, world/character shadows, volumetric lights, and a soft-shadow-heavy encounter.

Also record average and worst-frame time, internal/output dimensions when downsampling, shader compilation where post-processing is enabled, save/load, alt-tab, resolution changes, level transitions, and clean shutdown. The completed 3440 x 1440 Modern gate establishes representative Native and Max 2x/CAS gameplay; it does not waive the remaining matrix and campaign checks. A lane is accepted only for the evidence actually observed: successful process launch or a correctly staged config is insufficient.
