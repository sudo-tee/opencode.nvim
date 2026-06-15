local assert = require('luassert')
local stub = require('luassert.stub')

local navigation = require('opencode.ui.navigation')
local renderer = require('opencode.ui.renderer')
local state = require('opencode.state')
local ctx = require('opencode.ui.renderer.ctx')

---@param messages table[]
---@param rendered table[] list of { id = string, line_start = integer, line_end = integer? }
local function seed(messages, rendered)
  state.renderer.set_messages(messages)
  for _, r in ipairs(rendered) do
    ctx.render_state:set_message({ info = { id = r.id, role = r.role } }, r.line_start, r.line_end or r.line_start)
  end
end

local function clear_render()
  state.renderer.set_messages({})
  ctx.render_state:reset()
end

describe('navigation user message jumps', function()
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

  describe('renderer.get_prev_user_message', function()
    it('skips assistant messages and returns previous user message before cursor', function()
      seed({
        { info = { id = 'u1', role = 'user' } },
        { info = { id = 'a1', role = 'assistant' } },
        { info = { id = 'u2', role = 'user' } },
        { info = { id = 'a2', role = 'assistant' } },
        { info = { id = 'u3', role = 'user' } },
      }, {
        { id = 'u1', role = 'user', line_start = 1 },
        { id = 'a1', role = 'assistant', line_start = 20 },
        { id = 'u2', role = 'user', line_start = 40 },
        { id = 'a2', role = 'assistant', line_start = 60 },
        { id = 'u3', role = 'user', line_start = 80 },
      })

      local result = renderer.get_prev_user_message(50)

      assert.is_not_nil(result)
      assert.equals('u2', result.message.info.id)
    end)

    it('returns nil when only assistant messages exist before cursor', function()
      seed({
        { info = { id = 'a1', role = 'assistant' } },
        { info = { id = 'a2', role = 'assistant' } },
      }, {
        { id = 'a1', role = 'assistant', line_start = 1 },
        { id = 'a2', role = 'assistant', line_start = 20 },
      })

      local result = renderer.get_prev_user_message(30)

      assert.is_nil(result)
    end)

    it('returns the last user message before cursor when cursor is past all lines', function()
      seed({
        { info = { id = 'u1', role = 'user' } },
        { info = { id = 'a1', role = 'assistant' } },
        { info = { id = 'u2', role = 'user' } },
      }, {
        { id = 'u1', role = 'user', line_start = 1 },
        { id = 'a1', role = 'assistant', line_start = 10 },
        { id = 'u2', role = 'user', line_start = 20 },
      })

      local result = renderer.get_prev_user_message(999)

      assert.is_not_nil(result)
      assert.equals('u2', result.message.info.id)
    end)
  end)

  describe('renderer.get_next_user_message', function()
    it('skips assistant messages and returns next user message after cursor', function()
      seed({
        { info = { id = 'u1', role = 'user' } },
        { info = { id = 'a1', role = 'assistant' } },
        { info = { id = 'u2', role = 'user' } },
        { info = { id = 'a2', role = 'assistant' } },
        { info = { id = 'u3', role = 'user' } },
      }, {
        { id = 'u1', role = 'user', line_start = 1 },
        { id = 'a1', role = 'assistant', line_start = 20 },
        { id = 'u2', role = 'user', line_start = 40 },
        { id = 'a2', role = 'assistant', line_start = 60 },
        { id = 'u3', role = 'user', line_start = 80 },
      })

      local result = renderer.get_next_user_message(45)

      assert.is_not_nil(result)
      assert.equals('u3', result.message.info.id)
    end)

    it('returns nil when only assistant messages exist after cursor', function()
      seed({
        { info = { id = 'u1', role = 'user' } },
        { info = { id = 'a1', role = 'assistant' } },
        { info = { id = 'a2', role = 'assistant' } },
      }, {
        { id = 'u1', role = 'user', line_start = 1 },
        { id = 'a1', role = 'assistant', line_start = 20 },
        { id = 'a2', role = 'assistant', line_start = 40 },
      })

      local result = renderer.get_next_user_message(5)

      assert.is_nil(result)
    end)

    it('returns the last user message when cursor is before the first user line', function()
      seed({
        { info = { id = 'u1', role = 'user' } },
        { info = { id = 'u2', role = 'user' } },
        { info = { id = 'a1', role = 'assistant' } },
      }, {
        { id = 'u1', role = 'user', line_start = 10 },
        { id = 'u2', role = 'user', line_start = 20 },
        { id = 'a1', role = 'assistant', line_start = 30 },
      })

      local result = renderer.get_next_user_message(1)

      assert.is_not_nil(result)
      assert.equals('u1', result.message.info.id)
    end)
  end)

  describe('navigation.goto_prev_user_message', function()
    it('jumps to the previous user message when cursor is in the middle', function()
      seed({
        { info = { id = 'u1', role = 'user' } },
        { info = { id = 'a1', role = 'assistant' } },
        { info = { id = 'u2', role = 'user' } },
        { info = { id = 'a2', role = 'assistant' } },
        { info = { id = 'u3', role = 'user' } },
      }, {
        { id = 'u1', role = 'user', line_start = 1 },
        { id = 'a1', role = 'assistant', line_start = 20 },
        { id = 'u2', role = 'user', line_start = 40 },
        { id = 'a2', role = 'assistant', line_start = 60 },
        { id = 'u3', role = 'user', line_start = 80 },
      })

      vim.api.nvim_win_set_cursor(output_win, { 81, 0 })
      navigation.goto_prev_user_message()

      local cursor = vim.api.nvim_win_get_cursor(output_win)
      assert.equals(41, cursor[1])
    end)

    it('notifies and does not move when already on the first user message', function()
      seed({
        { info = { id = 'u1', role = 'user' } },
        { info = { id = 'a1', role = 'assistant' } },
        { info = { id = 'u2', role = 'user' } },
      }, {
        { id = 'u1', role = 'user', line_start = 1 },
        { id = 'a1', role = 'assistant', line_start = 20 },
        { id = 'u2', role = 'user', line_start = 40 },
      })

      vim.api.nvim_win_set_cursor(output_win, { 2, 0 })
      local notify_stub = stub(vim, 'notify')

      navigation.goto_prev_user_message()

      notify_stub:revert()

      local cursor = vim.api.nvim_win_get_cursor(output_win)
      assert.equals(2, cursor[1])
      assert.stub(notify_stub).was_called_with('No previous user message', vim.log.levels.INFO)
    end)
  end)

  describe('navigation.goto_next_user_message', function()
    it('jumps to the next user message when cursor is in the middle', function()
      seed({
        { info = { id = 'u1', role = 'user' } },
        { info = { id = 'a1', role = 'assistant' } },
        { info = { id = 'u2', role = 'user' } },
        { info = { id = 'a2', role = 'assistant' } },
        { info = { id = 'u3', role = 'user' } },
      }, {
        { id = 'u1', role = 'user', line_start = 1 },
        { id = 'a1', role = 'assistant', line_start = 20 },
        { id = 'u2', role = 'user', line_start = 40 },
        { id = 'a2', role = 'assistant', line_start = 60 },
        { id = 'u3', role = 'user', line_start = 80 },
      })

      vim.api.nvim_win_set_cursor(output_win, { 5, 0 })
      navigation.goto_next_user_message()

      local cursor = vim.api.nvim_win_get_cursor(output_win)
      assert.equals(41, cursor[1])
    end)

    it('notifies and does not move when already on the last user message', function()
      seed({
        { info = { id = 'u1', role = 'user' } },
        { info = { id = 'a1', role = 'assistant' } },
        { info = { id = 'u2', role = 'user' } },
      }, {
        { id = 'u1', role = 'user', line_start = 1 },
        { id = 'a1', role = 'assistant', line_start = 20 },
        { id = 'u2', role = 'user', line_start = 40 },
      })

      vim.api.nvim_win_set_cursor(output_win, { 41, 0 })
      local notify_stub = stub(vim, 'notify')

      navigation.goto_next_user_message()

      notify_stub:revert()

      local cursor = vim.api.nvim_win_get_cursor(output_win)
      assert.equals(41, cursor[1])
      assert.stub(notify_stub).was_called_with('No next user message', vim.log.levels.INFO)
    end)
  end)
end)
