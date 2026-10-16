local config = require('opencode.config')
local state = require('opencode.state')
local formatter = require('opencode.ui.formatter')
local output_window = require('opencode.ui.output_window')
local contexts = require('opencode.ui.renderer.ctx')
local buffer = require('opencode.ui.renderer.buffer')

describe('tool borders across neighboring rewrites', function()
  local original_config
  local buf, win, ctx
  local message = { id = 'msg', kind = 'assistant' }

  local function has_border(row)
    local marks = vim.api.nvim_buf_get_extmarks(
      buf,
      output_window.namespace,
      { row, 0 },
      { row, -1 },
      { details = true }
    )
    for _, mark in ipairs(marks) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        if chunk[2] == 'OpencodeToolBorder' then
          return true
        end
      end
    end
    return false
  end

  local function mount(parts)
    local lines = {}
    for _, part in ipairs(parts) do
      local formatted = formatter.format_part(part, message, true)
      local start = #lines
      vim.list_extend(lines, formatted.lines)
      ctx.formatted_parts[part.id] = formatted
      ctx.render_state:set_part(part, 'msg', part.id, start, #lines - 1)
    end
    output_window.set_lines(lines)
    for _, part in ipairs(parts) do
      output_window.set_extmarks(ctx.formatted_parts[part.id].extmarks, ctx.render_state:get_part(part.id).line_start)
    end
    buffer.set_all_folds(ctx)
  end

  before_each(function()
    original_config = vim.deepcopy(config.values)
    config.setup({})
    ctx = contexts.new()
    buf = vim.api.nvim_create_buf(false, true)
    win = vim.api.nvim_open_win(buf, true, { relative = 'editor', width = 80, height = 10, row = 0, col = 0 })
    state.ui.set_windows({ output_buf = buf, output_win = win })
    output_window.setup({ output_buf = buf, output_win = win })
  end)

  after_each(function()
    state.ui.set_windows(nil)
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
    config.values = original_config
  end)

  for _, name in ipairs({ 'hindsight_search_knowledge_pages', 'bash' }) do
    it('preserves every border on a following ' .. name .. ' tool when reasoning grows', function()
      local reasoning = { id = 'reasoning', kind = 'reasoning', text = 'short', time = { created = 1 } }
      local tool = {
        id = 'tool',
        kind = 'tool',
        name = name,
        state = 'completed',
        input = { query = 'find pages', command = 'make format-check' },
        result = { { kind = 'text', text = '{\n  "pages": []\n}' } },
      }
      mount({ reasoning, tool })
      local old_start = ctx.render_state:get_part('tool').line_start
      assert.is_true(has_border(old_start))

      local previous = ctx.formatted_parts.reasoning
      reasoning.text = string.rep('long reasoning\n', 30)
      local formatted = formatter.format_part(reasoning, message, true)
      ctx.formatted_parts.reasoning = formatted
      buffer.upsert_part_now('reasoning', 'msg', formatted, previous, ctx)

      local cached = ctx.render_state:get_part('tool')
      assert.is_true(cached.line_start > old_start)
      for row = cached.line_start, cached.line_end - 1 do
        assert.is_true(has_border(row), 'Missing ' .. name .. ' border at buffer row ' .. row)
      end
    end)
  end
end)
