# Hooks and events

[Documentation](README.md) / Hooks and events

Hooks cover plugin-level moments like a finished response or an edited file.
For raw server events, use a User autocmd. Events can belong to any session,
not only the one shown in the panel.

## User hooks

Configure callbacks under `hooks`:

| Hook | Input / behavior |
| --- | --- |
| `on_file_edited` | File path after an OpenCode edit |
| `on_session_loaded` | Loaded session object |
| `on_done_thinking` | Session when it becomes idle, including work started outside Neovim |
| `on_permission_requested` | Session with a permission request |
| `on_question_asked` | Session with a question |
| `on_topbar_render` | Bar segments; return replacement segments or `nil` to clear |
| `on_footer_render` | Bar segments; return replacement segments or `nil` to clear |

```lua
require('opencode').setup({
  hooks = {
    on_file_edited = function(path)
      vim.notify('OpenCode edited ' .. path)
    end,
    on_session_loaded = function(session)
      vim.notify('Loaded ' .. session.id)
    end,
    on_done_thinking = function(session)
      if not session.parentID then
        vim.notify('OpenCode finished in ' .. session.id)
      end
    end,
    on_footer_render = function(segments)
      table.insert(segments, 1, { vim.fn.fnamemodify(vim.fn.getcwd(), ':t') .. ' ', 'OpencodeHint' })
      return segments
    end,
  },
})
```

A bar segment is `{ 'text', 'HighlightGroup', align = 'left'|'right' }`.
Highlight and alignment are optional; alignment defaults to left. If a bar hook
throws, the built-in segments are used.

The command dispatcher also supports `on_command_before`, `on_command_after`,
`on_command_error`, and `on_command_finally`. These receive an
`OpencodeCommandDispatchContext`; see [`types.lua`](../lua/opencode/types.lua)
and [`dispatch.lua`](../lua/opencode/commands/dispatch.lua) for the lifecycle
contract. They fire for every command, whether it came from a key, an API
call, an Ex command, or a slash command.

## Local slash commands

Register a Lua callback before or after `setup()`:

```lua
require('opencode').register_slash_command({
  name = 'hello',
  desc = 'Show supplied arguments',
  args = true,
  fn = function(args)
    vim.notify(table.concat(args, ' '))
  end,
})
```

`fn` receives a string array, empty when no arguments were supplied. `args = true`
lets completion leave room for arguments. Commands appear in completion and the
picker, and execute through command lifecycle hooks; filter by `/hello`.

Names contain letters, digits, underscores, or hyphens, without a leading slash.
Builtin and registered name collisions throw. Local commands take precedence
over same-named server commands and skills. Callback errors use normal command
error handling. `require('opencode').unregister_slash_command('hello')` removes
the command and returns whether it existed.

See [Worktree sessions](recipes/worktree.md) for a practical command.

## Prompt guard

`prompt_guard(mentioned_files)` must return a boolean. It receives a list of
mentioned file paths and can also inspect Neovim state:

```lua
require('opencode').setup({
  prompt_guard = function(mentioned_files)
    local blocked = vim.fn.expand('~/work/private-project')
    return vim.fn.getcwd() ~= blocked
  end,
})
```

The guard runs before each prompt is sent and when a session opens. `false`
blocks the action. An error or a non-boolean result also blocks it and reports
why. The context bar shows when the guard has blocked something.

The example only matches that exact directory, not its subdirectories. The
guard only controls what Neovim sends; it does not limit what the agent can
read. Use OpenCode permissions for that.

## Server events as User autocmds

Forwarded server events use the pattern `OpencodeEvent:<event.type>`. The
event is in `args.data.event`:

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'OpencodeEvent:permission.*',
  callback = function(args)
    vim.notify(vim.inspect(args.data.event))
  end,
})
```

Use `OpencodeEvent:*` for everything or a family like
`OpencodeEvent:session.*`. Event names and payloads differ between V1 and V2,
so inspect an event before relying on its fields. Payloads can contain prompt
and file contents.

## Highlights

Default highlights cover light and dark backgrounds. Override them with
`nvim_set_hl`, typically in a `ColorScheme` autocmd:

```lua
vim.api.nvim_create_autocmd('ColorScheme', {
  callback = function()
    vim.api.nvim_set_hl(0, 'OpencodeBackground', { link = 'NormalFloat' })
    vim.api.nvim_set_hl(0, 'OpencodeHint', { link = 'Comment' })
  end,
})
```

Common groups:

| Area | Groups |
| --- | --- |
| Panel | `OpencodeBackground`, `OpencodeBorder`, `OpencodeHint`, `OpencodeInputLegend` |
| Messages | `OpencodeMessageRoleUser`, `OpencodeMessageRoleAssistant`, `OpencodeToolBorder`, `OpencodeReasoningText` |
| Agent/model | `OpencodeAgentBuild`, `OpencodeAgentPlan`, `OpencodeAgentCustom`, `OpencodeVariant` |
| Context | `OpencodeMention`, `OpencodeContextCurrentFile`, `OpencodeContextCurrentFileNotUpdated`, `OpencodeContextSelection`, `OpencodeContextReviewComment` |
| Review | `OpencodeDiffAdd`, `OpencodeDiffDelete`, `OpencodeReviewComment`, `OpencodeReviewCommentSign`, `OpencodeReviewCommentStale` |
| Tabs | `OpencodeSessionTabActive`, `OpencodeSessionTabInactive`, `OpencodeSessionTabPendingPermission`, `OpencodeSessionTabPendingQuestion` |
| Actions | `OpencodeContextualActions`, `OpencodeGuardDenied`, `OpencodeReference`, `OpencodeSymbolReference` |

The complete list and default links/colors are in
[`ui/highlight.lua`](../lua/opencode/ui/highlight.lua). `ui.window_highlight`
controls the panel's window highlight mapping.
