# Roadmap

## First version

- [x] Read fpcupdeluxe INI files and Lazarus configuration without editing them.
- [x] Import desktop launchers and preserve configuration arguments and working directories.
- [x] Remember scan roots and refresh stable build entries after updates.
- [x] Provide an editable GTK3 form with build selection and file-type checkboxes.
- [x] Register enabled builds through FileAss and set an explicit default.
- [x] Open projects and source files in the selected build.
- [x] Remove owned registrations and restore previous default entries.
- [x] Test discovery, quoting, forwarding, and association lifecycle in isolation.
- [x] Embed the mascot badge and application icon.
- [x] Provide GitHub documentation and a screenshot using example installations.
- [x] Build a versioned Linux release archive with documentation and a checksum.

## Follow-up checks

- Native Wayland GUI behavior.
- File-manager integration on additional Linux desktops.
- Windows 11.
- macOS only if someone asks: LazAssPicker.app as the single handler that
  asks which build to open.

## Windows

- [x] Find `lazarus.exe` beside fpcupdeluxe and import desktop and Start menu shortcuts.
- [x] Register each build under the user's `Software\Classes`, with Open With entries.
- [x] Report when an "Always use this app" choice keeps Windows on another program.
- [x] Pass Unicode paths, spaces and several files through unchanged.
- [x] Write command-line output to the console the program was started from.
