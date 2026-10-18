program lazasspicker;

{$mode objfpc}{$H+}{$codepage utf8}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF WINDOWS}
  Windows,
  {$ENDIF}
  Interfaces,
  Forms,
  Dialogs,
  SysUtils,
  Classes,
  LazUTF8,
  FileAssMan,
  lapProfiles,
  lapAssociations,
  lapMain;

  {$R icons/lapassets.res}

  {$IFDEF WINDOWS}
  // A GUI program on Windows starts with no standard output: write where
  // the output was redirected, else to the console it was started from,
  // else nowhere.
  procedure OpenStandardOutput;
  var
    Name: string;
  begin
    if (StdOutputHandle <> 0) and (StdOutputHandle <> INVALID_HANDLE_VALUE) then
      Name := ''
    else if AttachConsole(ATTACH_PARENT_PROCESS) then
      Name := 'CONOUT$'
    else
      Name := 'NUL';
    Assign(Output, Name);
    Rewrite(Output);
    Assign(StdErr, Name);
    Rewrite(StdErr);
  end;
  {$ENDIF}

  procedure CommandLine;
  var
    Settings: TLapSettings;
    Manager: TFileAssMan;
    Files, Log: TStringList;
    P: TLapProfile;
    I, Added: integer;
    Action: string;
  begin
    if ParamCount = 0 then Exit;
    {$IFDEF WINDOWS}
    OpenStandardOutput;
    {$ENDIF}
    Action := ParamStrUTF8(1);
    Settings := TLapSettings.Create;
    Manager := TFileAssMan.Create(nil);
    Files := TStringList.Create;
    Log := TStringList.Create;
    try
      try
        Settings.Load;
        if Copy(Action, 1, 7) = '--open=' then
        begin
          P := Settings.FindID(Copy(Action, 8, MaxInt));
          if P = nil then raise Exception.Create('This Lazarus build is no longer configured. Open LazAssPicker and rescan.');
          for I := 2 to ParamCount do
            if (I <> 2) or (ParamStrUTF8(I) <> '--') then Files.Add(ParamStrUTF8(I));
          LapLaunch(P, Files);
        end
        else if Action = '--apply' then LapApply(Settings, Manager, Log)
        else if Action = '--remove' then LapRemove(Manager, Log)
        else if (Action = '--list') or (Copy(Action, 1, 7) = '--scan=') then
        begin
          if Copy(Action, 1, 7) = '--scan=' then
          begin
            if Settings.ScanRoots.IndexOf(Copy(Action, 8, MaxInt)) < 0 then
              Settings.ScanRoots.Add(Copy(Action, 8, MaxInt));
            Added := Settings.Discover;
            Settings.Save;
            Log.Add('New builds: ' + IntToStr(Added));
          end;
          for I := 0 to Settings.Count - 1 do
            Log.Add(Settings[I].ID + #9 + Settings[I].Name + #9 + Settings[I].Executable + #9 + Settings[I].Arguments);
        end
        else if (Action = '--help') or (Action = '-h') then
        begin
          Log.Add('LazAssPicker: a companion for multiple fpcupdeluxe Lazarus builds.');
          Log.Add('Place the executable beside fpcupdeluxe and run it to open the GUI.');
          Log.Add('--scan=FOLDER  Read an install or fpcupdeluxe folder and desktop launchers.');
          Log.Add('--list         List saved builds.');
          Log.Add('--apply        Apply saved association choices.');
          Log.Add('--remove       Remove associations and restore previous defaults.');
        end
        else
          raise Exception.Create('Unknown option. Use --help.');
        Write(Log.Text);
      except
        on E: Exception do
        begin
          if Copy(Action, 1, 7) = '--open=' then
          begin
            Application.Initialize;
            MessageDlg('LazAssPicker', E.Message, mtError, [mbOK], 0);
          end
          else
            WriteLn(StdErr, 'LazAssPicker: ' + E.Message);
          ExitCode := 1;
        end;
      end;
    finally
      Log.Free;
      Files.Free;
      Manager.Free;
      Settings.Free;
    end;
    Halt(ExitCode);
  end;

begin
  CommandLine;
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Title := 'LazAssPicker';
  Application.Initialize;
  Application.CreateForm(TLapMainForm, LapMainForm);
  Application.Run;
end.
