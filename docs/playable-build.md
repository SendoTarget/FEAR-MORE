# Private owner launcher package

FearMore's launcher package is a locally assembled convenience payload, not a public binary release. It gives an existing F.E.A.R. v1.08 owner one folder with the rebuilt Release modules, validated Modern D3D11-wrapper dependencies, controller runtime, optional CAS dependency, guarded staging tools, notes, and exact file hashes. It deliberately contains no retail F.E.A.R. files, HD texture assets, saves, profiles, crash evidence, local registration, SDK, or RTX package.

## Build it from this checkout

The source/build repository is public, but it does not host an assembled binary release. Each legal game owner reproduces the launcher locally from their own SDK and downloaded inputs.

Install/build the prerequisites described in [building.md](building.md), acquire the pinned local dependencies through the existing project tools, and then run one command from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\runtime\New-FearMoreLauncherPackage.ps1 -PrivateOwnerBuild
```

The default ignored output is `dist\local\FearMore-Playable`. The switch remains intentionally explicit because the result contains locally compiled and downloaded inputs whose redistribution terms must be reviewed separately. Other legal owners can reproduce the layout from [SendoTarget/FEAR-MORE](https://github.com/SendoTarget/FEAR-MORE).

Install the official [Microsoft Visual C++ x86 runtime](https://aka.ms/vc14/vc_redist.x86.exe) before launching on a new machine. See Microsoft's [supported redistributables guidance](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170) for current platform details.

Before first launch, double-click `Verify FearMore Package.cmd`. It checks `fearmore-package-files.json`, rejects unknown files and reparse points, and verifies every allowlisted file's size and SHA-256. This is an accidental-corruption/tamper diagnostic from the same package, not an external signature.

## Play

1. Install the original F.E.A.R. Ultimate Shooter Edition and run it once. The launcher uses your own v1.08 retail installation read-only; Steam discovery is automatic on the tested owner machine, or `tools\runtime\Start-FearMore.ps1 -RetailRoot "D:\path\to\FEAR"` can be used explicitly.
2. Double-click `Launch FearMore.cmd`. The default is the tested `Modern` preset at a 144 FPS cap. Run only one FearMore instance at a time; a second launcher cannot replace files held by the active game. A failed Explorer launch keeps the error visible; set `FEARMORE_NO_PAUSE=1` only for scripted wrapper use. Automation should call `tools\runtime\Start-FearMore.ps1` directly.
3. Select the desired resolution in-game. The 3440 x 1440 ultrawide gameplay lane has real acceptance evidence. Pre-rendered videos may remain pillarboxed/letterboxed.
4. In **Options > Performance**, choose **Apply remaster quality**. Then use **Options > Display** for **Effects target: High** and **Post-processing: CAS**. Renderer quality **Max 2x** is optional and much more expensive; Native is the compatibility/performance default. These remain normal saved in-game choices—the package does not silently rewrite an existing profile.
5. In **Options > Game**, Enhanced Gore and corpse persistence are available. A genuinely new Modern profile seeds them on; existing profiles are preserved.
6. In **Options > Controls > Joystick**, verify controller input and tune sensitivity/deadzone. A new Modern profile enables the source-owned SDL path; keyboard/mouse and the legacy fallback remain intact.

For a conservative rollback, run `Launch FearMore.cmd -Preset Stable`. Stable uses the rebuilt modules with native D3D9 and preserves the same owner-only retail boundary.

## Optional HD textures

HD texture files are never copied into this package. Download and extract Rivarez's [Full v2.0.2 pack](https://www.moddb.com/downloads/fear-hd-textures-v202) and official [Lite Pack](https://www.moddb.com/mods/fear-xp-rivarez-mod/downloads/fear-hd-textures-lite-pack), then create and register the recommended local Lite tree:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\runtime\New-FearHdTextureLitePackage.ps1 -FullPackageRoot "D:\path\to\HDTextures4FEAR_XP_v2.0.2" -LitePatchRoot "D:\path\to\extracted-lite-patch" -DestinationRoot "D:\path\to\FearMore-HD-Textures-Lite"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\runtime\Register-FearHdTexturePack.ps1 -Mode Lite -PackageRoot "D:\path\to\FearMore-HD-Textures-Lite"
```

Packaged registration lives under `%LOCALAPPDATA%\FearMore\registrations\texture-packs`; the launcher payload stays immutable. Either HD mode also needs a private, attested Large Address Aware `FEAR.exe`/backup pair in `%LOCALAPPDATA%\FearMore\local-runtime\fearmore-stock-echopatch`. The package includes the pinned upstream EchoPatch archive for this owner's local bootstrap, but never includes either FEAR executable. `Invoke-FearLaaBootstrap.ps1` prepares the stock stage, opens EchoPatch's owner-observed LAA prompt, and attests the resulting pair, as documented in [the runtime notes](../tools/runtime/README.md). Until that pair exists, leave **HD Textures** Off; the ordinary Modern game remains playable.

From the package root, the current one-time bootstrap is:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\runtime\Invoke-FearLaaBootstrap.ps1
```

Accept EchoPatch's LAA prompt, let that disposable copy restart, and close the temporary stock F.E.A.R. window. The wrapper verifies a header-only LAA derivative against that player's selected retail executable; the retail installation is not patched. Once the pair attests, later Lite launches use the normal one-click launcher.

`Full v2.0.2 (experimental)` is deliberately not the recommended setup. It reproduced the same `d3dx9_27.dll` transition fault across Native/Max2x, CAS On/Off, and native/high effects combinations. Register it with `-Mode Full` only for deliberate A/B testing; the author-provided Lite overlay is the supported player path.

The derived Stable Lite tree passed the same saved-game failure gate at 3440 x 1440 with Max 2x, CAS, and Effects target High: Interval 01 transitioned into Interval 02, helicopter insertion completed, container-yard gameplay remained live, the scene stayed correctly rendered through its scripted fade cycle, and no new crash dump was written. High doubles only the proven volumetric-light shadow depth target; authored mirror/reflection targets retain their native dimensions after live testing exposed allocation-only scaling as the owner of persistent black/white corruption. This is the focused acceptance evidence for the default texture and effects modes; broader campaign coverage remains open.

## What the hash manifest means

`fearmore-package.json` is the exact three-field marker consumed by `FearRuntimeLayout.psm1`. `fearmore-package-files.json` records the Git revision/state plus every emitted file's classification, length, and SHA-256. Rebuilt game modules and all `vendor-local` entries are explicitly classified private. The assembler validates SDL, dgVoodoo2, EchoPatch, ReShade, and each x86 Release module through the same focused identity primitives used by staging before it copies anything.

RTX presets are intentionally not supported by this package. RTX remains parked research; Modern dgVoodoo D3D11 is the accepted playable renderer path.
