# FearMore runtime staging

This tool creates disposable, Git-ignored runtime stages without changing a retail installation, the Public Tools SDK, or build outputs. It encodes the EchoPatch compatibility boundary as separate lanes:

| Lane | Executable and modules | Modern patch | Intended proof |
| --- | --- | --- | --- |
| `StockEchoPatch` | Retail `FEAR.exe` and untouched retail game modules | Exact pinned EchoPatch 4.2.1 | Modern-resolution, ultrawide blur/shadow correction, SSAA, HUD, high-FPS, and persistence baseline |
| `Rebuilt` | Disposable retail `FEAR.exe` plus rebuilt `GameClient.dll`, `GameServer.dll`, `ClientFx.fxd` | Native D3D9/no patch by default; separately owned dgVoodoo2 D3D11, RTX Remix probe, and engine-only EchoPatch options | Retail menu, campaign, save, AI, damage, ClientFX, renderer A/B, and shutdown acceptance |
| `SdkSmoke` | Public Tools 1.08 `FEARDevSP.exe`, support runtime files, and rebuilt modules | Explicitly forbidden | Binary validation and module-overlay placement only; launch is forbidden |

`SdkSmoke` is a non-launching diagnostic. Public Tools supplies `FEARDevSP.exe` and the editable `Game` tree, but it relies on retail bootstrap DLLs such as `EngineServer.dll`, `GameDatabase.dll`, `SndDrv.dll`, and `StringEditRuntime.dll`. Those matching base-game binaries are not redistributed by the SDK. The script therefore refuses `-Lane SdkSmoke -Launch`; menu, campaign, saves, AI navigation, and production ClientFX checks require a user-owned F.E.A.R. v1.08 installation and the `Rebuilt` lane.

## One-click launcher

Double-click [`Launch FearMore.cmd`](../../Launch%20FearMore.cmd) at the repository root to prepare and start the accepted `Modern` preset. The explicit `-Preset Stable` native-D3D9 path remains available as the rollback and renderer-control lane. The batch file is only a Windows entry point; [`Start-FearMore.ps1`](Start-FearMore.ps1) maps friendly presets onto the focused owners below. `New-FearRuntimeStage.ps1` remains responsible for disposable-stage preparation and validation. A non-`PrepareOnly` RTX preset additionally uses the guarded retail-sidecar installer and an immutable Steam launch plan because Remix must sit beside the registered retail executable.

The tracked checkout remains the development surface. `New-FearMoreLauncherPackage.ps1 -PrivateOwnerBuild` now emits an ignored, exact-hash owner payload under `dist\local\FearMore-Playable`; it is a local convenience build, not a fresh-machine installer or redistributable release. Every launch still requires a user-owned F.E.A.R. v1.08 installation. Missing or wrong-version inputs fail closed, and a future public bootstrapper still needs a completed provenance review, dependency acquisition, prerequisite installation, license presentation, and first-run recovery.

| Preset | Renderer | Engine patch | Default cap | Status |
| --- | --- | --- | --- | --- |
| `Modern` | dgVoodoo2 D3D9-to-D3D11 | Engine-only EchoPatch | 144 FPS, dynamic VSync disabled | One-click default; live 3440 x 1440 gameplay passed at Native and Max 2x, CAS compiled, three alt-tab cycles recovered, and clean shutdown passed |
| `Stable` | Native D3D9 | None | Game default | Explicit rollback and renderer/engine-patch control lane; it keeps a separate profile and does not inherit the D3D11 wrapper or CAS chain |
| `RtxLab` | RTX Remix 1.5.2 probe | Query-light camera-diagnostic EchoPatch derivative | Fixed 60 FPS, dynamic VSync | Parked, isolated, and unverified future lab; its diagnostics remain available, but path tracing, scene completeness, stability, DLSS, and ray reconstruction are not claimed |
| `RtxBridgeLab` | RTX Remix 1.5.2 probe | Bounded camera-reassertion EchoPatch derivative | Fixed 60 FPS, dynamic VSync | Parked causal experiment; it reasserts only numerically validated D3D9 camera transforms during a bounded shader window and makes no renderer-compatibility claim |
| `CameraLab` | Native D3D9 | Query-light camera-diagnostic EchoPatch derivative | Fixed 60 FPS, dynamic VSync | Developer capture lane: setter-only D3D9 constant telemetry runs without dgVoodoo or Remix so normal gameplay can identify the real shader camera state |

The launcher keeps all five presets in separate `fearmore-launcher-*` stage roots and preserves each stage's existing `UserDirectory`; it does not repurpose, migrate, or remove developer/acceptance stages created through the lower-level tool. CameraLab's current default is `fearmore-launcher-native-camera-lab-armed`; the earlier `fearmore-launcher-native-camera-lab` remains untouched as historical local evidence. RtxLab defaults to `fearmore-launcher-rtx-query-light-restir-custom-focus-preserved-d9d8-lab`, while RtxBridgeLab uses `fearmore-launcher-rtx-camera-reassertion-prearm300s-300f-lab`; prior crash stages remain untouched so new-stage-only policy does not rewrite runtime-owned evidence or settings. On a new profile, the launcher creates only missing files: `settings.cfg` receives the current primary-display dimensions by default or an explicit `-Width`/`-Height` pair and seeds Enhanced Gore, bounded World persistence, and SDL controller input On for Modern (Off for the other presets), HD textures Off, renderer quality Native, effects target Native, post-processing Off, and centered 16:9 HUD placement; `Game.ini` receives `[Game] GameRuns=1`. The game increments that value to `2` before its main-menu check, preventing the legacy first-run performance auto-detect from replacing an explicit ultrawide resolution. This intentionally also skips the legacy first-run startup intros. Existing `settings.cfg` and `Game.ini` files are always preserved byte-for-byte; resolution and remaster choices then belong in the game's menus or an intentional profile edit. When an existing Modern `settings.cfg` has no `EnhancedGore` field, the launcher still uses the Modern enabled default for that launch without rewriting the file; leaving the Gameplay options screen persists the visible selection. World persistence and controller input are intentionally stricter: only a genuinely new Modern profile defaults them On, while an existing profile lacking either field remains Off until its in-game option is changed and saved. An explicit saved `0` or `1` always wins. The ordered transaction commits `Game.ini` before `settings.cfg`, so an interrupted seed cannot leave a newly written resolution exposed to the auto-detect path. That launcher-owned transaction reuses the runtime-stage component and file-target guards before every write, move, or cleanup, so an intermediate junction anywhere from the writable `local-runtime` root through `UserDirectory` fails before profile bytes can escape the stage. Stable, Modern, and CameraLab re-enter the stage owner for its immediate pre-launch scan. Either RTX preset with `-PrepareOnly` stops after stage/profile creation and performs no retail write; a launch first validates the exact running same-session Steam client, transactionally installs or verifies the exact reversible retail sidecars, validates the live Custom/ReSTIR/DLSSG-off config, then dispatches registered App ID 21090 and independently observes retail `FEAR.exe` startup. RTX presets currently require HD Textures Off because their retail path does not yet own an LAA executable and HD archive mount.

`FearRuntimeLayout.psm1` keeps the current checkout behavior unchanged: when the launcher root has a `.git` marker, writable stages stay under that checkout's ignored `local-runtime`. An assembled launcher payload omits `.git` and identifies itself only with an ordinary root `fearmore-package.json` containing exactly `SchemaVersion: 1`, `PackageId: "FearMore.Runtime"`, and `Layout: "LauncherPayload"`; that mode moves stages and profiles to `%LOCALAPPDATA%\FearMore\local-runtime`. Relative `-StageRoot` values resolve against the checkout in developer mode and against the per-user runtime root in packaged mode. Layout resolution is read-only; the existing guarded stage owner remains the sole stage creator/mutator. `FearLauncherPackage.psm1` owns the explicit copy allowlist and exact file-manifest verifier, while `New-FearMoreLauncherPackage.ps1` owns one transactional output mutation boundary. See [`../../docs/playable-build.md`](../../docs/playable-build.md) for the one-command owner workflow, private/public boundary, and verification command.

Retail package replacement is intentionally not implicit. If a different RtxLab sidecar package is already installed, the new launch fails closed rather than overwriting another manifest or mutable config. The exact prior package must be uninstalled and its receipt retired through `Install-FearMoreRetailSidecars.ps1` using that package's original stage and seed before the new package can install. A focused cross-version upgrader remains deferred until previous-seed provenance and interrupted-upgrade recovery can be made durable; this is a known gap in the end-user one-click story.

The rebuilt client exposes the player-facing remaster controls in game. The Gameplay options screen owns the persisted **Enhanced gore** toggle; stock **Gore** must also be Yes, low-violence policy still takes precedence, and a changed selection reaches the local server on the next world load. The separate **World persistence** toggle keeps existing profiles through the legacy `FearMoreCorpsePersistence` field. Off forwards original body caps and preserves authored effect lifetimes. On applies the bounded single-player 4096-unit / 24-local / 48-level corpse budget plus hard loaded-level ceilings of 512 ClientFX decals, 256 selected debris keys, 256 model decals, 200 shell casings, and 16 shatter groups. Existing lower regional/per-model/performance caps still win. It does not enable EchoPatch world hooks or serialize arbitrary world state. **Options > Display** owns restart-bound **Renderer quality** (Native / Max 2x), **Effects target** (Native / High), and **Post-processing** (Off / CAS), plus immediate **HUD placement** (Centered 16:9 / Full width). Effects target High doubles only the source-proven volumetric-light shadow depth target; authored mirror/reflection targets remain native because changing only their allocations broke their material projection/sampling contract. The corrected High lane passed the 3440 x 1440 Stable Lite + Max 2x + CAS Interval 02 crash gate without the earlier black/white scene corruption. **Options > Performance > Apply remaster quality** queues the existing retail-authored maximum-detail values for trilinear and anisotropic filtering, soft shadows, texture resolution, world detail, render targets, and light LOD; leaving that screen applies and saves through the established performance-manager path. The performance screen seeds its hidden width and height from the active user profile rather than legacy bootstrap CVars, so applying the preset preserves the selected display mode. **Options > Game > HD textures** remains restart-bound. These controls reuse the existing toggle/cycle, profile-save, screen-command, performance-record, and help-text patterns. Their labels and help are presently hardcoded English because no editable localized string database is tracked in this repository; localization remains explicit debt.

**Options > Controls > Joystick** also owns the source SDL3 controller toggle, right-stick sensitivity, radial deadzone, controller-only invert Y, and vibration. The screen remains reachable without an LTInput joystick. Keyboard and mouse stay simultaneous; an SDL-active physical controller suppresses only duplicate legacy gamepad bindings, and disconnect/disable restores that fallback. `Start-FearMore.ps1` acquires the official SDL 3.4.10 x86 archive into ignored `vendor-local/controller-deps` when absent, validates the exact archive/runtime/license/PE32 identity, and supplies it to the guarded stage workflow. Schema-9 Rebuilt stages own `SDL3.dll` and `.fearmore\licenses\SDL3-zlib.txt`; no SDL binary is tracked or copied from EchoPatch. See [`../../docs/controller-support.md`](../../docs/controller-support.md) for mapping and the still-open physical-controller acceptance matrix.

`Test-FearPhysicalController.ps1 -StageRoot <stage>` relaunches through x86 PowerShell, revalidates that stage's SDL payload, and directly samples the attached gamepad. Add `-RequireInputActivity` while moving sticks/pressing buttons and `-RumbleMilliseconds 300` for a bounded hardware-rumble request; it never changes the game profile.

```powershell
# Prepare the default Modern stage at 3440x1440 without starting the game.
& '.\Launch FearMore.cmd' -PrepareOnly -Width 3440 -Height 1440

# Explicit native-D3D9 rollback/control lane.
& '.\Launch FearMore.cmd' -Preset Stable -PrepareOnly -Width 3440 -Height 1440

# Prepare the experimental RTX lab without retail installation or launch.
& '.\Launch FearMore.cmd' -Preset RtxLab -PrepareOnly -Width 3440 -Height 1440

# Launch the prepared RTX lab. Steam must already be running and logged in in
# this Windows session; this still does not claim accepted path tracing.
& '.\Launch FearMore.cmd' -Preset RtxLab

# Native query-light camera capture control; no renderer wrapper is staged.
& '.\Launch FearMore.cmd' -Preset CameraLab -PrepareOnly

# A different explicit cap is valid only for Modern.
& '.\Launch FearMore.cmd' -Preset Modern -MaxFPS 120
```

## Optional HD textures

FearMore can mount a user-supplied Rivarez texture tree without running its installer or copying it into each stage. The recommended path combines the [Full v2.0.2 pack](https://www.moddb.com/downloads/fear-hd-textures-v202) with the official [HD Textures Lite Pack](https://www.moddb.com/mods/fear-xp-rivarez-mod/downloads/fear-hd-textures-lite-pack):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\runtime\New-FearHdTextureLitePackage.ps1 `
  -FullPackageRoot 'D:\path\to\HDTextures4FEAR_XP_v2.0.2' `
  -LitePatchRoot 'D:\path\to\extracted-lite-patch' `
  -DestinationRoot 'D:\path\to\FearMore-HD-Textures-Lite'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\runtime\Register-FearHdTexturePack.ps1 `
  -Mode Lite -PackageRoot 'D:\path\to\FearMore-HD-Textures-Lite'
```

Developer checkouts preserve the existing ignored `vendor-local\texture-packs\fearmore-hd-textures.json` registration. Assembled payloads instead store it under `%LOCALAPPDATA%\FearMore\registrations\texture-packs`; registration never writes into the package folder. The default private LAA prerequisite is likewise resolved through the selected layout's runtime root, so packaged mode looks under `%LOCALAPPDATA%\FearMore\local-runtime\fearmore-stock-echopatch`.

Then open **Options > Game > HD textures**, choose **Stable Lite (recommended)**, leave the screen so `settings.cfg` is saved, quit, and start the same FearMore preset again. The launcher reads the in-game setting (`0` Off, `1` Lite, `2` Full, including the engine's decimal serialization), rejects malformed or duplicate fields, and treats missing settings as Off. The setting is restart-bound because archive trees are mounted before the client UI starts.

The earlier Full smoke pass reached 3440 x 1440 gameplay and survived one fresh F5/F9 round trip, but later transition testing invalidated it as a stability claim. The same save repeatedly faulted at `d3dx9_27.dll+0xFCCDF` while Full was mounted; Native resolution, CAS Off, and native effects targets did not prevent it, while HD Off crossed the transition into Interval 02. Full therefore remains visible only as `Full v2.0.2 (experimental)`. Stable Lite is the recommended player path. Its exact saved-game replay passed the same gate at 3440 x 1440 with Max 2x and CAS, crossed Interval 01 into Interval 02, completed helicopter insertion, reached live container-yard gameplay, and emitted no new crash dump. This is focused acceptance evidence, not a full-campaign certification.

Full validates 1,882 base-game DDS files / 7,587,319,112 bytes / manifest SHA-256 `C92E8C14ABBD5D8C306D072C2ABAD1EA22D0426182CE37E302E948EB9346D801`. The official base-game Lite overlay is pinned at 1,297 files / 4,066,601,424 bytes / `0CDA60503FCC728D08B0870236861E0DA9184576331AAA272367BD9B015ED06D`; the complete derived Lite tree is 1,882 files / 4,440,752,072 bytes / `758A5112EA00FD802B5373066EE3BD9AF29A501D271AF6A5CA7F14F6FEFB63ED`. The builder rejects expansion content, reparse points, non-DDS files, malformed formats, and identity mismatches. One exact `HDTextures` junction mounts the selected `HDTextures\FEAR` tree; Off removes only that owned junction and restores the retail executable.

Both texture modes use an attested, private Large Address Aware `FEAR.exe`/backup pair. The stage copies only the validated LAA executable into its disposable root and never edits the retail installation. The default source is the already bootstrapped ignored `local-runtime\fearmore-stock-echopatch` pair; if it is absent, prepare/bootstrap that stock control lane first. Neither executable, either texture download, the derived tree, its installer, `LTMemory.dll`, nor its bundled D3D wrapper is redistributed.

Pass `-RetailRoot` for an unusual installation and `-StageRoot` for a separate ignored test stage. Additional unbound arguments are forwarded through the stage builder's protected launch-argument path; attempts to override `-userdirectory` remain rejected. Non-RTX rebuilt presets also reserve `+EnhancedGore`: the launcher derives one exact `0/1` pair from the strict saved setting, so change the value in Gameplay options instead of supplying a free-form override. `-PrepareOnly` performs staging and initial-profile seeding but never starts `FEAR.exe`.

## Inputs and safety boundary

Only the `SdkSmoke` diagnostic uses the Public Tools runtime layout:

```text
vendor-local/fear-sdk-108/
  Runtime/FEARDevSP.exe
  Game/
  Redist/ (or Tools/) containing msvcp71.dll and msvcr71.dll
```

The official Public Tools 1.08 installer supplies those files. Keep them under `vendor-local`; they are ignored and must not be committed. The similarly named checked-in `FEAR/Dev/Runtime` is a Perseus Mandate development tree stamped `1.9.654.0`, so it is not a compatible base-game 1.08 runtime. The retail-backed `Rebuilt` lane does not read the SDK runtime or its VC71 redistributables.

The stock lane uses the already-downloaded pinned archive:

```text
vendor-local/EchoPatch-4.2.1.zip
size:   1,978,793 bytes
SHA256: 5AE9BF8F4D549B0F1CD682D63B4123C2BFF2622BD2035779DF263183C61BF9AE
```

The tool refuses another hash rather than downloading or substituting a release. It copies only the archive's root `dinput8.dll` and `EchoPatch.ini` into the disposable stock stage.

The first renderer option uses the locally downloaded official dgVoodoo2 package:

```text
vendor-local/renderer-deps/dgVoodoo2_87_3.zip
size:   9,082,391 bytes
SHA256: 6FB954BED55BF70E948C5045A663A9DF31EA206FAF105E327BAFE46C318F867F
```

`-RendererMode DgVoodooD3D11` validates that exact archive, its 32-bit x86 `MS/x86/D3D9.dll`, and the upstream config version before copying only the proxy as stage-local `d3d9.dll`. The project-owned [`config/dgVoodoo-d3d11.conf`](config/dgVoodoo-d3d11.conf) is staged as `dgVoodoo.conf` and selects D3D11 feature level 11. **Renderer quality: Native** uses `Resolution = unforced`; **Max 2x** uses `Resolution = max_2x`, which chooses dgVoodoo's largest desktop-based resolution with the app aspect ratio and then doubles each axis. Its internal target is therefore desktop-derived, not universally twice whichever lower mode is selected inside the game. Both profiles use `GeneralExt.Resampling = lanczos-3`; filtering, presentation, VSync, and the game's own effects remain app-driven. If Max 2x is too expensive or unsupported, selecting Native in game and relaunching restores the exact unforced profile. dgVoodoo2 is freeware under its own redistribution terms, not project source; the downloaded package stays ignored under `vendor-local`.

The optional CAS presentation layer is separately owned because it hooks dgVoodoo2's D3D11 output through stage-local `dxgi.dll`, not the D3D9 proxy position. `-PostProcessMode ReShadeCas` is accepted only with `Rebuilt` + `DgVoodooD3D11`; **Post-processing: Off** stages no ReShade proxy. The package validator requires the exact user-supplied signed x86 ReShade 6.7.3 installer and extracts the pinned 32-bit binary without committing or redistributing it. Immutable project shader/config/license inputs live under `.fearmore\postprocess`; user-tunable `ReShade.ini`, `FearMore-CAS.ini`, `ReShade.log`, and `Cache` remain runtime-mutable and survive safe restaging after first enable. The project CAS shader uses [AMD FidelityFX CAS](https://gpuopen.com/fidelityfx-cas/) logic as a conservative final-frame color sharpening pass. It does not access depth or motion vectors, scale the image, recover HDR range, or provide temporal antialiasing. ReShade's official site asks projects to link users to the [official installer](https://reshade.me/) rather than redistribute its binaries or downloaded shader collections, so the installer remains an ignored local prerequisite.

The live 3440 x 1440 Modern gate passed both renderer-quality profiles. Native rendered the rooftop gameplay path through dgVoodoo2's D3D11 output. The Max 2x + CAS run produced ReShade log evidence for a 6880 x 2880 D3D11 swapchain downsampled to 3440 x 1440, compiled `FearMoreCAS`, returned to correct gameplay after three alt-tab cycles, rendered the same rooftop path, and shut down cleanly. This accepts the wrapper, downsample, and conservative sharpening chain for representative gameplay; it does not claim complete campaign parity, true HDR, temporal reconstruction, DLSS, ray tracing, or a native D3D11 renderer.

The bounded RTX experiment uses the locally downloaded official runtime release:

```text
vendor-local/renderer-deps/remix-1.5.2-release.zip
size:   231,778,218 bytes
SHA256: CC424BE4DD1A0C6FD922BC6A7F8E5F6582BAEA7043A38AFA6686D8B6FAABAD01
```

`-RendererMode RtxRemixProbe` validates all 252 ZIP entries, rejects unsafe or Windows-ambiguous paths, checks required x86/x64 PE architecture and notice identities, and stages all 165 files required by NVIDIA's full-runtime layout. The schema-9 manifest hashes every immutable package file. A separate project-owned `.trex\bridge.conf` is validated and recorded through the renderer-config fields without pretending it is a 166th package file; the retained lab profile contains only `client.forceWindowed = True`. Reruns require the archive hash, file count, every package-owned path/size/hash, and that config hash to match. On a new RTX stage only, the tracked `config/rtx-remix-runtime.conf` creates runtime-owned `rtx.conf` with exactly `rtx.graphicsPreset = 4`, `rtx.integrateIndirectMode = 1`, and `rtx.dlfg.enable = False`. Custom is essential: Remix 1.5.2's default Auto preset selected High on the tested RTX 4070 and reapplied NRC after parsing the explicit ReSTIR value. An existing stage is never re-seeded: user/runtime edits and intentional `rtx.conf` absence both survive safe restaging. Launch planning separately permits unrelated edited settings, resolves Remix's higher-priority `user.conf` when present, requires the effective safe triple, and fingerprints both configuration layers again immediately before Steam dispatch. A missing setting, duplicate, Auto/non-Custom preset, another indirect mode, or enabled DLSS Frame Generation in either effective layer blocks launch. In live acceptance, `[RTX] Integrate Indirect Mode: ReSTIR GI - activated` is required and `NRC SDK: Loading the default network config data.` is a rejection signal. Selecting a stock non-Custom preset in Remix UI can re-enable NRC; returning to Custom does not necessarily restore ReSTIR automatically. Runtime-created `rtx-remix` settings/captures/mod data likewise survive reruns. A changed/missing owned file or Bridge config, any other unowned file under immutable `.trex`, a legacy incomplete manifest, or a writable-path type swap fails before stage mutation.

`RtxLab` combines that renderer with `RtxCameraDiagnosticEchoPatch`, the separately pinned focus-preserving query-light GPL-side diagnostic; `RtxBridgeLab` uses the separately pinned `RtxCameraReassertionEchoPatch` bounded experiment. The lower-level planner also retains historical `CameraDiagnosticEchoPatch` and synchronous `RemixDiagnosticEchoPatch` combinations for explicit developer traces; no-patch and ordinary `EngineOnlyEchoPatch` combinations fail planning. RtxLab's 2026-07-15 controlled run used a genuinely windowed 3440 x 1440 surface, rendered the legal screen, frontend, and load screen, then armed from the rebuilt source-camera marker and preserved the first mission frame: 92 shader draws, 54,342 primitives, 29 shader records covering 26 unique shaders, 201 constant writes / 56,816 payload bytes, and three transform records. The x64 Bridge then raised an access violation in `nvoglv64.dll` while `NRC_Vulkan.dll` was active; the last Remix log line was loading the default Neural Radiance Cache network. This occurred during first gameplay rendering independently of alt-tab. Source and log inspection showed that Auto -> High, rather than the documented mode-1 value itself, was the owner that re-enabled NRC. The corrected Custom + ReSTIR + DLSSG-off stage is preserved but has not passed mission entry. RTX work is now parked; this is not proof that Remix captures a complete scene/camera or that path tracing/DLSS is usable. `Test-FearRemixCameraProbe.ps1` remains available for future lower-level traces. The archive, extracted stages, dumps, and captures stay ignored and are never redistributed by this repository.

[`Invoke-FearRemixExperiment.ps1`](Invoke-FearRemixExperiment.ps1) owns controlled one-setting renderer A/B sessions after an exact RtxLab stage and its retail sidecars are installed. `Control` temporarily replaces Remix's higher-priority `user.conf` with only the required Custom/ReSTIR/DLSSG-off safety triple; `Candidate` adds exactly one allowlisted compatibility setting. The script writes a durable intent journal and verified byte-exact backup, launches through the existing immutable Steam plan, waits for the exact observed F.E.A.R. process to exit, and restores the original `user.conf` (or its original absence) in `finally`. Normal RtxLab launch is blocked while this transaction is active. A game, terminal, Codex, or PC interruption leaves recovery evidence rather than silently adopting the experiment as user state; after F.E.A.R. is no longer running, use `-Recover` against the same retail root. `user.conf` remains outside the sidecar package and schema-9 `rtx.conf`-only mutable-file contract.

```powershell
# Identical Docks control and candidate runs, with a full process restart between them.
.\tools\runtime\Invoke-FearRemixExperiment.ps1 -Experiment AlphaBlendOff -Variant Control -StageRoot '.\local-runtime\fearmore-launcher-rtx-query-light-restir-custom-focus-preserved-d9d8-lab' -RetailRoot 'D:\path\to\FEAR'
.\tools\runtime\Invoke-FearRemixExperiment.ps1 -Experiment AlphaBlendOff -Variant Candidate -StageRoot '.\local-runtime\fearmore-launcher-rtx-query-light-restir-custom-focus-preserved-d9d8-lab' -RetailRoot 'D:\path\to\FEAR'

# Restore a transaction retained after the controlling PowerShell process stopped.
.\tools\runtime\Invoke-FearRemixExperiment.ps1 -Recover -RetailRoot 'D:\path\to\FEAR'
```

The bounded experiment names are `WhiteMaterialOff`, `AlphaBlendOff`, `VertexCapturedNormalsOff`, `SkyAutoDetect2`, `WorldMatricesOff`, `EmissiveOverrideOff`, `EmissiveTranslationOff`, and diagnostic-only `LegacyAlbedoDiagnostic`. A setting becomes part of the production compatibility baseline only after repeatable control/candidate evidence across representative scenes; the transient `user.conf` is never that production layer.

`CameraLab` is the native query-light control lane. It pairs `NativeD3D9` only with `CameraDiagnosticEchoPatch`, fixes the profile at 60 FPS with dynamic VSync, rejects an explicit `-MaxFPS`, and stages no dgVoodoo/Remix marker. The package validator hard-pins the outer manifest, DLL, and merged profile, then checks the declared hashes, exact mode/diagnostic proof, x86 PE identity, disabled game-module hooks, and current tracked patch, overlay, base-profile, and override hashes. The launcher owns `+FearMoreCameraDiagnostics 1`; callers cannot override that cvar. Captures are written beneath the isolated `UserDirectory\FearMoreDiagnostics` as `camera-d3d9-<pid>.jsonl`, and safe stage reruns preserve that directory. The paired live control completed 3,600 normal-gameplay frames at 3440 x 1440 / 59.959 FPS, observed 39 unique shaders, recovered all 2,811 constant samples, and matched all 24 eligible source projection transforms. This remains observation: it does not mirror matrices into D3D9 state or claim Remix scene compatibility.

[`Analyze-FearCameraCapture.ps1`](Analyze-FearCameraCapture.ps1) is the read-only CameraLab evidence consumer. Give it a D3D9 JSONL and, once the same process reaches the rebuilt main-camera path, the matching source JSONL. It requires exactly one `arm` record, all eight successful hook flags, schema/PID/QPC-frequency consistency on every record, and monotonic frame order before interpreting evidence. It then reports source-camera translation/orientation variation, identifies setter samples inside the authoritative render bracket or bounded post-submit frame window, validates whether full constant values are recoverable from inline data or the sidecar, numerically compares fixed-function view/projection writes with the source camera, and uses an installed Windows SDK `fxc.exe` to map dumped shader CTAB names to registers. Shader attribution remains provisional because the capture deliberately does not query state after D3D9 state-block application; a numeric source match is the acceptance gate. In the source JSONL, each successful projection probe stores normalized viewport coordinates in `screen_normalized_xy` and the distinct camera-depth result in `camera_z`; the old three-component `screen_normalized` field is not emitted. `Test-FearLauncherProfile.ps1` separately owns fresh-profile resolution/GameRuns transaction coverage and byte-for-byte preservation checks for existing profile files.

The source probe now emits schema 2 for that field split. The analyzer remains read-compatible with schema 1 captures recorded before the split, while rejecting a file that mixes versions between records.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '.\tools\runtime\Analyze-FearCameraCapture.ps1' -D3D9Path '.\local-runtime\fearmore-launcher-native-camera-lab-armed\UserDirectory\FearMoreDiagnostics\camera-d3d9-1234.jsonl' -SourcePath '.\local-runtime\fearmore-launcher-native-camera-lab-armed\UserDirectory\FearMoreDiagnostics\camera-source-1234.jsonl' | ConvertTo-Json -Depth 8"
```

`-EnginePatchMode EngineOnlyEchoPatch` consumes only the pinned local derivative built by [`../echopatch/Build-EngineOnlyEchoPatch.ps1`](../echopatch/Build-EngineOnlyEchoPatch.ps1). Its manifest, x86 PE identity, binary/config hashes, `PatchGameModules=0` compatibility proof, and safety-disabled game-module hooks are checked before staging. The default profile remains `MaxFPS=60` with `DynamicVsync=1`. An explicit `-MaxFPS 30..300` changes only the staged cap and forces `DynamicVsync=0`, making capped-FPS profiling independent of EchoPatch's dynamic VSync cadence. It does not enable EchoPatch's mixed client/server/ClientFX high-FPS patch family.

The runtime workflow now has focused read-only boundaries. `FearRuntimeExecutable.psm1`, `FearRendererPackage.psm1`, `FearEnginePatchPackage.psm1`, and `FearTexturePackage.psm1` parse PE/package/config/content identity and recognize pinned inputs. `FearLauncherSettings.psm1` owns strict consumption of launcher-relevant in-game settings, including the world-load-bound Enhanced Gore selection and restart-bound HD/renderer selections, plus the ignored local registration schema. `FearRuntimeStagePlan.psm1` owns renderer/engine-patch compatibility, default package paths, deterministic stage names, required/forbidden renderer paths, mutable RTX paths, explicit-versus-omitted frame-cap policy, and the complete Rebuilt ordinary-file mutation inventory. `FearRuntimeStageOwnership.psm1` owns existing manifest, runtime executable, proxy, immutable payload, Steam-hint, and completed package-layout validation. Both it and the stage write orchestrator reuse `FearRuntimeStageSafety.psm1` for canonical path, containment, ordinary-file/directory, exact read-only mounts, and reparse-tree checks. `New-FearRuntimeStage.ps1` remains the sole disposable-stage write orchestrator: every stage directory creation, copy, extraction, config edit, junction, removal, ownership transaction, and optional stage process launch occurs only after its single `ShouldProcess` boundary. Retail Remix deployment is a separate focused boundary: `FearRetailSidecarPackage.psm1` owns read-only package/install-state planning, `Install-FearMoreRetailSidecars.ps1` owns transactional install/uninstall/recovery/receipt retirement beside retail, and `FearSteamLaunch.psm1` owns the live-config-safe immutable launch plan, exact same-session Steam preflight, dispatch, and independent retail-process observation.

Retail archives are not copied or modified by the staging tool. A retail-backed stage contains one intentional, exact-target `Retail` directory junction that the workflow treats as read-only, plus a generated `Default.archcfg` whose entries stay inside that junction. Full HD mode may add one separately manifest-owned `HDTextures` junction to the already validated local DDS tree. A Windows junction does not itself apply a read-only ACL; every tool-owned write target explicitly rejects both mount subtrees. Every other existing component from `local-runtime` through the stage and every generated directory/file target must be an ordinary path, not a symbolic link, junction, or other reparse point. The tool scans the stage tree before mutation, attests the exact target of each existing mount, validates each write/removal target, scans the completed layout, and repeats the check immediately before an optional launch. An unexpected `Game`, `UserDirectory`, StageRoot, mount, or intermediate link fails closed. The deliberate RtxLab exception installs only exact manifest-backed sidecars, rebuilt modules, and a generated `FearMore.archcfg` beside registered retail; `FEAR.exe`, `Default.archcfg`, and retail archives are hash-protected and never replaced. An install record owns reversible removal, `rtx.conf` remains mutable and is preserved when edited, unfinished transactions recover or fail closed, and any active F.E.A.R. process blocks retail mutation.

Required retail bootstrap DLLs and `FEAR.exe` are copied into both disposable retail-backed stages, leaving the owned installation untouched. Public Tools `Documentation/General.chm` defines a folder-form `Runtime\Game` as a valid archive and documents retail mod startup as `FEAR.exe -archcfg MyMod.archcfg`; the `Rebuilt` lane follows that ownership model with the staged `Game` folder and generated archive config. Its default stage contains no proxy. The explicit engine-only mode may own the pinned `dinput8.dll` derivative, and the explicit renderer mode may own the pinned `d3d9.dll`; full stock EchoPatch is still forbidden with rebuilt modules. `SdkSmoke` copies only its redistributable support files and mounts only the rebuilt `Game` folder; it accepts neither optional proxy and does not link the SDK `Game` tree into the writable stage.

[Steamworks' initialization documentation](https://partner.steamgames.com/doc/sdk/api) specifies `steam_appid.txt` as the development hint when an executable runs outside Steam's normal launch context. A retail root is treated as Steam only when its executable matches the pinned Steam v1.08 hash or its `steamapps` manifest identifies App ID `21090` and the same install directory. Disposable stages receive an ASCII `steam_appid.txt` whose complete contents are `21090`. This is local-only: it is Git-ignored with the stage, must never be included in a release, still requires the Steam client under the same Windows user and an owned license, and does not replace ownership of the game. RtxLab's retail path is stricter: its appmanifest must bind App ID 21090 to that exact retail directory, and it dispatches through the exact running same-session `steam.exe -applaunch 21090`; the hint file is not accepted as a substitute. The schema-9 manifest records explicit tool ownership, the absolute hint path, exact controller/runtime/license and proxy/config or multi-file renderer identities, runtime-executable state, and optional HD-content identity/mount ownership. A rerun preserves or removes an existing hint only when those records and its current bytes agree (with narrow migrations for earlier owned native/no-patch stages); otherwise it fails before changing any stage file. GOG/portable roots and `SdkSmoke` do not receive a new hint. They remove only an exact previously tool-owned hint and leave an unowned or changed file untouched with a blocking error. Hint creation/removal and manifest replacement use one rollback transaction; fixed `.ownership.new`/`.ownership.previous` recovery files block later runs before mutation if cleanup or interruption prevents a complete commit.

Every existing Rebuilt-stage restage now adds one outer preimage journal over the complete planned mutation surface: runtime executable, archive config, retail bootstrap files, obsolete SDK files, rebuilt modules and ClientFX archive, renderer and post-process payloads, engine-patch proxy/config, optional HD mount, exact Retail-junction target, and the required directory set. Present files are copied and hashed; absent files and directories are recorded explicitly. Recovery validates the prior manifest, every backup, target type, ordinary-directory boundary, and exact mount targets before restoring prior bytes, junctions, or absence. User/runtime directories are preserved and never recursively replaced; rollback removes only journal-proven empty directories and otherwise fails closed. The verified ownership-manifest install is the commit point, and fixed transition marker/backup paths block later mutation if recovery or cleanup is interrupted. This keeps Native/Max 2x, Off/CAS, HD Full/Off, renderer, and rebuilt-module refreshes under the same guarded filesystem-mutation boundary without traversing private asset mounts or lane-local saves.

`BootstrapRequired` and its warning apply to every unpatched `StockEchoPatch` executable that still needs EchoPatch's Large Address Aware step, not only to Steam inputs. On the pinned Steam `.bind` input, EchoPatch's authenticated path creates `FEAR.exe.bak`, writes a private LAA executable, and automatically restarts. Upstream restarts without preserving this tool's `-userdirectory` and `-archcfg` arguments, so the staging tool refuses its ordinary isolated `-Launch` while bootstrap is required and does not claim profile isolation for that restart. `Invoke-FearLaaBootstrap.ps1` is the narrow guided exception: it prepares the disposable stock stage, explains the one-time owner prompt, launches only that local copy, and accepts success only after `FearRuntimeExecutable.psm1` attests the backup against retail and the patched executable as the expected header-only LAA derivative. Only that attested private pair becomes launchable through the normal tool; neither executable may be redistributed.

Subsequent stock restaging preserves only an attested x86 PE32 EchoPatch pair. The backup must byte-match the selected retail executable, and the LAA executable must match either EchoPatch's exact header-only transformation or the pinned Steam v1.08 input/output hashes. An unknown derivative is rejected before any stage mutation. `-RefreshRuntimeExecutable` explicitly replaces an ordinary stage-local executable/backup pair with the selected retail executable; it is stock-only and returns the stage to its bootstrap-required, launch-blocked state. Refresh is transactional: the selected retail executable is copied and verified first, the prior executable pair is moved to fixed recovery names, the replacement is attested, and the prior pair is deleted only after commit. A pre-commit failure restores the old pair. Any existing `FEAR.exe.refresh.new`, `FEAR.exe.refresh.previous`, or `FEAR.exe.bak.refresh.previous` blocks a later run before mutation so the recovery state can be inspected manually. Reparse points and non-file targets remain unrecoverable safety failures.

Renderer and engine-patch selection are orthogonal but fail-closed. Each nondefault combination receives a separate default stage root and manifest identity. A native stage rejects a stray `d3d9.dll`/`dgVoodoo.conf`; a no-patch rebuilt stage rejects `dinput8.dll`/`EchoPatch.ini`; and reruns verify every managed proxy/config against the prior manifest before overwriting it. dgVoodoo2 and engine-only EchoPatch coexist because they own different proxy filenames, and that Modern combination has passed representative 3440 x 1440 startup, gameplay, focus-recovery, and shutdown acceptance. ReShade CAS is a separately validated D3D11-output layer at `dxgi.dll`; it remains optional and can be removed through the in-game Off setting on the next launch.

The ordinary engine-only package is rebuilt locally from an exact EchoPatch commit, MinHook commit/archive, tracked compatibility patches, profile, Release/x86 mode, and v143 toolset. Its validator requires those exact source identities, a clean-submodule build record, x86 PE32 output, and manifest-to-binary/config coherence. It does not require one historical output hash because MSVC's rebuilt MinHook/EchoPatch artifacts are not byte-identical across clean builds. Parked camera/RTX diagnostic packages retain their separate fixed binary identities.

The parked RTX probe is the deliberate exception to renderer/engine-patch orthogonality: it accepts only the separately pinned `CameraDiagnosticEchoPatch`, synchronous `RemixDiagnosticEchoPatch`, focus-preserving `RtxCameraDiagnosticEchoPatch`, or bounded `RtxCameraReassertionEchoPatch` derivatives and rejects no-patch, ordinary engine-only, and unrelated proxy combinations. Its 165-file package payload, separately attested `.trex\bridge.conf`, and diagnostic DLL/config are immutable and exactly manifest-owned. `rtx.conf`, `rtx-remix`, and bounded camera traces remain runtime-mutable; the source-owned config is a new-stage-only seed, never restage ownership. The Steam launch plan nevertheless performs a read-only semantic safety check and fingerprints the full current retail `rtx.conf`, so preservation of user edits cannot silently restore Auto/NRC or DLSS Frame Generation. Native and dgVoodoo stages reject RTX markers, and switching renderer modes always requires a different stage directory. Keeping this isolated lab available does not make it part of the accepted launcher path or claim a working RTX feature.

Archive declarations are intentionally ordered as retail resources, rebuilt `Game`, then optional `HDTextures`. Both runtime file managers insert newly declared resource trees at the front of their search lists, then search from the front: the client path is implemented by `CClientFileMgr::AddResourceTrees`/`OpenFile` in `FEAR/Dev/Source/runtime/client/src/client_filemgr.cpp`, while the server path uses `CServerFileMgr::AddResources`/`OpenFile2` in `FEAR/Dev/Source/runtime/server/src/server_filemgr.cpp` and the front-inserting circular list in `FEAR/Dev/Source/runtime/lithtemplate/ltt_list_circular.h`. Search precedence is therefore the reverse of declaration order: rebuilt files override retail, and an explicitly selected HD DDS file overrides both without copying into or changing either source tree.

## Profile and save isolation

StockEchoPatch and Rebuilt each use a `UserDirectory` folder directly beneath their own stage. This keeps profiles, configuration, working saves, checkpoints, quicksaves, and manual saves from crossing between the stock and rebuilt game-code lanes. The staging tool creates and preserves that directory, refuses a junction or symbolic link at the location, and records its absolute path in both the returned summary and `fearmore-stage.json`. `SdkSmoke` remains non-launching and records no UserDirectory or launch arguments.

The tool does not silently import profiles or saves from the retail game's shared default directory. If an existing save is intentionally copied into a lane, keep the original backup and acceptance-test it in that lane; subsequent staging reruns preserve files already inside the lane's UserDirectory.

The user root must be selected by the engine-level dash switch during startup, before client-shell initialization can touch the default Public Documents location. The checked-in runtime documentation describes `-userdirectory (path)`, while `CGameClientShell::OnEngineInitialized` in `FEAR/Dev/Source/FEAR/ClientShellDLL/GameClientShell.cpp` consumes the selected `UserDirectory`, passes it to `LTFileOperations::SetUserDirectory`, and creates `Save` beneath that root. `FEAR/Dev/Source/FEAR/Shared/ProfileUtils.cpp` resolves `Profiles` from the same user root. A live retail diagnostic proved that the superficially similar `+UserDirectory` console-variable form is applied too late and can still create or use the default shared profile/save tree. Therefore the isolation switch is intentionally first in the client launch:

```text
FEAR.exe -userdirectory "<absolute-stage-path>\UserDirectory" -archcfg Default.archcfg
```

For RtxLab, the validated plan preserves the same early profile selection but targets the retail-installed archive configuration through Steam:

```text
steam.exe -applaunch 21090 -userdirectory "<absolute-RtxLab-stage>\UserDirectory" -archcfg FearMore.archcfg +FearMoreCameraDiagnostics 1
```

Do not copy that line as a bypass: the launcher first verifies the stage, reversible retail-sidecar install, live safe `rtx.conf`, registered appmanifest, exact Steam executable/session, and absence of an already-running retail game.

Additional launch arguments are allowed, but the tool rejects `-userdirectory`, `+UserDirectory`, and bare `UserDirectory` as overrides, including their `name=value` spellings, so lane isolation cannot be bypassed accidentally. It likewise reserves both space-separated and `name=value` forms of `+FearMoreHDTexturesActive` and `+FearMoreCameraDiagnostics`; only validated launcher/stage modes may append those owned values. Similar but distinct variable names remain valid additional arguments.

### AI profile summaries

[`Get-FearAiProfileSummary.ps1`](Get-FearAiProfileSummary.ps1) is a read-only, dependency-free consumer for the rebuilt server's `AIProfile.csv` output. It never stages, edits, or deletes a capture. From PowerShell, pass one or more files and optionally change the default five-second warmup:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '.\tools\runtime\Get-FearAiProfileSummary.ps1' -Path @('local-runtime\fearmore-ai-profile-60\UserDirectory\AIProfile.csv','local-runtime\fearmore-ai-profile-120\UserDirectory\AIProfile.csv','local-runtime\fearmore-ai-profile-144\UserDirectory\AIProfile.csv','local-runtime\fearmore-ai-profile-240\UserDirectory\AIProfile.csv') -WarmupSeconds 5 | Format-Table -AutoSize"
```

The returned objects expose stable duration, achieved FPS, FPS/frame/server percentiles, AI-active-frame ratio, and AI/sensor/goal/navigation update rates. Numeric fields are parsed with invariant culture; missing columns, invalid numbers, negative timings, or captures with no stable positive frame interval fail closed. Captures produced before the high-resolution timer correction in `AIProfiler` remain useful for cadence and update counts, but their sub-millisecond CPU values are quantized and must not be used for CPU attribution.

## Create and validate stages

Automatic retail discovery checks Steam app `21090`, configured Steam libraries, GOG and uninstall registry entries, and standard game directories. Use an explicit path for a portable or unusual installation.

```powershell
# Stock retail modules plus pinned EchoPatch.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/New-FearRuntimeStage.ps1 -Lane StockEchoPatch

# Stock lane with 2x internal width and height (4x the native pixel workload).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/New-FearRuntimeStage.ps1 -Lane StockEchoPatch -SSAAScale 2.0

# Explicitly discard an attested stock LAA derivative and return to the launch-blocked bootstrap state.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/New-FearRuntimeStage.ps1 -Lane StockEchoPatch -RefreshRuntimeExecutable

# Disposable retail launcher plus rebuilt Release modules, native D3D9 and no patch by default.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/New-FearRuntimeStage.ps1 -Lane Rebuilt

# Rebuilt modules through the pinned dgVoodoo2 x86 D3D9 -> D3D11 FL11 proxy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/New-FearRuntimeStage.ps1 -Lane Rebuilt `
  -RendererMode DgVoodooD3D11

# Rebuilt modules with the pinned engine-only EchoPatch derivative at an explicit profiling cap.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/New-FearRuntimeStage.ps1 -Lane Rebuilt `
  -EnginePatchMode EngineOnlyEchoPatch -MaxFPS 120

# Combined D3D11 renderer and engine-only patch; each proxy remains separately owned.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/New-FearRuntimeStage.ps1 -Lane Rebuilt `
  -RendererMode DgVoodooD3D11 -EnginePatchMode EngineOnlyEchoPatch -MaxFPS 120

# Same D3D11 lane with opt-in 2x downsampling and the signed local CAS layer.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/New-FearRuntimeStage.ps1 -Lane Rebuilt `
  -RendererMode DgVoodooD3D11 -EnginePatchMode EngineOnlyEchoPatch `
  -RendererQuality Max2x -PostProcessMode ReShadeCas -MaxFPS 144

# Full RTX Remix 1.5.2 payload plus the query-light bounded camera diagnostic.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/New-FearRuntimeStage.ps1 -Lane Rebuilt `
  -RendererMode RtxRemixProbe -EnginePatchMode CameraDiagnosticEchoPatch

# Native D3D9 query-light camera diagnostic at its fixed 60 FPS policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/New-FearRuntimeStage.ps1 -Lane Rebuilt `
  -RendererMode NativeD3D9 -EnginePatchMode CameraDiagnosticEchoPatch

# Explicit retail root.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/New-FearRuntimeStage.ps1 -Lane Rebuilt `
  -RetailRoot 'X:\Games\F.E.A.R. Platinum Collection'

# SDK-only loader/module staging check while retail is unavailable.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/New-FearRuntimeStage.ps1 -Lane SdkSmoke

# Validate inputs and dependencies without writing a stage.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/New-FearRuntimeStage.ps1 -Lane Rebuilt -ValidateOnly
```

The default outputs are separate directories below `local-runtime`:

- `fearmore-stock-echopatch`
- `fearmore-rebuilt-release` or `fearmore-rebuilt-debug`
- `fearmore-rebuilt-release-dgvoodoo-d3d11`, `fearmore-rebuilt-release-engine-only-echopatch`, `fearmore-rebuilt-release-camera-diagnostics`, the combined suffix, or `fearmore-rebuilt-release-rtx-remix-probe-1-5-2-camera-diagnostics` when those explicit modes are selected
- `fearmore-sdk-smoke-release` or `fearmore-sdk-smoke-debug`

Debug stages require the Visual Studio x86 debug CRT and are developer-only. Use a Release stage for distributable builds and player testing.

The script only updates a directory carrying a matching `fearmore-stage.json`. It refuses nonempty unowned directories, stages belonging to another lane/renderer/engine-patch identity, unsafe reparse points, archive-config paths that escape the retail root, wrong-version executables/modules, non-x86 or non-PE32 runtime executables/modules/proxies, unknown stock executable derivatives, unowned or changed Steam hints, and stray or changed proxy/config files.

When an owned Rebuilt stage from the earlier development-executable layout is reused, the tool removes only its known generated SDK runtime files before copying the retail launcher. Other files in that owned stage are left untouched.

`-SSAAScale` is a stock-lane-only value from `1.0` through `4.0`. Its default is `1.0` (native rendering) to preserve performance. The script verifies the pinned EchoPatch archive first, extracts a fresh `EchoPatch.ini`, and changes only the staged `SSAAScale` setting; it never edits the archive or the retail installation. Complete native acceptance first, then profile `1.25` and `1.5` before trying `2.0`; scaling both dimensions to `2.0` produces four times the native pixel workload and is an optional quality ceiling rather than the starting profile.

The pinned INI also keeps `FixNvidiaShadowCorruption = 1`, `FixAspectRatioBlur = 1`, `HighResolutionReflections = 1`, `HUDScaling = 1`, `AutoResolution = 1`, and `DisableLetterbox = 0`. The integration test verifies that the disposable stock stage preserves this modern-display baseline. These settings are necessary inputs, not proof of gameplay correctness.

The required manual resolution pass is 1920 x 1080, 2560 x 1080, **3440 x 1440**, 3840 x 1600, and 5120 x 1440. Gameplay must preserve vertical FOV and reveal more horizontally; HUD, subtitles, menus, mouse hit regions, zoom, slow motion, post effects, shadows, and reflections must remain usable. Pre-rendered video may be centered with black bars and must never stretch or crop. See [the modern rendering acceptance plan](../../docs/modern-rendering.md).

Pass `-Launch` only after reviewing the returned stage summary:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/New-FearRuntimeStage.ps1 -Lane Rebuilt -Launch
```

The rebuilt launch is `FEAR.exe -userdirectory "<stage>\UserDirectory" -archcfg Default.archcfg` with the disposable stage as its working directory, combining the engine's early user-root switch with the Public Tools mod-launch pattern. The non-RTX one-click presets append their launcher-owned `+EnhancedGore 0/1` pair so the saved Gameplay selection reaches the local server on world load. HD modes additionally supply the launcher-owned, non-persisted `+FearMoreHDTexturesActive 1/2` marker for Lite/Full so in-game help can distinguish the saved selection from the active mount. CameraLab similarly appends its reserved `+FearMoreCameraDiagnostics 1` marker after the isolated user-directory switch. The returned `LaunchArguments` and `LaunchArgumentString`, plus the schema-9 manifest, show the exact invocation before launch.

The state fields are deliberately separate. `RuntimeExecutableState` is `RetailOriginal`, `EchoPatchedLAA`, `AttestedLAAForHdTextures`, `SdkDiagnostic`, or `NotStaged`; `BootstrapRequired` identifies the stock first-launch LAA step, and `BootstrapNote` records its restart/argument warning. Lite and Full are Rebuilt-only and require an already attested private EchoPatch LAA executable/retail-backup pair; Off restores the selected retail executable in the disposable stage. The manifest also records the selected mode, retail/runtime/backup hashes, Steam-hint ownership, texture digest, file count, source root, exact mount target, and active-marker state. `InputsValidated` means the lane-specific source binaries, versions, x86 PE32 architecture checks, pinned inputs, and explicitly tested dependencies passed inspection; it is not a claim that every Windows runtime component has been exercised. `LayoutValidated` means a stage was written and its completed layout passed inspection; it remains false for `-ValidateOnly`. `LaunchPermitted` is only a policy gate: it is true for Rebuilt and for StockEchoPatch only after the executable/backup pair passes attestation; it is false for unbootstrapped StockEchoPatch and always false for SdkSmoke. It does not promise that process startup will succeed on a particular PC. `RendererCompatibilityStatus = LiveAcceptedDgVoodooD3D11` and `PostProcessCompatibilityStatus = LiveAcceptedDgVoodooDxgiChain` record the separate representative project-level live passes. `AcceptanceTested` and `PostProcessAcceptanceTested` remain false on every staging result because that individual invocation did not itself prove menus, campaign, saves, AI, damage, ClientFX, image quality, or clean shutdown; `AcceptanceNote` states that scope explicitly.

## Verification

The focused AI timing checks keep source ownership separate from live encounter evidence:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-AiTimingSource.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-FearAiEncounterAcceptance.ps1
```

`Test-AiTimingSource.ps1` protects the frame-synced/default scheduler, positive-interval rollback, intentional no-update paths, update order, sever wakeup, profiler wiring, processed-stimulus serializer symmetry, and flame-pot save compatibility without launching the game. `Test-FearAiEncounterAcceptance.ps1` uses synthetic profiles to protect the read-only encounter analyzer's bounded crop, dynamic/fixed population handling, starvation visibility, owner invariants, target-FPS pass plus below/above-band rejection, frozen/jumped simulation-timestamp rejection, percentiles, and malformed/short-capture rejection.

The related `CAISensorMgr::Save` repair keeps the inherited count-plus-elements wire layout but writes each actual processed stimulus ID instead of repeating the list size for every element. It needs no save-version bump: older malformed values remain consumable by the unchanged integer loader, while new saves preserve the intended IDs.

Analyze a real contiguous combat window separately:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Get-FearAiEncounterAcceptance.ps1 `
  -Path local-runtime/fearmore-ai-d3d11-120/UserDirectory/AIProfile.csv `
  -WarmupSeconds 45 -EncounterSeconds 30 -TargetFps 120
```

`-TargetFps` adds a combined cap-and-invariant `AcceptanceStatus` using `-FpsTolerancePercent` (five percent by default); omit it to retain invariant-only analysis. The live dgVoodoo2 D3D11 `ATC_Roof` gate passed the combined acceptance band and dynamic-population invariants with a simulation/wall ratio near 1.0, 100% AI-active frames, and zero starvation at measured 60.000, 119.909, and 143.901 FPS on 3440 x 1440. A 640 x 480 diagnostic reached 237.541 FPS, within five percent of the 240 cap; the earlier 3440 x 1440 240-cap attempt was renderer-limited near 185 FPS, so the low-resolution row is scheduler evidence only. Enemies visibly reacted, fired, used authored movement/cover, progressed through the encounter, and killed the unattended player in every run. Bidirectional 60-to-240 and 240-to-60 quick-save loads also resumed active AI and passed 30-second profiler windows; the load-side 240 and 60 measurements were 229.425 and 60.000 FPS respectively. This is a representative four-cap live matrix, not proof of every continuous frame rate. See `docs/ai-timing.md` for the exact matrix, save-hash preservation evidence, analyzer boundaries, and remaining retail-interval/flame-pot follow-ups.

The focused Enhanced Gore source check protects the server default-off/Modern-default-on boundary, persisted Gameplay toggle and stock-gore precedence, schema-283 save/load ordering, legacy imprecise-mask boundary, targeted zero-force replay, post-resolution client de-duplication, dispatch-scoped projectile node context, and the finite local-single-player runtime-control allowlist without launching the game:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-EnhancedGoreSource.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-CorpsePersistenceSource.ps1
```

The world-persistence check additionally executes the radius/total overlap model that previously under-evicted, and protects stock Off passthrough, the 4096/24/48 corpse bounds, the 512/256/256/200/16 effect ceilings, shared Gameplay setting, new-profile-only Modern seeding, strict multiplayer gore gate, and disabled EchoPatch game/world hooks. These are intentionally static ownership/order and script-model tests, not substitutes for the documented live body/effect-budget, visual-sever, rapid-fire, gore-disabled, and save/reload acceptance pass.

The focused ultrawide-cinematic check protects the existing gameplay/`CT_FULLSCREEN` Hor+ projection and the shared centered-aspect primitive used by the narrow ATC correction:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-UltrawideCinematicSource.ps1
```

The problematic helicopter shot is not owned by a `CT_LETTERBOX` CameraFX. It is a scripted `PlayerLure` sequence that animates `Heli_Sit`, disables the crosshair, and enables follow-lure behavior. The source correction requests centered 16:9 side masks only while that exact authored state is active; ordinary gameplay, interactive lures, and every live CameraFX remain full-width. A 3440 x 1440 Modern Max 2x + CAS replay confirmed 440-pixel side masks, no exposed duplicate actors, and automatic return to full-width checkpoint gameplay. The unattended player later died to the authored rooftop combat wave after the valid checkpoint; profile timing and level scripts exclude the presentation-only mask, `Max2x`, and CAS paths as owners. Native, ordinary campaign-entry, skip/restart, and unrelated-cinematic coverage remain open.

The focused remaster-control and post-process checks protect the in-game profile mappings, source-owned effects-target scaling, performance-record preset, signed local ReShade extraction, immutable/mutable file split, and transactional Off/CAS staging:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-ModernDisplaySource.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-EffectsTargetQualitySource.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-RemasterQualitySource.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-FearLauncherRendererQuality.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-FearPostProcessPackage.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-FearPostProcessStage.ps1
```

These automated checks prove ownership, mapping, fallback, and rollback behavior. The remaster-quality source check also protects the active-profile resolution seed that prevents stale bootstrap dimensions from being committed with the preset. The separate live gate supplied the runtime evidence: 3440 x 1440 Native and Max 2x gameplay, a logged 6880 x 2880 D3D11 swapchain downsample, successful `FearMoreCAS` compilation, three alt-tab recoveries, rooftop rendering, and clean shutdown.

The focused staging-architecture check parses the modules and orchestrator, verifies every imported read-only module and its exact export surface, rejects command/alias/static-I/O/stream mutators from those modules, derives mutating local wrappers through the orchestrator call graph, proves moved functions are absent, enforces one fail-closed `ShouldProcess` boundary before every top-level mutator entry point, preserves explicit-bound package and `-MaxFPS 60` semantics, and snapshots successful and rejected ownership checks to prove they do not mutate:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-FearRuntimeStageArchitecture.ps1
```

The base integration check exercises all three established lane layouts without launching the game:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-FearRuntimeStage.ps1
```

The base test uses an ignored synthetic retail-shaped fixture even when a user-owned installation is available. It verifies the documented early `-userdirectory` syntax, rejection of both override spellings, distinct non-redirecting stage roots, quoted paths containing spaces, schema-9 executable/Steam/validation state, non-mutating `-WhatIf` behavior for both new and existing owned stages, exact and explicitly owned `steam_appid.txt` contents, no-mutation rejection of unowned/changed hints in Steam, non-Steam, and `SdkSmoke` stages, transactional hint create/remove rollback, interrupted ownership-commit rejection, removal of an exact previously owned stale hint, unbootstrapped stock launch rejection, manifest/result launch arguments, preservation and transactional refresh of an attested LAA pair, no leftover refresh files after success, exact rollback after a mid-transaction failure, no-mutation rejection of interrupted recovery state, rejection and explicit refresh of an unknown executable derivative, x64-runtime rejection, preservation of an existing staged save across reruns, Rebuilt's lack of an SDK runtime dependency, SdkSmoke's non-launching state, native/no-patch defaults, archive priority, module hashes, stock EchoPatch modern-display settings, Git ignore coverage, and byte-for-byte protected inputs. Adversarial cases place both `Game` and StageRoot junctions over external sentinel directories and prove rejection without mutation. When the local pinned Steam retail executable and attested EchoPatch stage are both available (or are passed explicitly), the same test also exercises the real `.bind` input/output branch; otherwise that local-only check is reported as skipped.

The focused renderer/package suite is separate so proxy ownership and package corruption cases do not make the base lane test a catch-all:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-FearRendererStage.ps1
```

It verifies pinned dgVoodoo2, RTX Remix 1.5.2, engine-only EchoPatch, and Remix-diagnostic EchoPatch package identity; Native/Max 2x resolution and Lanczos-3 mappings; safe renderer-quality restaging; x86/x64 PE layout; ZIP-slip/Windows path rejection; exact 165-file RTX package ownership; separate immutable Bridge-config ownership; runtime-mutable path preservation; the exact Custom/ReSTIR/DLSSG-off seed; acceptance of unrelated live settings; rejection of an edited Auto/NRC path; native schema migration; rejection of legacy/incomplete RTX manifests, missing or changed config ownership, a different archive identity, a same-count changed owned-path set, other unowned `.trex` files, changed owned files, corrupt packages, mode mismatch, and proxy stacking; x86 proxy coexistence; frame-cap semantics; Git-ignore coverage; and byte-for-byte protected inputs. The separate post-process suites cover signed local ReShade extraction, exact CAS assets, Off/CAS compatibility, first-enable seeding, mutable-state preservation, and rollback. Synthetic suites do not launch F.E.A.R.; the live acceptance evidence is recorded separately and does not claim path tracing, true HDR, temporal reconstruction, or native renderer parity.

The retail installer and Steam dispatch have separate disposable-fixture suites:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-FearRetailSidecarInstall.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-FearSteamLaunch.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-FearRemixExperiment.ps1
```

They cover exact sidecar ownership, transactional rollback/recovery, edited or missing mutable-config preservation, protected retail originals, appmanifest binding, robust Windows argument quoting, owned-argument rejection, exact Steam executable/session validation before mutation, live Custom/ReSTIR/DLSSG-off enforcement, transient experiment authorization, allowlisted one-setting Control/Candidate generation, byte-exact `user.conf` restoration, launch-plan currentness, and independent observation of the registered retail `FEAR.exe`. The tests use synthetic directories and process snapshots; they neither alter the user's installation nor claim a live Remix pass.

The dedicated CameraLab test constructs a fully self-consistent forged package from checked-in profile/source inputs and an available x86 fixture executable, so its outer-pin rejection does not depend on a prebuilt camera artifact:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-FearCameraDiagnosticStage.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-FearCameraDiagnosticStage.ps1 -SkipRealPackage
```

The default run additionally validates and stages the hard-pinned local camera package when it is available. `-SkipRealPackage` proves the synthetic branch independently: even a fully self-consistent forged manifest/DLL/profile is rejected by the outer manifest pin, while planning, cvar ownership, native marker rejection, generic stage ownership, and log preservation remain testable without that artifact. Neither branch launches the game or validates captured matrix semantics.

The focused texture checks keep the local package boundary and restart-bound setting separate from general staging:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-FearHdTexturePackage.ps1 `
  -ValidateRealPackage `
  -RealPackageRoot 'D:\path\to\HDTextures4FEAR_XP_v2.0.2' `
  -RealLitePackageRoot 'D:\path\to\FearMore-HD-Textures-Lite'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-FearLauncherSettings.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/runtime/Test-FearHdTextureStage.ps1 `
  -RetailRoot 'D:\path\to\FEAR' -PackageRoot 'D:\path\to\HDTextures4FEAR_XP_v2.0.2'
```

They validate DDS structure and the pinned Full, official Lite-overlay, and complete Stable Lite identities; reject unsupported/malformed/case-ambiguous settings and package roots; and exercise exact junction/runtime-executable ownership. The real Full transition is retained as negative evidence: a short smoke/save-load pass did not predict the later deterministic `d3dx9_27.dll` level-transition fault. Lite stage preparation passed with the expected manifest, active-mode marker `1`, and attested LAA runtime; its matching live crash-gate replay also passed through Interval 02 into container-yard gameplay without a new dump. The real-package and real-stage branches remain local-only and do not redistribute or modify either supplied texture download.
