local state = require('opencode.state')
local ui = require('opencode.ui.ui')
local helpers = require('tests.helpers')
local output_window = require('opencode.ui.output_window')
local assert = require('luassert')
local stub = require('luassert.stub')
local config = require('opencode.config')

local function assert_output_matches(expected, actual, name)
  local normalized_extmarks = helpers.normalize_namespace_ids(actual.extmarks)

  local function legacy_effective_bottom(window)
    if not window or not window.cursor or not window.line_count then
      return nil
    end

    if window.cursor[1] == window.line_count - 1 then
      return window.line_count - 1
    end

    return window.line_count
  end

  local function visible_bottom_equivalent(expected_window, actual_window)
    if expected_window.visible_bottom == actual_window.visible_bottom then
      return true
    end

    if expected_window.effective_bottom == nil or actual_window.effective_bottom == nil then
      return false
    end

    if not vim.deep_equal(expected_window.cursor, actual_window.cursor) then
      return false
    end

    if expected_window.effective_bottom ~= actual_window.effective_bottom then
      return false
    end

    if expected_window.cursor[1] ~= expected_window.effective_bottom then
      return false
    end

    -- line('w$') can differ by one wrapped/padding row between event replay and
    -- bulk full-session render even when both windows are following the same
    -- effective bottom line.
    return math.abs(expected_window.visible_bottom - expected_window.effective_bottom) <= 1
      and math.abs(actual_window.visible_bottom - actual_window.effective_bottom) <= 1
  end

  assert.are.equal(
    #expected.lines,
    #actual.lines,
    string.format(
      'Line count mismatch: expected %d, got %d.\nFirst difference at index %d:\n  Expected: %s\n  Actual: %s',
      #expected.lines,
      #actual.lines,
      math.min(#expected.lines, #actual.lines) + 1,
      vim.inspect(expected.lines[math.min(#expected.lines, #actual.lines) + 1]),
      vim.inspect(actual.lines[math.min(#expected.lines, #actual.lines) + 1])
    )
  )

  for i = 1, #expected.lines do
    assert.are.equal(
      expected.lines[i],
      actual.lines[i],
      string.format(
        'Line %d mismatch:\n  Expected: %s\n  Actual: %s',
        i,
        vim.inspect(expected.lines[i]),
        vim.inspect(actual.lines[i])
      )
    )
  end

  assert.are.equal(
    #expected.extmarks,
    #normalized_extmarks,
    string.format(
      'Extmark count mismatch: expected %d, got %d.\nFirst difference at index %d:\n  Expected: %s\n  Actual: %s',
      #expected.extmarks,
      #normalized_extmarks,
      math.min(#expected.extmarks, #normalized_extmarks) + 1,
      vim.inspect(expected.extmarks[math.min(#expected.extmarks, #normalized_extmarks) + 1]),
      vim.inspect(normalized_extmarks[math.min(#expected.extmarks, #normalized_extmarks) + 1])
    )
  )

  for i = 1, #expected.extmarks do
    assert.are.same(
      expected.extmarks[i],
      normalized_extmarks[i],
      string.format(
        'Extmark %d mismatch:\n  Expected: %s\n  Actual: %s',
        i,
        vim.inspect(expected.extmarks[i]),
        vim.inspect(normalized_extmarks[i])
      )
    )
  end

  local expected_action_count = expected.actions and #expected.actions or 0
  local actual_action_count = actual.actions and #actual.actions or 0

  assert.are.equal(
    expected_action_count,
    actual_action_count,
    string.format('Action count mismatch: expected %d, got %d', expected_action_count, actual_action_count)
  )

  if expected.actions then
    -- Sort both arrays for consistent comparison since order doesn't matter
    local function sort_actions(actions)
      local sorted = vim.deepcopy(actions)
      table.sort(sorted, function(a, b)
        return vim.inspect(a) < vim.inspect(b)
      end)
      return sorted
    end

    assert.same(
      sort_actions(expected.actions),
      sort_actions(actual.actions),
      string.format(
        'Actions mismatch:\n  Expected: %s\n  Actual: %s',
        vim.inspect(expected.actions),
        vim.inspect(actual.actions)
      )
    )
  end

  if expected.window then
    local actual_window = actual.window or {}
    assert.are.same(expected.window.cursor, actual_window.cursor, 'Window cursor mismatch')
    assert.are.same(expected.window.line_count, actual_window.line_count, 'Window line_count mismatch')

    local expected_has_effective_bottom = expected.window.effective_bottom ~= nil
    if expected_has_effective_bottom then
      assert.are.same(
        expected.window.effective_bottom,
        actual_window.effective_bottom,
        'Window effective_bottom mismatch'
      )
      assert.is_true(
        visible_bottom_equivalent(expected.window, actual_window),
        string.format(
          'Window visible_bottom mismatch: expected %s, got %s (effective_bottom=%s)',
          vim.inspect(expected.window.visible_bottom),
          vim.inspect(actual_window.visible_bottom),
          vim.inspect(expected.window.effective_bottom)
        )
      )
    else
      local expected_visible_bottom = expected.window.visible_bottom
      local actual_visible_bottom = actual_window.visible_bottom
      local expected_effective_bottom = legacy_effective_bottom(expected.window)
      local matches_legacy_bottom_follow = actual_visible_bottom == expected_visible_bottom
        or actual_visible_bottom == expected_effective_bottom

      assert.is_true(
        matches_legacy_bottom_follow,
        string.format(
          'Window visible_bottom mismatch: expected %s, got %s (legacy effective_bottom=%s)',
          vim.inspect(expected_visible_bottom),
          vim.inspect(actual_visible_bottom),
          vim.inspect(expected_effective_bottom)
        )
      )
    end
  end
end

describe('renderer unit tests', function()
  local function event_subscriptions()
    local names = {}
    for _, sub in ipairs(require('opencode.ui.renderer').event_subscriptions()) do
      table.insert(names, sub[1])
    end
    return names
  end

  before_each(function()
    require('opencode.event_manager').setup()
  end)

  it('subsribes to events correctly', function()
    local renderer = require('opencode.ui.renderer')
    local event_manager = state.event_manager

    event_manager.events = {}

    renderer.setup_subscriptions()

    for _, event_name in ipairs(event_subscriptions()) do
      assert.is_true(
        event_manager.events[event_name] ~= nil,
        string.format('Renderer did not subscribe to event: %s', event_name)
      )
    end
  end)

  it('subscribes to file watcher updates for reference target invalidation', function()
    assert(vim.tbl_contains(event_subscriptions(), 'file.watcher.updated'))
    assert.is_true(require('opencode.ui.event_scope').should_handle('file.watcher.updated', {
      file = 'src/ok.lua',
      event = 'unlink',
    }))
  end)

  it('unsubsribes from events correctly', function()
    local renderer = require('opencode.ui.renderer')
    local event_manager = state.event_manager

    renderer.setup_subscriptions()

    renderer.setup_subscriptions(false)

    for _, event_name in ipairs(event_subscriptions()) do
      assert.is_true(
        vim.tbl_isempty(event_manager.events[event_name]),
        string.format('Renderer did not unsubscribe from event: %s', event_name)
      )
    end
  end)

  it('captures stable output window state', function()
    helpers.replay_setup()

    output_window.set_lines({ 'one', 'two', 'three' })
    vim.api.nvim_win_set_cursor(state.windows.output_win, { 2, 0 })

    local actual = helpers.capture_output(state.windows.output_buf, output_window.namespace)
    local window_keys = vim.tbl_keys(actual.window)
    table.sort(window_keys)

    assert.are.same({ 'cursor', 'effective_bottom', 'line_count', 'visible_bottom' }, window_keys)
    assert.are.same({ 2, 0 }, actual.window.cursor)
    assert.are.equal(3, actual.window.visible_bottom)
    assert.are.equal(3, actual.window.line_count)
    assert.are.equal(3, actual.window.effective_bottom)

    local existing_file = vim.fn.tempname()
    local file = assert(io.open(existing_file, 'w'))
    file:write(vim.json.encode({ timestamp = 123 }))
    file:close()

    local snapshot = helpers.output_snapshot(state.windows.output_buf, output_window.namespace, existing_file)
    vim.fn.delete(existing_file)

    assert.are.equal(123, snapshot.timestamp)
    assert.are.same(actual.window, snapshot.window)

    local existing_without_timestamp = vim.fn.tempname()
    file = assert(io.open(existing_without_timestamp, 'w'))
    file:write(vim.json.encode({ lines = {} }))
    file:close()

    local snapshot_without_timestamp =
      helpers.output_snapshot(state.windows.output_buf, output_window.namespace, existing_without_timestamp)
    vim.fn.delete(existing_without_timestamp)

    assert.is_nil(snapshot_without_timestamp.timestamp)

    ui.close_windows(state.windows)
  end)

  it('updates active session title from session.updated event', function()
    local renderer = require('opencode.ui.renderer')
    local topbar = require('opencode.ui.topbar')

    state.session.set_active({
      id = 'ses_123',
      title = 'New session - 2026-02-05T22:26:08.579Z',
      time = { created = 1, updated = 1 },
    })

    local active_session_ref = state.active_session

    renderer.on_session_updated({
      info = {
        id = 'ses_123',
        title = 'Branch review request',
        time = { created = 1, updated = 2 },
      },
    })

    assert.are.equal('Branch review request', state.active_session.title)
  end)

  it('rerenders full session when revert changes', function()
    local renderer = require('opencode.ui.renderer')

    state.renderer.set_messages({})
    state.session.set_active({
      id = 'ses_123',
      title = 'Session',
      time = { created = 1, updated = 1 },
      revert = { messageID = 'msg_1', snapshot = 'a', diff = '' },
    })

    local render_stub = stub(renderer, '_render_full_session_data')

    renderer.on_session_updated({
      info = {
        id = 'ses_123',
        title = 'Session',
        time = { created = 1, updated = 2 },
        revert = { messageID = 'msg_2', snapshot = 'b', diff = '' },
      },
    })

    assert.stub(render_stub).was_called_with(state.messages)
    render_stub:revert()
  end)

  it('refreshes the full session when compacted', function()
    local renderer = require('opencode.ui.renderer')
    local events = require('opencode.ui.renderer.events')

    state.session.set_active({
      id = 'ses_123',
      title = 'Session',
      time = { created = 1, updated = 1 },
    })

    local render_stub = stub(renderer, 'render_full_session')

    events.on_session_compacted()

    assert.stub(render_stub).was_called(1)
    render_stub:revert()
  end)

  it('render_output and render_lines do not write targets into RenderState', function()
    local renderer = require('opencode.ui.renderer')
    local ctx = require('opencode.ui.renderer.ctx')
    local Output = require('opencode.ui.output')

    helpers.replay_setup()
    local add_targets_stub = stub(ctx.render_state, 'add_targets')
    local clear_targets_stub = stub(ctx.render_state, 'clear_targets')

    local output = Output.new()
    output:add_line('open README.md')
    output:add_extmark(0, { hl_group = 'OpencodeReference', start_col = 5, end_col = 14 })
    output:add_fold(1, 1)
    output:add_target({
      kind = 'file',
      path = 'README.md',
      range = { line = 1, start_col = 5, end_col = 14 },
    })

    renderer.render_output(output)
    renderer.render_lines({ 'display only' })

    local lines = vim.api.nvim_buf_get_lines(state.windows.output_buf, 0, -1, false)

    add_targets_stub:revert()
    clear_targets_stub:revert()
    ui.close_windows(state.windows)

    assert.are.same({ 'display only' }, lines)
    assert.stub(add_targets_stub).was_not_called()
    assert.stub(clear_targets_stub).was_not_called()
  end)

  it('inserts a single synthetic revert message during full session render', function()
    local renderer = require('opencode.ui.renderer')

    helpers.replay_setup()

    state.session.set_active({
      id = 'ses_123',
      title = 'Session',
      time = { created = 1, updated = 1 },
      revert = { messageID = 'msg_1', snapshot = 'a', diff = '' },
    })

    renderer._render_full_session_data({
      {
        info = {
          id = 'msg_1',
          role = 'assistant',
          sessionID = 'ses_123',
        },
        parts = {},
      },
    })

    local revert_messages = vim.tbl_filter(function(message)
      return message.info and message.info.id == '__opencode_revert_message__'
    end, state.messages or {})

    assert.are.equal(1, #revert_messages)
  end)

  it('supports output target navigation from a replayed assistant file reference', function()
    local renderer = require('opencode.ui.renderer')
    local navigation = require('opencode.ui.navigation')

    helpers.replay_setup()

    local code_buf = vim.api.nvim_create_buf(false, true)
    local code_win = vim.api.nvim_open_win(code_buf, false, {
      relative = 'editor',
      width = 40,
      height = 8,
      row = 0,
      col = 0,
    })

    state.ui.set_last_code_window(code_win)
    local path = 'lua/opencode/ui/navigation.lua'
    local test_root = vim.fn.tempname()
    local absolute_path = test_root .. '/' .. path
    vim.fn.mkdir(vim.fn.fnamemodify(absolute_path, ':h'), 'p')
    local file = assert(io.open(absolute_path, 'w'))
    file:write('abc')
    file:close()

    local original_getcwd = vim.fn.getcwd
    vim.fn.getcwd = function()
      return test_root
    end
    vim.api.nvim_buf_set_name(code_buf, absolute_path)
    vim.api.nvim_buf_set_lines(code_buf, 0, -1, false, { 'abc' })
    local events = helpers.load_test_data('tests/data/output-target-navigation.json')
    state.session.set_active(helpers.get_session_from_events(events, true))
    local session_data = helpers.load_session_from_events(events)
    local ok, err = pcall(function()
      renderer._render_full_session_data(session_data)

      local lines = vim.api.nvim_buf_get_lines(state.windows.output_buf, 0, -1, false)
      local target_line, target_col
      for idx, line in ipairs(lines) do
        local col = line:find(path, 1, true)
        if col then
          target_line = idx
          target_col = col - 1
          break
        end
      end

      assert.is_not_nil(target_line, 'replayed output did not contain file reference')
      vim.api.nvim_set_current_win(state.windows.output_win)
      vim.api.nvim_win_set_cursor(state.windows.output_win, { target_line, target_col })

      navigation.jump_to_target_at_cursor()

      assert.equals(code_win, vim.api.nvim_get_current_win())
      assert.matches(path .. '$', vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(code_win)))
      assert.same({ 1, 2 }, vim.api.nvim_win_get_cursor(code_win))
    end)

    vim.fn.getcwd = original_getcwd
    pcall(vim.api.nvim_win_close, code_win, true)
    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    pcall(vim.fn.delete, test_root, 'rf')
    if not ok then
      error(err)
    end
  end)

  it('renders reference-scoped symbol highlights through full session replay', function()
    local renderer = require('opencode.ui.renderer')
    local symbol_snapshot = require('opencode.ui.symbol_snapshot')
    local events = helpers.load_test_data('tests/data/symbol-reference-navigation.json')
    local referenced_file = 'lua/opencode/ui/symbol_snapshot.lua'
    local cycle = { id = 'cycle' }
    local new_cycle_stub = stub(symbol_snapshot, 'new_cycle').returns(cycle)
    local targets_for_token_stub = stub(symbol_snapshot, 'targets_for_token').invokes(
      function(received_cycle, token, candidate_files)
        assert.are.equal(cycle, received_cycle)
        if token ~= 'collect' then
          return {}
        end
        assert.are.equal(1, #candidate_files)
        assert.matches(referenced_file .. '$', candidate_files[1])
        return {
          {
            path = candidate_files[1],
            line = 1,
            col = 10,
            token = token,
          },
        }
      end
    )

    helpers.replay_setup()
    local original_filereadable = vim.fn.filereadable
    vim.fn.filereadable = function(path)
      if path:match(referenced_file .. '$') then
        return 1
      end
      return original_filereadable(path)
    end
    state.session.set_active(helpers.get_session_from_events(events, true))
    renderer._render_full_session_data(helpers.load_session_from_events(events))

    local actual = helpers.capture_output(state.windows.output_buf, output_window.namespace)
    local symbol_mark
    for _, mark in ipairs(actual.extmarks) do
      if mark[4] and mark[4].hl_group == 'OpencodeSymbolReference' then
        symbol_mark = mark
        break
      end
    end

    new_cycle_stub:revert()
    targets_for_token_stub:revert()
    vim.fn.filereadable = original_filereadable

    assert.is_not_nil(symbol_mark)
  end)

  it('limits rendered messages and inserts a hidden-messages notice', function()
    local renderer = require('opencode.ui.renderer')

    helpers.replay_setup()
    config.ui.output.max_messages = 2

    state.session.set_active({
      id = 'ses_123',
      title = 'Session',
      time = { created = 1, updated = 1 },
    })

    renderer._render_full_session_data({
      {
        info = { id = 'msg_1', role = 'user', sessionID = 'ses_123', time = { created = 1 } },
        parts = {
          { id = 'part_1', messageID = 'msg_1', sessionID = 'ses_123', type = 'text', text = 'first' },
        },
      },
      {
        info = { id = 'msg_2', role = 'assistant', sessionID = 'ses_123', time = { created = 2 } },
        parts = {
          { id = 'part_2', messageID = 'msg_2', sessionID = 'ses_123', type = 'text', text = 'second' },
        },
      },
      {
        info = { id = 'msg_3', role = 'assistant', sessionID = 'ses_123', time = { created = 3 } },
        parts = {
          { id = 'part_3', messageID = 'msg_3', sessionID = 'ses_123', type = 'text', text = 'third' },
        },
      },
    })

    assert.is_not_nil(renderer.get_rendered_message('__opencode_hidden_messages_notice__'))
    assert.is_nil(renderer.get_rendered_message('msg_1'))
    assert.is_not_nil(renderer.get_rendered_message('msg_2'))
    assert.is_not_nil(renderer.get_rendered_message('msg_3'))

    local lines = vim.api.nvim_buf_get_lines(state.windows.output_buf, 0, -1, false)
    assert.are.equal('> 1 older message is not displayed.', lines[1])

    config.ui.output.max_messages = nil
  end)

  it('evicts the oldest rendered message during streaming updates', function()
    local renderer = require('opencode.ui.renderer')
    local events = require('opencode.ui.renderer.events')
    local flush = require('opencode.ui.renderer.flush')

    helpers.replay_setup()
    config.ui.output.max_messages = 2

    state.session.set_active({
      id = 'ses_123',
      title = 'Session',
      time = { created = 1, updated = 1 },
    })
    state.renderer.set_messages({
      {
        info = { id = 'msg_1', role = 'user', sessionID = 'ses_123', time = { created = 1 } },
        parts = {
          { id = 'part_1', messageID = 'msg_1', sessionID = 'ses_123', type = 'text', text = 'first' },
        },
      },
      {
        info = { id = 'msg_2', role = 'assistant', sessionID = 'ses_123', time = { created = 2 } },
        parts = {
          { id = 'part_2', messageID = 'msg_2', sessionID = 'ses_123', type = 'text', text = 'second' },
        },
      },
    })

    renderer._render_full_session_data(state.messages)

    events.on_message_updated({
      info = { id = 'msg_3', role = 'assistant', sessionID = 'ses_123', time = { created = 3 } },
      parts = {},
    })
    events.on_part_updated({
      part = { id = 'part_3', messageID = 'msg_3', sessionID = 'ses_123', type = 'text', text = 'third' },
    })
    flush.flush()

    assert.is_nil(renderer.get_rendered_message('msg_1'))
    assert.is_not_nil(renderer.get_rendered_message('msg_2'))
    assert.is_not_nil(renderer.get_rendered_message('msg_3'))

    local lines = vim.api.nvim_buf_get_lines(state.windows.output_buf, 0, -1, false)
    assert.are.equal('> 1 older message is not displayed.', lines[1])

    config.ui.output.max_messages = nil
  end)

  it('updates the hidden-messages notice when an older hidden message is removed', function()
    local renderer = require('opencode.ui.renderer')
    local events = require('opencode.ui.renderer.events')
    local flush = require('opencode.ui.renderer.flush')

    helpers.replay_setup()
    config.ui.output.max_messages = 2

    state.session.set_active({
      id = 'ses_123',
      title = 'Session',
      time = { created = 1, updated = 1 },
    })

    renderer._render_full_session_data({
      {
        info = { id = 'msg_1', role = 'user', sessionID = 'ses_123', time = { created = 1 } },
        parts = {
          { id = 'part_1', messageID = 'msg_1', sessionID = 'ses_123', type = 'text', text = 'first' },
        },
      },
      {
        info = { id = 'msg_2', role = 'assistant', sessionID = 'ses_123', time = { created = 2 } },
        parts = {
          { id = 'part_2', messageID = 'msg_2', sessionID = 'ses_123', type = 'text', text = 'second' },
        },
      },
      {
        info = { id = 'msg_3', role = 'assistant', sessionID = 'ses_123', time = { created = 3 } },
        parts = {
          { id = 'part_3', messageID = 'msg_3', sessionID = 'ses_123', type = 'text', text = 'third' },
        },
      },
      {
        info = { id = 'msg_4', role = 'assistant', sessionID = 'ses_123', time = { created = 4 } },
        parts = {
          { id = 'part_4', messageID = 'msg_4', sessionID = 'ses_123', type = 'text', text = 'fourth' },
        },
      },
    })

    events.on_message_removed({ sessionID = 'ses_123', messageID = 'msg_1' })
    flush.flush()

    local lines = vim.api.nvim_buf_get_lines(state.windows.output_buf, 0, -1, false)
    assert.are.equal('> 1 older message is not displayed.', lines[1])

    config.ui.output.max_messages = nil
  end)

  it('updates the hidden-messages notice count after multiple hidden removals', function()
    local renderer = require('opencode.ui.renderer')
    local events = require('opencode.ui.renderer.events')
    local flush = require('opencode.ui.renderer.flush')

    helpers.replay_setup()
    config.ui.output.max_messages = 2

    state.session.set_active({
      id = 'ses_123',
      title = 'Session',
      time = { created = 1, updated = 1 },
    })

    renderer._render_full_session_data({
      {
        info = { id = 'msg_1', role = 'user', sessionID = 'ses_123', time = { created = 1 } },
        parts = {
          { id = 'part_1', messageID = 'msg_1', sessionID = 'ses_123', type = 'text', text = 'first' },
        },
      },
      {
        info = { id = 'msg_2', role = 'assistant', sessionID = 'ses_123', time = { created = 2 } },
        parts = {
          { id = 'part_2', messageID = 'msg_2', sessionID = 'ses_123', type = 'text', text = 'second' },
        },
      },
      {
        info = { id = 'msg_3', role = 'assistant', sessionID = 'ses_123', time = { created = 3 } },
        parts = {
          { id = 'part_3', messageID = 'msg_3', sessionID = 'ses_123', type = 'text', text = 'third' },
        },
      },
      {
        info = { id = 'msg_4', role = 'assistant', sessionID = 'ses_123', time = { created = 4 } },
        parts = {
          { id = 'part_4', messageID = 'msg_4', sessionID = 'ses_123', type = 'text', text = 'fourth' },
        },
      },
    })

    events.on_message_removed({ sessionID = 'ses_123', messageID = 'msg_1' })
    flush.flush()

    local lines = vim.api.nvim_buf_get_lines(state.windows.output_buf, 0, -1, false)
    assert.are.equal('> 1 older message is not displayed.', lines[1])

    events.on_message_removed({ sessionID = 'ses_123', messageID = 'msg_2' })
    flush.flush()

    lines = vim.api.nvim_buf_get_lines(state.windows.output_buf, 0, -1, false)
    assert.are.equal('----', lines[1])

    config.ui.output.max_messages = nil
  end)

  it('ignores session.updated for non-active session IDs', function()
    local renderer = require('opencode.ui.renderer')

    state.session.set_active({
      id = 'ses_123',
      title = 'Session',
      time = { created = 1, updated = 1 },
    })

    local render_stub = stub(renderer, '_render_full_session_data')

    renderer.on_session_updated({
      info = {
        id = 'ses_999',
        title = 'Should not apply',
      },
    })

    assert.are.equal('Session', state.active_session.title)
    assert.stub(render_stub).was_not_called()
    render_stub:revert()
  end)
end)

describe('renderer functional tests', function()
  config.debug.show_ids = true

  before_each(function()
    helpers.replay_setup()
  end)

  after_each(function()
    if state.windows then
      ui.close_windows(state.windows)
    end
  end)

  local json_files = vim.fn.glob('tests/data/*.json', false, true)

  -- Don't do the full session test on these files, usually
  -- because they involve permission prompts
  local skip_full_session = {
    'permission-prompt',
    'permission-ask-new',
    'part-before-message-delta',
    'question-ask',
    'question-ask-other',
    'question-multiple-choices',
    'question-multiple-other',
    'multiple-question-ask',
    'shifting-and-multiple-perms',
    'message-removal',
  }

  for _, filepath in ipairs(json_files) do
    local name = vim.fn.fnamemodify(filepath, ':t:r')

    if not name:match('%.expected$') then
      local expected_path = 'tests/data/' .. name .. '.expected.json'

      if vim.fn.filereadable(expected_path) == 1 then
        for i = 1, 2 do
          config.ui.output.rendering.event_collapsing = i == 1 and true or false
          it(
            'replays '
              .. name
              .. ' correctly (event-by-event, '
              .. (config.ui.output.rendering.event_collapsing and 'collapsing' or 'no collapsing')
              .. ')',
            function()
              local events = helpers.load_test_data(filepath)
              state.session.set_active(helpers.get_session_from_events(events))
              local expected = helpers.load_test_data(expected_path)

              helpers.replay_events(events)
              vim.wait(1000, function()
                return vim.tbl_isempty(state.event_manager.throttling_emitter.queue)
              end)

              local actual = helpers.capture_output(state.windows and state.windows.output_buf, output_window.namespace)
              assert_output_matches(expected, actual, name)
            end
          )
        end

        if not vim.tbl_contains(skip_full_session, name) then
          it('replays ' .. name .. ' correctly (session)', function()
            local renderer = require('opencode.ui.renderer')
            local flush = require('opencode.ui.renderer.flush')
            local ctx = require('opencode.ui.renderer.ctx')
            local events = helpers.load_test_data(filepath)
            state.session.set_active(helpers.get_session_from_events(events, true))
            local expected = helpers.load_test_data(expected_path)

            local session_data = helpers.load_session_from_events(events)
            renderer._render_full_session_data(session_data)

            -- If bulk mode is active (async writing), wait for it to complete
            -- by forcing synchronous completion
            if ctx.bulk_mode then
              -- Force synchronous completion by calling end_bulk_mode directly
              -- This ensures all content is written before we check
              flush.end_bulk_mode()
            end

            local actual = helpers.capture_output(state.windows and state.windows.output_buf, output_window.namespace)
            assert_output_matches(expected, actual, name)
          end)
        end
      end
    end
  end
end)
