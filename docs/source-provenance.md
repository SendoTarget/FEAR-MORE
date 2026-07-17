# Source provenance and redistribution boundary

## Public repository source identity

- The repository tracks only FearMore's minimal SDK-relative patch, new-source overlay, build scaffold, tooling, tests, documentation, and the pinned EchoPatch submodule.
- `tools/public/Initialize-FearMoreModuleSource.ps1` applies that delta to an owner-supplied official F.E.A.R. Public Tools 1.08 `Source\Game` tree under ignored `FEAR/Dev/Source`.
- The generated game code reports network version `FEAR v1.08` in `FEAR/Dev/Source/FEAR/Shared/VersionMgr.cpp`.
- The official SDK base and the separate inherited LithTech research tree are not committed to this public repository.

## Current uncertainty

- There is no root `LICENSE` or `COPYING` file covering the complete inherited tree.
- Many F.E.A.R. files contain all-rights-reserved notices.
- The tree references or contains interfaces/binaries associated with proprietary middleware, including physics, video, networking, audio, and compression components.
- The local Runtime, Tools, and Doc trees include binaries, game content, internal scripts, and legacy documentation whose redistribution status has not been established.

Consequently, public access to FearMore should not be read as a grant to redistribute inherited source, game data, middleware, SDK files, or locally compiled binaries. The repository boundary reduces what is published; it does not resolve every upstream license question.

## EchoPatch

- Upstream: `https://github.com/Wemino/EchoPatch`
- Pinned revision: tag `4.2.1`, commit `b4a7074e4cbb2fb6bb238809f7cf26424f1f5961`
- License: GPL-3.0

Near-term use keeps EchoPatch as a distinct `dinput8.dll` and submodule. Copying or linking GPL implementation into a distributed FearMore binary is deferred until compatibility between GPL-3.0 and every inherited component is established.

The engine-only derivative is built locally from that exact commit plus the project compatibility patch and remains ignored under `vendor-local`. The separate Remix diagnostics derivative additionally carries the tracked camera-state patch, implementation overlay, and opt-in profile on the same GPL side; it is developer telemetry, not code copied into the inherited F.E.A.R. modules. Runtime staging validates exact manifests/binaries/configs before copying either local package. This does not resolve GPL obligations or authorize distributing a derivative together with inherited proprietary material.

## SDL3

- Upstream: `https://github.com/libsdl-org/SDL`
- Pinned local runtime package: release `3.4.10`, Windows x86 archive SHA-256 `95FA18CD5C8AD64DCEB0E0F5F006D223FF19630590457F3D4D3841EE2CA839BD`
- Staged runtime: `SDL3.dll`, 2,342,912 bytes, SHA-256 `7F85F7C0FB1189050405ACD39BD1E36A8F94FFF5952C513497A9DCAFCB86A9B0`
- License: zlib

The controller implementation in the rebuilt F.E.A.R. module is independently written against SDL's public API; it does not copy EchoPatch's controller source or enable its game-module hooks. The official archive stays ignored under `vendor-local/controller-deps`. One-click acquisition validates the complete archive identity, exact entry set, x86 PE32 runtime, and license bytes before schema-9 staging writes the DLL plus `.fearmore/licenses/SDL3-zlib.txt`. This establishes a clean technical boundary, but it does not change the unresolved redistribution status of the inherited game code.

## dgVoodoo2

- Upstream: `https://www.dege.freeweb.hu/dgVoodoo2/`
- Pinned local package: version `2.87.3`, SHA-256 `6FB954BED55BF70E948C5045A663A9DF31EA206FAF105E327BAFE46C318F867F`
- License: freeware with author-specific redistribution terms; not open-source FearMore code

The official archive stays ignored under `vendor-local/renderer-deps`. The runtime tool validates the exact archive and stages only its x86 D3D9 proxy beside an owned project config. The author's current terms permit shipping individual files with a game or mod, but any public package still needs a fresh terms/notices review and must remain separate from claims about the inherited source license.

## NVIDIA RTX Remix

- Upstream: `https://github.com/NVIDIAGameWorks/rtx-remix`
- Pinned local runtime package: release `1.5.2`, 231,778,218 bytes, SHA-256 `CC424BE4DD1A0C6FD922BC6A7F8E5F6582BAEA7043A38AFA6686D8B6FAABAD01`
- License boundary: the upstream combined repository is MIT; the release archive also carries its own `LICENSE.txt` and third-party notices, which remain authoritative for the packaged components

The official release archive stays ignored under `vendor-local/renderer-deps` and is never a Git or release artifact. The opt-in staging probe validates the complete archive, required 32-bit bridge and 64-bit renderer/bridge PE identities, notices, and every extracted file hash before copying the full runtime into one disposable local stage. Its exact notices are staged with the binaries. This is local compatibility research, not permission to redistribute RTX Remix with inherited F.E.A.R. material and not a claim that F.E.A.R.'s programmable D3D9 renderer is compatible.

## Rivarez F.E.A.R. HD Textures v2.0.2

- Upstream listing: [ModDB F.E.A.R. HD Textures v2.0.2](https://www.moddb.com/downloads/fear-hd-textures-v202)
- Stability overlay: [ModDB HD Textures Lite Pack](https://www.moddb.com/mods/fear-xp-rivarez-mod/downloads/fear-hd-textures-lite-pack), archive MD5 `29E9AEAFC1786AD2B8BB5201B61F255E` as published by ModDB
- Pinned local Full package: 1,882 DDS files, 7,587,319,112 bytes, canonical manifest SHA-256 `C92E8C14ABBD5D8C306D072C2ABAD1EA22D0426182CE37E302E948EB9346D801`
- Pinned official base-game Lite overlay: 1,297 DDS files, 4,066,601,424 bytes, canonical manifest SHA-256 `0CDA60503FCC728D08B0870236861E0DA9184576331AAA272367BD9B015ED06D`
- Pinned derived Stable Lite package: 1,882 DDS files, 4,440,752,072 bytes, canonical manifest SHA-256 `758A5112EA00FD802B5373066EE3BD9AF29A501D271AF6A5CA7F14F6FEFB63ED`
- Local source root: user-supplied and ignored; no redistribution license for the texture assets has been established

FearMore validates and mounts only a base-game `HDTextures/FEAR` DDS tree. `New-FearHdTextureLitePackage.ps1` validates the exact Full tree and official Lite overlay, creates a new local base-game-only tree, applies the reduced files, and validates the complete derived identity; it never modifies either input. The package's `XP`/`FEARXP` trees are rejected. Installer executables are not run or copied, and no bundled D3D wrapper, memory patch, or other executable component is treated as part of the texture feature. The ignored schema-2 registration stores separate Lite and optional Full records; the stage owns one exact junction, archive entry, private LAA executable selection, and integer active-mode marker. Project tooling rejects writes through that mount. The junction does not impose a read-only ACL on the source tree. No texture is copied into Git, a public release, the retail installation, or the rebuilt `Game` directory. `tools/installer/New-FearMoreInstallerPackage.ps1` is the deliberate private exception: with an explicit acknowledgement it can copy the owner's exact Stable Lite tree into an ignored Project Installer. Its output remains non-redistributable and is not a GitHub artifact.

Full is retained for explicit comparison, not accepted as the player default. On the tested Modern stack it repeatedly reached the same `d3dx9_27.dll+0xFCCDF` access violation from the same save during a level/checkpoint transition; Native resolution, CAS Off, and native effects targets did not remove the fault, while HD Off crossed the transition. The author's own Lite description identifies reduced texture sizes as a stability measure. Stable Lite therefore replaces the former saved value `1` path; Full moves to explicit value `2` and remains visibly experimental in game. The exact saved-game replay with Stable Lite crossed into Interval 02 and remained live through helicopter insertion into 3440 x 1440 Max-2x/CAS gameplay without a new crash dump. This focused pass does not establish full-campaign stability.

## F.E.A.R. Public Tools 1.08

The game-module build requires the `Source` directory and legacy libraries from the F.E.A.R. Public Tools 1.08 installer. They are local-only inputs under `vendor-local` and are excluded from Git.

The installer used for the verified build was `fear_publictools_108.exe`, 671,441,087 bytes, with MD5 `7bc14d28571c289175d79ad32ff694bb` and SHA-1 `25b16fc70cf93027779e6f1fd673996d27ad5d84`. A historical download remains available from [AusGamers](https://www.ausgamers.com/files/download/25133/fear-sdk-v108), but public availability is not treated as permission to republish its contents.

An indexed GitHub mirror was useful for confirming exact file identity, but it has no repository license and the mirrored files retain all-rights-reserved notices. FearMore therefore does not vendor from or redistribute that mirror.

External open-source projects used for architectural research are recorded in [reference-implementations.md](reference-implementations.md). Their licenses do not automatically apply to, or cure the provenance of, inherited F.E.A.R./LithTech code.

## Asset rule

- Never commit retail `.Arch00` files, saves, extracted retail models/textures/audio, or a complete installed game.
- Never commit local SDK installations or proprietary redistributables merely because the compiler can link them.
- Project-owned replacement assets require an explicit source and license record.
- Runtime tests use a local staging directory populated from a user-owned F.E.A.R. v1.08 installation.

## Required audit before any public release

1. Establish the provenance and license grant for each inherited source subtree.
2. Inventory every linked binary and middleware interface.
3. Determine whether the intended combined work can legally satisfy EchoPatch's GPL-3.0 terms.
4. Separate clean project-owned code/assets from local compatibility inputs.
5. Review release artifacts, notices, source-offer obligations, and asset manifests before publication.
