# Repairing Codex history lookup

A cached chat can appear in Zommi while Codex returns
`no rollout found for thread id ...` when it is opened. Check the `codexHome`
returned by app-server `initialize` against the home containing that chat's
`sessions/.../rollout-...-<thread-id>.jsonl` file. Launching Zommi from a terminal
or updater that inherits a different `CODEX_HOME` can expose this mismatch.
The sidebar catalog stores runtime and session IDs; it does not move histories
when the runtime's home changes.

Zommi now saves the `codexHome` reported by the first successful app-server
handshake for each exact runtime target. Subsequent launches and recovery
attempts explicitly set `CODEX_HOME` to that directory, including inside the
Windows-to-WSL relay. A different returned home or an unreadable binding stops
the connection before loading or creating chats.

Bindings live in a `codex-homes` directory next to `session-binding.json`.
Each file is named with the SHA-256 of the runtime target ID and contains
`runtimeTargetId` and `codexHome`. When repairing an existing split installation,
close Zommi, repair the history links below, and set that target's binding to the
chosen absolute home before restarting. Changing a binding selects a history
directory; it does not move histories or credentials. Keep bindings scoped to
the exact runtime and execution host. Older servers that do not report
`codexHome` retain their existing behavior until a home has been bound.

`scripts/repair_codex_history.py` reproduces the missing-file lookup repair.
Run it on the host where Codex stores its history: for Windows Zommi using WSL
Codex, run the script **inside that WSL distribution**, with the Windows catalog
accessible through `/mnt/c`. Python 3.10 or newer is required. Native Windows
also needs permission to create symbolic links.

Identify the exact Codex target in the catalog's `runtimes` table (`runtime_id`
is `codex`), or use `runtimeTargetId` from `session-binding.json` when Codex is
selected. Supply only the homes belonging to that same runtime and user.
Preview the links, using the real paths and target ID from your installation:

```sh
python3 scripts/repair_codex_history.py \
  --catalog /path/to/Zommi/session-catalog.sqlite \
  --runtime-target-id runtime-your-codex-target \
  --home /path/to/original-codex-home \
  --home /path/to/current-codex-home
```

Repeat the command with `--apply` to create the links. Save its JSON output as
the repair record. `links` identifies every planned source and destination;
`createdLinks` lists the links created by this invocation, including a partial
run that fails. Exit code 0 means the preview or apply succeeded with no
unresolved IDs, 1 means validation or a filesystem operation failed, and
2 means some catalog
IDs have no rollout in any supplied home (available histories are still linked
when `--apply` is supplied). A successful repair can be run again without changes.

The tool reads the catalog without modifying it and considers only IDs for the
chosen Codex target. It validates each rollout's session metadata, creates
missing symbolic links to the original files, and leaves existing files intact.
Continuing a chat through a link writes to its original history. Archived and
uncached chats are outside the repair's scope. Ambiguous sources, mismatched
metadata, broken links, and destinations outside the supplied session directories
cause an error. The report contains paths and IDs, not transcript text or
credentials. Keep original files in place while their links are in use.

After applying, open the previously failing chats in the installed Zommi app,
check their histories, and switch back to the current chat. This verifies the
running app as well as the filesystem. The repair does not change runtime-home
selection: select the repaired home in the target's home binding before
reconnecting. It does not resolve a genuinely missing rollout,
an active writer in another process, or another provider's connection failure.

Run the regression suite with:

```sh
python3 tests/test_codex_history_repair.py -v
python3 tests/test_codex_home_persistence.py -v
```
