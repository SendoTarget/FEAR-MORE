# FearMore component licenses

FearMore is a mixed-license source and build-tooling repository. This file
grants permission only for the components identified below. It does not place
F.E.A.R., the F.E.A.R. Public Tools SDK, LithTech, EchoPatch, or any other
third-party work under the FearMore MIT license.

## FearMore MIT components

The MIT License in this file applies to the following independently written
FearMore material, except where a file carries a more specific notice:

- the root Markdown documentation and Windows command launchers;
- `docs/**`;
- `source-scaffold/**`;
- every `CMakeLists.txt` under `source-overlay/**`;
- the `FearMore*.h`, `FearMore*.cpp`, `AIProfiler.h`, and `AIProfiler.cpp`
  files under `source-overlay/**`;
- `tools/bootstrap/**`, `tools/installer/**`, and `tools/public/**`;
- `tools/runtime/**`, except the third-party/adapted post-processing files
  identified below; and
- FearMore-authored scripts, profiles, tests, and documentation directly under
  `tools/echopatch/**`, excluding `tools/echopatch/overlays/**`.

This allowlist is deliberate. A new file is not automatically MIT-licensed
merely because it is added to this repository or placed near a covered file.
Its ownership and license must be recorded when it is introduced.

### MIT License

Copyright (c) 2026 FearMore contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## EchoPatch GPL boundary

`external/EchoPatch` is an independent project licensed under GPL-3.0. The
FearMore changes intended to patch or compile into EchoPatch are offered under
GPL-3.0-only rather than the FearMore MIT license:

- `patches/echopatch/**`; and
- `tools/echopatch/overlays/**`.

The complete GPL-3.0 license text is supplied by the pinned submodule at
`external/EchoPatch/LICENSE`. Distributing a modified EchoPatch build requires
compliance with that license and the licenses of its compiled dependencies.

## Separately licensed files

`tools/runtime/postprocess/Shaders/FearMoreCAS.fx` incorporates and adapts AMD
FidelityFX CAS material. Its MIT notice is recorded in the file and in
`tools/runtime/postprocess/licenses/AMD-CAS-MIT.txt`. Other files under that
`licenses` directory reproduce their respective upstream notices and are not
relicensed by FearMore.

Third-party programs that the tooling downloads or consumes—including SDL,
dgVoodoo2, ReShade, MinHook, and NVIDIA RTX Remix—remain under their respective
upstream terms. See `CREDITS.md` and `docs/source-provenance.md`.

## Not licensed by FearMore

No FearMore license grant applies to:

- `source-patches/**`, which is an SDK-relative delta containing inherited
  context and requires a separate upstream-rights review;
- an owner-supplied or reconstructed F.E.A.R. Public Tools source tree;
- F.E.A.R. or LithTech source, executable code, campaign data, models,
  textures, audio, video, trademarks, or other assets;
- proprietary middleware, SDK libraries, or redistributables;
- `external/**`, except according to each external project's own license;
- HD texture packs or other user-supplied content; or
- generated modules, runtime stages, installers, or combined binaries merely
  because FearMore tooling created them.

A legally acquired copy of F.E.A.R. is still required to use FearMore. Nothing
in this file grants permission to redistribute the original game, its SDK,
third-party assets, or a combined binary whose upstream redistribution rights
have not been established.
