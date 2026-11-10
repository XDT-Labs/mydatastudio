; Inno Setup script for the Windows installer (.exe).
;
; Inno Setup rather than MSIX: an MSIX won't install unless it's signed by a
; certificate the machine trusts, and signing isn't set up yet. An unsigned
; .exe installs after a SmartScreen warning.
;
; Per-user by default (no admin prompt), into %LOCALAPPDATA%\Programs. The
; user's data lives in %APPDATA%\<realm> and is left alone on uninstall.
;
; Built in CI by:
;   iscc /DAppVersion=1.2.3 /DSourceDir=<bundle> /DOutputDir=<dir> /DOutputName=<name> mydatastudio.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\build\windows\installer"
#endif
#ifndef OutputName
  #define OutputName "MyDataStudio-setup"
#endif

[Setup]
; Never change the AppId: Windows uses it to find the installed app for
; upgrades and uninstall.
AppId={{D1B4E804-6E7F-469B-B84A-D599B06F226F}
AppName=My Data Studio
AppVersion={#AppVersion}
AppPublisher=XDT Labs
AppPublisherURL=https://github.com/XDT-Labs/mydatastudio
DefaultDirName={autopf}\My Data Studio
DefaultGroupName=My Data Studio
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\mydatastudio.exe
; The bundled aiserver zip is already compressed; solid LZMA over it would
; take minutes for almost nothing.
Compression=lzma2/fast
SolidCompression=no
WizardStyle=modern
; The app must not be running while its files are replaced.
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\My Data Studio"; Filename: "{app}\mydatastudio.exe"
Name: "{autodesktop}\My Data Studio"; Filename: "{app}\mydatastudio.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\mydatastudio.exe"; Description: "{cm:LaunchProgram,My Data Studio}"; Flags: nowait postinstall skipifsilent
