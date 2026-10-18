unit lapMain;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls, CheckLst,
  Dialogs, IniPropStorage, FileAssMan, lapProfiles;

type
  TLapMainForm = class(TForm)
    AddButton, ApplyButton, BrowseButton, ImportButton, OpenButton, RemoveBuildButton, RemoveButton, RescanButton: TButton;
    ArgumentsEdit, DirectoryEdit, ExecutableEdit, NameEdit: TEdit;
    ArgumentsLabel, DefaultLabel, DirectoryLabel, ExecutableLabel, IntroLabel, NameLabel, ReadOnlyLabel, SourceLabel, TitleLabel: TLabel;
    BottomPanel, DetailsPanel, DiscoveryPanel, HeaderPanel, ProfilesPanel: TPanel;
    Builds: TCheckListBox;
    Badge: TImage;
    VersionLabel, ReleasesLabel: TLabel;
    DefaultBuild: TComboBox;
    FileTypes: TCheckGroup;
    Log: TMemo;
    Splitter: TSplitter;
    FileDialog: TOpenDialog;
    FolderDialog: TSelectDirectoryDialog;
    Geometry: TIniPropStorage;
    Associations: TFileAssMan;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: boolean);
    procedure GeometryRestore(Sender: TObject);
    procedure BuildClick(Sender: TObject);
    procedure BuildCheck(Sender: TObject);
    procedure EditDone(Sender: TObject);
    procedure DefaultChange(Sender: TObject);
    procedure TypesChange(Sender: TObject);
    procedure FileTypeClick(Sender: TObject; Index: integer);
    procedure RescanClick(Sender: TObject);
    procedure BrowseClick(Sender: TObject);
    procedure ImportClick(Sender: TObject);
    procedure AddClick(Sender: TObject);
    procedure RemoveBuildClick(Sender: TObject);
    procedure ApplyClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure OpenClick(Sender: TObject);
    procedure ReleasesClick(Sender: TObject);
  private
    FSettings: TLapSettings;
    FSelected: integer;
    FUpdating: boolean;
    procedure StoreSelected;
    procedure RefreshBuilds;
    procedure ShowSelected;
    procedure SaveChoices;
    procedure ReportError(E: Exception);
  end;

const
  // release.sh checks that this matches the VERSION file.
  LapVersion = '0.2.0';
  LapReleasesURL = 'https://github.com/TonyStone31/LazAssPicker/releases';

var
  LapMainForm: TLapMainForm;

implementation

uses
  LCLIntf, lapAssociations;

  {$R *.lfm}

procedure TLapMainForm.FormCreate(Sender: TObject);
var
  I, Added: integer;
  Selected: TStringList;
  FirstRun: boolean;
begin
  VersionLabel.Caption := 'Version ' + LapVersion;
  Badge.Picture.LoadFromResourceName(HInstance, 'LAPBADGE', TPortableNetworkGraphic);
  Icon.LoadFromResourceName(HInstance, 'MAINICON');
  Application.Icon.Assign(Icon);
  FSelected := -1;
  FSettings := TLapSettings.Create;
  ForceDirectories(LapConfigDirectory);
  Geometry.IniFileName := LapConfigDirectory + 'window.ini';
  FirstRun := not FileExists(LapConfigDirectory + 'settings.ini');
  FSettings.Load;
  Selected := TStringList.Create;
  try
    Selected.CommaText := FSettings.Extensions;
    for I := 0 to LapTypeCount - 1 do
    begin
      FileTypes.Items.Add(LapExtensions[I]);
      FileTypes.Checked[I] := Selected.IndexOf(LapExtensions[I]) >= 0;
    end;
  finally
    Selected.Free;
  end;
  if FirstRun then
  begin
    Added := FSettings.Discover;
    FSettings.Save;
    Log.Lines.Add('Found ' + IntToStr(Added) + ' Lazarus builds. Choose a default, then Apply.');
  end
  else
    Log.Lines.Add('Choose a project to open, or adjust your file associations.');
  Log.Lines.Add('Scanning reads installation files and original launchers without changing them.');
  RefreshBuilds;
end;

procedure TLapMainForm.FormDestroy(Sender: TObject);
begin
  FSettings.Free;
end;

procedure TLapMainForm.FormCloseQuery(Sender: TObject; var CanClose: boolean);
begin
  try
    SaveChoices;
  except
    on E: Exception do
    begin
      CanClose := False;
      ReportError(E);
    end;
  end;
end;

procedure TLapMainForm.GeometryRestore(Sender: TObject);
begin
  MakeFullyVisible;
end;

procedure TLapMainForm.ReportError(E: Exception);
begin
  Log.Lines.Add('Error: ' + E.Message);
  MessageDlg('LazAssPicker', E.Message, mtError, [mbOK], 0);
end;

procedure TLapMainForm.StoreSelected;
var
  P: TLapProfile;
begin
  if FUpdating or (FSelected < 0) or (FSelected >= FSettings.Count) then Exit;
  P := FSettings[FSelected];
  P.Name := Trim(NameEdit.Text);
  P.Executable := Trim(ExecutableEdit.Text);
  P.Arguments := Trim(ArgumentsEdit.Text);
  P.WorkingDirectory := Trim(DirectoryEdit.Text);
end;

procedure TLapMainForm.ShowSelected;
var
  P: TLapProfile;
begin
  FUpdating := True;
  try
    DetailsPanel.Enabled := (FSelected >= 0) and (FSelected < FSettings.Count);
    OpenButton.Enabled := DetailsPanel.Enabled;
    RemoveBuildButton.Enabled := DetailsPanel.Enabled;
    NameEdit.Clear;
    ExecutableEdit.Clear;
    ArgumentsEdit.Clear;
    DirectoryEdit.Clear;
    SourceLabel.Caption := 'Source: select or add a build';
    if not DetailsPanel.Enabled then Exit;
    P := FSettings[FSelected];
    NameEdit.Text := P.Name;
    ExecutableEdit.Text := P.Executable;
    ArgumentsEdit.Text := P.Arguments;
    DirectoryEdit.Text := P.WorkingDirectory;
    SourceLabel.Caption := 'Source: ' + P.Source;
    SourceLabel.Hint := SourceLabel.Caption;
  finally
    FUpdating := False;
  end;
end;

procedure TLapMainForm.RefreshBuilds;
var
  I, DefaultIndex: integer;
begin
  FUpdating := True;
  try
    Builds.Items.Clear;
    DefaultBuild.Items.Clear;
    DefaultIndex := -1;
    for I := 0 to FSettings.Count - 1 do
    begin
      Builds.Items.Add(FSettings[I].Name);
      Builds.Checked[I] := FSettings[I].Enabled;
      if FSettings[I].Enabled then
      begin
        DefaultBuild.Items.AddObject(FSettings[I].Name, FSettings[I]);
        if FSettings[I].ID = FSettings.DefaultID then DefaultIndex := DefaultBuild.Items.Count - 1;
      end;
    end;
    if (DefaultIndex < 0) and (DefaultBuild.Items.Count > 0) then
    begin
      DefaultIndex := 0;
      FSettings.DefaultID := TLapProfile(DefaultBuild.Items.Objects[0]).ID;
    end;
    DefaultBuild.ItemIndex := DefaultIndex;
    if FSelected >= FSettings.Count then FSelected := FSettings.Count - 1;
    if (FSelected < 0) and (FSettings.Count > 0) then FSelected := 0;
    Builds.ItemIndex := FSelected;
  finally
    FUpdating := False;
  end;
  ShowSelected;
end;

procedure TLapMainForm.BuildClick(Sender: TObject);
begin
  if FUpdating then Exit;
  StoreSelected;
  FSelected := Builds.ItemIndex;
  ShowSelected;
end;

procedure TLapMainForm.BuildCheck(Sender: TObject);
var
  I: integer;
begin
  if FUpdating then Exit;
  StoreSelected;
  for I := 0 to FSettings.Count - 1 do FSettings[I].Enabled := Builds.Checked[I];
  FSelected := Builds.ItemIndex;
  RefreshBuilds;
end;

procedure TLapMainForm.EditDone(Sender: TObject);
begin
  if FUpdating then Exit;
  StoreSelected;
  RefreshBuilds;
end;

procedure TLapMainForm.DefaultChange(Sender: TObject);
begin
  if not FUpdating and (DefaultBuild.ItemIndex >= 0) then
    FSettings.DefaultID := TLapProfile(DefaultBuild.Items.Objects[DefaultBuild.ItemIndex]).ID;
end;

procedure TLapMainForm.TypesChange(Sender: TObject);
var
  I: integer;
begin
  FSettings.Extensions := '';
  for I := 0 to FileTypes.Items.Count - 1 do
    if FileTypes.Checked[I] then
    begin
      if FSettings.Extensions <> '' then FSettings.Extensions := FSettings.Extensions + ',';
      FSettings.Extensions := FSettings.Extensions + FileTypes.Items[I];
    end;
end;

procedure TLapMainForm.FileTypeClick(Sender: TObject; Index: integer);
begin
  TypesChange(Sender);
end;

procedure TLapMainForm.SaveChoices;
begin
  StoreSelected;
  TypesChange(nil);
  FSettings.Save;
end;

procedure TLapMainForm.RescanClick(Sender: TObject);
var
  Added: integer;
begin
  try
    StoreSelected;
    Added := FSettings.Discover;
    FSettings.Save;
    RefreshBuilds;
    Log.Lines.Add('Rescan complete: ' + IntToStr(Added) + ' new builds. Existing launchers refreshed.');
  except
    on E: Exception do ReportError(E);
  end;
end;

procedure TLapMainForm.BrowseClick(Sender: TObject);
var
  Added: integer;
begin
  FolderDialog.InitialDir := ExtractFileDir(ExpandFileName(ParamStr(0)));
  if not FolderDialog.Execute then Exit;
  try
    StoreSelected;
    if FSettings.ScanRoots.IndexOf(FolderDialog.FileName) < 0 then
      FSettings.ScanRoots.Add(FolderDialog.FileName);
    Added := FSettings.Discover;
    FSettings.Save;
    RefreshBuilds;
    Log.Lines.Add('Folder scan complete: ' + IntToStr(Added) + ' new builds.');
  except
    on E: Exception do ReportError(E);
  end;
end;

procedure TLapMainForm.ImportClick(Sender: TObject);
begin
  FileDialog.Title := 'Import a Lazarus launcher';
  FileDialog.Filter := 'Lazarus launchers|' + LapLauncherMask;
  FileDialog.InitialDir := LapDesktopDirectory;
  if not FileDialog.Execute then Exit;
  try
    StoreSelected;
    if FSettings.ImportLauncher(FileDialog.FileName) then
      Log.Lines.Add('Imported launcher.')
    else
      Log.Lines.Add('No new build: duplicate, missing executable, or unsupported launcher.');
    FSettings.Save;
    RefreshBuilds;
  except
    on E: Exception do ReportError(E);
  end;
end;

procedure TLapMainForm.AddClick(Sender: TObject);
var
  P: TLapProfile;
begin
  FileDialog.Title := 'Choose the Lazarus executable';
  {$IFDEF WINDOWS}
  FileDialog.Filter := 'Programs|*.exe';
  {$ELSE}
  FileDialog.Filter := 'All files|*';
  {$ENDIF}
  FileDialog.InitialDir := GetUserDir;
  if not FileDialog.Execute then Exit;
  StoreSelected;
  P := TLapProfile.Create;
  P.Name := 'Lazarus ' + ExtractFileName(ExtractFileDir(FileDialog.FileName));
  P.Executable := FileDialog.FileName;
  P.WorkingDirectory := ExtractFileDir(P.Executable);
  P.Source := 'Manual entry';
  FSettings.Add(P);
  FSelected := FSettings.Count - 1;
  RefreshBuilds;
end;

procedure TLapMainForm.RemoveBuildClick(Sender: TObject);
begin
  if FSelected < 0 then Exit;
  FSettings.Delete(FSelected);
  RefreshBuilds;
  Log.Lines.Add('Build removed from the list. Apply to update its associations.');
end;

procedure TLapMainForm.ApplyClick(Sender: TObject);
begin
  try
    SaveChoices;
    LapApply(FSettings, Associations, Log.Lines);
  except
    on E: Exception do ReportError(E);
  end;
end;

procedure TLapMainForm.RemoveClick(Sender: TObject);
begin
  try
    LapRemove(Associations, Log.Lines);
  except
    on E: Exception do ReportError(E);
  end;
end;

procedure TLapMainForm.OpenClick(Sender: TObject);
begin
  if FSelected < 0 then Exit;
  FileDialog.Title := 'Open a project or source file in ' + FSettings[FSelected].Name;
  FileDialog.Filter := 'Lazarus projects and sources|*.lpi;*.lpr;*.lpk;*.pas;*.pp;*.lfm;*.inc|All files|*';
  FileDialog.InitialDir := GetUserDir;
  FileDialog.Options := FileDialog.Options + [ofAllowMultiSelect];
  try
    if FileDialog.Execute then
    begin
      SaveChoices;
      LapLaunch(FSettings[FSelected], FileDialog.Files);
      Log.Lines.Add('Opened in ' + FSettings[FSelected].Name + '.');
    end;
  except
    on E: Exception do ReportError(E);
  end;
  FileDialog.Options := FileDialog.Options - [ofAllowMultiSelect];
end;

procedure TLapMainForm.ReleasesClick(Sender: TObject);
begin
  if not OpenURL(LapReleasesURL) then
    Log.Lines.Add('Could not open a browser. The releases are at ' + LapReleasesURL);
end;

end.
