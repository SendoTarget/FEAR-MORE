# Building the F.E.A.R. game modules

This lane rebuilds the F.E.A.R. v1.08 game modules for the original 32-bit retail engine. It does not build a standalone engine or include retail game data.

## Prerequisites

- Windows and Visual Studio 2022 Build Tools.
- MSVC v141 (14.16) toolset and a Windows 10/11 SDK.
- CMake 3.20 or newer.
- The `Source` directory installed or extracted from F.E.A.R. Public Tools 1.08.

Keep the Public Tools files outside tracked source. `vendor-local/fear-sdk-108/Source` is the tested local layout and is already ignored.

## Reconstruct, configure, and build

From the repository root in PowerShell, the supported public entry point reconstructs the ignored working source and builds Release:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\public\Build-FearMoreModules.ps1
```

Use `-SdkSourceRoot 'D:\path\to\Source'` when the official SDK is stored elsewhere. For direct CMake diagnostics after reconstruction:

```powershell
$cmake = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
$sdkSource = (Resolve-Path 'vendor-local\fear-sdk-108\Source').Path

Push-Location 'FEAR\Dev\Source'
& $cmake --preset fear-win32 -DFEAR_LEGACY_SOURCE_ROOT="$sdkSource"
& $cmake --build --preset fear-win32-debug
& $cmake --build --preset fear-win32-release
Pop-Location
```

Outputs are written to:

- `build/fear-win32/bin/Debug`
- `build/fear-win32/bin/Release`

Each contains `GameClient.dll`, `GameServer.dll`, and `ClientFx.fxd`. The preset deliberately rejects x64 and leaves the inherited engine and unrelated games disabled.

Controller support adds no compile-time SDL include or link dependency. `GameClient.dll` resolves SDL3's public functions dynamically at runtime. The one-click launcher separately acquires and validates the pinned official SDL 3.4.10 Windows x86 archive into ignored `vendor-local/controller-deps`, and rebuilt staging owns `SDL3.dll` plus its zlib license beside the disposable runtime.

Configuration maps CMake Debug to the Public Tools `Debug` libraries and CMake Release to its `Final` libraries. The official Debug archives require a narrow legacy CRT bridge and `/SAFESEH:NO`; those exceptions are Debug-only.

The v141 client deliberately skips the automatic GameSpy patch-information request. That retail engine interface embeds a VC7.1 `std::string`, whose layout is not compatible with a modern MSVC string; crossing the boundary crashes before the menu, and the patch service is obsolete. The original VC7.1 project path keeps its historical behavior. This is one proven failure, not the complete ABI boundary: every retail-engine virtual interface carrying `std::string` or another standard-library object remains unverified and unsafe to call from the modern build. Multiplayer server-startup structures and client/server content-transfer callbacks are known examples. Those paths require a VC7.1-built module/bridge or an independently verified ABI-neutral interface before modern-toolchain multiplayer can be claimed.

The presets intentionally serialize the MSBuild project graph (`jobs = 1`). Modern MSBuild's multiprocess project mode fails inside this legacy CMake `ZERO_CHECK` graph without reporting an error. Translation units still compile in parallel through `/MP`, so do not add CMake's `--parallel` flag.

## Runtime verification boundary

Use two separate disposable staging directories populated from a user-owned F.E.A.R. v1.08 installation:

1. Stock retail modules plus unmodified EchoPatch establish the modern-resolution, SSAA, HUD, high-FPS, and persistence baseline.
2. Rebuilt `GameClient.dll`, `GameServer.dll`, and `ClientFx.fxd` run without EchoPatch first, verifying menu boot, a stock level, an existing save, AI navigation, damage/sever effects, ClientFX, and clean shutdown.

Do not initially combine the rebuilt modules with EchoPatch. EchoPatch scans and patches retail machine-code signatures in those modules; a v141 rebuild changes their layouts. An individual EchoPatch feature can return only after its hooks are proven engine-only, disabled for rebuilt modules, or ported independently into the responsible source path.

Do not commit the staging directory, Public Tools files, retail archives, compiled modules, or extracted game assets.
