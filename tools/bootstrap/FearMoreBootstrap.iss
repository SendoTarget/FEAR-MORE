#ifndef OutputRoot
  #error OutputRoot is required.
#endif
#ifndef AppVersion
  #define AppVersion "0.1.2"
#endif

[Setup]
AppId={{D6539978-729D-419B-9D9C-53A17E18E850}
AppName=FearMore Project Installer Bootstrap
AppVersion={#AppVersion}
AppPublisher=FearMore contributors
AppPublisherURL=https://github.com/SendoTarget/FEAR-MORE
DefaultDirName={localappdata}\FearMore\Bootstrap
DefaultGroupName=FearMore Project Installer
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputRoot}
OutputBaseFilename=FearMore-Project-Installer-Bootstrap
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
UninstallDisplayIcon={app}\Bootstrap-FearMoreProject.ps1

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#SourcePath}\Bootstrap-FearMoreProject.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourcePath}\FearMoreBootstrapPrerequisites.psm1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourcePath}\BOOTSTRAP-README.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Build and install FearMore"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Bootstrap-FearMoreProject.ps1"""; WorkingDir: "{app}"
Name: "{group}\FearMore bootstrap help"; Filename: "{app}\BOOTSTRAP-README.txt"

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Bootstrap-FearMoreProject.ps1"""; Description: "Build and install FearMore now"; WorkingDir: "{app}"; Flags: postinstall skipifsilent
