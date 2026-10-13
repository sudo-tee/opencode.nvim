# Compatibility

[Documentation](README.md) / Compatibility

The plugin works with both OpenCode V1 and V2. It detects the protocol from the
server's health response; there is nothing to configure.

| Area | V2 | V1 |
| --- | --- | --- |
| Local startup | Native background service when supported by the CLI | Local `serve` process |
| Chat, context, sessions | Supported | Supported |
| Change review | Session diff API and inline review comments | Experimental Git-worktree snapshots |
| Skills | Native activation or skill attachment when the server supports it | Skill content sent as a prompt |
| Service shutdown | Owned by OpenCode | Plugin-managed process cleanup |

Some features depend on what your server version supports. If one is missing,
update OpenCode.

## The legacy plugin branch

To stay on the old plugin implementation:

```lua
return { 'sudo-tee/opencode.nvim', branch = 'v1' }
```

You don't need this to talk to a V1 server. These docs cover the current
branch; the `v1` branch has its own README.

## V1 snapshots and restore points

> [!WARNING]
> V1 snapshots are experimental and were never an official OpenCode feature.
> Reverting overwrites files, so commit first. V2 uses
> [session diffs](review.md) instead.

On V1 the plugin keeps Git-worktree snapshots of the workspace. Put the cursor
on a snapshot in the output to get these actions:

- Diff: compare the current files with the snapshot.
- Revert file: restore one file from the snapshot.
- Revert all: restore every file from the snapshot.

`<leader>ora` / `<leader>ort` revert all/current-file changes since the last
prompt; `<leader>orA` / `<leader>orT` target the session snapshot. Snapshot-specific
commands are listed in the [reference](reference.md#legacy-snapshot-actions-v1).

Each revert first saves a restore point. Its Restore file and Restore all
actions undo the revert. `<leader>orr` and `<leader>orR` do the same from the
keyboard.

`snapshot_path` sets where snapshots are stored. The default is OpenCode's data
directory (`$XDG_DATA_HOME/opencode`), and the plugin appends
`/snapshot/<project_id>/<worktree_hash>`. It only affects V1.
