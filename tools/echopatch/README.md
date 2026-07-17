# EchoPatch compatibility derivatives

This workflow creates local, reproducible EchoPatch 4.2.1 derivatives without
editing the pinned `external/EchoPatch` submodule. The default derivative defines
a safe boundary between EchoPatch's retail-EXE hooks and FearMore's rebuilt game
modules. Explicitly selected diagnostics derivatives cover the isolated RTX
Remix laboratory and a query-light native/D3D11 camera-constant capture lane;
a separately identified RtxLab-only flavor adds the focus-lifecycle exception.
`tools/runtime` consumes only pinned local packages in separately named,
fail-closed modes; no derivative is a default dependency or a redistributable
game package.

## What the patch changes

`patches/echopatch/0001-add-game-module-compatibility-switch.patch` applies to
exact EchoPatch commit `b4a7074e4cbb2fb6bb238809f7cf26424f1f5961` and adds:

- `[Compatibility] PatchGameModules=1`, preserving upstream behavior by default;
- `PatchGameModules=0`, which does not install the `LoadGameDLL` interception and
  therefore does not call the Client, Server, or ClientFX patch entry points; and
- a runtime proof line in both the debugger and `FearMore-EchoPatch.log` when
  module hooks are skipped.

The project-owned `EchoPatch.engine-only.ini` selects `PatchGameModules=0`. It
keeps only options whose hook implementations are confined to the retail EXE or
engine/API boundary. Mixed or game-module-dependent features are disabled:

| Disabled feature family | Why it is off |
| --- | --- |
| `HighFPSFixes` | Spans engine, Client, Server, and ClientFX. FearMore owns its rebuilt AI timing fix directly. |
| `HUDScaling`, `CustomFOV`, `AutoResolution`, `DisableLetterbox` | Require Client module hooks or have a Client half. |
| `SSAAScale` (set to `1.0`) | Has both engine render-target and Client camera hooks. Engine-only mode does not claim SSAA. |
| Persistent world state, reflections, weapon fixes, flashlight, weapon capacity, hip-fire changes | Patch Client and/or Server modules. |
| SDL controller support and console | Span EXE, Client, Server, and/or ClientFX integration. |
| Keyboard and XP widescreen fixes | Include Client module patching. |
| `SkipSplashScreen` | Includes a Client patch; the separate EXE-owned intro-video flags remain available. |

The retained options were traced to these EXE/engine/API owners:

| Retained option family | EchoPatch owner called by `Init` |
| --- | --- |
| Redundant HID initialization | `ApplyFixDirectInputFps`, `ApplyDisableJoystick` |
| Save-write buffering | `ApplyOptimizeSaveSpeed` |
| Nvidia shadow and aspect-blur fixes | `ApplyFixNvidiaShadowCorruption`, `ApplyFixAspectRatioBlur` |
| VRAM detection | `ApplyFastVRAMDetection`, `ApplyDeviceCreationHook` |
| Sound-wrapper loading | `DirectSoundHelper::Init` |
| Scripted-animation crash guard | `ApplyFixScriptedAnimationCrash` |
| FPS cap and VSync | `HookMainLoop`, `HookVSyncOverride` |
| LOD and mip-bias controls | `ApplyConsoleVariableHook`, `ApplyReducedMipMapBias`, `ApplyDeviceCreationHook` |
| Window handling | `ApplyFixWindow`, `ApplyForceRenderMode`, `ApplyConsoleVariableHook` |
| Intro-video skipping | `ApplySkipIntroHook` (not the Client-owned `SkipSplashScreen`) |
| Save-folder redirection and PunkBuster suppression | `ApplySaveFolderRedirect`, `ApplyDisablePunkBuster` |
| Crash reports | `CrashHandler::Install` |

No retained configuration variable is referenced beneath `src/Client`,
`src/Server`, or `src/ClientFX`. `CheckLAAPatch` is EXE-owned but intentionally
off so this conservative profile does not modify a user-owned executable.
Controller sensitivity/binding numbers remain inert because the parent
`SDLGamepadSupport` toggle and every controller subfeature toggle are off.
Console scaling, debug, and file-log values likewise remain inert because
`ConsoleEnabled` is off; the build script asserts these parent and subfeature
settings before it creates a package. The EXE-owned limiter remains available,
but this profile caps it at 60 FPS while the mixed `HighFPSFixes` family is off;
higher caps need an explicit runtime physics/movement acceptance pass.

## RTX Remix camera diagnostics

`-RemixCameraDiagnostics` additionally applies
`patches/echopatch/0003-add-remix-camera-diagnostics.patch`, copies the tracked
`overlays/RemixCameraDiagnostics.cpp` implementation into the isolated source
archive, and appends `EchoPatch.remix-diagnostics.override.ini`. The normal
engine-only package is unchanged.

The diagnostic installs bounded hooks at the exact D3D9 device vtable operations
used for render targets, scene boundaries, fixed-function transforms, viewport,
draws, vertex shaders, and vertex-shader constants. It writes no more than 3,600
schema-3 JSONL frame records beneath the disposable stage's
`rtx-remix/logs/fearmore-camera-<pid>.jsonl`. Every draw resynchronizes the actual
device shader, transform, and c72-c75 state so a state-block `Apply` cannot bypass
the probe. Qualifying fixed-function camera state is retained at draw time, shader
identity is derived from the queried bytecode rather than cached COM addresses,
and non-finite constants serialize as JSON `null`. This is developer telemetry,
not a user graphics feature, and it is enabled only in the explicit RTX lab
mode (`RtxLab` or its lower-level equivalent).

The historical correlated 3440 x 1440 schema-3 runs installed all eight hooks but
advanced only two startup frames. They contained four shader draws, zero
fixed-function draws, zero game `SetTransform` calls, and no valid fixed-function
camera. Forcing a windowed swapchain and a one-run Present-semaphore bypass did
not advance a third frame; the unsafe bypass is not shipped. Because this deep
probe synchronously queries device state and hashes shader bytecode at draw time,
those runs now describe probe perturbation rather than the current RTX blocker.
`RemixDiagnosticEchoPatch` remains available only as a lower-level developer
instrument; the one-click `RtxLab` uses the query-light derivative below.

The query-light control removed that ambiguity. Native CameraLab recorded 3,600
normal-gameplay frames at 3440 x 1440 and approximately 60 FPS, with 39 unique
shaders and all 2,811 captured constants recoverable. All 24 eligible source
projection samples matched D3D9 numeric transforms; the source view transform's
engine-space handedness/offset remains explicit instead of being papered over.
The same derivative then allowed RTX Remix to render the 3440 x 1440 frontend and
load screen and arm on the rebuilt source marker. Its first mission frame captured
92 shader draws, 54,342 primitives, 26 unique shaders, 202 recoverable constants,
and three submitted transforms before the x64 Bridge faulted in NVIDIA's Neural
Radiance Cache initialization. That crash is now the immediate renderer blocker;
camera mirroring or broader geometry work must remain a separately evidenced step.

## Query-light camera diagnostics

`-CameraDiagnostics` applies the independent
`patches/echopatch/0004-add-camera-diagnostics.patch`, copies the tracked
`overlays/CameraDiagnostics.cpp` implementation into the isolated source archive,
and appends `EchoPatch.camera-diagnostics.override.ini`. It is mutually exclusive
with `-RemixCameraDiagnostics`, and neither the normal package nor the Remix
package receives its hooks, configuration, or output contract.

The package records D3D9 setter activity during ordinary native or translation-
layer gameplay. Draw hooks only count calls and primitives from cached setter
state: they never call `GetVertexShader`, `GetTransform`, or
`GetVertexShaderConstantF`. Shader bytecode is queried only on the first observed
`SetVertexShader` for each of at most 128 shader objects, hashed with unsigned-
byte FNV-1a, and dumped once under the same diagnostics root with both hash and
byte count in its filename. Each cached object receives a bounded `AddRef` so a
destroyed shader cannot have its pointer reused under a stale identity; those
references are released when the 3,600-frame capture closes (or by process
teardown if the game exits sooner). This avoids EchoPatch's signed-`char` FNV
behavior and makes offline register-table correlation deterministic from the
exact bytes.

Hook installation and one capability record still occur at D3D9 device creation,
but the bounded telemetry remains disarmed through frontend and menu rendering.
Only `EndScene` checks for the matching
`camera-source-<pid>.jsonl` written by the rebuilt main-camera seam; draw and
setter hooks perform no filesystem readiness checks. The source file must be a
regular non-reparse file whose last write is from the current process lifetime,
so a preserved diagnostic directory plus a reused PID cannot arm from stale
evidence. When that check succeeds, the sidecar writes an explicit `arm` event
and starts frame, shader, constant, transform, and payload accounting on the
following frame. If the authoritative main camera never renders, the log remains
capability-only and none of the 3,600-frame or record budgets is consumed.

Constant records bind the observed shader identity to the exact start register,
vector count, full-value hash, and a 16-float JSON preview. Because F.E.A.R. can
upload broad register tables in one setter call, the complete sampled range is
also appended as little-endian IEEE-754 floats to a bounded sidecar; each JSON
record carries its byte offset and length. For each shader/register-range shape,
the sampler captures the first eight changed payloads without a frame delay,
then spreads later changed samples across the 3,600-frame window at a 150-frame
cadence, up to 32 samples. Global limits remain 8,192 records and 32 MiB of exact
constant payloads. Fixed-function transform samples, frame summaries, viewport
state, and render-target descriptions are also bounded. Every JSONL event
includes the PID, QPC timestamp/frequency, frame number, schema, and capability
identity. The probe does not name any register as a camera, resynchronize state
blocks, issue per-draw device-state queries, or mirror state into D3D9 transforms.

The DLL parses the launcher's early `-userdirectory` argument and refuses to log
outside a real, non-reparse-point user directory. Output is isolated beneath:

```text
<UserDirectory>\FearMoreDiagnostics\camera-d3d9-<pid>.jsonl
<UserDirectory>\FearMoreDiagnostics\camera-d3d9-<pid>.constants.f32bin
<UserDirectory>\FearMoreDiagnostics\shaders\vs-<unsigned-fnv>-<bytes>.dxso
```

The package manifest identity is `CameraDiagnosticEchoPatch`; it records the
camera patch, overlay, base profile, override profile, and binary hashes. This is
developer telemetry, not an in-game graphics option. It observes evidence only;
it does not claim that a shader constant is the main camera or that RTX Remix can
consume it.

## RtxLab focus preservation

`-CameraDiagnostics -RtxFocusPreservation` creates the separate
`RtxCameraDiagnosticEchoPatch` flavor. It applies
`patches/echopatch/0005-add-rtx-focus-preservation.patch`, copies the focused
`overlays/RtxFocusPreservation.cpp` implementation, and appends only
`EchoPatch.rtx-focus-preservation.override.ini`. The ordinary engine-only and
`CameraDiagnosticEchoPatch` profiles do not contain the setting, and the source
default is `PreserveRtxRendererOnFocusChange=0`.

The F.E.A.R. v1.08 `WM_ACTIVATEAPP` handler owns more than rendering: it sends
client focus events, clears input, releases/reacquires the sound handle, and
tracks active state. The RTX flavor therefore does not swallow the message or
install a second WindowProc detour. `ConsoleEnabled` remains the sole owner of
EchoPatch's existing `Console_WindowProc` hook. After verifying the exact
decrypted v1.08 instructions at `Console_WindowProc+0xE0` and `+0x190`, the
focused overlay replaces the five-byte `r_InitRender` call with
`mov eax, LT_OK` and NOPs the five-byte `r_TermRender` call. The explicit success
result is required because the original gain path immediately tests EAX; merely
NOPing the call leaves that branch consuming an undefined value. The guard covers
the complete init-call/result-test sequence, both sites must match before the
first write, final bytes are read back, and any second-write/readback failure
restores both native calls. Runtime success or failure is appended to
`FearMore-EchoPatch.log`. FEARMP and both expansions always retain upstream
behavior.

This is a narrowly scoped workaround for Remix's persistent D3D9/Vulkan device:
the legacy loss/gain cycle can otherwise issue a swapchain reset while Bridge is
presenting. It intentionally changes renderer focus semantics in RtxLab, so it
still needs live tests for repeated Alt-Tab, minimize/restore, monitor sleep,
display-mode changes, and clean shutdown. A byte mismatch fails closed and may
show an EchoPatch error; it must not be generalized to another executable by
loosening the byte guard. Source/package tests do not constitute runtime
acceptance, and this flavor is not built or deployed by those tests.

## Experimental RTX camera reassertion

`-CameraDiagnostics -RtxFocusPreservation -RtxCameraReassertion` creates the
separate `RtxCameraReassertionEchoPatch` candidate. It layers
`patches/echopatch/0006-add-rtx-camera-reassertion.patch`, the tracked
`overlays/RtxCameraReassertion.cpp` passive observer, and the combined
`EchoPatch.rtx-camera-reassertion.override.ini` profile onto the query-light and
focus-preserved source. The source default remains
`EnableRtxCameraReassertion=false`; only this exact candidate enables camera
diagnostics, focus preservation, and reassertion together.

`CameraDiagnostics.cpp` remains the sole owner of its D3D9 vtable hooks. The
candidate integration patch is applied only after that tracked overlay has been
copied into the isolated archive. It forwards successful vertex-shader changes,
draws, and scene boundaries to the passive reassertion API; the observer does not
install a second D3D9 hook or any WindowProc hook. The candidate initially targets
the exact `F7D91705` / 880-byte shader and performs a bounded, query-gated
`c0`-through-`c3` experiment before reasserting unchanged fixed-function camera
state. Its separate 300-frame log is evidence for an RTX camera fix, not runtime
acceptance or a general shader-camera mapping.

The build manifest pins the camera diagnostics and focus-preservation source
identities plus the reassertion patch, overlay, combined profile, and embedded
proof string. `RtxCameraDiagnosticEchoPatch` remains unchanged as the live A/B
control and immediate rollback package. Do not replace the ordinary `RtxLab`
selection with this candidate until moving-camera gameplay at 3440 x 1440 has
confirmed correct world placement, HUD/viewmodel isolation, Alt-Tab recovery,
and clean shutdown.

## Build

EchoPatch's pinned `libMinHook.x86.lib` contains v145 compiler intermediate
code. The currently installed v143 linker cannot consume that object format.
Rather than install a system-wide toolchain or alter upstream, the isolated
workflow rebuilds official [MinHook v1.3.4](https://github.com/TsudaKageyu/minhook/tree/v1.3.4)
source (2-clause BSD) with the same selected toolset as EchoPatch. The separate
exact-commit `0002-minhook-match-echopatch-crt.patch` changes only MinHook's
`Release|Win32` runtime from static `/MT` to dynamic `/MD`, matching EchoPatch;
the workflow treats any remaining `LNK4098` CRT conflict as a build failure.
Download the exact source commit once into the ignored dependency cache:

```powershell
New-Item -ItemType Directory -Force vendor-local\echopatch-deps | Out-Null
curl.exe -L https://github.com/TsudaKageyu/minhook/archive/c3fcafdc10146beb5919319d0683e44e3c30d537.zip -o vendor-local\echopatch-deps\minhook-c3fcafdc10146beb5919319d0683e44e3c30d537.zip
```

The build refuses any archive whose SHA-256 is not
`CDCB160F734D81BD4D235DFEA79E3F5A661C8EF0AB74FA814272AA5449069034`.
`-MinHookArchive` may point at another local copy with that exact hash.

From the repository root in PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\echopatch\Build-EngineOnlyEchoPatch.ps1

# Separate developer-only RTX camera-state package.
powershell -NoProfile -ExecutionPolicy Bypass -File tools\echopatch\Build-EngineOnlyEchoPatch.ps1 -RemixCameraDiagnostics

# Separate developer-only query-light native/D3D11 capture package.
powershell -NoProfile -ExecutionPolicy Bypass -File tools\echopatch\Build-EngineOnlyEchoPatch.ps1 -CameraDiagnostics

# Separate RtxLab-only query-light package with guarded focus preservation.
powershell -NoProfile -ExecutionPolicy Bypass -File tools\echopatch\Build-EngineOnlyEchoPatch.ps1 -CameraDiagnostics -RtxFocusPreservation

# Experimental RTX camera-reassertion candidate (all dependencies are explicit).
powershell -NoProfile -ExecutionPolicy Bypass -File tools\echopatch\Build-EngineOnlyEchoPatch.ps1 -CameraDiagnostics -RtxFocusPreservation -RtxCameraReassertion

# Focused source/identity regression checks (no retail files required).
powershell -NoProfile -ExecutionPolicy Bypass -File tools\echopatch\Test-CameraDiagnosticsSource.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\echopatch\Test-RtxFocusPreservationSource.ps1

# Transaction rollback/promotion integration (performs two camera-only builds).
powershell -NoProfile -ExecutionPolicy Bypass -File tools\echopatch\Test-EchoPatchTransactionalBuild.ps1
```

The script:

1. verifies the submodule and parent gitlink are exactly the pinned commit and
   that the submodule is clean;
2. creates a unique, short-named ignored sibling transaction root beside the selected output
   and uses `git archive` to copy pristine upstream source into that isolated root;
3. verifies and extracts the pinned MinHook source, applies the narrow CRT patch,
   then rebuilds its x86 static library with the selected toolset inside the
   ignored output tree;
4. preflights and applies the project-owned compatibility patch only to the
   EchoPatch archive, plus exactly one diagnostic patch/overlay when requested;
   the RTX focus flavor layers its one focused patch/overlay only on the
   query-light camera derivative; the camera-reassertion candidate then copies
   its passive observer and patches the generated CameraDiagnostics source so
   that the existing hooks remain the sole vtable owner;
5. replaces the archived copy's INI with the conservative engine-only profile;
6. builds the existing solution as `Release|x86` (mapped by the solution to the
   project's `Release|Win32`) with installed MSBuild (`v143` by default,
   overridable with `-PlatformToolset`); the ignored command driver also
   normalizes duplicate case-variant `PATH` entries before MSBuild starts;
7. validates PE32/x86, the embedded compatibility proof string, SHA-256 hashes,
   and that the source submodule stayed at the same clean commit; and
8. emits the manifest and package in the transaction root, verifies that their
   mode, DLL hash, and profile hash agree, then promotes the complete root to the
   stable output path with rollback to the previous root if promotion fails.

Failed builds remove only their unique unpromoted transaction root; they never
delete or edit the current validated output. `EchoPatchPromotion.psm1` owns the
guarded promotion boundary. It serializes promotion/recovery per output, flushes
an immutable intent record before renaming the current root to its deterministic
backup, and flushes a separate commit record only after the promoted package has
been revalidated. Startup rolls an uncommitted rename back to the previous root;
a committed recovery preserves the new root while finishing backup cleanup. The
commit record remains present while recursive backup cleanup can be interrupted,
so a restart never restores a partially deleted backup. A custom `-OutputRoot`
must remain beneath `vendor-local`. Every existing path component from
`vendor-local` through that output root must also be a real directory, not a
junction or other reparse point; recursive cleanup separately rejects reparse
points anywhere in a target tree. If an intent record is unreadable while any
unidentified `.epb-*` candidate remains, recovery fails closed and retains the
journal, output, backup, and candidates for manual inspection; it never deletes
an unassociable candidate or labels an unvalidated output recovered. The test-only pre-promotion failure switch is
restricted to `echopatch-transaction-test-*` output roots.

Here, reproducible means pinned source inputs, an exact patch, and repeatable
validation. The upstream MSVC project emits build timestamps/debug identity, so
bit-for-bit identical DLL hashes across separate builds are not claimed; each
manifest records the binary hash produced by that run.

## Runtime and feature boundary

PE and build checks do not prove runtime compatibility. The explicit Rebuilt
runtime modes additionally validate package identity and use a user-owned F.E.A.R.
v1.08 retail executable/campaign archives; those inputs are not present in the
public source/SDK and must not be committed. The conservative engine-only package
has passed startup and ultrawide gameplay experiments, but its module-dependent
SSAA/HUD/controller options remain disabled and unclaimed. The Remix derivative
has passed hook/bridge initialization but not valid-camera or path-traced-image
acceptance. Neither result makes these packages independently shippable.

## GPL boundary

EchoPatch's `LICENSE` is GNU GPL version 3. This patch and any modified EchoPatch
binary remain on that GPL side of the repository boundary; they are not folded
into the inherited F.E.A.R. game-module source. Local build output is ignored.
MinHook remains under its separate 2-clause BSD license and its notice is copied
into the local package.
Anyone conveying a modified binary must also satisfy GPLv3's corresponding-source,
license, and notice requirements. The generated local package includes the GPL
license and patch for provenance, but it is not by itself represented as a
distribution-ready compliance bundle; retain the exact source archive, patch,
build script, and manifest together and perform a release-license review before
publication. This is repository hygiene, not legal advice.
