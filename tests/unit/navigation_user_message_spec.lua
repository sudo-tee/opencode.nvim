local assert = require('luassert')
local stub = require('luassert.stub')

local navigation = require('opencode.ui.navigation')
local renderer = require('opencode.ui.renderer')
local state = require('opencode.state')
local contexts = require('opencode.ui.renderer.ctx')

---@param entries table[] list of { id, kind, line_start?, line_end? }
local function seed(entries)
  contexts.current().entries = {}
  for _, r in ipairs(entries) do
    local entry = { id = r.id, kind = r.kind, content = {} }
    contexts.current().entries[#contexts.current().entries + 1] = entry
    if r.line_start then
      contexts.current().render_state:set_message(entry, r.line_start, r.line_end or r.line_start)
    end
  end
end

local function clear_render()
  contexts.current().entries = {}
  contexts.current().render_state:reset()
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
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 20 },
        { id = 'u2', kind = 'user', line_start = 40 },
        { id = 'a2', kind = 'assistant', line_start = 60 },
        { id = 'u3', kind = 'user', line_start = 80 },
      })

      local result = renderer.get_prev_user_message(50)

      assert.is_not_nil(result)
      assert.equals('u2', result.message.id)
    end)

    it('returns nil when only assistant messages exist before cursor', function()
      seed({
        { id = 'a1', kind = 'assistant', line_start = 1 },
        { id = 'a2', kind = 'assistant', line_start = 20 },
      })

      local result = renderer.get_prev_user_message(30)

      assert.is_nil(result)
    end)

    it('returns the last user message before cursor when cursor is past all lines', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 10 },
        { id = 'u2', kind = 'user', line_start = 20 },
      })

      local result = renderer.get_prev_user_message(999)

      assert.is_not_nil(result)
      assert.equals('u2', result.message.id)
    end)
  end)

  describe('renderer.get_next_user_message', function()
    it('skips assistant messages and returns next user message after cursor', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 20 },
        { id = 'u2', kind = 'user', line_start = 40 },
        { id = 'a2', kind = 'assistant', line_start = 60 },
        { id = 'u3', kind = 'user', line_start = 80 },
      })

      local result = renderer.get_next_user_message(45)

      assert.is_not_nil(result)
      assert.equals('u3', result.message.id)
    end)

    it('returns nil when only assistant messages exist after cursor', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 20 },
        { id = 'a2', kind = 'assistant', line_start = 40 },
      })

      local result = renderer.get_next_user_message(5)

      assert.is_nil(result)
    end)

    it('returns the last user message when cursor is before the first user line', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 10 },
        { id = 'u2', kind = 'user', line_start = 20 },
        { id = 'a1', kind = 'assistant', line_start = 30 },
      })

      local result = renderer.get_next_user_message(1)

      assert.is_not_nil(result)
      assert.equals('u1', result.message.id)
    end)
  end)

  describe('navigation.goto_prev_user_message', function()
    it('jumps to the previous user message when cursor is in the middle', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 20 },
        { id = 'u2', kind = 'user', line_start = 40 },
        { id = 'a2', kind = 'assistant', line_start = 60 },
        { id = 'u3', kind = 'user', line_start = 80 },
      })

      vim.api.nvim_win_set_cursor(output_win, { 81, 0 })
      navigation.goto_prev_user_message()

      local cursor = vim.api.nvim_win_get_cursor(output_win)
      assert.equals(41, cursor[1])
    end)

    it('notifies and does not move when already on the first user message', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 20 },
        { id = 'u2', kind = 'user', line_start = 40 },
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
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 20 },
        { id = 'u2', kind = 'user', line_start = 40 },
        { id = 'a2', kind = 'assistant', line_start = 60 },
        { id = 'u3', kind = 'user', line_start = 80 },
      })

      vim.api.nvim_win_set_cursor(output_win, { 5, 0 })
      navigation.goto_next_user_message()

      local cursor = vim.api.nvim_win_get_cursor(output_win)
      assert.equals(41, cursor[1])
    end)

    it('notifies and does not move when already on the last user message', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 20 },
        { id = 'u2', kind = 'user', line_start = 40 },
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

  describe('lazy render interaction', function()
    local original_load

    before_each(function()
      original_load = renderer.load_all_messages
    end)

    after_each(function()
      renderer.load_all_messages = original_load
      contexts.current().lazy_render_count = nil
    end)

    it('calls load_all_messages before navigating to the previous user message', function()
      seed({
        { id = 'u1', kind = 'user' },
        { id = 'a1', kind = 'assistant' },
        { id = 'u2', kind = 'user' },
      })
      contexts.current().lazy_render_count = 0

      local called = 0
      renderer.load_all_messages = function()
        called = called + 1
        return true
      end

      navigation.goto_prev_user_message()

      assert.equals(1, called)
    end)

    it('calls load_all_messages before navigating to the next user message', function()
      seed({
        { id = 'u1', kind = 'user' },
        { id = 'u2', kind = 'user' },
      })
      contexts.current().lazy_render_count = 0

      local called = 0
      renderer.load_all_messages = function()
        called = called + 1
        return true
      end

      navigation.goto_next_user_message()

      assert.equals(1, called)
    end)

    it('jumps after load_all_messages renders the target user message', function()
      seed({
        { id = 'u1', kind = 'user' },
        { id = 'a1', kind = 'assistant' },
        { id = 'u2', kind = 'user' },
      })
      contexts.current().lazy_render_count = 1

      renderer.load_all_messages = function()
        contexts.current().render_state:set_message(contexts.current().entries[1], 1, 1)
        contexts.current().render_state:set_message(contexts.current().entries[3], 40, 40)
        return true
      end

      vim.api.nvim_win_set_cursor(output_win, { 41, 0 })
      navigation.goto_prev_user_message()

      assert.equals(2, vim.api.nvim_win_get_cursor(output_win)[1])
    end)
  end)

  describe('jumplist preservation', function()
    it('marks the previous position before jumping to the next user message', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 20 },
        { id = 'u2', kind = 'user', line_start = 40 },
      })

      vim.api.nvim_win_set_cursor(output_win, { 5, 0 })
      vim.api.nvim_buf_set_mark(output_buf, "'", 1, 0, {})
      navigation.goto_next_user_message()

      local mark = vim.api.nvim_buf_get_mark(output_buf, "'")
      assert.equals(5, mark[1])
      assert.equals(0, mark[2])
    end)

    it('marks the previous position before jumping to the previous user message', function()
      seed({
        { id = 'u1', kind = 'user', line_start = 1 },
        { id = 'a1', kind = 'assistant', line_start = 20 },
        { id = 'u2', kind = 'user', line_start = 40 },
      })

      vim.api.nvim_win_set_cursor(output_win, { 81, 0 })
      vim.api.nvim_buf_set_mark(output_buf, "'", 1, 0, {})
      navigation.goto_prev_user_message()

      local mark = vim.api.nvim_buf_get_mark(output_buf, "'")
      assert.equals(81, mark[1])
      assert.equals(0, mark[2])
    end)
  end)
end)
