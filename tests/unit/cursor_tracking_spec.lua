local state = require('opencode.state')
local store = require('opencode.state.store')
local config = require('opencode.config')
local ui = require('opencode.ui.ui')

describe('cursor persistence (state)', function()
  before_each(function()
    state.ui.set_cursor_position('input', nil)
    state.ui.set_cursor_position('output', nil)
  end)

  describe('renderer.scroll_to_bottom', function()
    local renderer = require('opencode.ui.renderer')
    local buf, win

    before_each(function()
      config.setup({})
      renderer.reset()

      buf = vim.api.nvim_create_buf(false, true)
      local lines = {}
      for i = 1, 20 do
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

      state.ui.set_windows({ output_win = win, output_buf = buf })
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { 20, 0 })
    end)

    after_each(function()
      renderer.reset()
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      state.ui.set_windows(nil)
    end)

    it('auto-scrolls when cursor was at previous bottom and buffer grows', function()
      renderer.scroll_to_bottom()

      vim.api.nvim_buf_set_lines(buf, 20, 20, false, { 'line 21', 'line 22' })
      renderer.scroll_to_bottom()

      local cursor = vim.api.nvim_win_get_cursor(win)
      assert.equals(22, cursor[1])
    end)

    it('does not auto-scroll when user scrolled away from bottom before growth', function()
      renderer.scroll_to_bottom()

      -- Simulate user scrolling away (moves viewport, which fires WinScrolled → sync_cursor_with_viewport)
      vim.api.nvim_win_set_cursor(win, { 5, 0 })
      local output_window = require('opencode.ui.output_window')
      output_window.sync_cursor_with_viewport(win)

      vim.api.nvim_buf_set_lines(buf, 20, 20, false, { 'line 21', 'line 22' })
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

      vim.api.nvim_buf_set_lines(buf, 20, 20, false, { 'line 21' })
      renderer.scroll_to_bottom()

      local cursor = vim.api.nvim_win_get_cursor(win)
      assert.equals(21, cursor[1])

      pcall(vim.api.nvim_win_close, input_win, true)
      pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
    end)
  end)

  describe('set/get round-trip', function()
    it('stores and retrieves input cursor', function()
      state.ui.set_cursor_position('input', { 5, 3 })
      assert.same({ 5, 3 }, state.ui.get_cursor_position('input'))
    end)

    it('stores and retrieves output cursor', function()
      state.ui.set_cursor_position('output', { 10, 0 })
      assert.same({ 10, 0 }, state.ui.get_cursor_position('output'))
    end)

    it('input and output are independent', function()
      state.ui.set_cursor_position('input', { 1, 0 })
      state.ui.set_cursor_position('output', { 99, 5 })
      assert.same({ 1, 0 }, state.ui.get_cursor_position('input'))
      assert.same({ 99, 5 }, state.ui.get_cursor_position('output'))
    end)

    it('returns nil for unknown win_type', function()
      assert.is_nil(state.ui.get_cursor_position('footer'))
    end)
  end)

  describe('normalize_cursor edge cases', function()
    it('clamps negative line to 1', function()
      state.ui.set_cursor_position('input', { -5, 3 })
      local pos = state.ui.get_cursor_position('input')
      assert.equals(1, pos[1])
    end)

    it('clamps negative col to 0', function()
      state.ui.set_cursor_position('input', { 1, -1 })
      local pos = state.ui.get_cursor_position('input')
      assert.equals(0, pos[2])
    end)

    it('floors fractional values', function()
      state.ui.set_cursor_position('input', { 3.7, 2.9 })
      local pos = state.ui.get_cursor_position('input')
      assert.equals(3, pos[1])
      assert.equals(2, pos[2])
    end)

    it('rejects non-table input', function()
      state.ui.set_cursor_position('input', 'bad')
      assert.is_nil(state.ui.get_cursor_position('input'))
    end)

    it('rejects table with fewer than 2 elements', function()
      state.ui.set_cursor_position('input', { 1 })
      assert.is_nil(state.ui.get_cursor_position('input'))
    end)

    it('rejects non-numeric elements', function()
      state.ui.set_cursor_position('input', { 'a', 'b' })
      assert.is_nil(state.ui.get_cursor_position('input'))
    end)

    it('clears position when set to nil', function()
      state.ui.set_cursor_position('input', { 5, 3 })
      state.ui.set_cursor_position('input', nil)
      assert.is_nil(state.ui.get_cursor_position('input'))
    end)
  end)

  describe('get_window_cursor', function()
    it('returns nil for invalid window', function()
      assert.is_nil(state.ui.get_window_cursor(nil))
      assert.is_nil(state.ui.get_window_cursor(999999))
    end)

    it('gets cursor from a real window', function()
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

      local pos = state.ui.get_window_cursor(win)
      assert.same({ 2, 3 }, pos)

      -- Manually save to verify persistence path
      state.ui.set_cursor_position('output', pos)
      assert.same({ 2, 3 }, state.ui.get_cursor_position('output'))

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

    state.ui.set_windows({ output_win = win, output_buf = buf })
  end)

  after_each(function()
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    state.ui.set_windows(nil)
  end)

  it('returns true when cursor is on last line', function()
    vim.api.nvim_win_set_cursor(win, { 50, 0 })
    assert.is_true(output_window.is_at_bottom(win))
  end)

  it('returns false when _was_at_bottom_by_win flag is explicitly false', function()
    -- Simulate user having scrolled away: flag is set to false
    output_window._was_at_bottom_by_win[win] = false
    assert.is_false(output_window.is_at_bottom(win))
  end)

  it('returns false when cursor is far from bottom (viewport not showing last line)', function()
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    assert.is_false(output_window.is_at_bottom(win))
  end)

  it('returns false when user has scrolled viewport away from bottom', function()
    -- Simulate scrolling to bottom then user scrolling away
    local scroll = require('opencode.ui.renderer.scroll')
    scroll.scroll_win_to_bottom(win, buf)
    assert.is_true(output_window.is_at_bottom(win))

    -- Simulate WinScrolled: user scrolls viewport up
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview({ topline = 1 })
    end)
    output_window.sync_cursor_with_viewport(win)
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
    state.ui.set_windows(nil)
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
    state.ui.set_windows({ output_win = empty_win, output_buf = empty_buf })

    assert.is_true(output_window.is_at_bottom(empty_win))

    pcall(vim.api.nvim_win_close, empty_win, true)
    pcall(vim.api.nvim_buf_delete, empty_buf, { force = true })
  end)

  it('viewport-based: scrolling viewport up stops auto-scroll even when cursor stays at last line', function()
    -- Scroll to bottom so _was_at_bottom_by_win is set to true
    local scroll = require('opencode.ui.renderer.scroll')
    scroll.scroll_win_to_bottom(win, buf)
    assert.is_true(output_window.is_at_bottom(win))

    -- Scroll the viewport up without touching the cursor.
    -- WinScrolled fires → sync_cursor_with_viewport → _was_at_bottom_by_win = false
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview({ topline = 1 })
    end)
    output_window.sync_cursor_with_viewport(win)

    -- Even though cursor is still at line 50, viewport has scrolled away
    assert.is_false(output_window.is_at_bottom(win))
  end)

  it('reports the actual visible bottom line in wrapped windows', function()
    local long_line = string.rep('x', 180)

    vim.api.nvim_win_set_width(win, 20)
    vim.api.nvim_set_option_value('wrap', true, { win = win, scope = 'local' })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line 1', 'line 2', long_line, 'line 4', 'line 5' })
    vim.api.nvim_win_set_cursor(win, { 5, 0 })
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview({ topline = 1 })
    end)

    local visible_bottom = output_window.get_visible_bottom_line(win)
    -- With topline=1, height=10, wrap=true, width=20:
    -- line 1 (1 row), line 2 (1 row), long_line (180/20=9 rows).
    -- In headless Neovim the visible bottom is line 3 (the long wrapped line)
    -- or line 2 depending on the environment's redraw behaviour.
    -- The important property is that it is not the last buffer line (5).
    assert.is_true(visible_bottom ~= nil)
    assert.is_true(visible_bottom < 5)
  end)
end)

describe('output_window.sync_cursor_with_viewport', function()
  local output_window = require('opencode.ui.output_window')
  local buf, win

  before_each(function()
    config.setup({})
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      'line 1',
      'line 2',
      string.rep('x', 180),
      'line 4',
      'line 5',
    })

    win = vim.api.nvim_open_win(buf, true, {
      relative = 'editor',
      width = 20,
      height = 5,
      row = 0,
      col = 0,
    })

    vim.api.nvim_set_option_value('wrap', true, { win = win, scope = 'local' })
    state.ui.set_windows({ output_win = win, output_buf = buf })
    output_window.reset_scroll_tracking(win)
  end)

  after_each(function()
    output_window.reset_scroll_tracking(win)
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    state.ui.set_windows(nil)
  end)

  it('sets _was_at_bottom_by_win to false when viewport scrolls away from bottom', function()
    -- Start with viewport and cursor at last line
    vim.api.nvim_win_set_cursor(win, { 5, 0 })
    local scroll = require('opencode.ui.renderer.scroll')
    scroll.scroll_win_to_bottom(win, buf)
    assert.is_true(output_window._was_at_bottom_by_win[win])

    -- Scroll the viewport up (simulate mouse wheel scroll)
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview({ topline = 1 })
    end)
    output_window.sync_cursor_with_viewport(win)

    assert.is_false(output_window._was_at_bottom_by_win[win])
  end)

  it('does not move the cursor when the user is already reading earlier content', function()
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    output_window.sync_cursor_with_viewport(win)

    local cursor = vim.api.nvim_win_get_cursor(win)
    assert.equals(2, cursor[1])
  end)
end)

describe('renderer.scroll_to_bottom', function()
  local renderer = require('opencode.ui.renderer')
  local ctx = require('opencode.ui.renderer.ctx')
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

    state.ui.set_windows({ output_win = win, output_buf = buf })
    ctx.prev_line_count = 50
  end)

  after_each(function()
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    state.ui.set_windows(nil)
    ctx.prev_line_count = 0
    output_window.reset_scroll_tracking(win)
  end)

  it('does not force-scroll when viewport has scrolled away from bottom', function()
    -- cursor at line 10, viewport shows lines 1-10, buffer has 50 lines
    -- _was_at_bottom_by_win is unset → fallback live check: visible_bottom(10) < 51 → false
    vim.api.nvim_win_set_cursor(win, { 10, 0 })

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

  it('moves to the visual end when the last wrapped line grows', function()
    local long_line = string.rep('x', 120)
    local longer_line = string.rep('x', 180)

    vim.api.nvim_win_set_width(win, 20)
    vim.api.nvim_set_option_value('wrap', true, { win = win, scope = 'local' })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line 1', 'line 2', long_line })
    ctx.prev_line_count = 3
    vim.api.nvim_win_set_cursor(win, { 3, 0 })

    renderer.scroll_to_bottom()
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { longer_line })
    renderer.scroll_to_bottom()

    local cursor = vim.api.nvim_win_get_cursor(win)
    assert.equals(3, cursor[1])
    assert.equals(#longer_line - 1, cursor[2])
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

    state.ui.set_windows({
      input_win = input_win,
      output_win = output_win,
      input_buf = input_buf,
      output_buf = output_buf,
    })
    store.set('last_input_window_position', { 1, 4 })
  end)

  after_each(function()
    pcall(vim.api.nvim_win_close, input_win, true)
    pcall(vim.api.nvim_win_close, output_win, true)
    pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, output_buf, { force = true })
    state.ui.set_windows(nil)
    store.set('last_input_window_position', nil)
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
  local events = require('opencode.ui.renderer.events')
  local ctx = require('opencode.ui.renderer.ctx')
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

    state.ui.set_windows({ output_win = win, output_buf = buf })
    state.session.set_active({ id = 'test-session' })
    state.renderer.set_messages({})
    ctx.prev_line_count = 1
    ctx.render_state:reset()
  end)

  after_each(function()
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    state.ui.set_windows(nil)
    state.session.set_active(nil)
    state.renderer.set_messages(nil)
    ctx.prev_line_count = 0
    ctx.render_state:reset()
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

    events.on_message_updated(user_message)

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

    events.on_message_updated(assistant_message)

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

    events.on_message_updated(system_message)

    assert.stub(renderer.scroll_to_bottom).was_not_called()

    renderer.scroll_to_bottom:revert()
  end)
end)
