# Changelog

## 0.3.0

- Each build shows the configuration folder it starts with, worked out as
  Lazarus does: the launch arguments, then `lazarus.cfg` beside the
  executable, then the default. `~/` and relative folders are read as
  Lazarus reads them, and a build found through a shortcut and a folder
  scan is listed once.
- A warning beside the build and when applying when two checked builds
  would share one configuration folder.
- `--pcp <folder>` written with a space is refused instead of being passed
  on, where Lazarus would open the folder as a file.
- Quotes around the folder in `lazarus.cfg` are pointed out: Lazarus 4 and
  older read them as part of the folder's name.

## 0.2.0

- Windows: finds builds beside fpcupdeluxe and from desktop and Start menu
  shortcuts, and registers them for the current user.
- Windows: says when an "Always use this app" choice keeps another program
  as the default, and how to change it.
- Command-line options print to the console they were run from on Windows.
- Unicode file names and arguments pass through unchanged on Windows.

## 0.1.0

- Discover Lazarus builds from fpcupdeluxe settings, install folders, and desktop launchers.
- Keep separate configuration arguments and working directories for each build.
- Choose a double-click default and register other builds in Open With through FileAss.
- Open projects and source files from the build list.
- Remove associations and restore previous default entries while preserving newer choices.
- Provide a GTK3 interface with the cheetah mascot, light/dark theme support, and saved geometry.
- A donkey on a guitar pick for the application icon.
- The window shows its version and links to the releases page.
- Package a standalone Linux x86-64 executable with documentation and checksums.
