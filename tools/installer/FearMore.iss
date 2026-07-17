#ifndef LauncherRoot
  #error LauncherRoot must point at a validated FearMore private owner launcher payload.
#endif
#ifndef OutputRoot
  #error OutputRoot must select the ignored private installer output directory.
#endif

#define AppVersion "0.1.1"
#define PublisherName "FearMore contributors"

[Setup]
AppId={{8B29A044-8031-4F0A-A73A-D836796CA537}
AppName=FearMore
AppVersion={#AppVersion}
AppPublisher={#PublisherName}
AppPublisherURL=https://github.com/SendoTarget/FEAR-MORE
DefaultDirName={localappdata}\FearMore\Installer
DefaultGroupName=FearMore
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputRoot}
OutputBaseFilename=FearMore-Setup
Compression=lzma2/ultra64
SolidCompression=yes
DiskSpanning=yes
DiskSliceSize=2000000000
WizardStyle=modern
UninstallDisplayIcon={localappdata}\FearMore\Launcher\Launch FearMore.cmd
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked
#ifdef HdLiteRoot
Name: "hdbootstrap"; Description: "Prepare HD Lite support now (recommended)"; GroupDescription: "First-run setup:"
#endif

[Files]
Source: "{#LauncherRoot}\*"; DestDir: "{tmp}\FearMoreLauncher"; Flags: ignoreversion recursesubdirs createallsubdirs deleteafterinstall
Source: "{#SourcePath}\FearMoreInstaller.psm1"; DestDir: "{app}\support"; Flags: ignoreversion
Source: "{#SourcePath}\Ensure-FearMoreVCRuntime.ps1"; DestDir: "{app}\support"; Flags: ignoreversion
Source: "{#SourcePath}\Install-FearMore.ps1"; DestDir: "{app}\support"; Flags: ignoreversion
Source: "{#SourcePath}\Remove-FearMore.ps1"; DestDir: "{app}\support"; Flags: ignoreversion
Source: "{#SourcePath}\Finish-FearMoreHdSetup.ps1"; DestDir: "{app}\support"; Flags: ignoreversion
Source: "{#SourcePath}\PRIVATE-PROJECT-INSTALLER.txt"; DestDir: "{app}"; Flags: ignoreversion
#ifdef HdLiteRoot
Source: "{#HdLiteRoot}\HDTextures\*"; DestDir: "{app}\..\texture-packs\StableLite\HDTextures"; Flags: ignoreversion recursesubdirs createallsubdirs uninsneveruninstall
#endif

[Icons]
Name: "{group}\Launch FearMore"; Filename: "{cmd}"; Parameters: "/c ""{app}\..\Launcher\Launch FearMore.cmd"""; WorkingDir: "{app}\..\Launcher"
#ifdef HdLiteRoot
Name: "{group}\Finish FearMore HD Setup"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\support\Finish-FearMoreHdSetup.ps1"" -FearMoreRoot ""{app}\.."""; WorkingDir: "{app}"
#endif
Name: "{group}\FearMore private build notes"; Filename: "{app}\PRIVATE-PROJECT-INSTALLER.txt"
Name: "{autodesktop}\FearMore"; Filename: "{cmd}"; Parameters: "/c ""{app}\..\Launcher\Launch FearMore.cmd"""; WorkingDir: "{app}\..\Launcher"; Tasks: desktopicon

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\support\Remove-FearMore.ps1"" -FearMoreRoot ""{app}\.."""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveValidatedFearMoreLauncher"

[Code]
function RunFearMoreInitialization(): Boolean;
var
  Parameters: String;
  ExitCode: Integer;
begin
  Parameters := '-NoProfile -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{app}\support\Install-FearMore.ps1') + '" -PayloadRoot "' +
    ExpandConstant('{tmp}\FearMoreLauncher') + '" -FearMoreRoot "' +
    ExpandConstant('{app}\..') + '"';
#ifdef HdLiteRoot
  Parameters := Parameters + ' -HdLiteRoot "' +
    ExpandConstant('{app}\..\texture-packs\StableLite') + '"';
  if WizardIsTaskSelected('hdbootstrap') then
    Parameters := Parameters + ' -BootstrapHd';
#endif
  Result := Exec(
    ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    Parameters,
    ExpandConstant('{app}'),
    SW_SHOW,
    ewWaitUntilTerminated,
    ExitCode);
  if Result and (ExitCode <> 0) then
  begin
    Log('FearMore initialization failed with exit code ' + IntToStr(ExitCode));
    Result := False;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    if not RunFearMoreInitialization() then
      RaiseException('FearMore could not finish its validated first-run setup. See the setup log and retry the installer.');
  end;
end;
