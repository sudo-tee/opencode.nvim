local state = require('opencode.state')
local store = require('opencode.state.store')
local session_tabs = require('opencode.state.session_tabs')
local session_tab_strip = require('opencode.ui.session_tab_strip')

describe('opencode session tab strip', function()
  local original_state
  local windows

  before_each(function()
    original_state = vim.deepcopy(store.state())
    session_tabs.reset()
  end)

  after_each(function()
    session_tab_strip.close(false, windows)
    if windows then
      if windows.output_win and vim.api.nvim_win_is_valid(windows.output_win) then
        pcall(vim.api.nvim_win_close, windows.output_win, true)
      end
      if windows.output_buf and vim.api.nvim_buf_is_valid(windows.output_buf) then
        pcall(vim.api.nvim_buf_delete, windows.output_buf, { force = true })
      end
    end
    state.ui.set_windows(nil)
    windows = nil
    session_tabs.reset()
    for key, value in pairs(original_state) do
      store.set(key, value)
    end
  end)

  it('renders truncated, selectable tabs with an active marker', function()
    local first = session_tabs.ensure_current()
    first.active_session = { id = 'session-one', title = 'A very long first session title' }
    state.session.set_active(first.active_session)

    local second = session_tabs.create({ id = 'session-two', title = 'Second' })
    session_tabs.activate(second)

    local output_buf = vim.api.nvim_create_buf(false, true)
    local output_win = vim.api.nvim_open_win(output_buf, false, {
      relative = 'editor',
      width = 40,
      height = 10,
      row = 1,
      col = 1,
    })
    windows = {
      output_buf = output_buf,
      output_win = output_win,
      tab_strip_buf = session_tab_strip.create_buf(),
      position = 'float',
    }

    session_tab_strip.create_window(windows)
    state.ui.set_windows(windows)
    session_tab_strip.setup(windows)

    local line = vim.api.nvim_buf_get_lines(windows.tab_strip_buf, 0, 1, false)[1]
    assert.matches('Second', line)
    assert.matches('> %[%s*2', line)
    assert.is_true(vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(windows.tab_strip_win))

    local marks = vim.api.nvim_buf_get_extmarks(windows.tab_strip_buf, -1, 0, -1, { details = true })
    local groups = {}
    for _, mark in ipairs(marks) do
      if mark[4] and mark[4].hl_group then
        groups[mark[4].hl_group] = true
      end
    end
    assert.is_true(groups.OpencodeSessionTabActive)
    assert.is_true(groups.OpencodeSessionTabInactive)
  end)
end)
