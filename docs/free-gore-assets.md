# Free gore-asset intake

FearMore's working Enhanced Gore path uses the game's existing sever models, caps, blood effects, sounds, and material records from a user-owned installation. Those assets stay private and are never copied into the repository or a public package. External art is supplemental only and must match F.E.A.R.'s grounded visual language, have a clear redistributable license, and survive an in-engine lighting, mip, alpha-edge, and repetition review.

## Accepted for local prototype review

| Asset | License and source | Local identity | Intended test |
| --- | --- | --- | --- |
| [Blood Splatter by ExileGL](https://opengameart.org/content/blood-splatter) | CC0, as declared on the canonical asset page | Ignored `vendor-local/gore-assets/opengameart-blood_0.png`; 1600 x 1200 ARGB PNG; 2,625,982 bytes; SHA-256 `2F625D3CE46C723C54F3A78A94CD54AEF808EF2480B470DD70BF7B6FDBB42C14` | A realistic supplemental decal atlas after conversion through the existing F.E.A.R. texture/ClientFX pipeline. It is not yet shipped or referenced by game data. |

The reviewed texture has irregular dark-red pooling, droplets, and fine spray rather than outlined, exaggerated, or pixel-art shapes. Before adoption, split it into a small varied atlas, remove any black RGB fringe under transparent pixels, generate alpha-safe mips, and compare it against the stock blood materials under F.E.A.R.'s actual lighting. The existing decal limits remain the owner of lifetime and performance.

## Useful source, not a drop-in gore asset

- Blender's official [Human Base Meshes bundle](https://download.blender.org/demo/bundles/bundles-3.6/) provides reusable base topology from Blender's asset library. It may help a future clean-room replacement-mesh workflow, but it is not anatomy, not pre-authored damage art, and would require substantial modeling, rigging, weighting, texture, LOD, and sever-cap work. It is therefore not part of the playable slice.

## Rejected direction

Pixel-art meat chunks, cartoon sprays, generic zombie-wall textures, and low-resolution screen splats do not match the game's restrained photoreal presentation. A permissive license does not override that art-direction gate.
