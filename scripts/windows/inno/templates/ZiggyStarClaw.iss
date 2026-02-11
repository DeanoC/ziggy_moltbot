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
; Pure client profile (no node runner)
Filename: "{app}\ziggystarclaw-cli.exe"; Parameters: "node profile apply --profile client"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated skipifdoesntexist; Check: IsProfileClient

; Service node profile (system service in elevated context)
Filename: "{app}\ziggystarclaw-cli.exe"; Parameters: "node runner install --mode service --url ""{code:GetServerUrl}"" --gateway-token ""{code:GetGatewayToken}"""; WorkingDir: "{app}"; Flags: runhidden waituntilterminated skipifdoesntexist; Check: IsProfileService
Filename: "{app}\ziggystarclaw-cli.exe"; Parameters: "node runner start"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated skipifdoesntexist; Check: IsProfileService
; Tray startup should be per-user; run this part as the original user context.
Filename: "{app}\ziggystarclaw-cli.exe"; Parameters: "tray install-startup"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated runasoriginaluser skipifdoesntexist; Check: IsProfileService

; User session node profile (user Scheduled Task + tray startup in original user context)
Filename: "{app}\ziggystarclaw-cli.exe"; Parameters: "node runner install --mode session --url ""{code:GetServerUrl}"" --gateway-token ""{code:GetGatewayToken}"""; WorkingDir: "{app}"; Flags: runhidden waituntilterminated runasoriginaluser skipifdoesntexist; Check: IsProfileSession
Filename: "{app}\ziggystarclaw-cli.exe"; Parameters: "node runner start"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated runasoriginaluser skipifdoesntexist; Check: IsProfileSession
Filename: "{app}\ziggystarclaw-cli.exe"; Parameters: "tray install-startup"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated runasoriginaluser skipifdoesntexist; Check: IsProfileSession

[UninstallRun]
Filename: "{app}\ziggystarclaw-cli.exe"; Parameters: "node profile apply --profile client"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated skipifdoesntexist

[Code]
const
  ProfileClient = 0;
  ProfileService = 1;
  ProfileSession = 2;

var
  ProfilePage: TInputOptionWizardPage;
  ConnectionPage: TInputQueryWizardPage;

procedure InitializeWizard;
begin
  ProfilePage := CreateInputOptionPage(
    wpSelectTasks,
    'Node Setup Profile',
    'Choose how this machine should run ZiggyStarClaw',
    'Only one node mode can be active on a machine at a time.',
    True,
    False
  );
  ProfilePage.Add('Pure Client (no node runner)');
  ProfilePage.Add('Service Node (starts at boot, recommended for always-on)');
  ProfilePage.Add('User Session Node (interactive desktop access)');
  ProfilePage.Values[ProfileClient] := True;

  ConnectionPage := CreateInputQueryPage(
    ProfilePage.ID,
    'Gateway Connection',
    'Node profiles need gateway connection details',
    'Provide your OpenClaw gateway URL. Token is optional when your gateway allows tokenless auth.'
  );
  ConnectionPage.Add('Server URL', False);
  ConnectionPage.Add('Gateway Token (optional)', True);
  ConnectionPage.Values[0] := 'wss://';
  ConnectionPage.Values[1] := '';
end;

function IsProfileClient: Boolean;
begin
  Result := Assigned(ProfilePage) and ProfilePage.Values[ProfileClient];
end;

function IsProfileService: Boolean;
begin
  Result := Assigned(ProfilePage) and ProfilePage.Values[ProfileService];
end;

function IsProfileSession: Boolean;
begin
  Result := Assigned(ProfilePage) and ProfilePage.Values[ProfileSession];
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if Assigned(ConnectionPage) and (PageID = ConnectionPage.ID) then
    Result := IsProfileClient;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  ServerURL: String;
begin
  Result := True;
  if Assigned(ConnectionPage) and (CurPageID = ConnectionPage.ID) then
  begin
    ServerURL := Trim(ConnectionPage.Values[0]);
    if (ServerURL = '') then
    begin
      MsgBox('Server URL is required for Service Node and User Session Node profiles.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
  end;
end;

function SanitizeArg(Value: String): String;
begin
  Result := Trim(Value);
  StringChangeEx(Result, '"', '', True);
end;

function GetServerUrl(Param: String): String;
begin
  if Assigned(ConnectionPage) then
    Result := SanitizeArg(ConnectionPage.Values[0])
  else
    Result := '';
end;

function GetGatewayToken(Param: String): String;
begin
  if Assigned(ConnectionPage) then
    Result := SanitizeArg(ConnectionPage.Values[1])
  else
    Result := '';
end;
