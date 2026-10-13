# TUI/Neovim sync

[Recipes](../README.md) / TUI/Neovim sync

Work on the same OpenCode session from the terminal TUI and from Neovim.

![Bidirectional sync demo](./bidirectional-sync.gif)

## How it works

Both frontends connect to one OpenCode server, so messages, tool output,
questions, and permission requests show up in both. Each frontend still has its
own windows, cursor, and unsent draft.

Connecting to the same server does not open the same session. You pick the
session in each frontend yourself, usually by passing its ID to the TUI.

To find the session ID in Neovim, set `debug.enabled = true` and press
`<leader>oDs` in the output window.

## OpenCode V2

No setup is needed. The V2 TUI and the plugin both use OpenCode's background
service by default.

```bash
# Open the TUI in the project
opencode /path/to/project

# Or resume the session that Neovim is showing
opencode --session ses_XXXX /path/to/project
```

If the service is slow to start on your machine, raise the timeout in
`setup()`:

```lua
require('opencode').setup({
  server = { timeout = 30 },
})
```

Quitting Neovim leaves the service running, so the TUI keeps working.

For a V2 server at an explicit address, use
`opencode --server <endpoint> --session ses_XXXX <directory>` and set
`OPENCODE_PASSWORD` if the server requires it. Configure the plugin with the
same endpoint; see [Servers](../../servers.md).

## OpenCode V1

V1 has no background service, so start one shared server and point both
frontends at it.

```bash
opencode attach http://127.0.0.1:4096 --dir /path/to/project --session ses_XXXX
```

Configure Neovim with the same endpoint and credentials:

```lua
require('opencode').setup({
  server = {
    url = 'http://127.0.0.1',
    port = 4096,
    password_file = vim.fn.stdpath('state') .. '/opencode/server-password',
  },
})
```

The password file must contain the password on its first line and be readable
only by you (`chmod 600`). If you start the shared server yourself, do not pass
`--shutdown-after-last-client`, or it stops when the first frontend exits.

### Helper script

[`oc-sync.sh`](oc-sync.sh) starts the shared V1 server if it is not running,
then attaches the TUI to it. It reuses the plugin's password file, creating it
if needed. It refuses to run against a V2 CLI.

| Variable | Default | Description |
| --- | --- | --- |
| `OPENCODE_SYNC_PORT` | `4096` | Server port |
| `OPENCODE_SYNC_HOST` | `127.0.0.1` | Server address |
| `OPENCODE_SYNC_WAIT_TIMEOUT_SEC` | `20` | Seconds to wait for startup |
| `OPENCODE_SYNC_PASSWORD_FILE` | `$XDG_STATE_HOME/nvim/opencode/server-password` | Shared password file |

## Troubleshooting

On V2, check the service before debugging the plugin:

```bash
opencode service status
opencode api get /api/info
```

A `401` or `403` means the credentials do not match; starting another server
will not fix it. If both frontends are connected but show different
conversations, they are on different sessions. Pass `--session` to the TUI.

Related: [Three-state layout toggle](../three-state-layout/README.md).
