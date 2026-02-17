local state = require('opencode.state')
local config = require('opencode.config')
local ui = require('opencode.ui.ui')

describe('cursor persistence (state)', function()
  before_each(function()
    state.set_cursor_position('input', nil)
    state.set_cursor_position('output', nil)
  end)

  describe('renderer.scroll_to_bottom', function()
    local renderer = require('opencode.ui.renderer')
    local buf, win

    before_each(function()
      config.setup({})
      renderer.reset()

      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        'line 1',
        'line 2',
        'line 3',
        'line 4',
        'line 5',
        'line 6',
        'line 7',
        'line 8',
        'line 9',
        'line 10',
      })

      win = vim.api.nvim_open_win(buf, true, {
        relative = 'editor',
        width = 80,
        height = 10,
        row = 0,
        col = 0,
      })

      state.windows = { output_win = win, output_buf = buf }
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { 10, 0 })
    end)

    after_each(function()
      renderer.reset()
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      state.windows = nil
    end)

    it('auto-scrolls when cursor was at previous bottom and buffer grows', function()
      renderer.scroll_to_bottom()

      vim.api.nvim_buf_set_lines(buf, 10, 10, false, { 'line 11', 'line 12' })
      renderer.scroll_to_bottom()

      local cursor = vim.api.nvim_win_get_cursor(win)
      assert.equals(12, cursor[1])
    end)

    it('does not auto-scroll when user moved away from previous bottom before growth', function()
      renderer.scroll_to_bottom()

      vim.api.nvim_win_set_cursor(win, { 5, 0 })
      vim.api.nvim_buf_set_lines(buf, 10, 10, false, { 'line 11', 'line 12' })
      renderer.scroll_to_bottom()

      local cursor = vim.api.nvim_win_get_cursor(win)
      assert.equals(5, cursor[1])
    end)

    it('auto-scrolls even when output window is unfocused if cursor was at previous bottom', function()
      renderer.scroll_to_bottom()

      local input_buf = vim.api.nvim_create_buf(false, true)
      vim.cmd('vsplit')
      local input_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(input_win, input_buf)
      vim.api.nvim_set_current_win(input_win)

      vim.api.nvim_buf_set_lines(buf, 10, 10, false, { 'line 11' })
      renderer.scroll_to_bottom()

      local cursor = vim.api.nvim_win_get_cursor(win)
      assert.equals(11, cursor[1])

      pcall(vim.api.nvim_win_close, input_win, true)
      pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
    end)
  end)

  describe('set/get round-trip', function()
    it('stores and retrieves input cursor', function()
      state.set_cursor_position('input', { 5, 3 })
      assert.same({ 5, 3 }, state.get_cursor_position('input'))
    end)

    it('stores and retrieves output cursor', function()
      state.set_cursor_position('output', { 10, 0 })
      assert.same({ 10, 0 }, state.get_cursor_position('output'))
    end)

    it('input and output are independent', function()
      state.set_cursor_position('input', { 1, 0 })
      state.set_cursor_position('output', { 99, 5 })
      assert.same({ 1, 0 }, state.get_cursor_position('input'))
      assert.same({ 99, 5 }, state.get_cursor_position('output'))
    end)

    it('returns nil for unknown win_type', function()
      assert.is_nil(state.get_cursor_position('footer'))
    end)
  end)

  describe('normalize_cursor edge cases', function()
    it('clamps negative line to 1', function()
      state.set_cursor_position('input', { -5, 3 })
      local pos = state.get_cursor_position('input')
      assert.equals(1, pos[1])
    end)

    it('clamps negative col to 0', function()
      state.set_cursor_position('input', { 1, -1 })
      local pos = state.get_cursor_position('input')
      assert.equals(0, pos[2])
    end)

    it('floors fractional values', function()
      state.set_cursor_position('input', { 3.7, 2.9 })
      local pos = state.get_cursor_position('input')
      assert.equals(3, pos[1])
      assert.equals(2, pos[2])
    end)

    it('rejects non-table input', function()
      state.set_cursor_position('input', 'bad')
      assert.is_nil(state.get_cursor_position('input'))
    end)

    it('rejects table with fewer than 2 elements', function()
      state.set_cursor_position('input', { 1 })
      assert.is_nil(state.get_cursor_position('input'))
    end)

    it('rejects non-numeric elements', function()
      state.set_cursor_position('input', { 'a', 'b' })
      assert.is_nil(state.get_cursor_position('input'))
    end)

    it('clears position when set to nil', function()
      state.set_cursor_position('input', { 5, 3 })
      state.set_cursor_position('input', nil)
      assert.is_nil(state.get_cursor_position('input'))
    end)
  end)

  describe('save_cursor_position', function()
    it('returns nil for invalid window', function()
      assert.is_nil(state.save_cursor_position('input', nil))
      assert.is_nil(state.save_cursor_position('input', 999999))
    end)

    it('captures and persists from a real window', function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line1', 'line2', 'line3' })
      local win = vim.api.nvim_open_win(buf, true, {
        relative = 'editor',
        width = 40,
        height = 10,
        row = 0,
        col = 0,
      })
      vim.api.nvim_win_set_cursor(win, { 2, 3 })

      local saved = state.save_cursor_position('output', win)
      assert.same({ 2, 3 }, saved)
      assert.same({ 2, 3 }, state.get_cursor_position('output'))

      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)
  end)
end)

describe('output_window.is_at_bottom', function()
  local output_window = require('opencode.ui.output_window')
  local buf, win

  before_each(function()
    config.setup({})
    buf = vim.api.nvim_create_buf(false, true)
    local lines = {}
    for i = 1, 50 do
      lines[i] = 'line ' .. i
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    win = vim.api.nvim_open_win(buf, true, {
      relative = 'editor',
      width = 80,
      height = 10,
      row = 0,
      col = 0,
    })

    state.windows = { output_win = win, output_buf = buf }
  end)

  after_each(function()
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    state.windows = nil
  end)

  it('returns true when cursor is on last line', function()
    vim.api.nvim_win_set_cursor(win, { 50, 0 })
    assert.is_true(output_window.is_at_bottom(win))
  end)

  it('returns false when cursor is on second-to-last line', function()
    vim.api.nvim_win_set_cursor(win, { 49, 0 })
    assert.is_false(output_window.is_at_bottom(win))
  end)

  it('returns false when cursor is far from bottom', function()
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    assert.is_false(output_window.is_at_bottom(win))
  end)

  it('returns false when cursor is a few lines above bottom', function()
    vim.api.nvim_win_set_cursor(win, { 45, 0 })
    assert.is_false(output_window.is_at_bottom(win))
  end)

  it('returns true when always_scroll_to_bottom is enabled', function()
    config.values.ui.output.always_scroll_to_bottom = true
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    assert.is_true(output_window.is_at_bottom(win))
    config.values.ui.output.always_scroll_to_bottom = false
  end)

  it('returns true for invalid window', function()
    assert.is_true(output_window.is_at_bottom(999999))
  end)

  it('returns true when no windows in state', function()
    state.windows = nil
    assert.is_true(output_window.is_at_bottom(win))
  end)

  it('returns true for empty buffer', function()
    local empty_buf = vim.api.nvim_create_buf(false, true)
    local empty_win = vim.api.nvim_open_win(empty_buf, true, {
      relative = 'editor',
      width = 40,
      height = 5,
      row = 0,
      col = 0,
    })
    state.windows = { output_win = empty_win, output_buf = empty_buf }

    assert.is_true(output_window.is_at_bottom(empty_win))

    pcall(vim.api.nvim_win_close, empty_win, true)
    pcall(vim.api.nvim_buf_delete, empty_buf, { force = true })
  end)

  it('cursor-based: scrolling viewport without moving cursor does NOT change result', function()
    vim.api.nvim_win_set_cursor(win, { 50, 0 })
    assert.is_true(output_window.is_at_bottom(win))

    -- Scroll viewport up via winrestview, cursor stays at line 50
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview({ topline = 1 })
    end)

    -- Cursor is still at 50, so is_at_bottom should still be true
    -- This is the key behavioral difference from viewport-based check
    assert.is_true(output_window.is_at_bottom(win))
  end)
end)

describe('renderer.scroll_to_bottom', function()
  local renderer = require('opencode.ui.renderer')
  local output_window = require('opencode.ui.output_window')
  local buf, win

  before_each(function()
    config.setup({})
    buf = vim.api.nvim_create_buf(false, true)
    local lines = {}
    for i = 1, 50 do
      lines[i] = 'line ' .. i
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    win = vim.api.nvim_open_win(buf, true, {
      relative = 'editor',
      width = 80,
      height = 10,
      row = 0,
      col = 0,
    })

    state.windows = { output_win = win, output_buf = buf }
    renderer._prev_line_count = 50
  end)

  after_each(function()
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    state.windows = nil
    renderer._prev_line_count = 0
    output_window.viewport_at_bottom = nil
  end)

  it('does not force-scroll when user cursor is above previous bottom', function()
    vim.api.nvim_win_set_cursor(win, { 10, 0 })
    output_window.viewport_at_bottom = true

    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { 'line 51' })
    renderer.scroll_to_bottom()

    local cursor = vim.api.nvim_win_get_cursor(win)
    assert.equals(10, cursor[1])
  end)

  it('still scrolls when always_scroll_to_bottom is enabled', function()
    config.values.ui.output.always_scroll_to_bottom = true
    vim.api.nvim_win_set_cursor(win, { 10, 0 })

    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { 'line 51' })
    renderer.scroll_to_bottom()

    local cursor = vim.api.nvim_win_get_cursor(win)
    assert.equals(51, cursor[1])
    config.values.ui.output.always_scroll_to_bottom = false
  end)
end)

describe('ui.focus_input', function()
  local input_buf, output_buf, input_win, output_win

  before_each(function()
    input_buf = vim.api.nvim_create_buf(false, true)
    output_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { 'abcde' })
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { 'output' })

    output_win = vim.api.nvim_open_win(output_buf, true, {
      relative = 'editor',
      width = 40,
      height = 5,
      row = 0,
      col = 0,
    })
    input_win = vim.api.nvim_open_win(input_buf, true, {
      relative = 'editor',
      width = 40,
      height = 5,
      row = 6,
      col = 0,
    })

    state.windows = {
      input_win = input_win,
      output_win = output_win,
      input_buf = input_buf,
      output_buf = output_buf,
    }
    state.last_input_window_position = { 1, 4 }
  end)

  after_each(function()
    pcall(vim.api.nvim_win_close, input_win, true)
    pcall(vim.api.nvim_win_close, output_win, true)
    pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, output_buf, { force = true })
    state.windows = nil
    state.last_input_window_position = nil
  end)

  it('does not restore cursor when already focused in input window', function()
    vim.api.nvim_set_current_win(input_win)
    vim.api.nvim_win_set_cursor(input_win, { 1, 2 })

    ui.focus_input({ restore_position = true, start_insert = false })

    assert.same({ 1, 2 }, vim.api.nvim_win_get_cursor(input_win))
  end)
end)

describe('renderer._add_message_to_buffer scrolling', function()
  local renderer = require('opencode.ui.renderer')
  local formatter = require('opencode.ui.formatter')
  local stub = require('luassert.stub')
  local buf, win

  before_each(function()
    config.setup({})
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'existing line' })

    win = vim.api.nvim_open_win(buf, true, {
      relative = 'editor',
      width = 80,
      height = 10,
      row = 0,
      col = 0,
    })

    state.windows = { output_win = win, output_buf = buf }
    state.active_session = { id = 'test-session' }
    state.messages = {}
    renderer._prev_line_count = 1
    renderer._render_state:reset()
  end)

  after_each(function()
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    state.windows = nil
    state.active_session = nil
    state.messages = nil
    renderer._prev_line_count = 0
    renderer._render_state:reset()
  end)

  it('scrolls to bottom when user message is added', function()
    vim.api.nvim_win_set_cursor(win, { 1, 0 })

    local user_message = {
      info = {
        id = 'msg-1',
        sessionID = 'test-session',
        role = 'user',
      },
      parts = {},
    }

    local scroll_called_with_force = false
    stub(renderer, 'scroll_to_bottom').invokes(function(force)
      scroll_called_with_force = force == true
    end)

    renderer._add_message_to_buffer(user_message)

    assert.is_true(scroll_called_with_force)
    assert.stub(renderer.scroll_to_bottom).was_called_with(true)

    renderer.scroll_to_bottom:revert()
  end)

  it('does not scroll when assistant message is added', function()
    vim.api.nvim_win_set_cursor(win, { 1, 0 })

    local assistant_message = {
      info = {
        id = 'msg-2',
        sessionID = 'test-session',
        role = 'assistant',
      },
      parts = {},
    }

    stub(renderer, 'scroll_to_bottom')

    renderer._add_message_to_buffer(assistant_message)

    assert.stub(renderer.scroll_to_bottom).was_not_called()

    renderer.scroll_to_bottom:revert()
  end)

  it('does not scroll when system message is added', function()
    vim.api.nvim_win_set_cursor(win, { 1, 0 })

    local system_message = {
      info = {
        id = 'msg-3',
        sessionID = 'test-session',
        role = 'system',
      },
      parts = {},
    }

    stub(renderer, 'scroll_to_bottom')

    renderer._add_message_to_buffer(system_message)

    assert.stub(renderer.scroll_to_bottom).was_not_called()

    renderer.scroll_to_bottom:revert()
  end)
end)
