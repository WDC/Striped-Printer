; Inno Setup script for Striped Printer (Windows)
; Build with: iscc StripedPrinter.iss

#define MyAppName "Striped Printer"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "WDC"
#define MyAppExeName "StripedPrinter.exe"

[Setup]
AppId={{D4E5F6A7-B8C9-0123-4567-89ABCDEF0123}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\StripedPrinter
DefaultGroupName={#MyAppName}
OutputDir=..\.build
OutputBaseFilename=StripedPrinter-{#MyAppVersion}-Setup
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
SetupIconFile=..\StripedPrinter\Resources\printer.ico
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\.build\publish\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{userstartup}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"

[Registry]
; .zpl file association
Root: HKCU; Subkey: "Software\Classes\.zpl"; ValueType: string; ValueName: ""; ValueData: "StripedPrinter.ZplFile"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\StripedPrinter.ZplFile"; ValueType: string; ValueName: ""; ValueData: "ZPL Label File"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\StripedPrinter.ZplFile\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#MyAppExeName},0"
Root: HKCU; Subkey: "Software\Classes\StripedPrinter.ZplFile\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""

; Auto-start at login
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "StripedPrinter"; ValueData: """{app}\{#MyAppExeName}"""; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch Striped Printer"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\StripedPrinter"
