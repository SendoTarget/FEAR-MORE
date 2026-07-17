# Asset and tool sourcing

FearMore prefers reusable free assets and tools over recreating commodity work, but "free" is not enough. Every adopted asset must pass the license, provenance, technical, and visual gates below before it enters a project-owned content pack.

No candidate listed here is part of a build merely because it is listed. `candidate` means it still needs visual and in-engine review; `reference-only` means it must not ship.

## Visual direction

Enhanced Gore must match F.E.A.R.'s grounded industrial-horror presentation:

- anatomically plausible scale and silhouette;
- dark, desaturated blood with restrained wet highlights rather than uniform bright red;
- fine impact mist, directional spatter, material-aware decals, and weighty fragments;
- no pixel art, comic outlines, oversized organs, novelty sounds, or exaggerated arcade fountains;
- no change to the original game's readable combat timing or horror atmosphere.

## Adoption record

Before an asset is copied into a project-owned source directory, record:

- stable asset id, title, author, and original URL;
- exact license shown by the hosting platform and any author-supplied license file;
- download date, original archive name, byte size, and SHA-256;
- whether the source is human-created, scanned, procedural, or AI-generated;
- every crop, retouch, mesh edit, bake, resample, mix, and format conversion;
- target F.E.A.R. record/model/effect owner and final redistribution status.

Prefer CC0. CC-BY may be considered only when attribution can remain attached to every distributed form. Reject unclear, non-commercial, no-derivatives, editorial-only, marketplace-only, ripped, or license-conflicting material.

## Screened asset candidates

| Status | Candidate | Evidence | Intended use | Decision |
| --- | --- | --- | --- | --- |
| candidate | [Blood Splatter by ExileGL](https://opengameart.org/content/blood-splatter) | OpenGameArt marks the high-resolution PNG as CC0. A quarantined copy was hashed and visually inspected on 2026-07-14. | Source mask for wall/floor decal variants after crop, color grading, downsampling, and DXT artifact testing. | Silhouettes pass the grounded-style screen; the supplied red is too saturated for direct use and the sheet is not yet an in-game asset. |
| candidate | [~100 grunge brushstrokes and splatters set by Dino0040](https://opengameart.org/content/100-grunge-brushstrokes-and-splatters-set) | OpenGameArt marks the scanned watercolor/grunge masks as CC0. | Monochrome breakup masks for project-authored decal variation. | Useful source material, not finished blood art; download and visual QA are still pending. |
| candidate | [Blood Spatter Squelch Near Mono by _stubb](https://freesound.org/people/_stubb/sounds/406582/) | Freesound marks the 48 kHz, 24-bit mono WAV as CC0. | One layer in a restrained close-impact sound, not a complete effect by itself. | Promising; audition and normalize locally before adoption. |
| candidate | [Wet impact by gprosser](https://freesound.org/people/gprosser/sounds/360942/) | Freesound marks the short WAV as CC0. | Optional subtle transient layer beneath an existing grounded impact. | Audition first; never use it as an exaggerated standalone splat. |
| candidate | [Poly Haven](https://polyhaven.com/license) | Poly Haven publishes its assets under CC0 and targets photorealistic VFX/game use. | Neutral concrete, metal, fabric, grime, and studio-lighting references around gore content. | Approved source library, but each selected asset still gets its own record and hash. |
| reference-only | [Anatomical figure - ecorche](https://sketchfab.com/3d-models/anatomical-figure-ecorche-9a3f4fef02af4be3a3cd105aea218dc5) | The museum scan is CC0 but is a 303k-triangle scan of a historical sculpture. | Anatomical proportion and muscle-flow reference. | Not a game-ready wound or gib asset; do not ship directly. |
| rejected | [Gore Blood Gibs Meat Chunks](https://opengameart.org/content/gore-blood-gibs-meat-chunks) | CC0, but explicitly pixel-art sprites. | None. | Wrong visual language for F.E.A.R. |
| blocked | [Human Materials 1](https://sketchfab.com/3d-models/human-materials-1-cc0-be48a7526b304914b7c9f45c289b2ecf) | The title/description say CC0 while Sketchfab displays CC Attribution. | Possible skin/flesh material reference. | License metadata conflicts; reject unless the platform record is unambiguously corrected. |

Freesound downloads may require an account. Do not bypass access controls or treat search metadata as a downloaded asset license record.

### Quarantined download record

The ExileGL candidate is stored only under ignored `vendor-local/asset-candidates` while its suitability is evaluated:

- original URL: `https://opengameart.org/sites/default/files/blood_0.png`;
- downloaded: 2026-07-14;
- original size: 2,625,982 bytes;
- dimensions/format: 1600 x 1200, 32-bit ARGB PNG;
- SHA-256: `2F625D3CE46C723C54F3A78A94CD54AEF808EF2480B470DD70BF7B6FDBB42C14`;
- author/source method: credited to ExileGL; creation method is not stated on the source page;
- transform history: none;
- redistribution state: candidate only, not approved for the tracked content pack.

## Selected first content slice

The first new-art candidate should be one Tier-1 deep-wound model decal for the compatible Soldier humanoid family. It must extend F.E.A.R.'s existing `WeaponFX::ApplyModelDecal`, `ModelsDB` decal selection, and `CGameModelDecalMgr` save/load, transfer, fade, and performance-budget path rather than adding a second gore renderer.

Proposed project-owned targets are:

```text
Tex/FearMore/Gore/fm_wound_t1_01.tga
FX/Impacts/ModelDecals/FearMore_Wound_T1_01.Mat00
Database/FX/ModelDecal/FearMore_Wound_T1.record
```

Start with two or three irregular CC0 source masks, a dark desaturated maroon-to-near-black grade, restrained wet centers, roughly 14-22 model-decal radius, modest variance, and the stock high-setting budget of 200 total decals, 10 per model, and 10 per second until runtime measurements justify a change.

The data path already receives instant weapon damage on the client. The eventual threshold selection belongs in the existing model-decal node structure, with defaults retaining the stock first-match behavior. Do not make the wound unconditional: the current `EnhancedGore` control is server-owned, so client visibility or an explicitly versioned compatible setting sync must be proven before this content is enabled.

The Public Tools tree includes editable Soldier and sever model sources and database records, but referenced production model-decal materials, gore audio, and editable named ClientFX definitions are absent. `Gib_Blood`, `Blood_Gib_Stump`, `Blood_Gib_Head`, and `Blood_Gib_Squirt` remain retail-mounted private dependencies. The first art slice therefore changes no anatomy mesh and does not redistribute stock content.

## Screened tools

| Tool | License/status | FearMore role |
| --- | --- | --- |
| F.E.A.R. Public Tools 1.08 | Proprietary local build/content input; already kept outside Git. | `ModelEdit`, `AssetBuilder`, `FXEdit`, `GDBEdit`, `ArchiveEdit`, `WorldEdit`, and the supplied model/FX/material/world packers remain the authoritative final conversion path. The installer does not contain `LTC.exe`. |
| [Blender](https://docs.blender.org/manual/en/3.2/getting_started/about/license.html) | GPL application; Blender documents that the GPL does not apply to artwork created with it. | Mesh cleanup, retopology, UVs, weight transfer, wound-cap authoring, baking, and LODs. |
| [Material Maker](https://github.com/RodZill4/material-maker) | MIT unless a file says otherwise. | Procedural masks and PBR texture authoring before conversion to the legacy material pipeline. |
| [Meshroom](https://github.com/alicevision/meshroom) | MPL-2.0. | Optional photogrammetry for original, legally owned physical reference material; never scan people or copyrighted props without releases. |
| [Audacity](https://manual.audacityteam.org/man/license.html) | GPL v2. | Trim, layer, filter, and normalize legally sourced or original gore audio. |
| [GIMP](https://www.gimp.org/docs/userfaq.html) | GPL v3+ application; its official FAQ places no restriction on work produced with it. | Crop, clean, color-grade, and atlas legally sourced decal masks before legacy texture conversion. |
| [LithTech LTA Blender plug-in](https://www.moddb.com/games/no-one-lives-forever/downloads/lta-blender-plugin) | Free download, but no verified source license found; its author also reports LOD and animation/frame-string defects. | Quarantined research candidate only. Do not install, redistribute, or base production files on it until license, source, archive hash, and security review pass. |

GPL-licensed tools are safe to use as separate authoring applications; their source code is not copied or linked into FearMore. Output assets retain the license of their actual source material and authorship, not an automatically inferred tool license.

## Content-pipeline order

1. Prove Enhanced Gore mechanics with existing local F.E.A.R. effects and temporary project-owned diagnostics.
2. Select only the minimum external candidates needed by the supported vertical slice.
3. Record and hash original downloads before editing.
4. Author and bake in free tools, then convert through the local Public Tools pipeline.
5. Review against stock F.E.A.R. lighting, scale, compression, animation, and performance budgets.
6. Commit only assets whose redistribution status is explicit; keep retail-derived intermediates local.

The bundled Public Tools EULA restricts transfer of created "New Materials." Treat compiled or converted F.E.A.R. content as private unless a dedicated rights review clears distribution, even when an upstream mask or sound is CC0. Source provenance and tool-output distribution rights are separate questions.
