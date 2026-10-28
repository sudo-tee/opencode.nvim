# Render opencode-pty tools

[Recipes](README.md) / Render opencode-pty tools

Give the tools from [opencode-pty](https://github.com/shekohex/opencode-pty)
a compact presentation: the spawned command as a header, and the terminal
buffer without the plugin's XML wrapper and model-facing reminders.

## When to use it

opencode-pty lets the agent run dev servers, watchers, and REPLs in background
terminals. Its tool names contain an underscore, so without a formatter they
render through the MCP fallback: `pty_read` shows up as server `pty`, tool
`read`, followed by the raw input JSON and the full `<pty_output>` block. Use
this recipe as a starting point for any server plugin that adds its own tools.

## Prerequisites

- OpenCode V1 or V2 with opencode-pty installed (`"plugin": ["opencode-pty"]`
  for V1, `"opencode-pty/v2"` for V2). Both normalize tool parts to the same
  `input`, `result`, `state`, `error`, and `time` fields before formatting.
- No additional Neovim plugins needed.

## Setup

Register before the first PTY tool part renders. `pty_spawn` and `pty_read`
are not built-in names, so no `replace` opt-in is needed.

```lua
local opencode = require('opencode')
local config = require('opencode.config')

local function result_text(part)
  local text = {}
  for _, item in ipairs(part.result or {}) do
    if item.kind == 'text' then
      text[#text + 1] = item.text
    end
  end
  return table.concat(text, '\n')
end

local function command_line(input)
  return vim.trim((input.command or '') .. ' ' .. table.concat(input.args or {}, ' '))
end

-- pty_read wraps the buffer in <pty_output> and may append <system_reminder>
-- blocks meant for the model; keep only the buffer.
local function buffer_lines(text)
  local body = text:match('<pty_output[^>]*>\n(.-)\n</pty_output>')
  if not body then
    return {}
  end
  local lines = {}
  for _, line in ipairs(vim.split(body, '\n')) do
    lines[#lines + 1] = (line:gsub('^%d+| ', ''))
  end
  return lines
end

local function add_folded(output, lines)
  local tools = config.values.ui.output.tools
  if #lines == 0 or not (tools.show_output or tools.use_folds) then
    return
  end
  output:add_empty_line()
  local content_start = output:get_line_count() + 1
  output:add_lines(lines)
  output:add_fold_with_threshold(content_start, tools.show_output, tools.use_folds)
end

opencode.register_tool_formatter('pty_spawn', {
  format = function(output, part)
    local input = part.input or {}
    local command = command_line(input)
    if command == '' then
      command = 'starting'
    end
    local id = result_text(part):match('ID: (pty_%w+)')
    output:add_line('**pty** `' .. command .. '`' .. (id and (' · ' .. id) or ''))
    if input.title or input.description then
      output:add_line(input.title or input.description)
    end
  end,
  summary = function(part)
    return '', 'pty', command_line(part.input or {})
  end,
})

opencode.register_tool_formatter('pty_read', {
  format = function(output, part)
    local input = part.input or {}
    local header = '**pty read** `' .. (input.id or 'pending') .. '`'
    if input.pattern then
      header = header .. ' /' .. input.pattern .. '/'
    end
    output:add_line(header)
    add_folded(output, buffer_lines(result_text(part)))
  end,
  summary = function(part)
    return '', 'pty read', (part.input and part.input.id) or ''
  end,
})

opencode.setup({})
```

`pty_write`, `pty_list`, and `pty_kill` keep the MCP fallback. Register them
the same way if you want them to match.

## Try it

1. Install opencode-pty and restart the OpenCode server.
2. Ask `Start the dev server in a background PTY session, then show me any
   errors in its output`.
3. The `pty_spawn` part shows the command and session ID. The `pty_read` part
   shows the filter pattern and the matching buffer lines under a fold, with
   no XML tags, line-number prefixes, or system reminders. Folding still
   follows `ui.output.tools.show_output`, `use_folds`, and `folding_threshold`.

## Caveats and undo

The formatter parses opencode-pty's text output (`ID: pty_…` and the
`<pty_output>` wrapper). If a plugin release changes that text, the header
loses the ID and the buffer renders empty; the tool border, error callouts,
and streaming preview still come from core rendering. If the formatter throws,
the error is logged and the MCP fallback renders that part instead.

Remove the formatters to restore the fallback for future renders:

```lua
require('opencode').unregister_tool_formatter('pty_spawn')
require('opencode').unregister_tool_formatter('pty_read')
```

See [Tool formatters](../extensions.md#tool-formatters) for the stable contract,
including how to override a built-in formatter such as `bash`.

## Related

- [GitHub issue references](completion-source.md) uses the same recipe-owned
  registration pattern for completion.
