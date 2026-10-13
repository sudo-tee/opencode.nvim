# Worktree sessions

[Recipes](README.md) / Worktree sessions

Keep a conversation for each Git worktree in a separate panel tab without
changing Neovim's working directory.

## When to use it

Use this when an agent works in a feature worktree while you keep editing the
main checkout. If you already open a separate Neovim instance in each worktree,
the normal session picker is enough; no extra setup is needed.

## Prerequisites

- Git and Neovim 0.10.3 or later.
- A current opencode.nvim with `open_session` and `register_slash_command`.
- OpenCode V1 or V2. No worktree plugin is required.
- The worktree must exist locally and be accessible to the OpenCode server.
  For a container or remote server, see [Servers](../servers.md#translate-paths).

## Setup

First create a worktree from your repository root. This example assumes your
base branch is `main` and creates a new branch named `feature-login`:

```sh
git worktree add -b feature-login ../feature-login main
```

Add the following after your existing `require('opencode').setup(...)` call.
With lazy.nvim, put it in the plugin's `config` function after
`require('opencode').setup(opts)`:

```lua
require('opencode').register_slash_command({
  name = 'worktree',
  desc = 'Resume a session in an existing worktree',
  args = true,
  fn = function(args)
    local directory = table.concat(args, ' ')
    assert(directory ~= '', 'Usage: /worktree /absolute/path/to/worktree')
    return require('opencode.api').open_session({ directory = directory })
  end,
})
```

The command resumes the most recent root session created in that exact
directory, or creates one if none exists. An already-open session reuses its
panel tab. Errors are reported through the command lifecycle.

## Try it

1. Run `git worktree list` to find the absolute path of `feature-login`.
2. In Neovim, open the panel with `<leader>oi`.
3. Type `/worktree /absolute/path/to/feature-login`, then press `<Esc>` and
   `<CR>`. Replace the example path with the path from step 1; do not quote it,
   even if it contains spaces.
4. Send a prompt about the feature. The session and file completion use the
   worktree, while `:pwd` still shows your original editor directory.
5. Use `<leader>o<` / `<leader>o>` to switch panel tabs. Each bound tab keeps
   its own session directory.

For a fresh conversation instead of resuming, call the API directly:

```lua
require('opencode.api').open_session({
  directory = '/absolute/path/to/feature-login',
  new = true,
  title = 'Feature login',
}):catch(function(err)
  vim.notify(tostring(err), vim.log.levels.ERROR)
end)
```

## Caveats and undo

- This opens a session, not a Git worktree or an editor tabpage. It does not
  move an existing conversation to another directory.
- Automatic current-file context still comes from your editor. When editing
  the main checkout, disable `context.current_file.enabled` for worktree
  prompts or open the worktree file first. See [Context](../context.md).
- An explicit `:cd`, `:lcd`, or `:tcd` follows
  `lock_session_to_directory`. To keep bound tabs in their worktrees across
  editor directory changes, set it to `true` in your existing `setup()` options.
  Manual `:Opencode session toggle_lock` overrides the policy for the active
  panel tab. See [Directory changes](../configuration.md#directory-changes).
- Register the command once. To remove it, delete the setup snippet and run
  `:lua require('opencode').unregister_slash_command('worktree')` or restart
  Neovim. Close its panel tab with `<leader>oQ`; this does not delete the session.

Before removing a worktree, stop its agent and save or commit your changes.
From the main checkout, run `git worktree remove ../feature-login`. Git refuses
to remove a dirty worktree; do not use `--force` to bypass that protection.
The branch and conversation remain, but the session's directory no longer
exists. Recreate the worktree before reopening that session.

## Related

- [Directory-bound sessions](../reference.md#directory-bound-sessions)
- [Local slash commands](../extensions.md#local-slash-commands)
- [Sessions and panel tabs](../usage.md#sessions-and-panel-tabs)
