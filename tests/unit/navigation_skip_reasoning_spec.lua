local assert = require('luassert')

local navigation = require('opencode.ui.navigation')
local renderer = require('opencode.ui.renderer')
local state = require('opencode.state')
local ctx = require('opencode.ui.renderer.ctx')

---@param entries table[] list of { id, kind, line_start, line_end? }
---@param parts table[] list of { id, message_id, kind, line_start, line_end }
local function seed(entries, parts)
  ctx.entries = {}
  for _, r in ipairs(entries) do
    local entry = { id = r.id, kind = r.kind, content = {} }
    ctx.entries[#ctx.entries + 1] = entry
    ctx.render_state:set_message(entry, r.line_start, r.line_end or r.line_start)
  end
  for _, p in ipairs(parts or {}) do
    ctx.render_state:set_part(
      { id = p.id, kind = p.kind, synthetic = p.synthetic },
      p.message_id,
      p.id,
      p.line_start,
      p.line_end or p.line_start
    )
  end
end

local function clear_render()
  ctx.entries = {}
  ctx.render_state:reset()
end

describe('navigation skip-reasoning default', function()
  local output_buf, output_win
  local original_windows

  before_each(function()
    clear_render()
    original_windows = state.store.get('windows')
    output_buf = vim.api.nvim_create_buf(false, true)
    local lines = {}
    for i = 1, 200 do
      lines[i] = 'line ' .. i
    end
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, lines)
    output_win = vim.api.nvim_open_win(output_buf, true, {
      relative = 'editor',
      width = 80,
      height = 10,
      row = 0,
      col = 0,
    })
    state.ui.set_windows({ output_buf = output_buf, output_win = output_win })
  end)

  after_each(function()
    clear_render()
    pcall(vim.api.nvim_win_close, output_win, true)
    pcall(vim.api.nvim_buf_delete, output_buf, { force = true })
    if original_windows ~= nil then
      state.ui.set_windows(original_windows)
    else
      state.ui.clear_windows()
    end
  end)

  describe('renderer.get_next_rendered_message', function()
    it('skips the reasoning part and lands on the next text part of the next message', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 10 },
        { id = 'u2', kind = 'user', line_start = 60 },
      }, {
        { id = 'r1', message_id = 'a1', kind = 'reasoning', line_start = 12 },
        { id = 't1', message_id = 'a1', kind = 'text', line_start = 30 },
        { id = 'tool1', message_id = 'a1', kind = 'tool', line_start = 45 },
      })

      local result = renderer.get_next_rendered_message(5)

      assert.is_not_nil(result)
      assert.equals('a1', result.message.id)
      assert.equals(30, result.line_start)
    end)

    it('falls back to message header when the next message has only reasoning', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 20 },
      }, {
        { id = 'r1', message_id = 'a1', kind = 'reasoning', line_start = 22 },
      })

      local result = renderer.get_next_rendered_message(5)

      assert.is_not_nil(result)
      assert.equals('a1', result.message.id)
      assert.equals(20, result.line_start)
    end)

    it('preserves the header fallback when no parts are registered for the next message', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 20 },
      }, {})

      local result = renderer.get_next_rendered_message(5)

      assert.is_not_nil(result)
      assert.equals(20, result.line_start)
    end)

    it('skips synthetic parts', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 10 },
      }, {
        { id = 'syn1', message_id = 'a1', kind = 'text', synthetic = true, line_start = 12 },
        { id = 't1', message_id = 'a1', kind = 'text', line_start = 20 },
      })

      local result = renderer.get_next_rendered_message(5)

      assert.is_not_nil(result)
      assert.equals(20, result.line_start)
    end)

    it('skips step_start and step_finish parts', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 10 },
      }, {
        { id = 's_start', message_id = 'a1', kind = 'step_start', line_start = 11 },
        { id = 'r1', message_id = 'a1', kind = 'reasoning', line_start = 13 },
        { id = 's_end', message_id = 'a1', kind = 'step_finish', line_start = 18 },
        { id = 't1', message_id = 'a1', kind = 'text', line_start = 20 },
      })

      local result = renderer.get_next_rendered_message(5)

      assert.is_not_nil(result)
      assert.equals(20, result.line_start)
    end)

    it('lands on current message content when cursor sits above the first content part', function()
      -- Cursor on the message header or inside reasoning must land on the
      -- current message's first visible content part.
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 10 },
        { id = 'u2', kind = 'user', line_start = 80 },
      }, {
        { id = 'r1', message_id = 'a1', kind = 'reasoning', line_start = 15 },
        { id = 't1', message_id = 'a1', kind = 'text', line_start = 30 },
      })

      local from_header = renderer.get_next_rendered_message(11)
      assert.is_not_nil(from_header)
      assert.equals('a1', from_header.message.id)
      assert.equals(30, from_header.line_start)

      local from_reasoning = renderer.get_next_rendered_message(16)
      assert.is_not_nil(from_reasoning)
      assert.equals('a1', from_reasoning.message.id)
      assert.equals(30, from_reasoning.line_start)
    end)
  end)

  describe('renderer.get_prev_rendered_message', function()
    it('skips the reasoning part and lands on the first content part of the previous message', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 10 },
        { id = 'u2', kind = 'user', line_start = 80 },
      }, {
        { id = 'r1', message_id = 'a1', kind = 'reasoning', line_start = 12 },
        { id = 't1', message_id = 'a1', kind = 'text', line_start = 30 },
      })

      local result = renderer.get_prev_rendered_message(70)

      assert.is_not_nil(result)
      assert.equals('a1', result.message.id)
      assert.equals(30, result.line_start)
    end)

    it('returns nil when no message exists before cursor', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 30 },
      }, {})

      local result = renderer.get_prev_rendered_message(2)

      assert.is_nil(result)
    end)

    it('skips the current message and lands on previous message content when cursor is on reasoning', function()
      -- From a1 reasoning, `p` must skip a1 and land on u1's content.
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 10 },
      }, {
        { id = 'r1', message_id = 'a1', kind = 'reasoning', line_start = 15 },
        { id = 't1', message_id = 'a1', kind = 'text', line_start = 30 },
      })

      local result = renderer.get_prev_rendered_message(16)

      assert.is_not_nil(result)
      assert.equals('u1', result.message.id)
      assert.equals(1, result.line_start)
    end)
  end)

  describe('navigation.goto_next_message', function()
    it('lands on the text part when reasoning opens the assistant message', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 10 },
      }, {
        { id = 'r1', message_id = 'a1', kind = 'reasoning', line_start = 12 },
        { id = 't1', message_id = 'a1', kind = 'text', line_start = 30 },
      })

      vim.api.nvim_win_set_cursor(output_win, { 2, 0 })
      navigation.goto_next_message()

      local cursor = vim.api.nvim_win_get_cursor(output_win)
      assert.equals(31, cursor[1])
    end)

    it('falls back to message header when reasoning is the only part', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 20 },
      }, {
        { id = 'r1', message_id = 'a1', kind = 'reasoning', line_start = 22 },
      })

      vim.api.nvim_win_set_cursor(output_win, { 2, 0 })
      navigation.goto_next_message()

      local cursor = vim.api.nvim_win_get_cursor(output_win)
      assert.equals(21, cursor[1])
    end)
  end)

  describe('navigation.goto_prev_message', function()
    it('lands on the first content part of the previous message', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 10 },
        { id = 'u2', kind = 'user', line_start = 80 },
      }, {
        { id = 'r1', message_id = 'a1', kind = 'reasoning', line_start = 12 },
        { id = 't1', message_id = 'a1', kind = 'text', line_start = 30 },
      })

      vim.api.nvim_win_set_cursor(output_win, { 70, 0 })
      navigation.goto_prev_message()

      local cursor = vim.api.nvim_win_get_cursor(output_win)
      assert.equals(31, cursor[1])
    end)
  end)

  describe('jumplist preservation with reasoning present', function()
    -- The content-aware jump must preserve the previous position too.
    it('marks the previous position before jumping past reasoning', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 10 },
        { id = 'u2', kind = 'user', line_start = 80 },
      }, {
        { id = 'r1', message_id = 'a1', kind = 'reasoning', line_start = 12 },
        { id = 't1', message_id = 'a1', kind = 'text', line_start = 30 },
      })
      vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, vim.fn['repeat']({ 'line' }, 100))
      vim.api.nvim_win_set_cursor(output_win, { 5, 0 })
      vim.api.nvim_buf_set_mark(output_buf, "'", 1, 0, {})

      navigation.goto_next_message()

      local mark = vim.api.nvim_buf_get_mark(output_buf, "'")
      assert.equals(5, mark[1])
      assert.equals(0, mark[2])

      local cursor = vim.api.nvim_win_get_cursor(output_win)
      assert.equals(31, cursor[1])
    end)
  end)
end)
