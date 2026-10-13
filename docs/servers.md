# Servers

[Documentation](README.md) / Servers

With a local OpenCode V2 install, leave `server` unset. Read on if OpenCode runs
somewhere else (another host, a container, WSL) or you start it yourself.

## How the plugin finds a server

- **V2 CLI:** the plugin asks `opencode service status` for the address and
  credentials of OpenCode's background service, and starts the service if it
  is stopped. Quitting Neovim leaves it running.
- **V1 CLI:** the plugin starts `opencode serve` locally and stops it when the
  last Neovim instance using it exits.
- **`server.url` or `server.spawn_command` set:** the plugin connects to that
  server instead, as described below.

In every case the plugin checks the server's health endpoint to tell V1 from V2.

Several frontends can share one server, but each picks its own session. To
work on the same session from the TUI, see
[TUI/Neovim sync](recipes/bidirectional-sync/README.md).

## Connect to a running server

```lua
require('opencode').setup({
  server = {
    url = 'http://127.0.0.1',
    port = 8080,
    timeout = 10,
  },
})
```

Put the host in `url` and the port in `port`; do not add the port to the URL.
For a server on another machine, use HTTPS or an SSH tunnel. The server must
see the project at the same path as Neovim, or you need a
[path map](#translate-paths).

## Authentication

The password is taken from the first of these that is set:

1. `server.password`
2. the file at `server.password_file`
3. `$OPENCODE_PASSWORD`
4. `$OPENCODE_SERVER_PASSWORD`

The username is `server.username`, then `$OPENCODE_SERVER_USERNAME`, then
`opencode`. The V2 background service supplies its own credentials, so none of
this applies to it.

A password file holds the password on its first line and must be readable only
by you (`chmod 600`); otherwise connecting fails. Prefer a file or environment
variable to a password written in your config.

`username` and `password` can also be functions, called when connecting:

```lua
require('opencode').setup({
  server = {
    url = 'http://127.0.0.1',
    port = 8080,
    password = function()
      return vim.fn.readfile(vim.fn.expand('~/.config/opencode/server-password'))[1]
    end,
  },
})
```

## Translate paths

If the server sees the project at a different path, map between the two. For a
project mounted at `/app` in a container:

```lua
require('opencode').setup({
  server = {
    url = 'http://127.0.0.1',
    port = 8080,
    path_map = '/app',
  },
})
```

`path_map` is either a base path on the server or a function that turns a local
path into a server path. `reverse_path_map` does the opposite, for paths the
server sends back. For Neovim on Windows with OpenCode in WSL:

```lua
require('opencode').setup({
  server = {
    url = 'http://127.0.0.1',
    port = 8080,
    path_map = function(path)
      local drive, rest = path:match('^([A-Za-z]):(.*)$')
      if drive then
        return '/mnt/' .. drive:lower() .. rest:gsub('\\', '/')
      end
      return path
    end,
    reverse_path_map = function(path)
      local drive, rest = path:match('^/mnt/([a-z])(.*)$')
      if drive then
        return drive:upper() .. ':' .. rest:gsub('/', '\\')
      end
      return path
    end,
  },
})
```

Start the server in WSL first. Before asking for edits, check that `@`
mentions and `gf` in the output both open the right files.

## Start the server yourself

`spawn_command(port, url, env)` is called when nothing answers at the
configured address. Start the server there, passing `env` to the process: it
holds the credentials the plugin will use. `kill_command(port, url)` is called
to stop it.

A V1 example:

```lua
require('opencode').setup({
  server = {
    url = 'http://127.0.0.1',
    port = 'auto',
    spawn_command = function(port, url, env)
      return vim.fn.jobstart({
        'opencode', 'serve', '--hostname', '127.0.0.1', '--port', tostring(port),
      }, { env = env, detach = true })
    end,
  },
})
```

`port = 'auto'` picks a free port. Do not use this with V2, which has its own
service. For Docker or WSL launchers, run the command by hand first, pass
arguments as a list rather than a shell string, and expose only the port you
need.

With `auto_kill = true` (the default), a server started by `spawn_command` is
stopped when the last Neovim instance using it exits. Servers you started
outside Neovim are never stopped by the plugin.

## Settings

| Setting | Default | Purpose |
| --- | --- | --- |
| `url`, `port` | `nil` | Server address; `port` is a number or `'auto'` |
| `timeout` | `5` | Seconds to wait for the server to respond |
| `retry_delay` | `2000` | Milliseconds between connection attempts |
| `health_check_ttl_ms` | `5000` | How long a successful health check is reused |
| `spawn_command`, `kill_command` | `nil` | Start and stop a server yourself |
| `auto_kill` | `true` | Stop a spawned server when the last Neovim exits |
| `path_map`, `reverse_path_map` | `nil` | Translate paths to and from the server |
| `username`, `password` | `nil` | Credentials, as strings or functions |
| `password_file` | `nil` | File holding the password |

For a V1 server on a fixed port, the plugin keeps a generated password in
Neovim's state directory, so later Neovim instances can reuse the server. The
[sync recipe](recipes/bidirectional-sync/README.md#opencode-v1) shows how to
share it with the TUI.

If the connection fails, see [Troubleshooting](troubleshooting.md).
