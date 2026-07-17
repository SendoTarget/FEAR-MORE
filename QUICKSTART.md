# FearMore quick start

FearMore requires a legally acquired and installed copy of F.E.A.R. v1.08. It is a mod/build project, not a standalone game, and this repository contains no retail game files.

Repository: [SendoTarget/FEAR-MORE](https://github.com/SendoTarget/FEAR-MORE)

## Simplest route: Project Installer Bootstrap

1. Install F.E.A.R. v1.08 and start it once. Steam owners should leave Steam running and signed in.
2. Download **FearMore-Project-Installer-Bootstrap.exe** from [GitHub Releases](https://github.com/SendoTarget/FEAR-MORE/releases).
3. Run it and leave **Build and install FearMore now** selected. Windows may show an unsigned-publisher warning and request administrator approval for public build tools.
4. When asked for F.E.A.R. Public Tools 1.08, first check the installed game's `extras\fear_publictools_108.exe`. Otherwise let the bootstrap open the [verified SDK v1.08 download page](https://www.ausgamers.com/files/download/25133/fear-sdk-v108).
5. Install Public Tools and select its folder named `Source`—not the retail game folder. FearMore then builds and opens the local playable setup.

The bootstrap is deliberately small: it contains no game, SDK, HD-texture, compiled FearMore-module, or third-party runtime binaries. It may download several gigabytes because Visual Studio build tools and all permitted dependencies are acquired on the user's PC.

## Install with an already prepared local Project Installer

1. Install F.E.A.R. v1.08 and start it once. Steam owners should leave Steam running and signed in.
2. Keep `FearMore-Setup.exe` and every adjacent `.bin` file together, then run the setup.
3. Launch **FearMore (Modern)** from the Start menu or desktop shortcut.
4. The launcher detects the installed game and creates an isolated runtime under `%LOCALAPPDATA%\FearMore`; it does not overwrite the retail installation.

If automatic detection fails, open PowerShell in the installed FearMore folder and run:

```powershell
& '.\Launch FearMore.cmd' -RetailRoot 'D:\path\to\your\F.E.A.R. folder'
```

## Recommended in-game settings

1. Under **Options > Display**, select the monitor's native resolution. Ultrawide gameplay including 3440 x 1440 is supported; pre-rendered videos may retain black bars.
2. Start with **Renderer quality > Native** and **Effects target > High**. Try **Max 2x** only when the GPU has enough headroom.
3. Set **Post-processing > CAS** for conservative sharpening, or keep **Off** as the exact fallback. Renderer and post-processing changes apply after restart.
4. Under **Options > Performance**, choose **Apply remaster quality**.
5. Under **Options > Game**, leave retail **Gore** enabled, then choose **Enhanced gore** and **Corpse persistence**. These apply on the next world load.
6. Controller settings are under **Options > Controls > Joystick**. Keyboard and mouse remain available.

Modern uses a 144 FPS cap. FearMore preserves F.E.A.R.'s original GOAP/A* combat behavior and corrects its scheduler timing for modern frame rates.

## Build the Project Installer from GitHub

The repository deliberately excludes the official SDK base, retail data, binaries produced from that SDK, downloaded wrappers, and optional HD textures. Each builder supplies those inputs locally.

Prerequisites:

- Git for Windows;
- Visual Studio 2022 Build Tools with Desktop development with C++, the MSVC v141 toolset, CMake tools, and a Windows 10/11 SDK;
- Inno Setup 7;
- the official F.E.A.R. Public Tools 1.08 `Source` directory; and
- a legally acquired F.E.A.R. v1.08 installation for playing/testing.

Clone with the pinned EchoPatch submodule:

```powershell
git clone --recurse-submodules https://github.com/SendoTarget/FEAR-MORE.git
cd FEAR-MORE
```

Place the official SDK `Source` directory at:

```text
vendor-local\fear-sdk-108\Source
```

Then double-click:

```text
Build FearMore Project Installer.cmd
```

The command reconstructs the modified module source from the local SDK plus the tracked FearMore delta, downloads and verifies pinned open/free dependencies, builds the 32-bit modules and engine-only EchoPatch derivative, assembles the launcher, and compiles the setup. The final folder is:

```text
dist\local\FearMore-Project-Installer
```

The default build excludes optional HD textures, so it works without third-party texture files. See [Project Installer](docs/project-installer.md) for custom SDK/output paths, HD Lite packaging, troubleshooting, and the exact redistribution boundary.

### Finding the official Public Tools

- Steam distributions may include `fear_publictools_108.exe` under the installed game's `extras` folder.
- A verified historical mirror is [AusGamers: F.E.A.R. SDK v1.08](https://www.ausgamers.com/files/download/25133/fear-sdk-v108). Its listing identifies `fear_publictools_108.exe` as 671,441,087 bytes with SHA-1 `25b16fc70cf93027779e6f1fd673996d27ad5d84`.
- [GameFront's F.E.A.R. v1.08 SDK page](https://www.gamefront.com/games/f-e-a-r/file/f-e-a-r-v1-08-sdk) is an alternative historical listing.

Use Public Tools **1.08**. FearMore validates the SDK's expected source files and rejects a retail installation folder or an incomplete extraction.

## Optional HD textures by Rivarez

FearMore supports a local, validated Stable Lite tree assembled from Rivarez's [F.E.A.R. HD Textures v2.0.2](https://www.moddb.com/downloads/fear-hd-textures-v202) and official [HD Textures Lite Pack](https://www.moddb.com/mods/fear-xp-rivarez-mod/downloads/fear-hd-textures-lite-pack). Those files are not in this repository and are not downloaded automatically because their redistribution terms are separate.

The Full texture mode remains experimental: the tested Full tree reproducibly crashed during a level transition, while the reduced Stable Lite tree crossed that gate. See [the runtime guide](tools/runtime/README.md) for local preparation and registration.

## Safe rollback

Run the Stable preset to use native D3D9 and the original presentation defaults:

```powershell
& '.\Launch FearMore.cmd' -Preset Stable
```

If Modern fails, keep the crash dialog/dump and launcher error text. Generated stages, settings, and saves are isolated from the retail installation.
