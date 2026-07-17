# Project Installer

The public FearMore repository can build an easy Windows setup for a person who legally owns and has installed F.E.A.R. v1.08. The generated setup contains the locally built FearMore launcher and modules, but no retail executable, campaign archives, audio, video, saves, or profiles.

## Public Release bootstrap

For most users, download **FearMore-Project-Installer-Bootstrap.exe** from [GitHub Releases](https://github.com/SendoTarget/FEAR-MORE/releases). The bootstrap installs only its project-owned PowerShell guidance, then:

1. offers missing Git, Visual Studio 2022 Build Tools with C++/CMake/v141, and Inno Setup 7 through exact public WinGet packages;
2. clones the exact tagged FearMore source and pinned EchoPatch submodule;
3. finds `extras\fear_publictools_108.exe` in common Steam locations or opens a verified Public Tools 1.08 download page;
4. validates the user-selected SDK `Source` folder;
5. runs the established public project builder locally; and
6. opens the locally generated `FearMore-Setup.exe`.

Expect several gigabytes of downloads, Windows administrator prompts for build-tool installation, and an unsigned-publisher warning. Logs remain under `%LOCALAPPDATA%\FearMore\Bootstrap\logs`.

The Release bootstrap contains no retail files, SDK files, source-derived game modules, HD textures, EchoPatch/dgVoodoo2/SDL binaries, or playable installer. Its adjacent manifest and `SHA256SUMS.txt` attest that boundary. The locally generated playable setup remains private to the legal game owner and must not be uploaded as a public Release asset.

### Finding Public Tools 1.08

Check the installed F.E.A.R. directory first for `extras\fear_publictools_108.exe`. If it is absent, use the bootstrap's link to [AusGamers' verified F.E.A.R. SDK v1.08 listing](https://www.ausgamers.com/files/download/25133/fear-sdk-v108); [GameFront](https://www.gamefront.com/games/f-e-a-r/file/f-e-a-r-v1-08-sdk) provides an alternative historical page. After installation, select the SDK folder named `Source`, not the retail game folder. FearMore checks the required game, engine SDK, library, and project files before it downloads or builds the mod.

## Manual one-click project build

Install the prerequisites listed in [QUICKSTART.md](../QUICKSTART.md), clone with `--recurse-submodules`, and place the official F.E.A.R. Public Tools 1.08 `Source` directory under `vendor-local\fear-sdk-108\Source`. Then run the repository-root command:

```text
Build FearMore Project Installer.cmd
```

That entry point delegates to `tools/public/Build-FearMorePublicProject.ps1`. The public bootstrapper:

1. requires a clean tracked Git revision;
2. validates the local official SDK input;
3. downloads exact pinned EchoPatch, dgVoodoo2, MinHook, and SDL3 packages into ignored `vendor-local` paths;
4. reconstructs the modified F.E.A.R. module source from the SDK plus the tracked minimal patch/overlay;
5. builds the three 32-bit Release modules and pinned engine-only EchoPatch derivative;
6. delegates launcher assembly and installer compilation to the established guarded project builders; and
7. emits the setup under ignored `dist\local\FearMore-Project-Installer`.

The default excludes HD textures. This keeps the ordinary project build reproducible without requiring an unrelated third-party texture download.

## Custom paths and optional HD Lite

PowerShell exposes the same build with explicit paths:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\public\Build-FearMorePublicProject.ps1 `
  -SdkSourceRoot 'D:\path\to\FEAR-Public-Tools\Source' `
  -OutputRoot 'D:\path\to\FearMore-Project-Installer'
```

To include an already prepared and validated Stable Lite tree, add:

```powershell
-HdLiteRoot 'D:\path\to\FearMore-HD-Textures-Lite'
```

Rivarez's texture downloads and derived Lite tree remain local. Do not commit them or attach them to a GitHub release unless their rightsholder's terms separately permit that redistribution.

## Output and recipient steps

The build never overwrites an existing output folder. After success, copy the entire output directory so `FearMore-Setup.exe` and all adjacent `.bin` files stay together. The recipient installs F.E.A.R. v1.08, starts it once, runs the setup, and launches the Modern shortcut.

The setup is not commercially Authenticode-signed, so Windows may show an unknown-publisher warning. `SHA256SUMS.txt` records the exact generated file hashes for transfer verification.

## What GitHub includes

GitHub provides the project-owned scripts, documentation, tests, feature overlay, minimal SDK-relative source patch, build scaffold, pinned EchoPatch submodule, and original upstream links. It does not provide:

- F.E.A.R. retail files or extracted game assets;
- the F.E.A.R. Public Tools SDK base files;
- compiled `GameClient.dll`, `GameServer.dll`, or `ClientFx.fxd` outputs;
- downloaded EchoPatch, dgVoodoo2, SDL3, MinHook, ReShade, or HD-texture binaries/assets;
- a locally derived Large Address Aware executable; or
- an assembled launcher or final setup.

The sole public EXE is the scripts-only Project Installer Bootstrap described above; it does not weaken any of these exclusions.

Those excluded inputs and outputs remain ignored. A public repository is not a license grant for F.E.A.R., its SDK, third-party assets, or locally produced combined binaries. Review [CREDITS.md](../CREDITS.md) and [source provenance](source-provenance.md) before redistributing any generated artifact.
