local state = require('opencode.state')
local store = require('opencode.state.store')
local session_tabs = require('opencode.state.session_tabs')
local session_tab_strip = require('opencode.ui.session_tab_strip')
local config = require('opencode.config')
local stub = require('luassert.stub')

describe('opencode session tab strip', function()
  local original_state
  local original_config
  local windows

  before_each(function()
    original_state = vim.deepcopy(store.state())
    original_config = vim.deepcopy(config.values)
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
    config.values = original_config
    for key, value in pairs(original_state) do
      store.set(key, value)
    end
  end)

  it('renders truncated, selectable tabs with styled tokens', function()
    local first = session_tabs.ensure_current()
    first.active_session = { id = 'session-one', title = 'A very long first session title' }
    state.session.set_active(first.active_session)

    local second = session_tabs.create({ id = 'session-two', title = 'New session - 2026-02-05T22:26:08.579Z' })
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
    assert.matches('2%s+New session', line)
    assert.is_nil(line:find('2026'))
    assert.is_nil(line:find('>'))
    assert.is_nil(line:find('%['))
    assert.is_nil(line:find('%]'))
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
    assert.is_true(groups.OpencodeSessionTabIndex)
    assert.is_true(groups.OpencodeSessionTabSeparator)
  end)

  it('shows a clickable overflow marker when tabs do not fit', function()
    session_tabs.ensure_current().active_session = { id = 'session-one', title = 'One' }
    local last
    for index = 2, 5 do
      last = session_tabs.create({ id = 'session-' .. index, title = 'Session ' .. index })
    end
    session_tabs.activate(last)

    local output_buf = vim.api.nvim_create_buf(false, true)
    local output_win = vim.api.nvim_open_win(output_buf, false, {
      relative = 'editor',
      width = 50,
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
    assert.matches('%+2', line)
    assert.matches('5 Session 5', line)
    assert.is_true(vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(windows.tab_strip_win))

    local marks = vim.api.nvim_buf_get_extmarks(windows.tab_strip_buf, -1, 0, -1, { details = true })
    local groups = {}
    for _, mark in ipairs(marks) do
      if mark[4] and mark[4].hl_group then
        groups[mark[4].hl_group] = true
      end
    end
    assert.is_true(groups.OpencodeSessionTabOverflow)

    local picker = require('opencode.ui.session_tab_picker')
    local picker_stub = stub(picker, 'select')
    local marker_column = assert(line:find('%+2'))
    vim.api.nvim_set_current_win(windows.tab_strip_win)
    vim.api.nvim_win_set_cursor(windows.tab_strip_win, { 1, marker_column - 1 })
    vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'xt', false)
    vim.wait(20)
    assert.stub(picker_stub).was_called()
    picker_stub:revert()
  end)

  it('marks tabs with pending permissions and questions', function()
    local first = session_tabs.ensure_current()
    first.active_session = { id = 'session-one', title = 'One' }
    state.session.set_active(first.active_session)
    session_tabs.add_pending_permission(first.id, { id = 'permission-one' })
    session_tabs.add_pending_question(first.id, { id = 'question-one' })

    local second = session_tabs.create({ id = 'session-two', title = 'Two' })
    session_tabs.add_pending_permission(second.id, { id = 'permission-two' })
    session_tabs.add_pending_permission(second.id, { id = 'permission-three' })
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
    assert.is_true(line:find('1 [!][?] One', 1, true) ~= nil)
    assert.is_true(line:find('2 [!2] Two', 1, true) ~= nil)

    local marks = vim.api.nvim_buf_get_extmarks(windows.tab_strip_buf, -1, 0, -1, { details = true })
    local groups = {}
    for _, mark in ipairs(marks) do
      if mark[4] and mark[4].hl_group then
        groups[mark[4].hl_group] = true
      end
    end
    assert.is_true(groups.OpencodeSessionTabPendingPermission)
    assert.is_true(groups.OpencodeSessionTabActive)
    assert.is_true(groups.OpencodeSessionTabInactive)
  end)

  it('hides the tab strip for one tab and restores it for multiple tabs', function()
    config.values.ui.hide_single_tab = true

    local first = session_tabs.ensure_current()
    first.active_session = { id = 'session-one', title = 'First' }
    state.session.set_active(first.active_session)

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

    assert.is_nil(windows.tab_strip_win)

    local second = session_tabs.create({ id = 'session-two', title = 'Second' })
    session_tabs.activate(second)
    state.ui.set_windows(windows)
    vim.wait(50)

    assert.is_not_nil(windows.tab_strip_win)
    assert.is_true(vim.api.nvim_win_is_valid(windows.tab_strip_win))
    assert.matches('Second', vim.api.nvim_buf_get_lines(windows.tab_strip_buf, 0, 1, false)[1])

    session_tabs.remove(first)
    vim.wait(50)

    assert.is_nil(windows.tab_strip_win)
  end)
end)
