# GitHub issue references

[Recipes](README.md) / GitHub issue references

Use a recipe-owned completion source to insert GitHub issue references while
writing an OpenCode prompt.

## When to use it

Use this when prompts frequently refer to issues in the current repository.
The built-in completion sources do not query GitHub, so this recipe adds a
  small `>`-triggered source without changing built-in completion behavior.

## Prerequisites

- `gh` authenticated for the repository.
- OpenCode V1 or V2; completion runs before either protocol is used.
- An LSP-compatible completion client, or Neovim's native completion.

## Setup

Place this after `require('opencode')` is available and before the first
`opencode` buffer opens. `gh issue list` runs in the current working directory.

```lua
local Promise = require('opencode.promise')
local opencode = require('opencode')

local function issue_source()
  return {
    name = 'github_issue_references',
    priority = 10,
    get_trigger_character = function()
      return '>'
    end,
    complete = Promise.async(function(ctx)
      if ctx.trigger_char ~= '>' then
        return {}
      end

      local result = Promise.system({
        'gh',
        'issue',
        'list',
        '--state',
        'all',
        '--limit',
        '50',
        '--json',
        'number,title',
      }, { text = true }):await()
      local issues = vim.json.decode(result.stdout)
      local input = ctx.input:lower()
      local items = {}

      for _, issue in ipairs(issues) do
        local label = string.format('>%d %s', issue.number, issue.title)
        if input == '' or label:lower():find(input, 1, true) then
          table.insert(items, {
            label = label,
            kind = 'issue',
            kind_icon = '',
            detail = 'GitHub issue',
            documentation = 'Insert #' .. issue.number .. ' into the prompt.',
            insert_text = tostring(issue.number),
            data = { number = issue.number },
          })
        end
      end

      return items
    end),
    on_complete = function(item)
      vim.schedule(function()
        local buf = vim.api.nvim_get_current_buf()
        local win = vim.api.nvim_get_current_win()
        local cursor = vim.api.nvim_win_get_cursor(win)
        local row, col = unpack(cursor)
        local reference = '>' .. item.data.number
        local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
        local start_col = col - #reference
        if line:sub(col - #reference + 2, col + 1) == reference then
          col = col + 1
          start_col = col - #reference
        end
        if start_col < 0 or line:sub(start_col + 1, col) ~= reference then
          vim.notify('Could not locate selected issue reference', vim.log.levels.WARN)
          return
        end

        local tick = vim.api.nvim_buf_get_changedtick(buf)
        vim.system({ 'gh', 'issue', 'view', tostring(item.data.number), '--json', 'number,title,body,url' }, {
          text = true,
          cwd = vim.fn.getcwd(),
        }, vim.schedule_wrap(function(result)
          if result.code ~= 0 then
            vim.notify('Could not load GitHub issue: ' .. (result.stderr or ''), vim.log.levels.WARN)
            return
          end
          local ok, issue = pcall(vim.json.decode, result.stdout)
          if not ok then
            vim.notify('Could not decode GitHub issue', vim.log.levels.WARN)
            return
          end
          if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick then
            vim.notify('Issue not expanded: draft changed while loading', vim.log.levels.WARN)
            return
          end

          local body = issue.body or ''
          if vim.fn.strchars(body) > 10000 then
            body = vim.fn.strcharpart(body, 0, 10000) .. '\n\n[Issue description truncated]'
          end
          local text = ('GitHub issue #%s: %s\n%s\n\n%s'):format(issue.number, issue.title, issue.url, body)
          local lines = vim.split(text, '\n', { plain = true })
          local move_cursor = vim.api.nvim_get_current_win() == win
            and vim.api.nvim_win_is_valid(win)
            and vim.api.nvim_win_get_buf(win) == buf
            and vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor)
          vim.api.nvim_buf_set_text(buf, row - 1, start_col, row - 1, col, lines)
          if move_cursor then
            vim.api.nvim_win_set_cursor(win, { row + #lines - 1, #lines[#lines] })
          end
        end))
      end)
    end,
  }
end

opencode.register_completion_source(issue_source())
opencode.setup({})
```

## Try it

1. Open an `opencode` input buffer in a GitHub checkout.
2. Type `>` or `>login`.
3. Select an issue. Its title, URL, and description replace `><number>` in the
   draft. Review the text before sending.

## Caveats and undo

An unavailable or failed `gh` command is isolated by the completion registry,
so the source returns no items while built-in sources remain available. The
source is queried on each completion request and is intentionally limited to
the first 50 issues. Descriptions longer than 10,000 characters are truncated.
If issue loading fails or the draft changes while loading, the reference stays
in place and a warning is shown; no context is attached silently.

Remove it with:

```lua
require('opencode').unregister_completion_source('github_issue_references')
```

See [Completion sources](../extensions.md#completion-sources) for the stable
source contract.
