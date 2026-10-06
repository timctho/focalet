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

Already published release assets and recorded demos keep their original bytes,
checksums and source revisions. A repository rename does not rename old installer
assets. If a release lists `Zommi-Setup-x64.exe`, `Zommi-macOS-*.dmg` or
`Zommi-Ubuntu-amd64.deb`, it predates this change. Use that release's filenames,
or build Focalet from the current source until a new release is published.
New release artifacts use `Focalet-*` and `focalet-*` names.
