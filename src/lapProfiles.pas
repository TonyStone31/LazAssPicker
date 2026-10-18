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
    function ConfigPath: string;
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
    property Profiles[Index: integer]: TLapProfile read GetProfile; default;
  end;

function LapConfigDirectory: string;
function LapDataDirectory: string;
function LapDesktopDirectory: string;
function LapQuoteArgument(const Value: string): string;
function LapIsExecutable(const Filename: string): boolean;
procedure LapLaunch(Profile: TLapProfile; Files: TStrings);

const
  // What a launcher file is called on this system, for scans and dialogs.
  LapLauncherMask = {$IFDEF WINDOWS}'*.lnk'{$ELSE}'*.desktop'{$ENDIF};

implementation

uses
  IniFiles, UTF8Process, StrUtils, LazFileUtils, FileUtil, FAFormats,
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
  Args: TStringList;
  I: integer;
  S: string;
begin
  Result := '';
  Args := TStringList.Create;
  try
    if not FileAssParseArguments(Arguments, Args) then Exit;
    for I := 0 to Args.Count - 1 do
    begin
      S := Args[I];
      if AnsiStartsStr('--pcp=', S) then Result := Copy(S, 7, MaxInt)
      else if AnsiStartsStr('--primary-config-path=', S) then Result := Copy(S, 23, MaxInt)
      else if ((S = '--pcp') or (S = '--primary-config-path')) and (I + 1 < Args.Count) then
        Result := Args[I + 1];
    end;
  finally
    Args.Free;
  end;
end;

procedure TLapProfile.Validate;
var
  Args: TStringList;
  I: integer;
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
  finally
    Args.Free;
  end;
  if (ConfigPath <> '') and not DirectoryExists(ConfigPath) then
    raise Exception.Create('The Lazarus configuration directory is missing: ' + ConfigPath);
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
    if (Profiles[I].Executable = Profile.Executable) and ((Profiles[I].ConfigPath = Profile.ConfigPath) or ((Profiles[I].Source <> '') and
      (Profiles[I].Source = Profile.Source))) then
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
    Exe, Cfg, Line, PCP: string;
    Lines: TStringList;
    P: TLapProfile;
    I: integer;
  begin
    Exe := IncludeTrailingPathDelimiter(Base) + 'lazarus' + PathDelim + 'lazarus' + GetExeExt;
    if not FileExists(Exe) then Exe := IncludeTrailingPathDelimiter(Base) + 'lazarus' + GetExeExt;
    if not LapIsExecutable(Exe) then Exit;
    Cfg := IncludeTrailingPathDelimiter(ExtractFileDir(Exe)) + 'lazarus.cfg';
    PCP := '';
    Lines := TStringList.Create;
    try
      if FileExists(Cfg) then
      begin
        Lines.LoadFromFile(Cfg);
        for I := 0 to Lines.Count - 1 do
        begin
          Line := Trim(Lines[I]);
          if AnsiStartsStr('--primary-config-path=', Line) then PCP := Copy(Line, 23, MaxInt)
          else if AnsiStartsStr('--pcp=', Line) then PCP := Copy(Line, 7, MaxInt);
        end;
      end;
    finally
      Lines.Free;
    end;
    PCP := AnsiDequotedStr(PCP, '"');
    if (PCP = '') and DirectoryExists(IncludeTrailingPathDelimiter(Base) + 'config_lazarus') then
      PCP := IncludeTrailingPathDelimiter(Base) + 'config_lazarus';
    if (PCP <> '') and not FilenameIsAbsolute(PCP) then
      PCP := ExpandFileName(IncludeTrailingPathDelimiter(ExtractFileDir(Exe)) + PCP);
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
    Proc.CurrentDirectory := Profile.WorkingDirectory;
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
