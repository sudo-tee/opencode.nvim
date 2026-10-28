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

## Completion sources

Recipes can add completion sources without modifying built-in sources or the
completion engine. Register sources before `setup()` or before opening the
first `opencode` buffer so custom trigger characters are advertised to the
completion client:

```lua
local Promise = require('opencode.promise')
local opencode = require('opencode')

opencode.register_completion_source({
  name = 'issue_references',
  priority = 10,
  get_trigger_character = function()
    return '>'
  end,
  complete = Promise.async(function(ctx)
    if ctx.trigger_char ~= '>' then
      return {}
    end

    return {
      {
        label = '>123 Fix login timeout',
        kind = 'issue',
        kind_icon = '',
        detail = 'GitHub issue',
        documentation = 'Insert an issue reference.',
        insert_text = '123',
        data = { number = 123 },
      },
    }
  end),
  on_complete = function(item)
    vim.notify('Selected issue #' .. item.data.number)
  end,
})

opencode.setup({})
```

`name` must be unique. Built-in names (`commands`, `context`, `files`,
`skills`, and `subagents`) are reserved. `complete` receives a
`CompletionContext` with `input`, `trigger_char`, `line`, and `cursor_pos`, and
may return either a `Promise<CompletionItem[]>` or an item array. The registry
adds `source_name` to returned items so `on_complete` can be called after
selection. Item metadata includes `kind`, `kind_icon`, `kind_hl`, `detail`,
`documentation`, `insert_text`, `priority`, and arbitrary `data`. Set
source-level `custom_kind` to a numeric LSP completion kind when the default
function kind is not suitable. `insert_text` replaces text after the trigger
character; include the trigger in `label` but not in `insert_text`.

Completion-source errors are logged and that source contributes no items;
other sources continue working. Selection callback errors are isolated the
same way. Set `is_incomplete = true` when a source expects the client to ask
for more results. Remove a recipe with:

```lua
require('opencode').unregister_completion_source('issue_references')
```

The function returns `true` when a source was removed and `false` otherwise.
For a practical selection callback, see the [GitHub issue references recipe](recipes/completion-source.md),
which expands the selected issue into the visible draft.

## Tool formatters

Recipes can render tools added by an OpenCode server plugin. Registration uses
the exact tool name reported in `part.name`. This one renders `pty_read` from
[opencode-pty](https://github.com/shekohex/opencode-pty), keeping the terminal
buffer and dropping the `<pty_output>` wrapper and model-facing reminders:

```lua
local function result_text(part)
  local text = {}
  for _, item in ipairs(part.result or {}) do
    if item.kind == 'text' then
      text[#text + 1] = item.text
    end
  end
  return table.concat(text, '\n')
end

require('opencode').register_tool_formatter('pty_read', {
  format = function(output, part)
    local input = part.input or {}
    output:add_line('**pty read** `' .. (input.id or 'pending') .. '`')

    local body = result_text(part):match('<pty_output[^>]*>\n(.-)\n</pty_output>')
    if not body then
      return
    end

    output:add_empty_line()
    local content_start = output:get_line_count() + 1
    output:add_lines(vim.split(body, '\n'))
    local tools = require('opencode.config').values.ui.output.tools
    output:add_fold_with_threshold(content_start, tools.show_output, tools.use_folds)
  end,
  summary = function(part)
    return '', 'pty read', (part.input and part.input.id) or ''
  end,
})

require('opencode').setup({})
```

Use the exact name the server reports; a plugin can add several tools, so
register each one separately. `format(output, part, context)` runs on every
render, including while the tool streams. Do not assume the final input or
result is present:

- `pending` and `streaming`: `part.input` may be incomplete or absent. V2
  exposes the raw streamed fragment as `part.input_text`; V1 may expose a
  partial `part.input`.
- `running`: input is usually available, but `part.result` may not be.
- `completed` and `error`: `part.result` and `part.error` are available when
  the server supplies them.

Guard optional fields and return without content when nothing useful is
available yet. Core re-renders the part as input and results arrive, so the
formatter stays in sync without callbacks or timers.

Add detail lines under a fold to let the streaming preview work. While a tool
or reasoning part streams, core keeps the last
`ui.output.tools.streaming_preview_lines` content lines of the final fold
visible. Fold filtering, including `fold_exclude`, still applies after the
formatter returns.

Use the output methods available to built-in formatters: `add_line`,
`add_lines`, `add_empty_line`, `add_extmark`, `add_action`, `add_target`, and
`add_fold_with_threshold`. `part` is the normalized tool part, so the same
fields (`name`, `state`, `input`, `input_text`, `result`, `time`, `error`) are
available for V1 and V2 sessions. Do not create windows or buffers, change the
renderer, or keep references to the output after `format` returns; the renderer
owns that lifecycle.

`summary(part)` is optional and returns the icon, label, and value shown when
the tool appears as a row inside a task or subagent. An override without
`summary` keeps the matching built-in summary when one exists, then falls back
to the generic tool summary.

Core rendering still owns:

- the tool border;
- fold filtering, including `fold_exclude`;
- streaming previews;
- error callouts;
- renderer scheduling and lifecycle.

Registration can happen before or after `setup()` and applies to the next
render of a matching tool part. An unregistered plugin tool name uses the MCP
formatter when it contains an underscore, otherwise the generic tool formatter.

Built-in names such as `bash`, `shell`, `read`, `edit`, `write`, `grep`,
`webfetch`, and `task` are reserved. Replacing one requires an explicit opt-in:

```lua
require('opencode').register_tool_formatter('bash', {
  format = function(output, part)
    output:add_line('Bash: ' .. (part.input.command or ''))
  end,
}, { replace = true })
```

Duplicate custom registrations are rejected, including a second attempt with
`replace = true`; only one active override exists per tool. If a custom
formatter throws, the error is logged, its partial output is discarded, and the
matching built-in formatter renders the part instead. Remove a registration
with:

```lua
require('opencode').unregister_tool_formatter('pty_read')
```

The function returns `true` when a custom formatter or built-in override was
removed and `false` otherwise. Removing an override restores the built-in
formatter. For complete formatters covering `pty_spawn` and `pty_read`, see the
[opencode-pty recipe](recipes/tool-formatter.md).

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
