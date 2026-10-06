# Upgrade to Focalet

The project formerly named **Zommi** now uses **Focalet** for the repository,
source paths, Dart packages, Rust crates, .NET namespaces, executables, installers,
OS application IDs, settings directories and `FOCALET_*` environment variables.
The repository is [timctho/focalet](https://github.com/timctho/focalet).

## Existing installations

1. Quit the old app, including its tray icon and background runtime connections.
2. Uninstall the old app using its own uninstaller, keeping its data. On Ubuntu,
   remove the old package and disable its GNOME extension. On macOS, remove the
   old application bundle after quitting it.
3. Install a Focalet build. The new app uses separate Focalet state directories;
   your agent accounts and canonical conversations remain with each agent.
4. Optionally import your UI preferences and configured runtime commands with
   `python scripts/migrate_legacy_settings.py --apply` before first launch. Run
   without `--apply` to preview the files. Existing Focalet files are never
   overwritten and old files are retained. Automatic discovery and local session
   metadata are rebuilt; accepted or uncertain turns are not replayed.
5. Replace `ZOMMI_` with `FOCALET_` in environment configuration. Update executable
   paths and external integrations to the new names. macOS permissions and GNOME
   desktop integration may need to be authorized again for the new app ID.

Capture and Desktop both use new single-instance identities. Do not run an old
and a new version together: they can compete for hotkeys and agent sessions.
The migration command only copies `settings.json` and `runtime-overrides.json`;
it does not migrate active sessions, cached runtime paths, relay processes,
credentials or agent history.

## Releases and recordings

The first release under the Focalet name is **v0.3.0**. It contains independent
Capture and Desktop installers for Windows x64, macOS Apple Silicon/Intel and
Ubuntu 24.04 GNOME Wayland x64. Download the appropriate installer from the
[README download table](https://github.com/timctho/focalet#download).

Previous GitHub release downloads were removed after the new installers were
published and verified. Git tags retain their source history. Recorded demos keep
their original footage and provenance; current builds display Focalet.
