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
Filename: "{app}\ziggystarclaw-cli.exe"; Parameters: "{code:GetClientConfigArgs}"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated runasoriginaluser skipifdoesntexist; Check: ShouldSaveClientConfig

; Service node profile (system service in elevated context)
; Ensure clean swap from user-session mode.
Filename: "{app}\ziggystarclaw-cli.exe"; Parameters: "node session uninstall"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated skipifdoesntexist; Check: IsProfileService
Filename: "{app}\ziggystarclaw-cli.exe"; Parameters: "node runner install --mode service {code:GetConnectionArgs}"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated skipifdoesntexist; Check: IsProfileService
Filename: "{app}\ziggystarclaw-cli.exe"; Parameters: "node runner start"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated skipifdoesntexist; Check: IsProfileService

; User session node profile (user Scheduled Task + tray startup in original user context)
; Ensure clean swap from service mode (requires installer elevation).
Filename: "{app}\ziggystarclaw-cli.exe"; Parameters: "node service uninstall"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated skipifdoesntexist; Check: IsProfileSession
Filename: "{app}\ziggystarclaw-cli.exe"; Parameters: "{code:GetSessionConfigArgs}"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated skipifdoesntexist; Check: ShouldSaveSessionConfig
Filename: "{sys}\schtasks.exe"; Parameters: "{code:GetSessionNodeDeleteArgs}"; Flags: runhidden waituntilterminated skipifdoesntexist; Check: IsProfileSession
Filename: "{sys}\schtasks.exe"; Parameters: "{code:GetSessionNodeCreateArgs}"; Flags: runhidden waituntilterminated skipifdoesntexist; Check: IsProfileSession
Filename: "{sys}\schtasks.exe"; Parameters: "{code:GetSessionNodeRunArgs}"; Flags: runhidden waituntilterminated skipifdoesntexist; Check: IsProfileSession

; Tray startup task installation:
; user-context only (installer-context ONLOGON task creation can block on credential prompts)
Filename: "{app}\ziggystarclaw-cli.exe"; Parameters: "tray install-startup"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated runasoriginaluser skipifdoesntexist; Check: ShouldInstallTrayStartup
Filename: "{sys}\schtasks.exe"; Parameters: "{code:GetSessionTrayDeleteArgs}"; Flags: runhidden waituntilterminated skipifdoesntexist; Check: IsProfileSession
Filename: "{sys}\schtasks.exe"; Parameters: "{code:GetSessionTrayCreateArgs}"; Flags: runhidden waituntilterminated skipifdoesntexist; Check: IsProfileSession
Filename: "{sys}\schtasks.exe"; Parameters: "{code:GetSessionTrayRunArgs}"; Flags: runhidden waituntilterminated skipifdoesntexist; Check: IsProfileSession

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
  ExistingServerUrl: String;
  ExistingGatewayToken: String;
  ExistingConfigHasConnection: Boolean;
  SessionTaskScriptsReady: Boolean;
  SessionNodeScriptPath: String;
  SessionTrayScriptPath: String;

procedure EnsureSessionTaskScripts; forward;

function IsWhitespace(const C: Char): Boolean;
begin
  Result := (C = ' ') or (C = #9) or (C = #10) or (C = #13);
end;

function ExtractJsonStringValue(const Json, Key: String; var Value: String): Boolean;
var
  Pattern: String;
  P, I, L: Integer;
  C: Char;
  OutValue: String;
begin
  Result := False;
  Value := '';
  Pattern := '"' + Key + '"';
  P := Pos(Pattern, Json);
  if P = 0 then
    Exit;

  I := P + Length(Pattern);
  L := Length(Json);
  while (I <= L) and (Json[I] <> ':') do
    I := I + 1;
  if I > L then
    Exit;

  I := I + 1;
  while (I <= L) and IsWhitespace(Json[I]) do
    I := I + 1;
  if (I > L) or (Json[I] <> '"') then
    Exit;

  I := I + 1;
  OutValue := '';
  while I <= L do
  begin
    C := Json[I];
    if C = '"' then
    begin
      Value := OutValue;
      Result := True;
      Exit;
    end;

    if C = '\' then
    begin
      I := I + 1;
      if I > L then
        Break;
      C := Json[I];
    end;

    OutValue := OutValue + C;
    I := I + 1;
  end;
end;

function TryLoadConnectionFromConfig(const ConfigPath: String; var Url, Token: String): Boolean;
var
  Content: AnsiString;
  TmpUrl, TmpToken: String;
begin
  Result := False;
  Url := '';
  Token := '';
  if (not FileExists(ConfigPath)) then
    Exit;
  if (not LoadStringFromFile(ConfigPath, Content)) then
    Exit;

  if ExtractJsonStringValue(String(Content), 'wsUrl', TmpUrl) then
  begin
    Url := Trim(TmpUrl);
    Result := Url <> '';
  end;
  if ExtractJsonStringValue(String(Content), 'authToken', TmpToken) then
    Token := TmpToken;
end;

function TryLoadConnectionFromLegacyClientConfig(const ConfigPath: String; var Url, Token: String): Boolean;
var
  Content: AnsiString;
  TmpUrl, TmpToken: String;
begin
  Result := False;
  Url := '';
  Token := '';
  if (not FileExists(ConfigPath)) then
    Exit;
  if (not LoadStringFromFile(ConfigPath, Content)) then
    Exit;

  if ExtractJsonStringValue(String(Content), 'server_url', TmpUrl) then
  begin
    Url := Trim(TmpUrl);
    Result := Url <> '';
  end;
  if ExtractJsonStringValue(String(Content), 'token', TmpToken) then
    Token := TmpToken;
end;

function ServiceRunnerInstalled: Boolean;
var
  ResultCode: Integer;
begin
  Result := False;
  if Exec(ExpandConstant('{sys}\sc.exe'), 'query "ZiggyStarClaw Node"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := (ResultCode = 0);
end;

function SessionRunnerInstalled: Boolean;
var
  ResultCode: Integer;
begin
  Result := False;
  if Exec(ExpandConstant('{sys}\schtasks.exe'), '/Query /TN "ZiggyStarClaw Node"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := (ResultCode = 0);
end;

function TrayStartupInstalled: Boolean;
var
  ResultCode: Integer;
begin
  Result := False;
  if Exec(ExpandConstant('{sys}\schtasks.exe'), '/Query /TN "ZiggyStarClaw Tray"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := (ResultCode = 0);
end;

procedure InitializeWizard;
var
  UserCfg, CommonCfg, UserLegacyCfg, UrlValue, TokenValue: String;
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
  if ServiceRunnerInstalled then
    ProfilePage.Values[ProfileService] := True
  else if SessionRunnerInstalled then
    ProfilePage.Values[ProfileSession] := True
  else
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

  ExistingServerUrl := '';
  ExistingGatewayToken := '';
  ExistingConfigHasConnection := False;
  SessionTaskScriptsReady := False;
  SessionNodeScriptPath := '';
  SessionTrayScriptPath := '';

  UserCfg := ExpandConstant('{userappdata}\ZiggyStarClaw\config.json');
  CommonCfg := ExpandConstant('{commonappdata}\ZiggyStarClaw\config.json');
  UserLegacyCfg := ExpandConstant('{userappdata}\ZiggyStarClaw\ziggystarclaw_config.json');

  UrlValue := '';
  TokenValue := '';
  if ProfilePage.Values[ProfileService] then
  begin
    if (not TryLoadConnectionFromConfig(CommonCfg, UrlValue, TokenValue)) then
      if (not TryLoadConnectionFromConfig(UserCfg, UrlValue, TokenValue)) then
        TryLoadConnectionFromLegacyClientConfig(UserLegacyCfg, UrlValue, TokenValue);
  end
  else
  begin
    if (not TryLoadConnectionFromConfig(UserCfg, UrlValue, TokenValue)) then
      if (not TryLoadConnectionFromConfig(CommonCfg, UrlValue, TokenValue)) then
        TryLoadConnectionFromLegacyClientConfig(UserLegacyCfg, UrlValue, TokenValue);
  end;

  if UrlValue <> '' then
  begin
    ExistingConfigHasConnection := True;
    ExistingServerUrl := UrlValue;
    ExistingGatewayToken := TokenValue;
    ConnectionPage.Values[0] := ExistingServerUrl;
    ConnectionPage.Values[1] := ExistingGatewayToken;
  end;
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

function ShouldInstallTrayStartup: Boolean;
begin
  Result := IsProfileService and (not TrayStartupInstalled);
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  ServerURL: String;
begin
  Result := True;
  if Assigned(ConnectionPage) and (CurPageID = ConnectionPage.ID) then
  begin
    ServerURL := Trim(ConnectionPage.Values[0]);
    if ((ServerURL = '') and (not ExistingConfigHasConnection)) then
    begin
      MsgBox('Server URL is required (unless an existing config is detected).', mbError, MB_OK);
      Result := False;
      Exit;
    end;

    if (ServerURL <> '') and ((Pos('ws://', Lowercase(ServerURL)) <> 1) and (Pos('wss://', Lowercase(ServerURL)) <> 1)) then
    begin
      MsgBox('Server URL must start with ws:// or wss://', mbError, MB_OK);
      Result := False;
      Exit;
    end;

    if (Lowercase(ServerURL) = 'ws://') or (Lowercase(ServerURL) = 'wss://') then
    begin
      MsgBox('Server URL must include a host (example: wss://your-gateway.example)', mbError, MB_OK);
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

function GetConnectionArgs(Param: String): String;
var
  UrlValue, TokenValue: String;
begin
  UrlValue := SanitizeArg(GetServerUrl(''));
  TokenValue := SanitizeArg(GetGatewayToken(''));

  if (UrlValue = '') then
  begin
    // Preserve existing config on upgrades when URL is left blank.
    Result := '';
    Exit;
  end;

  Result := '--url "' + UrlValue + '"';
  if (TokenValue <> '') then
    Result := Result + ' --gateway-token "' + TokenValue + '"';
end;

function GetClientConfigArgs(Param: String): String;
var
  ConnArgs: String;
  ConfigPath: String;
begin
  ConnArgs := GetConnectionArgs('');
  if ConnArgs = '' then
  begin
    // Preserve existing client config when URL is intentionally left blank.
    Result := '';
    Exit;
  end;

  ConfigPath := ExpandConstant('{userappdata}\ZiggyStarClaw\ziggystarclaw_config.json');
  Result := '--save-config --config "' + ConfigPath + '" ' + ConnArgs;
end;

function ShouldSaveClientConfig: Boolean;
begin
  Result := IsProfileClient and (GetClientConfigArgs('') <> '');
end;

function GetSessionConfigArgs(Param: String): String;
var
  ConnArgs: String;
  ConfigPath: String;
begin
  ConnArgs := GetConnectionArgs('');
  if ConnArgs = '' then
  begin
    Result := '';
    Exit;
  end;

  ConfigPath := ExpandConstant('{userappdata}\ZiggyStarClaw\config.json');
  Result := '--save-config --config "' + ConfigPath + '" ' + ConnArgs;
end;

function ShouldSaveSessionConfig: Boolean;
begin
  Result := IsProfileSession and (GetSessionConfigArgs('') <> '');
end;

function GetSessionNodeDeleteArgs(Param: String): String;
begin
  Result := '/Delete /F /TN "ZiggyStarClaw Node"';
end;

function GetSessionNodeCreateArgs(Param: String): String;
begin
  EnsureSessionTaskScripts;
  Result := '/Create /F /TN "ZiggyStarClaw Node" /TR "' + SessionNodeScriptPath + '" /SC ONLOGON /IT /RL LIMITED';
end;

function GetSessionNodeRunArgs(Param: String): String;
begin
  Result := '/Run /TN "ZiggyStarClaw Node"';
end;

function GetSessionTrayDeleteArgs(Param: String): String;
begin
  Result := '/Delete /F /TN "ZiggyStarClaw Tray"';
end;

function GetSessionTrayCreateArgs(Param: String): String;
begin
  EnsureSessionTaskScripts;
  Result := '/Create /F /TN "ZiggyStarClaw Tray" /TR "' + SessionTrayScriptPath + '" /SC ONLOGON /IT /RL LIMITED';
end;

function GetSessionTrayRunArgs(Param: String): String;
begin
  Result := '/Run /TN "ZiggyStarClaw Tray"';
end;

procedure EnsureSessionTaskScripts;
var
  ScriptDir, CliPath, TrayPath: String;
  NodeScript, TrayScript: String;
begin
  if SessionTaskScriptsReady then
    Exit;

  ScriptDir := ExpandConstant('{commonappdata}\ZiggyStarClaw');
  if (not DirExists(ScriptDir)) then
    ForceDirectories(ScriptDir);

  SessionNodeScriptPath := ScriptDir + '\session-node.cmd';
  SessionTrayScriptPath := ScriptDir + '\session-tray.cmd';

  CliPath := ExpandConstant('{app}\ziggystarclaw-cli.exe');
  TrayPath := ExpandConstant('{app}\ziggystarclaw-tray.exe');

  NodeScript :=
    '@echo off' + #13#10 +
    '"' + CliPath + '" node supervise --as-node --no-operator --log-level info' + #13#10;
  TrayScript :=
    '@echo off' + #13#10 +
    '"' + TrayPath + '"' + #13#10;

  if (not SaveStringToFile(SessionNodeScriptPath, NodeScript, False)) then
    RaiseException('Failed to write session task script: ' + SessionNodeScriptPath);
  if (not SaveStringToFile(SessionTrayScriptPath, TrayScript, False)) then
    RaiseException('Failed to write tray task script: ' + SessionTrayScriptPath);

  SessionTaskScriptsReady := True;
end;
