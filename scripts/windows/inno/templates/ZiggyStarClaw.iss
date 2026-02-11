#define AppName "ZiggyStarClaw"
#define AppPublisher "DeanoC"
#define AppExeName "ziggystarclaw-client.exe"

#ifndef AppVersion
  #error "AppVersion define is required"
#endif
#ifndef SourceBin
  #error "SourceBin define is required"
#endif
#ifndef RepoRoot
  #error "RepoRoot define is required"
#endif
#ifndef OutputDir
  #define OutputDir SourcePath
#endif
#ifndef SetupIcon
  #define SetupIcon AddBackslash(RepoRoot) + "assets\\icons\\ziggystarclaw.ico"
#endif
#ifndef LicenseFile
  #define LicenseFile AddBackslash(RepoRoot) + "LICENSE"
#endif
#ifndef ReadmeFile
  #define ReadmeFile AddBackslash(RepoRoot) + "README.md"
#endif

[Setup]
AppId={{E711A309-9139-45DC-AF5B-4C4F23500614}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\ZiggyStarClaw
DefaultGroupName=ZiggyStarClaw
DisableProgramGroupPage=yes
LicenseFile={#LicenseFile}
SetupIconFile={#SetupIcon}
UninstallDisplayIcon={app}\{#AppExeName}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
OutputDir={#OutputDir}
OutputBaseFilename=ZiggyStarClaw_Setup_{#AppVersion}_x64
UsePreviousAppDir=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop icon"; GroupDescription: "Additional icons:"

[Dirs]
Name: "{userappdata}\ZiggyStarClaw"

[Files]
Source: "{#SourceBin}\ziggystarclaw-client.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceBin}\ziggystarclaw-cli.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceBin}\ziggystarclaw-tray.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "{#LicenseFile}"; DestDir: "{app}"; DestName: "LICENSE"; Flags: ignoreversion
Source: "{#ReadmeFile}"; DestDir: "{app}"; DestName: "README.md"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\ZiggyStarClaw"; Filename: "{app}\ziggystarclaw-client.exe"; WorkingDir: "{userappdata}\ZiggyStarClaw"
Name: "{autodesktop}\ZiggyStarClaw"; Filename: "{app}\ziggystarclaw-client.exe"; Tasks: desktopicon; WorkingDir: "{userappdata}\ZiggyStarClaw"

[Run]
Filename: "{app}\ziggystarclaw-client.exe"; Parameters: "--install-profile-only"; WorkingDir: "{userappdata}\ZiggyStarClaw"; Description: "Configure node profile now"; Flags: nowait postinstall runasoriginaluser skipifsilent

[UninstallRun]
Filename: "{app}\ziggystarclaw-cli.exe"; Parameters: "node profile apply --profile client"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated skipifdoesntexist
