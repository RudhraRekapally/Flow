; Inno Setup script. Builds FlowSetup.exe from the PyInstaller output in dist\.
; Installs for the current user only, so nobody is asked for an administrator password.

#define AppName "Flow"
#define AppVersion "1.1.2"
#define AppExe "Flow.exe"

[Setup]
AppId={{87B27686-CB12-4D2A-9A82-F8C353289869}
AppName={#AppName}
AppVersion={#AppVersion}
AppCopyright=Copyright (c) 2026 Rudhra Rekapally. All rights reserved.
LicenseFile=..\LICENSE
DefaultDirName={autopf}\Flow
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
DisableDirPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
SetupIconFile=..\assets\icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
OutputDir=..\dist
OutputBaseFilename=FlowSetup
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "..\dist\Flow\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "..\THIRD-PARTY-NOTICES.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; HotKey: "ctrl+alt+w"; Comment: "Pick a desktop wallpaper (Ctrl+Alt+W)"
Name: "{autoprograms}\{#AppName} - open wallpapers folder"; Filename: "{app}\{#AppExe}"; Parameters: "--open-folder"; Comment: "Add or remove wallpapers"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Parameters: "--open-folder"; Description: "Open my wallpapers folder, so I can add pictures"; Flags: postinstall nowait skipifsilent
Filename: "{app}\{#AppExe}"; Description: "Open {#AppName} now"; Flags: postinstall nowait skipifsilent unchecked

[InstallDelete]
; Left behind by 1.0, which was called Wallpaper Selector. The old shortcut carries the
; same Ctrl+Alt+W hotkey, so it has to go or the two would fight over it.
Type: files; Name: "{autoprograms}\Wallpaper Selector.lnk"
Type: files; Name: "{autoprograms}\Wallpaper Selector - open wallpapers folder.lnk"
Type: files; Name: "{autodesktop}\Wallpaper Selector.lnk"
Type: files; Name: "{app}\WallpaperSelector.exe"

[UninstallDelete]
; Thumbnail cache and settings. The user's own pictures are never touched.
Type: filesandordirs; Name: "{localappdata}\Flow"
Type: filesandordirs; Name: "{userappdata}\Flow"
