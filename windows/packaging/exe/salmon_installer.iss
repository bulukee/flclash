#ifndef MyAppVersion
  #define MyAppVersion "1.0.1"
#endif

[Setup]
AppId={{78A822A8-1E4C-4DAF-A9A8-D798D9A63BFF}
AppVersion={#MyAppVersion}
AppName=三文鱼
AppPublisher=SWYWL
AppPublisherURL=https://swywl.com
AppSupportURL=https://swywl.com
AppUpdatesURL=https://swywl.com
DefaultDirName={autopf64}\Salmon
; Keep every release on the same installation path so the setup EXE upgrades
; the existing Salmon installation instead of creating a second copy.
UsePreviousAppDir=yes
DisableDirPage=no
DirExistsWarning=no
DefaultGroupName=三文鱼
DisableProgramGroupPage=yes
CloseApplications=yes
RestartApplications=no
OutputDir={#SourcePath}\..\..\..\dist
OutputBaseFilename=Salmon-Windows-x64-{#MyAppVersion}-Setup
Compression=lzma2/ultra64
SolidCompression=yes
SetupIconFile={#SourcePath}\..\..\runner\resources\app_icon.ico
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\Salmon.exe

[Languages]
Name: "chineseSimplified"; MessagesFile: "{#SourcePath}\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Files]
Source: "{#SourcePath}\..\..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\三文鱼"; Filename: "{app}\Salmon.exe"; IconFilename: "{app}\Salmon.exe"; IconIndex: 0
Name: "{autodesktop}\三文鱼"; Filename: "{app}\Salmon.exe"; IconFilename: "{app}\Salmon.exe"; IconIndex: 0; Tasks: desktopicon

[Run]
Filename: "{app}\Salmon.exe"; Description: "{cm:LaunchProgram,三文鱼}"; Flags: runascurrentuser nowait postinstall skipifsilent

[Code]
procedure KillProcess(const FileName: String);
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{cmd}'), '/C taskkill /F /IM "' + FileName + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  KillProcess('Salmon.exe');
  KillProcess('FlClash.exe');
  KillProcess('FlClashCore.exe');
  KillProcess('FlClashHelperService.exe');
  Result := '';
end;
