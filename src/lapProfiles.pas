unit lapProfiles;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, Contnrs;

type
  TLapProfile = class
  public
    ID, Name, Executable, Arguments, WorkingDirectory, Source, Icon: string;
    Enabled: boolean;
    constructor Create;
    { The IDE configuration folder this build starts with, worked out as
      Lazarus does; Explicit is False when only the default applies. }
    function ConfigPath: string;
    function ConfigPath(out Explicit: boolean): string;
    // the folder Arguments and WorkingDirectory resolve against
    function LaunchDirectory: string;
    procedure Validate;
  end;

  TLapSettings = class
  private
    FProfiles: TObjectList;
    function GetProfile(Index: integer): TLapProfile;
  public
    DefaultID, Extensions: string;
    ScanRoots: TStringList;
    constructor Create;
    destructor Destroy; override;
    function Count: integer;
    function FindID(const ID: string): TLapProfile;
    function IndexOf(Profile: TLapProfile): integer;
    function Add(Profile: TLapProfile): boolean;
    procedure Delete(Index: integer);
    procedure Load;
    procedure Save;
    function ImportDesktop(const Filename: string): boolean;
    {$IFDEF WINDOWS}
    function ImportShortcut(const Filename: string): boolean;
    {$ENDIF}
    // A .desktop launcher on Linux, a .lnk shortcut on Windows.
    function ImportLauncher(const Filename: string): boolean;
    function ScanLaunchers(const Directory: string): integer;
    function ScanDesktopLaunchers: integer;
    function Discover: integer;
    function ScanFolder(const Directory: string): integer;
    // another enabled build that starts with the same configuration folder
    function SharesConfig(Profile: TLapProfile): TLapProfile;
    property Profiles[Index: integer]: TLapProfile read GetProfile; default;
  end;

function LapConfigDirectory: string;
function LapDataDirectory: string;
function LapDesktopDirectory: string;
function LapQuoteArgument(const Value: string): string;
function LapIsExecutable(const Filename: string): boolean;
{ Where Lazarus keeps its settings when nothing names a folder:
  ~/.lazarus, or %LOCALAPPDATA%\lazarus on Windows. }
function LapDefaultLazarusConfig: string;
{ The configuration folder of Lazarus started as Executable with Arguments
  in Directory: the default, then lazarus.cfg beside the executable, then
  the arguments, the last --pcp or --primary-config-path winning.  Relative
  folders and ~/ expand as the IDE expands them. }
function LapConfigOf(const Executable, Arguments, Directory: string; out Explicit: boolean): string;
{ True when the lazarus.cfg beside Executable puts quotes around a
  configuration folder: Lazarus 5 takes them off, 4 and older read them as
  part of the folder's name. }
function LapCfgQuoted(const Executable: string): boolean;
procedure LapLaunch(Profile: TLapProfile; Files: TStrings);

const
  // What a launcher file is called on this system, for scans and dialogs.
  LapLauncherMask = {$IFDEF WINDOWS}'*.lnk'{$ELSE}'*.desktop'{$ENDIF};

implementation

uses
  IniFiles, UTF8Process, StrUtils, LazFileUtils, LazUTF8, FileUtil, FAFormats,
  {$IFDEF WINDOWS}Windows, ActiveX, ShlObj, ComObj{$ELSE}BaseUnix{$ENDIF};

function LapConfigDirectory: string;
begin
  {$IFDEF WINDOWS}
  Result := SysUtils.GetEnvironmentVariable('LOCALAPPDATA');
  if Result = '' then Result := GetUserDir + 'AppData\Local';
  {$ELSE}
  Result := SysUtils.GetEnvironmentVariable('XDG_CONFIG_HOME');
  if Result = '' then Result := GetUserDir + '.config';
  {$ENDIF}
  Result := IncludeTrailingPathDelimiter(IncludeTrailingPathDelimiter(Result) + 'lazasspicker');
end;

function LapIsExecutable(const Filename: string): boolean;
begin
  {$IFDEF WINDOWS}
  Result := FileExists(Filename) and SameText(ExtractFileExt(Filename), '.exe');
  {$ELSE}
  Result := FileExists(Filename) and (fpAccess(Filename, X_OK) = 0);
  {$ENDIF}
end;

function LapDefaultLazarusConfig: string;
begin
  {$IFDEF WINDOWS}
  Result := SysUtils.GetEnvironmentVariable('LOCALAPPDATA');
  if Result = '' then Result := GetUserDir + 'AppData\Local';
  Result := IncludeTrailingPathDelimiter(Result) + 'lazarus';
  {$ELSE}
  Result := GetUserDir + '.lazarus';
  {$ENDIF}
end;

{ A --pcp= or --primary-config-path= option's folder, any case.  Quotes
  come off only in lazarus.cfg, where no shell took them off first. }
function ConfigOption(const Param, Base: string; Dequote: boolean; out Folder: string): boolean;
const
  Options: array[0..1] of string = ('--primary-config-path=', '--pcp=');
var
  Option: string;
begin
  Result := False;
  for Option in Options do
    if SameText(Copy(Param, 1, Length(Option)), Option) then
    begin
      Folder := Copy(Param, Length(Option) + 1, MaxInt);
      if Dequote then Folder := AnsiDequotedStr(AnsiDequotedStr(Folder, ''''), '"');
      Folder := ChompPathDelim(ExpandFileNameUTF8(Folder, Base));
      Exit(True);
    end;
end;

function CfgFileOf(const Executable: string): string;
var
  Exe: string;
begin
  // lazarus.cfg is read beside the program itself, past any symbolic link
  Result := Executable;
  {$IFNDEF WINDOWS}
  Exe := ReadAllLinks(Executable, False);
  if Exe <> '' then Result := Exe;
  {$ENDIF}
  Result := AppendPathDelim(ExtractFileDir(Result)) + 'lazarus.cfg';
end;

function LapCfgQuoted(const Executable: string): boolean;
var
  Lines: TStringList;
  S: string;
  I, P: integer;
begin
  Result := False;
  if not FileExists(CfgFileOf(Executable)) then Exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(CfgFileOf(Executable));
    for I := 0 to Lines.Count - 1 do
    begin
      S := Trim(Lines[I]);
      P := Pos('=', S);
      if (P > 0) and (SameText(Copy(S, 1, P), '--pcp=') or SameText(Copy(S, 1, P), '--primary-config-path=')) and
        (Copy(S, P + 1, 1) <> '') and (S[P + 1] in ['"', '''']) then
        Exit(True);
    end;
  finally
    Lines.Free;
  end;
end;

function LapConfigOf(const Executable, Arguments, Directory: string; out Explicit: boolean): string;
var
  Lines, Args: TStringList;
  Cfg, S, Folder: string;
  I: integer;
begin
  Explicit := False;
  Result := ChompPathDelim(LapDefaultLazarusConfig);
  Cfg := CfgFileOf(Executable);
  Lines := TStringList.Create;
  Args := TStringList.Create;
  try
    if FileExists(Cfg) then
    begin
      Lines.LoadFromFile(Cfg);
      for I := 0 to Lines.Count - 1 do
      begin
        S := Lines[I];
        // Lazarus takes a line only when it starts with the dash
        if (S = '') or (S[1] <> '-') then Continue;
        S := Trim(S);
        {$IFDEF WINDOWS}
        // the installer writes it in the Windows code page
        if FindInvalidUTF8Codepoint(PChar(S), Length(S), True) > 0 then S := WinCPToUTF8(S);
        {$ENDIF}
        if ConfigOption(S, ExtractFileDir(Cfg), True, Folder) then
        begin
          Result := Folder;
          Explicit := True;
        end;
      end;
    end;
    if FileAssParseArguments(Arguments, Args) then
      for I := 0 to Args.Count - 1 do
        if ConfigOption(Args[I], Directory, False, Folder) then
        begin
          Result := Folder;
          Explicit := True;
        end;
  finally
    Args.Free;
    Lines.Free;
  end;
end;

function LapDataDirectory: string;
begin
  Result := SysUtils.GetEnvironmentVariable('XDG_DATA_HOME');
  if Result = '' then Result := GetUserDir + '.local/share';
  Result := IncludeTrailingPathDelimiter(Result);
end;

{$IFDEF WINDOWS}
function LapDesktopDirectory: string;
begin
  Result := IncludeTrailingPathDelimiter(SysUtils.GetEnvironmentVariable('USERPROFILE')) + 'Desktop';
end;

{$ELSE}

function LapDesktopDirectory: string;
var
  Lines: TStringList;
  Root, Filename, Line: string;
  I: integer;
begin
  Root := SysUtils.GetEnvironmentVariable('XDG_CONFIG_HOME');
  if Root = '' then Root := GetUserDir + '.config';
  Filename := IncludeTrailingPathDelimiter(Root) + 'user-dirs.dirs';
  Result := GetUserDir + 'Desktop';
  Lines := TStringList.Create;
  try
    if FileExists(Filename) then
    begin
      Lines.LoadFromFile(Filename);
      for I := 0 to Lines.Count - 1 do
      begin
        Line := Trim(Lines[I]);
        if AnsiStartsStr('XDG_DESKTOP_DIR=', Line) then
        begin
          Result := AnsiDequotedStr(Copy(Line, 17, MaxInt), '"');
          Result := StringReplace(Result, '$HOME', ExcludeTrailingPathDelimiter(GetUserDir), [rfReplaceAll]);
          Break;
        end;
      end;
    end;
  finally
    Lines.Free;
  end;
end;
{$ENDIF}

function LapQuoteArgument(const Value: string): string;
begin
  Result := '"' + StringReplace(StringReplace(Value, '\', '\\', [rfReplaceAll]), '"', '\"', [rfReplaceAll]) + '"';
end;

constructor TLapProfile.Create;
var
  GUID: TGUID;
begin
  inherited Create;
  CreateGUID(GUID);
  ID := 'build-' + LowerCase(Copy(GUIDToString(GUID), 2, 36));
  Enabled := True;
end;

function TLapProfile.ConfigPath: string;
var
  Explicit: boolean;
begin
  Result := ConfigPath(Explicit);
end;

function TLapProfile.ConfigPath(out Explicit: boolean): string;
begin
  Result := LapConfigOf(Executable, Arguments, LaunchDirectory, Explicit);
end;

function TLapProfile.LaunchDirectory: string;
begin
  Result := WorkingDirectory;
  if Result = '' then Result := ExtractFileDir(Executable);
end;

procedure TLapProfile.Validate;
var
  Args: TStringList;
  I: integer;
  Explicit: boolean;
  Config: string;
begin
  if Trim(Name) = '' then raise Exception.Create('Enter a name for the Lazarus build.');
  if (Executable = '') or not FilenameIsAbsolute(Executable) or not LapIsExecutable(Executable) then
    raise Exception.Create('The Lazarus executable is missing or is not executable: ' + Executable);
  if (WorkingDirectory <> '') and not DirectoryExists(WorkingDirectory) then
    raise Exception.Create('The working directory is missing: ' + WorkingDirectory);
  for I := 1 to Length(ID) do
    if not (ID[I] in ['a'..'z', '0'..'9', '-']) then raise Exception.Create('Invalid build ID.');
  if ID = '' then raise Exception.Create('Missing build ID.');
  Args := TStringList.Create;
  try
    if not FileAssParseArguments(Arguments, Args) then
      raise Exception.Create('The launch arguments contain an unmatched quote.');
    // Lazarus reads only --pcp=<folder>; a separate value is opened as a file
    for I := 0 to Args.Count - 1 do
      if SameText(Args[I], '--pcp') or SameText(Args[I], '--primary-config-path') then
        raise Exception.Create('Write the configuration folder as ' + Args[I] + '=<folder>: Lazarus reads no separate value and would open the folder as a file.');
  finally
    Args.Free;
  end;
  Config := ConfigPath(Explicit);
  if Explicit and not DirectoryExists(Config) then
    raise Exception.Create('The Lazarus configuration directory is missing: ' + Config);
end;

constructor TLapSettings.Create;
begin
  inherited Create;
  FProfiles := TObjectList.Create(True);
  ScanRoots := TStringList.Create;
  Extensions := '.pas,.pp,.lfm,.lpr,.lpi,.lpk,.inc';
end;

destructor TLapSettings.Destroy;
begin
  ScanRoots.Free;
  FProfiles.Free;
  inherited Destroy;
end;

function TLapSettings.Count: integer;
begin
  Result := FProfiles.Count;
end;

function TLapSettings.GetProfile(Index: integer): TLapProfile;
begin
  Result := TLapProfile(FProfiles[Index]);
end;

function TLapSettings.FindID(const ID: string): TLapProfile;
var
  I: integer;
begin
  for I := 0 to Count - 1 do
    if Profiles[I].ID = ID then Exit(Profiles[I]);
  Result := nil;
end;

function TLapSettings.Add(Profile: TLapProfile): boolean;
var
  I: integer;
begin
  for I := 0 to Count - 1 do
    if (Profiles[I].Executable = Profile.Executable) and ((CompareFilenames(Profiles[I].ConfigPath, Profile.ConfigPath) = 0) or
      ((Profiles[I].Source <> '') and (Profiles[I].Source = Profile.Source))) then
    begin
      // A launcher supplies more precise settings than an install-folder scan.
      if (ExtractFileExt(Profile.Source) = '.desktop') or (ExtractFileExt(Profiles[I].Source) <> '.desktop') then
      begin
        Profiles[I].Name := Profile.Name;
        Profiles[I].Arguments := Profile.Arguments;
        Profiles[I].WorkingDirectory := Profile.WorkingDirectory;
        Profiles[I].Source := Profile.Source;
        Profiles[I].Icon := Profile.Icon;
      end;
      Profile.Free;
      Exit(False);
    end;
  FProfiles.Add(Profile);
  if DefaultID = '' then DefaultID := Profile.ID;
  Result := True;
end;

function TLapSettings.IndexOf(Profile: TLapProfile): integer;
begin
  Result := FProfiles.IndexOf(Profile);
end;

function TLapSettings.SharesConfig(Profile: TLapProfile): TLapProfile;
var
  I: integer;
  Config: string;
begin
  Config := Profile.ConfigPath;
  for I := 0 to Count - 1 do
    if (Profiles[I] <> Profile) and Profiles[I].Enabled and (CompareFilenames(Profiles[I].ConfigPath, Config) = 0) then
      Exit(Profiles[I]);
  Result := nil;
end;

procedure TLapSettings.Delete(Index: integer);
begin
  if Profiles[Index].ID = DefaultID then DefaultID := '';
  FProfiles.Delete(Index);
  if (DefaultID = '') and (Count > 0) then DefaultID := Profiles[0].ID;
end;

procedure TLapSettings.Load;
var
  Ini: TIniFile;
  I: integer;
  P: TLapProfile;
  Section: string;
begin
  FProfiles.Clear;
  Ini := TIniFile.Create(LapConfigDirectory + 'settings.ini');
  Ini.Options := Ini.Options - [ifoStripQuotes];
  try
    DefaultID := Ini.ReadString('Settings', 'Default', '');
    Extensions := Ini.ReadString('Settings', 'Extensions', Extensions);
    ScanRoots.CommaText := Ini.ReadString('Settings', 'ScanRoots', '');
    for I := 0 to Ini.ReadInteger('Settings', 'Count', 0) - 1 do
    begin
      Section := 'Build' + IntToStr(I);
      P := TLapProfile.Create;
      P.ID := Ini.ReadString(Section, 'ID', P.ID);
      P.Name := Ini.ReadString(Section, 'Name', 'Lazarus');
      P.Executable := Ini.ReadString(Section, 'Executable', '');
      P.Arguments := Ini.ReadString(Section, 'Arguments', '');
      P.WorkingDirectory := Ini.ReadString(Section, 'WorkingDirectory', '');
      P.Source := Ini.ReadString(Section, 'Source', '');
      P.Icon := Ini.ReadString(Section, 'Icon', '');
      P.Enabled := Ini.ReadBool(Section, 'Enabled', True);
      FProfiles.Add(P);
    end;
  finally
    Ini.Free;
  end;
end;

procedure TLapSettings.Save;
var
  Ini: TMemIniFile;
  I: integer;
  Section: string;
  P: TLapProfile;
begin
  ForceDirectories(LapConfigDirectory);
  Ini := TMemIniFile.Create(LapConfigDirectory + 'settings.ini');
  try
    Ini.Clear;
    Ini.WriteString('Settings', 'Default', DefaultID);
    Ini.WriteString('Settings', 'Extensions', Extensions);
    Ini.WriteString('Settings', 'ScanRoots', ScanRoots.CommaText);
    Ini.WriteInteger('Settings', 'Count', Count);
    for I := 0 to Count - 1 do
    begin
      P := Profiles[I];
      Section := 'Build' + IntToStr(I);
      Ini.WriteString(Section, 'ID', P.ID);
      Ini.WriteString(Section, 'Name', P.Name);
      Ini.WriteString(Section, 'Executable', P.Executable);
      Ini.WriteString(Section, 'Arguments', P.Arguments);
      Ini.WriteString(Section, 'WorkingDirectory', P.WorkingDirectory);
      Ini.WriteString(Section, 'Source', P.Source);
      Ini.WriteString(Section, 'Icon', P.Icon);
      Ini.WriteBool(Section, 'Enabled', P.Enabled);
    end;
    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
end;

function DesktopValue(const S: string): string;
var
  I: integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '\') and (I < Length(S)) then
    begin
      Inc(I);
      case S[I] of
        's': Result := Result + ' ';
        'n': Result := Result + #10;
        't': Result := Result + #9;
        'r': Result := Result + #13;
        else
          Result := Result + S[I];
      end;
    end
    else
      Result := Result + S[I];
    Inc(I);
  end;
end;

// lazarus, startlazarus, lazarus-<version>, with .exe on Windows.
function IsLazarusName(const Path: string): boolean;
var
  S: string;
begin
  S := LowerCase(ExtractFileName(Path));
  if SameText(ExtractFileExt(S), '.exe') then S := ChangeFileExt(S, '');
  Result := (S = 'lazarus') or (S = 'startlazarus') or AnsiStartsStr('lazarus-', S);
end;

function TLapSettings.ImportDesktop(const Filename: string): boolean;
var
  Ini: TIniFile;
  Args: TStringList;
  P: TLapProfile;
  S, Token: string;
  I: integer;
begin
  Result := False;
  Ini := TIniFile.Create(Filename);
  Ini.Options := Ini.Options - [ifoStripQuotes];
  Args := TStringList.Create;
  P := nil;
  try
    if Ini.ReadString('Desktop Entry', 'Type', '') <> 'Application' then Exit;
    if Ini.ReadBool('Desktop Entry', 'Hidden', False) then Exit;
    S := DesktopValue(Ini.ReadString('Desktop Entry', 'Exec', ''));
    if not FileAssParseArguments(S, Args) or (Args.Count = 0) then Exit;
    if not IsLazarusName(Args[0]) then Exit;
    if not FilenameIsAbsolute(Args[0]) then Args[0] := ExeSearch(Args[0]);
    if (Args[0] = '') or not LapIsExecutable(Args[0]) then Exit;
    P := TLapProfile.Create;
    P.Name := DesktopValue(Ini.ReadString('Desktop Entry', 'Name', 'Lazarus'));
    P.Executable := Args[0];
    P.WorkingDirectory := DesktopValue(Ini.ReadString('Desktop Entry', 'Path', ExtractFileDir(P.Executable)));
    P.Source := Filename;
    P.Icon := DesktopValue(Ini.ReadString('Desktop Entry', 'Icon', ''));
    for I := 1 to Args.Count - 1 do
    begin
      Token := Args[I];
      if (Token = '%f') or (Token = '%F') or (Token = '%u') or (Token = '%U') then Continue;
      if Token = '%c' then Token := P.Name
      else if Token = '%k' then Token := Filename
      else if Token = '%i' then Continue;
      Token := StringReplace(Token, '%%', #1, [rfReplaceAll]);
      if Pos('%', Token) > 0 then Exit;
      Token := StringReplace(Token, #1, '%', [rfReplaceAll]);
      if P.Arguments <> '' then P.Arguments := P.Arguments + ' ';
      P.Arguments := P.Arguments + LapQuoteArgument(Token);
    end;
    Result := Add(P);
    P := nil;
  finally
    P.Free;
    Args.Free;
    Ini.Free;
  end;
end;

function TLapSettings.ScanLaunchers(const Directory: string): integer;
var
  SR: TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(Directory) + LapLauncherMask, faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Attr and faDirectory = 0) and ImportLauncher(IncludeTrailingPathDelimiter(Directory) + SR.Name) then Inc(Result);
    until FindNext(SR) <> 0;
  finally
    SysUtils.FindClose(SR);
  end;
end;

function TLapSettings.ImportLauncher(const Filename: string): boolean;
begin
  {$IFDEF WINDOWS}
  Result := ImportShortcut(Filename);
  {$ELSE}
  Result := ImportDesktop(Filename);
  {$ENDIF}
end;

{$IFDEF WINDOWS}
function TLapSettings.ImportShortcut(const Filename: string): boolean;
var
  Link: IShellLinkW;
  Buffer: array[0..MAX_PATH * 4] of widechar;
  IconIndex: longint;
  P: TLapProfile;
  Target, Arguments: string;
begin
  Result := False;
  Link := CreateComObject(CLSID_ShellLink) as IShellLinkW;
  if (Link as IPersistFile).Load(pwidechar(UnicodeString(Filename)), STGM_READ) <> S_OK then Exit;
  Buffer[0] := #0;
  Link.GetPath(Buffer, Length(Buffer), nil, 0);
  Target := UTF8Encode(UnicodeString(pwidechar(Buffer)));
  if not IsLazarusName(Target) or not LapIsExecutable(Target) then Exit;
  Buffer[0] := #0;
  Link.GetArguments(Buffer, Length(Buffer));
  Arguments := UTF8Encode(UnicodeString(pwidechar(Buffer)));
  P := TLapProfile.Create;
  try
    P.Name := ChangeFileExt(ExtractFileName(Filename), '');
    P.Executable := Target;
    // The shortcut's command line is kept as written; LapLaunch splits it.
    P.Arguments := Arguments;
    Buffer[0] := #0;
    Link.GetWorkingDirectory(Buffer, Length(Buffer));
    P.WorkingDirectory := UTF8Encode(UnicodeString(pwidechar(Buffer)));
    if P.WorkingDirectory = '' then P.WorkingDirectory := ExtractFileDir(Target);
    Buffer[0] := #0;
    Link.GetIconLocation(Buffer, Length(Buffer), @IconIndex);
    P.Icon := UTF8Encode(UnicodeString(pwidechar(Buffer)));
    P.Source := Filename;
    Result := Add(P);
    P := nil;
  finally
    P.Free;
  end;
end;
{$ENDIF}

{$IFDEF WINDOWS}
function TLapSettings.ScanDesktopLaunchers: integer;
var
  Base, Root: string;
  SR: TSearchRec;
begin
  // The user's and the shared desktop, and the Start menu with its folders.
  Result := ScanLaunchers(LapDesktopDirectory) +
    ScanLaunchers(IncludeTrailingPathDelimiter(SysUtils.GetEnvironmentVariable('PUBLIC')) + 'Desktop');
  for Base in [SysUtils.GetEnvironmentVariable('APPDATA'), SysUtils.GetEnvironmentVariable('ProgramData')] do
  begin
    if Base = '' then Continue;
    Root := IncludeTrailingPathDelimiter(Base) + 'Microsoft\Windows\Start Menu\Programs\';
    Result := Result + ScanLaunchers(Root);
    if FindFirst(Root + '*', faDirectory, SR) = 0 then
    try
      repeat
        if (SR.Attr and faDirectory <> 0) and (SR.Name <> '.') and (SR.Name <> '..') then
          Result := Result + ScanLaunchers(Root + SR.Name);
      until FindNext(SR) <> 0;
    finally
      SysUtils.FindClose(SR);
    end;
  end;
end;

{$ELSE}

function TLapSettings.ScanDesktopLaunchers: integer;
var
  Dirs: TStringList;
  I: integer;
  S: string;
begin
  Result := ScanLaunchers(LapDesktopDirectory) + ScanLaunchers(LapDataDirectory + 'applications');
  S := SysUtils.GetEnvironmentVariable('XDG_DATA_DIRS');
  if S = '' then S := '/usr/local/share:/usr/share';
  Dirs := TStringList.Create;
  try
    Dirs.StrictDelimiter := True;
    Dirs.Delimiter := ':';
    Dirs.DelimitedText := S;
    for I := 0 to Dirs.Count - 1 do
      Result := Result + ScanLaunchers(IncludeTrailingPathDelimiter(Dirs[I]) + 'applications');
  finally
    Dirs.Free;
  end;
end;
{$ENDIF}

function TLapSettings.Discover: integer;
var
  I: integer;
begin
  Result := ScanFolder(ExtractFileDir(ExpandFileName(ParamStr(0))));
  for I := 0 to ScanRoots.Count - 1 do
    if DirectoryExists(ScanRoots[I]) then Result := Result + ScanFolder(ScanRoots[I]);
  Result := Result + ScanDesktopLaunchers;
end;

function TLapSettings.ScanFolder(const Directory: string): integer;
var
  SR: TSearchRec;
  Ini: TIniFile;
  Root, InstallRoot: string;

  procedure AddInstall(const Base: string);
  var
    Exe, Cfg, PCP: string;
    P: TLapProfile;
    Explicit: boolean;
  begin
    Exe := IncludeTrailingPathDelimiter(Base) + 'lazarus' + PathDelim + 'lazarus' + GetExeExt;
    if not FileExists(Exe) then Exe := IncludeTrailingPathDelimiter(Base) + 'lazarus' + GetExeExt;
    if not LapIsExecutable(Exe) then Exit;
    Cfg := IncludeTrailingPathDelimiter(ExtractFileDir(Exe)) + 'lazarus.cfg';
    PCP := LapConfigOf(Exe, '', ExtractFileDir(Exe), Explicit);
    // an fpcupdeluxe folder with no lazarus.cfg still has its own settings
    if not Explicit then
      if DirectoryExists(IncludeTrailingPathDelimiter(Base) + 'config_lazarus') then
        PCP := IncludeTrailingPathDelimiter(Base) + 'config_lazarus'
      else
        PCP := '';
    P := TLapProfile.Create;
    P.Name := 'Lazarus ' + ExtractFileName(ExcludeTrailingPathDelimiter(Base));
    P.Executable := ExpandFileName(Exe);
    P.WorkingDirectory := ExtractFileDir(P.Executable);
    P.Source := Cfg;
    if PCP <> '' then P.Arguments := LapQuoteArgument('--pcp=' + PCP);
    P.Icon := P.WorkingDirectory + PathDelim + 'images' + PathDelim + 'icons' + PathDelim + 'lazarus128x128.png';
    if not FileExists(P.Icon) then P.Icon := 'applications-development';
    if Add(P) then Inc(Result);
  end;

begin
  Result := 0;
  Root := IncludeTrailingPathDelimiter(ExpandFileName(Directory));
  if not DirectoryExists(Root) then raise Exception.Create('The scan folder does not exist.');
  AddInstall(Root);
  Ini := TIniFile.Create(Root + 'fpcupdeluxe.ini');
  try
    InstallRoot := Ini.ReadString('General', 'InstallDirectory', '');
    if InstallRoot <> '' then
    begin
      if not FilenameIsAbsolute(InstallRoot) then InstallRoot := Root + InstallRoot;
      AddInstall(InstallRoot);
    end;
  finally
    Ini.Free;
  end;
  // Scan one level only; source trees and archived drives are not install catalogs.
  if FindFirst(Root + '*', faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Attr and faDirectory <> 0) and (SR.Name <> '.') and (SR.Name <> '..') then
        AddInstall(Root + SR.Name);
    until FindNext(SR) <> 0;
  finally
    SysUtils.FindClose(SR);
  end;
  Result := Result + ScanLaunchers(Root);
end;

procedure LapLaunch(Profile: TLapProfile; Files: TStrings);
var
  Proc: TProcessUTF8;
  I: integer;
begin
  Profile.Validate;
  // TProcessUTF8 hands the arguments to Windows as UTF-16.
  Proc := TProcessUTF8.Create(nil);
  try
    Proc.Executable := Profile.Executable;
    Proc.CurrentDirectory := Profile.LaunchDirectory;
    if not FileAssParseArguments(Profile.Arguments, Proc.Parameters) then
      raise Exception.Create('Invalid launch arguments.');
    for I := 0 to Files.Count - 1 do Proc.Parameters.Add(ExpandFileName(Files[I]));
    Proc.Options := [];
    Proc.Execute;
  finally
    Proc.Free;
  end;
end;

end.
