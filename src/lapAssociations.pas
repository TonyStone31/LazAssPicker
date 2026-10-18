unit lapAssociations;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, lapProfiles, FileAssMan;

const
  LapTypeCount = 7;
  LapExtensions: array[0..LapTypeCount - 1] of string =
    ('.pas', '.pp', '.lfm', '.lpr', '.lpi', '.lpk', '.inc');
  LapMimes: array[0..LapTypeCount - 1] of string =
    ('text/x-pascal', 'text/x-pascal', 'application/x-lazarus-form', 'text/x-pascal', 'application/x-lazarus-project', 'application/x-lazarus-package',
    'text/x-lazarus-include');

function LapApplicationID(const ProfileID: string): string;
function LapDefaultFile: string;
function LapReadDefault(const Contents, Mime: string): string;
function LapPatchDefault(const Contents, Mime, Value: string): string;
procedure LapApply(Settings: TLapSettings; Manager: TFileAssMan; Log: TStrings);
procedure LapRemove(Manager: TFileAssMan; Log: TStrings);

implementation

uses
  IniFiles, StrUtils, Process, Math, FATypes, FAFormats, FACollection
  {$IFDEF WINDOWS}, Windows, Registry, ShlObj{$ENDIF};

function LapApplicationID(const ProfileID: string): string;
begin
  Result := 'io.github.tonystone31.lazasspicker.' + ProfileID;
end;

function LapDefaultFile: string;
var
  Root: string;
  Desktops: TStringList;
  I: integer;
begin
  Root := SysUtils.GetEnvironmentVariable('XDG_CONFIG_HOME');
  if Root = '' then Root := GetUserDir + '.config';
  Root := IncludeTrailingPathDelimiter(Root);
  Result := Root + 'mimeapps.list';
  Desktops := TStringList.Create;
  try
    Desktops.StrictDelimiter := True;
    Desktops.Delimiter := ':';
    Desktops.DelimitedText := LowerCase(SysUtils.GetEnvironmentVariable('XDG_CURRENT_DESKTOP'));
    for I := 0 to Desktops.Count - 1 do
      if (Desktops[I] <> '') and (Pos('/', Desktops[I]) = 0) and FileExists(Root + Desktops[I] + '-mimeapps.list') then
        Exit(Root + Desktops[I] + '-mimeapps.list');
  finally
    Desktops.Free;
  end;
end;

function FindDefault(const Contents, Mime: string; out StartAt, EndAt, InsertAt: integer): boolean;
var
  P, Q: integer;
  Line: string;
  InSection: boolean;
begin
  Result := False;
  InSection := False;
  StartAt := 0;
  EndAt := 0;
  InsertAt := 0;
  P := 1;
  while P <= Length(Contents) do
  begin
    Q := PosEx(#10, Contents, P);
    if Q = 0 then Q := Length(Contents) + 1;
    Line := Trim(Copy(Contents, P, Q - P));
    if AnsiStartsStr('[', Line) then
    begin
      if InSection then Exit;
      InSection := Line = '[Default Applications]';
      if InSection then InsertAt := Min(Q + 1, Length(Contents) + 1);
    end
    else if InSection then
    begin
      if AnsiStartsStr(Mime + '=', Line) then
      begin
        StartAt := P;
        EndAt := Q;
        Exit(True);
      end;
      InsertAt := Min(Q + 1, Length(Contents) + 1);
    end;
    P := Q + 1;
  end;
end;

function LapReadDefault(const Contents, Mime: string): string;
var
  P, Q, InsertAt: integer;
begin
  Result := '';
  if FindDefault(Contents, Mime, P, Q, InsertAt) then
  begin
    Result := Trim(Copy(Contents, P, Q - P));
    Delete(Result, 1, Pos('=', Result));
  end;
end;

function LapPatchDefault(const Contents, Mime, Value: string): string;
var
  P, Q, InsertAt: integer;
  Ending, NewLine: string;
begin
  Result := Contents;
  Ending := #10;
  if Pos(#13#10, Contents) > 0 then Ending := #13#10;
  NewLine := '';
  if Value <> '' then NewLine := Mime + '=' + Value + Ending;
  if FindDefault(Contents, Mime, P, Q, InsertAt) then
  begin
    if Q > Length(Contents) then NewLine := Mime + '=' + Value;
    if Value = '' then NewLine := '';
    Result := Copy(Contents, 1, P - 1) + NewLine + Copy(Contents, Q + 1, MaxInt);
  end
  else if Value <> '' then
  begin
    if InsertAt = 0 then
    begin
      if (Result <> '') and (Result[Length(Result)] <> #10) then Result := Result + Ending;
      Result := Result + '[Default Applications]' + Ending + NewLine;
    end
    else
    begin
      if (InsertAt > 1) and (Result[InsertAt - 1] <> #10) then NewLine := Ending + NewLine;
      Insert(NewLine, Result, InsertAt);
    end;
  end;
end;

{$IFNDEF WINDOWS}
function ReadOptional(const Filename: string): string;
begin
  Result := '';
  if FileExists(Filename) then Result := FileAssReadFile(Filename);
end;

procedure WriteDefault(const Filename, Mime, Value: string);
var
  Original, Updated, Temp: string;
begin
  Original := ReadOptional(Filename);
  Updated := LapPatchDefault(Original, Mime, Value);
  if Updated = Original then Exit;
  ForceDirectories(ExtractFileDir(Filename));
  Temp := GetTempFileName(ExtractFileDir(Filename), '.lap');
  try
    FileAssWriteFile(Temp, Updated);
    if ReadOptional(Filename) <> Original then
      raise Exception.Create('File associations changed in another program. Apply again.');
    if not RenameFile(Temp, Filename) then RaiseLastOSError;
  finally
    if FileExists(Temp) then DeleteFile(Temp);
  end;
end;

{$ENDIF}

procedure RequireSuccess(const Outcome: TFileAssResult);
begin
  if not Outcome.Succeeded then raise Exception.Create(Outcome.Message);
end;

procedure Configure(Manager: TFileAssMan; Profile: TLapProfile; const Extensions: string);
var
  Selected: TStringList;
  I: integer;
  Item: TFileAssTypeItem;
begin
  Manager.FileTypes.Clear;
  Manager.ApplicationID := LapApplicationID(Profile.ID);
  Manager.ApplicationName := Profile.Name;
  Manager.ApplicationDescription := 'Open in this Lazarus build';
  Manager.ExecutablePath := ExpandFileName(ParamStr(0));
  Manager.RegistrationScope := fasCurrentUser;
  Manager.SupportsMultipleFiles := True;
  Manager.ShowInApplicationMenu := False;
  Manager.LinuxApplicationIcon := 'applications-development';
  Selected := TStringList.Create;
  try
    Selected.StrictDelimiter := True;
    Selected.Delimiter := ',';
    Selected.DelimitedText := Extensions;
    for I := 0 to LapTypeCount - 1 do
      if Selected.IndexOf(LapExtensions[I]) >= 0 then
      begin
        Item := Manager.FileTypes.Add;
        Item.Extension := LapExtensions[I];
        Item.MimeType := LapMimes[I];
        Item.Description := Copy(LapExtensions[I], 2, MaxInt) + ' Lazarus file';
        Item.OpenArguments := '--open=' + Profile.ID + ' --';
      end;
  finally
    Selected.Free;
  end;
end;

function IsOurDefault(const Value: string): boolean;
begin
  Result := AnsiStartsStr('io.github.tonystone31.lazasspicker.build-', Value);
end;

{ The default for one key: a MIME type in mimeapps.list on Linux, an
  extension under the user's Software\Classes on Windows. }

{$IFDEF WINDOWS}
const
  ClassesKey = 'Software\Classes\';
  UserChoiceKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\';

function ReadRegistry(const Key, Name: string): string;
var
  Reg: TRegistry;
begin
  Result := '';
  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKeyReadOnly(Key) then
    try
      if Reg.ValueExists(Name) then Result := Reg.ReadString(Name);
    finally
      Reg.CloseKey;
    end;
  finally
    Reg.Free;
  end;
end;

function OurValue(const ID, Key: string): string;
begin
  Result := LapApplicationID(ID) + Key;
end;

function CurrentDefault(State: TMemIniFile; const Key: string): string;
begin
  Result := ReadRegistry(ClassesKey + Key, '');
end;

procedure SetDefault(State: TMemIniFile; const Key, Value: string);
var
  Reg: TRegistry;
begin
  Reg := TRegistry.Create;
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if not Reg.OpenKey(ClassesKey + Key, Value <> '') then Exit;
    try
      if Value <> '' then Reg.WriteString('', Value)
      else
        Reg.DeleteValue('');
    finally
      Reg.CloseKey;
    end;
  finally
    Reg.Free;
  end;
  SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nil, nil);
end;

// A choice made with "Always use this app" outranks Software\Classes.
function EffectiveDefault(const Key: string): string;
begin
  Result := ReadRegistry(UserChoiceKey + Key + '\UserChoice', 'ProgId');
  if Result = '' then Result := CurrentDefault(nil, Key);
end;

procedure DefaultKeys(const Extensions: string; Keys: TStrings);
var
  Exts: TStringList;
  I: integer;
begin
  Exts := TStringList.Create;
  try
    Exts.StrictDelimiter := True;
    Exts.Delimiter := ',';
    Exts.DelimitedText := Extensions;
    for I := 0 to LapTypeCount - 1 do
      if Exts.IndexOf(LapExtensions[I]) >= 0 then Keys.Add(LapExtensions[I]);
  finally
    Exts.Free;
  end;
end;
{$ELSE}

function OurValue(const ID, Key: string): string;
begin
  Result := LapApplicationID(ID) + '.desktop;';
end;

function DefaultFileOf(State: TMemIniFile): string;
begin
  Result := State.ReadString('State', 'DefaultFile', '');
  if Result = '' then
  begin
    Result := LapDefaultFile;
    State.WriteString('State', 'DefaultFile', Result);
    State.UpdateFile;
  end;
end;

function CurrentDefault(State: TMemIniFile; const Key: string): string;
begin
  Result := LapReadDefault(ReadOptional(DefaultFileOf(State)), Key);
end;

procedure SetDefault(State: TMemIniFile; const Key, Value: string);
begin
  WriteDefault(DefaultFileOf(State), Key, Value);
end;

function EffectiveDefault(const Key: string): string;
var
  Output: string;
  P: integer;
begin
  Result := '';
  // GIO honors quoted Exec paths; the generic xdg-mime parser does not.
  if not RunCommand('env', ['LC_ALL=C', 'gio', 'mime', Key], Output) then
    raise Exception.Create('Could not verify the default application with GIO.');
  P := Pos(#10, Output);
  if P > 0 then SetLength(Output, P - 1);
  P := Pos(': ', Output);
  if P > 0 then Result := Trim(Copy(Output, P + 2, MaxInt)) + ';';
end;

// Pascal sources share one MIME type, so the keys are the distinct MIME types.
procedure DefaultKeys(const Extensions: string; Keys: TStrings);
var
  Exts: TStringList;
  I: integer;
begin
  Exts := TStringList.Create;
  try
    Exts.StrictDelimiter := True;
    Exts.Delimiter := ',';
    Exts.DelimitedText := Extensions;
    for I := 0 to LapTypeCount - 1 do
      if (Exts.IndexOf(LapExtensions[I]) >= 0) and (Keys.IndexOf(LapMimes[I]) < 0) then
        Keys.Add(LapMimes[I]);
  finally
    Exts.Free;
  end;
end;
{$ENDIF}

procedure RestoreDefault(State: TMemIniFile; const Key: string; Log: TStrings);
begin
  if IsOurDefault(CurrentDefault(State, Key)) then
    SetDefault(State, Key, State.ReadString('PreviousDefaults', Key, ''));
  State.DeleteKey('PreviousDefaults', Key);
  State.UpdateFile;
  Log.Add('Restored previous choice for ' + Key + '.');
end;

procedure LapApply(Settings: TLapSettings; Manager: TFileAssMan; Log: TStrings);
var
  State: TMemIniFile;
  Desired, OldIDs, Keys, Previous, Overruled: TStringList;
  Profile: TLapProfile;
  I, J: integer;
  Wanted, Effective: string;
begin
  Profile := Settings.FindID(Settings.DefaultID);
  if (Profile = nil) or not Profile.Enabled then
    raise Exception.Create('Choose an enabled build as the default.');
  if Settings.Extensions = '' then raise Exception.Create('Select at least one file type.');
  for I := 0 to Settings.Count - 1 do
    if Settings[I].Enabled then Settings[I].Validate;
  Settings.Save;
  State := TMemIniFile.Create(LapConfigDirectory + 'associations.ini');
  Desired := TStringList.Create;
  OldIDs := TStringList.Create;
  Keys := TStringList.Create;
  Previous := TStringList.Create;
  Overruled := TStringList.Create;
  try
    DefaultKeys(Settings.Extensions, Keys);
    if Keys.Count = 0 then raise Exception.Create('No supported file types selected.');
    State.ReadSection('Registered', OldIDs);
    for I := 0 to Settings.Count - 1 do
      if Settings[I].Enabled then
      begin
        Configure(Manager, Settings[I], Settings.Extensions);
        // Record the ID first so even a partial registration can be removed.
        State.WriteBool('Registered', Settings[I].ID, True);
        State.UpdateFile;
        RequireSuccess(Manager.RegisterAll);
        Desired.Add(Settings[I].ID);
        Log.Add('Registered ' + Settings[I].Name + ' in Open With.');
      end;
    State.ReadSection('PreviousDefaults', Previous);
    for I := 0 to Previous.Count - 1 do
      if Keys.IndexOf(Previous[I]) < 0 then RestoreDefault(State, Previous[I], Log);
    for I := 0 to Keys.Count - 1 do
    begin
      if not State.ValueExists('PreviousDefaults', Keys[I]) then
      begin
        State.WriteString('PreviousDefaults', Keys[I], CurrentDefault(State, Keys[I]));
        State.UpdateFile;
      end;
      Wanted := OurValue(Settings.DefaultID, Keys[I]);
      SetDefault(State, Keys[I], Wanted);
      Effective := EffectiveDefault(Keys[I]);
      if Effective <> Wanted then
      {$IFDEF WINDOWS}
        Overruled.Add(Keys[I]);
        {$ELSE}
        raise Exception.Create('The desktop did not accept the default for ' + Keys[I] + '. Expected ' + Wanted + ', received ' +
          Trim(Effective) + '. Check Open With settings.');
      {$ENDIF}
    end;
    for J := 0 to OldIDs.Count - 1 do
      if Desired.IndexOf(OldIDs[J]) < 0 then
      begin
        Manager.ApplicationID := LapApplicationID(OldIDs[J]);
        RequireSuccess(Manager.UnregisterAll);
        State.DeleteKey('Registered', OldIDs[J]);
        State.UpdateFile;
      end;
    Log.Add('Default: ' + Profile.Name + '. Associations applied.');
    // Windows keeps a choice made with "Always use this app" over ours.
    if Overruled.Count > 0 then
      Log.Add('Windows keeps your earlier choice for ' + Overruled.CommaText + '. To change it, right-click such a file, Open with, choose ' +
        Profile.Name + ' and tick "Always use this app".');
  finally
    Overruled.Free;
    Previous.Free;
    Keys.Free;
    OldIDs.Free;
    Desired.Free;
    State.Free;
  end;
end;

procedure LapRemove(Manager: TFileAssMan; Log: TStrings);
var
  State: TMemIniFile;
  IDs, Mimes: TStringList;
  I: integer;
begin
  ForceDirectories(LapConfigDirectory);
  State := TMemIniFile.Create(LapConfigDirectory + 'associations.ini');
  IDs := TStringList.Create;
  Mimes := TStringList.Create;
  try
    State.ReadSection('PreviousDefaults', Mimes);
    for I := 0 to Mimes.Count - 1 do RestoreDefault(State, Mimes[I], Log);
    State.ReadSection('Registered', IDs);
    for I := 0 to IDs.Count - 1 do
    begin
      Manager.ApplicationID := LapApplicationID(IDs[I]);
      RequireSuccess(Manager.UnregisterAll);
      State.DeleteKey('Registered', IDs[I]);
      State.UpdateFile;
    end;
    State.EraseSection('State');
    State.UpdateFile;
    Log.Add('Removed LazAssPicker associations. Your build list is kept.');
  finally
    Mimes.Free;
    IDs.Free;
    State.Free;
  end;
end;

end.
