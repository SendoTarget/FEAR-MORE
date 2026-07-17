FEARMORE PROJECT INSTALLER BOOTSTRAP

What this is
------------
This small public bootstrap downloads the public build tools and FearMore source,
then builds the playable Project Installer locally on your own Windows PC.

You need
--------
1. A legally acquired and installed copy of F.E.A.R. v1.08.
2. The official F.E.A.R. Public Tools 1.08 SDK.
3. Several gigabytes of free space for Visual Studio build tools and build files.

Finding F.E.A.R. Public Tools 1.08
---------------------------------
1. First check your installed game's extras folder for:
   extras\fear_publictools_108.exe
2. If it is not there, the bootstrap can open this verified historical page:
   https://www.ausgamers.com/files/download/25133/fear-sdk-v108
3. Install the SDK, then select the folder named Source when FearMore asks.
   Do not select the retail F.E.A.R. game folder.

What happens
------------
1. Missing Git, Visual Studio 2022 Build Tools, v141/CMake components, and Inno
   Setup 7 are offered through their exact public WinGet packages.
2. FearMore v0.1.2 and its pinned EchoPatch submodule are cloned from:
   https://github.com/SendoTarget/FEAR-MORE
3. The SDK-relative source changes are reconstructed and compiled locally.
4. The private local FearMore-Setup.exe opens when the build succeeds.

This bootstrap contains no F.E.A.R. retail files, Public Tools SDK files, HD
textures, compiled FearMore game modules, or third-party runtime binaries.

Logs are written under:
%LOCALAPPDATA%\FearMore\Bootstrap\logs
