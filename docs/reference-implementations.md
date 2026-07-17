# External reference implementations

These projects can shorten FearMore's research without importing incompatible code. License boundaries apply to code, assets, shader binaries, and derived work separately.

| Project | Useful evidence | License | FearMore treatment |
| --- | --- | --- | --- |
| [EchoPatch](https://github.com/Wemino/EchoPatch) | Retail F.E.A.R. SSAA, resolution recovery, HUD scaling, high-FPS corrections, persistent bodies/decals/debris, executable compatibility, and concrete D3D9 hook seams | GPL-3.0 | Pinned submodule and separate `dinput8.dll`; use the full profile only with stock modules. Rebuilt accepts only separately built, pinned `PatchGameModules=0` derivatives. The Remix-only derivative adds bounded camera telemetry on EchoPatch's GPL side; do not paste or link its implementation into inherited modules without a full license audit. |
| [SDL](https://github.com/libsdl-org/SDL) | Maintained cross-vendor gamepad enumeration, standardized axes/buttons, hotplug, and two-motor rumble on modern Windows | zlib | Independently authored rebuilt-source integration against SDL's public API. Dynamically load the exact validated x86 runtime from the executable directory; keep EchoPatch's GPL controller/game-module hooks disabled. The official archive and DLL stay ignored local dependencies, while the exact zlib license is staged with the runtime. |
| [dgVoodoo2](https://www.dege.freeweb.hu/dgVoodoo2/ReadmeGeneral/) | Native-Windows x86 D3D9 translation to D3D11/D3D12, forced resolution, MSAA, anisotropic filtering, and presentation controls | Freeware with project-specific redistribution terms | First off-the-shelf renderer experiment. Pin the upstream package archive identity locally, extract only its x86 `d3d9.dll` and an owned config into a separate stage, and retain native D3D9 as the fallback. Individual files may be shipped with a game or mod under the author's current terms; do not treat the binary as open-source FearMore code. |
| [DXVK](https://github.com/doitsujin/dxvk) | D3D9-to-Vulkan translation, shader capture, and a separate compatibility/performance comparison | zlib/libpng | Experimental runtime lane only. It owns `d3d9.dll`; test native-Windows behavior and EchoPatch device-hook interaction rather than assuming Wine results transfer. |
| [Microsoft D3D9On12](https://github.com/microsoft/D3D9On12) | D3D9-to-D3D12 mapping architecture, D3D12 resource interop, and a source-selected translation seam | MIT source; the supported runtime is a Windows component | Local engine research only. Applications should use the operating-system component rather than ship a custom mapping-layer build. It does not add new lighting or temporal-upscaler inputs by itself. |
| [RTX Remix](https://github.com/NVIDIAGameWorks/rtx-remix) | D3D8/9 interception, scene capture, path-traced replacement rendering, DLSS, and Reflex | MIT for the combined open-source repository; the release package includes additional third-party notices | The pinned 1.5.2 runtime has an isolated full-payload stage plus separate exact query-light and deep diagnostic EchoPatch companions. Native query-light capture correlates all 24 eligible source projection samples. The corrected Custom + ReSTIR + DLSSG-off stage reached a genuinely windowed 3440 x 1440 frontend/load and captured first-mission-frame telemetry, then the Bridge faulted during mission entry. RTX is therefore parked and nondefault; camera/geometry completeness, path tracing, stability, and DLSS remain unaccepted. Ignored upstream binaries are not redistributed. |
| [NVIDIA Streamline](https://github.com/NVIDIA-RTX/Streamline) | Required resources and frame tags for DLSS/DLAA integration | MIT core; listed third-party, Nsight, and separately distributed feature-binary terms also apply | Architecture reference for a future modern renderer. Current D3D9/Win32 game-module work cannot provide the required temporal buffers or API seam, and Streamline's documented build/package path is x64; a 64-bit engine/process migration or another explicitly supported integration remains a separate gate. |
| [AMD FidelityFX SDK](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK) | Current temporal-upscaler contract: depth, motion vectors, jitter, reactive data, and render/output resources | Samples are MIT; repository third-party notices still apply | Architecture and acceptance reference only until an owned renderer exposes those resources. The standalone FSR 2 repository is a useful versioned/archival reference, but dependency decisions must use the current SDK. FSR 1 remains the only plausible spatial backport experiment. |
| [ReShade](https://github.com/crosire/reshade) | D3D9 post-process injection and optional screen-space AO/color/sharpening experimentation | BSD-3-Clause core; shader licenses vary | Optional separate/chained lane after baseline acceptance. Never present screen-space AO as ray tracing, and audit every preset/shader asset. |
| [Magpie](https://github.com/Blinue/Magpie) | External Windows window capture and spatial scaling with FSR-, NIS-, and other filters | GPL-3.0 | Optional local performance/compatibility tool after native 3440 x 1440 acceptance. It avoids the in-process DLL chain but adds capture, cursor, latency, and frame-pacing risks; it is not temporal reconstruction. |
| [Special K](https://github.com/SpecialKO/SpecialK) | Frame-time diagnostics, presentation controls, and an experimental dgVoodoo-backed HDR route for old D3D9 titles | GPL-3.0 | Optional, separately named diagnostics/HDR laboratory only. Prefer global x86 injection after a dgVoodoo D3D11 stage is stable; do not make it a core runtime dependency or stack it during first-pass renderer validation. |
| [Rivarez F.E.A.R. HD Textures v2.0.2](https://www.moddb.com/downloads/fear-hd-textures-v202) | Authored higher-resolution replacement DDS files for the base game and expansions | No redistribution license established for the supplied assets | Optional local content only. FearMore validates the pinned base-game DDS tree, ignores the installer/XP tree, and mounts it through an exact manifest-owned junction that project tooling treats as no-write. The junction has no read-only ACL; never commit or bundle the texture files. |
| [OpenJK](https://github.com/JACoders/OpenJK) | Mature model-part/dismemberment configuration and Ghoul2 attachment patterns | GPL-2.0 | Design and test-case reference only. No code copying into FearMore's mixed-provenance modules. |
| [Doom 3 GPL source](https://github.com/id-Software/DOOM-3) | Articulated-figure ragdolls, damage effects, blood/decal ownership, and bounded gib behavior | GPL-3.0 | Design reference only. Doom 3 game data remains separate and is not reusable here. |
| [ioquake3](https://github.com/ioquake/ioq3) | Long-lived engine maintenance and bounded impact-mark lifecycle patterns | GPL-2.0 | Design reference only; useful for eviction-policy tests, not a source donor. |

## EchoPatch first-use profile

EchoPatch already owns the immediate modern-display path for the retail executable and its stock game modules. The stock-only runtime test profile should enable:

```ini
[Fixes]
HighFPSFixes = 1
FixNvidiaShadowCorruption = 1
FixAspectRatioBlur = 1

[Graphics]
SSAAScale = 1.0
HighResolutionReflections = 1
EnablePersistentWorldState = 1

[Display]
HUDScaling = 1
AutoResolution = 1
DisableLetterbox = 0
```

`SSAAScale = 1.0` is the compatibility baseline. At 3440 x 1440, profile 1.25 and 1.5 before treating 2.0's 6880 x 2880 internal target as an optional quality ceiling; EchoPatch documents no device/VRAM guard for unsupported internal sizes. EchoPatch's unlimited persistence remains useful only as a retail visual reference. The rebuilt source now owns the first explicit budget: optional corpse persistence keeps the inherited Off payload intact and uses bounded 4096/24/48 radius/level limits when On. Separate decal, gib, shell, and debris budgets remain future work.

This full profile is not applied to rebuilt game modules. EchoPatch hooks exact retail client, server, and ClientFX machine-code signatures. The optional Rebuilt runtime mode consumes only the pinned local derivative that proves `PatchGameModules=0`, keeps module-dependent settings disabled, and records exact binary/config ownership. That permits a bounded engine-hook experiment; it is not evidence that every retained hook is runtime-compatible, and it does not replace independently authored source fixes.

## Rebuilt-source candidates from EchoPatch

EchoPatch's `HighFPSFixes` is a bundle, not a safe switch for rebuilt modules. Its source identifies separate behavior owners that should be profiled and ported independently: jump impulse/state, normal friction and liquid/swim velocity, PolyGrid collision timing, client/server slow-motion charge, ClientFX particle update thresholds/lifetimes, sever timing, and AI server-update scheduling. FearMore owns the measured AI scheduling correction and now owns the two ClientFX particle invariants directly: positive sub-millisecond deltas are simulated, and batch markers begin zero-expired without changing authored update time. Movement/liquid invariance, slow-motion synchronization, PolyGrid lifetime invariance, and live 60/120/144/240 ClientFX comparison remain separate acceptance work.

SSAA and high-resolution reflections also span engine and Client hooks upstream. Their correct long-term owners are FearMore's `PlayerCamera`/shared render-target path and `RenderTargetGroupFx`, respectively, not the engine-only EchoPatch INI. User-visible quality controls should reuse the established screen/profile primitives and state whether restart is required. Proxy renderer selection, RTX mode, and archive mounts cannot hot-switch after process start; a future dedicated Modern Features screen must hand those saved choices to a common bootstrap launcher rather than pretending they apply immediately.

## What is not needed now

The original F.E.A.R. GOAP planner, goals, actions, squads, and authored navigation remain the behavior owners. No external behavior tree, planner, or navigation replacement is justified yet. FearMore has already applied the measured frame-synced `AIUpdateInterval` scheduler correction and fixed the flame-pot sensor's broken grace-period comparison without replacing those systems. Encounter telemetry and capped-frame acceptance come next; further behavior changes require measured defects.
