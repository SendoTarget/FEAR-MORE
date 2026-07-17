# Credits and upstream links

FearMore is an unofficial preservation/remaster experiment. It exists because of the original F.E.A.R. team and the modders and open-source developers who kept this game practical on modern PCs.

Please use the original links below. In particular, download EchoPatch and the HD texture pack from their authors' pages instead of reposting their files.

For players, the optional texture path uses Rivarez's **[F.E.A.R. HD Textures v2.0.2](https://www.moddb.com/downloads/fear-hd-textures-v202)** plus the official **[HD Textures Lite Pack](https://www.moddb.com/mods/fear-xp-rivarez-mod/downloads/fear-hd-textures-lite-pack)**. EchoPatch, dgVoodoo2, ReShade, SDL, and MinHook links below are the original sources used by the local project build.

## Original game

- **F.E.A.R.** was created by **Monolith Productions**. FearMore is not affiliated with or endorsed by Monolith or the game's publishers/rightsholders.
- A legally owned F.E.A.R. v1.08 installation supplies the executable, campaign archives, audio, video, models, textures, and other retail content. None of that content belongs to FearMore.
- The original **F.E.A.R. Public Tools 1.08** installer may be present as `extras\fear_publictools_108.exe` in a legal game installation. Historical download listings are available from [AusGamers](https://www.ausgamers.com/files/download/25133/fear-sdk-v108) and [GameFront](https://www.gamefront.com/games/f-e-a-r/file/f-e-a-r-v1-08-sdk). The SDK remains a user-supplied local input and is not redistributed by FearMore.

## Modern playable stack

- **EchoPatch 4.2.1** by **Wemino** — [source repository](https://github.com/Wemino/EchoPatch) and [exact 4.2.1 release](https://github.com/Wemino/EchoPatch/releases/tag/4.2.1). It is the major F.E.A.R. compatibility reference and patch foundation. FearMore builds a pinned, local **engine-only** derivative with retail game-module hooks disabled so it can coexist with rebuilt game modules. EchoPatch and the derivative remain GPL-3.0 software on their own side of the project boundary.
- **dgVoodoo2 2.87.3** by **Dege** — [exact 2.87.3 release](https://github.com/dege-diosg/dgVoodoo2/releases/tag/v2.87.3), [exact archive](https://github.com/dege-diosg/dgVoodoo2/releases/download/v2.87.3/dgVoodoo2_87_3.zip), and [author documentation/terms](https://www.dege.freeweb.hu/dgVoodoo2/ReadmeGeneral/). It supplies the validated x86 D3D9-to-D3D11 wrapper used by the Modern renderer path. dgVoodoo2 is freeware under its author's terms, not FearMore source code.
- **ReShade 6.7.3** by **crosire / Patrick Mours** — [official site](https://reshade.me/) and [pinned 6.7.3 installer](https://reshade.me/downloads/ReShade_Setup_6.7.3.exe). It supplies the validated x86 D3D11 post-processing runtime used for optional CAS. FearMore directs users to the official site and does not treat ReShade as project-owned software.
- **[AMD FidelityFX Contrast Adaptive Sharpening](https://github.com/GPUOpen-Effects/FidelityFX-CAS)** by **AMD / GPUOpen** — the MIT-licensed CAS reference used for FearMore's conservative, sharpen-only ReShade FX adaptation.
- **SDL 3.4.10** by **Sam Lantinga and the SDL contributors** — [exact release](https://github.com/libsdl-org/SDL/releases/tag/release-3.4.10) and [exact Win32 x86 archive](https://github.com/libsdl-org/SDL/releases/download/release-3.4.10/SDL3-3.4.10-win32-x86.zip). It supplies the zlib-licensed x86 runtime used by FearMore's independently written controller integration.

## Optional player-supplied textures

- **[F.E.A.R. HD Textures v2.0.2](https://www.moddb.com/downloads/fear-hd-textures-v202)** and the official **[HD Textures Lite Pack](https://www.moddb.com/mods/fear-xp-rivarez-mod/downloads/fear-hd-textures-lite-pack)** by **Rivarez** — optional higher-resolution texture content. FearMore recommends the author's reduced Lite overlay because the Full tree reproducibly crashed the tested remaster stack during a level/checkpoint transition. The integration validates a local derived base-game tree; it does not run the pack's installer, use its executable wrapper, or use the Expansion Point content. No redistribution license for those texture assets has been established, so neither download nor the derived tree may be committed to Git or placed in a FearMore public release. The separate ignored Project Installer builder may embed the owner's validated Lite tree in a private setup for another legal game owner; that private artifact must not be uploaded or mirrored.

## Supporting upstream projects

The local engine-only EchoPatch build also depends on upstream components that deserve their own credit and notices:

- **[MinHook](https://github.com/TsudaKageyu/minhook)** by **Tsuda Kageyu and contributors** — 2-clause BSD-licensed API hooking library. FearMore rebuilds pinned v1.3.4 source with the compatible runtime-library setting.
- **[Dear ImGui](https://github.com/ocornut/imgui)** by **Omar Cornut and contributors** — MIT-licensed immediate-mode UI code vendored and compiled by upstream EchoPatch.
- **[mINI](https://github.com/metayeti/mINI)** by **Danijel Durakovic (metayeti) and contributors** — MIT-licensed INI reader vendored by upstream EchoPatch.

The locally built EchoPatch derivative is not itself a distribution-ready binary release. Anyone redistributing it must satisfy EchoPatch's GPL-3.0 corresponding-source obligations and every compiled dependency's notice/license requirements.

## FearMore work

FearMore contributors own only their new, independently written work where applicable, including the runtime staging/validation tools, safe in-game remaster controls, modern-display corrections, frame-rate timing fixes, controller integration, Enhanced Gore rules, corpse-persistence budget, CAS adaptation/plumbing, tests, and documentation. That work does not grant rights to inherited F.E.A.R./LithTech source or third-party inputs.

EchoPatch was used as an implementation reference where documented, but its rebuilt-module hooks are disabled in the playable Modern lane. Controller input, gore/persistence behavior, AI timing, HUD/ultrawide changes, and in-game remaster settings are owned in the rebuilt source path rather than copied from EchoPatch's retail module patches.

## Evaluated but not shipped as a feature

- **[NVIDIA RTX Remix](https://github.com/NVIDIAGameWorks/rtx-remix)** was evaluated in isolated diagnostic stages. That research remains parked and is not part of the Modern playable stack. FearMore makes no current RTX, path-tracing, DLSS, ray-reconstruction, stability, or scene-completeness claim.

## Redistribution boundary

This public repository contains only the reviewed project tooling/delta boundary. It does not grant rights to publish or attach the following to a release:

- retail F.E.A.R. files, archives, saves, or extracted assets;
- inherited F.E.A.R./LithTech source or built proprietary-derived `GameClient.dll`, `GameServer.dll`, or `ClientFx.fxd` binaries;
- F.E.A.R. Public Tools SDK files or proprietary middleware;
- Rivarez's HD textures, installer, or wrapper;
- a locally assembled FearMore launcher/setup unless a dedicated license and provenance review clears every included component; or
- third-party binaries without satisfying their exact license, notice, source-delivery, and redistribution terms.

See [source-provenance.md](docs/source-provenance.md) for the detailed audit record. This is project hygiene, not legal advice.
