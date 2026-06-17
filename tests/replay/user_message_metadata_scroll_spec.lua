local helpers = require('tests.helpers')
local state = require('opencode.state')
local ui = require('opencode.ui.ui')
local output_window = require('opencode.ui.output_window')

local fixture_path = 'tests/data/user-message-metadata-update.json'

local function wait_for_replay_queue()
  local ok = vim.wait(1000, function()
    local emitter = state.event_manager and state.event_manager.throttling_emitter
    return emitter and vim.tbl_isempty(emitter.queue)
  end)

  assert.is_true(ok, 'Timed out waiting for replay queue to drain')
end

local function replay_event(event)
  helpers.replay_event(event)
  wait_for_replay_queue()
end

local function capture_window()
  return helpers.capture_output(state.windows.output_buf, output_window.namespace).window
end

local function format_window(window)
  return string.format(
    'cursor=%s visible_bottom=%s line_count=%s effective_bottom=%s',
    vim.inspect(window.cursor),
    vim.inspect(window.visible_bottom),
    vim.inspect(window.line_count),
    vim.inspect(window.effective_bottom)
  )
end

local function is_at_effective_bottom(window)
  return window.visible_bottom == window.effective_bottom and window.cursor[1] == window.effective_bottom
end

local function move_output_away_from_bottom()
  local win = state.windows.output_win
  vim.api.nvim_win_set_height(win, 1)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd('normal! zt')
  end)

  local window = capture_window()
  assert.is_true(
    window.visible_bottom ~= window.effective_bottom and window.cursor[1] ~= window.effective_bottom,
    'Could not construct user-away output window state: ' .. format_window(window)
  )
  return window
end

local function assert_preserved_user_away(update_kind, before, actual)
  assert.is_true(
    vim.deep_equal(actual.cursor, before.cursor)
      and actual.visible_bottom == before.visible_bottom
      and actual.line_count == before.line_count
      and actual.effective_bottom == before.effective_bottom,
    'Expected existing user metadata '
      .. update_kind
      .. ' update to preserve user-away output window state; before '
      .. format_window(before)
      .. ', actual '
      .. format_window(actual)
  )
end

local function assert_followed_bottom(actual)
  assert.is_true(
    is_at_effective_bottom(actual),
    'Expected new user message submit-follow to reach bottom; actual ' .. format_window(actual)
  )
end

local function assert_preserved_user_away_after_growth(before, actual)
  assert.is_true(
    vim.deep_equal(actual.cursor, before.cursor)
      and actual.visible_bottom == before.visible_bottom
      and actual.line_count > before.line_count,
    'Expected external new user message to render without force-scrolling; before '
      .. format_window(before)
      .. ', actual '
      .. format_window(actual)
  )
end

describe('replay user message metadata scroll behavior', function()
  before_each(function()
    helpers.replay_setup()
  end)

  after_each(function()
    if state.windows then
      ui.close_windows(state.windows)
    end
  end)

  it('preserves user-away scroll when replaying existing user summary metadata updates', function()
    local events = helpers.load_test_data(fixture_path)
    state.session.set_active(helpers.get_session_from_events(events))

    replay_event(events[1])
    replay_event(events[2])
    local before = move_output_away_from_bottom()

    replay_event(events[3])

    assert_preserved_user_away('summary', before, capture_window())
  end)

  it('preserves user-away scroll when replaying duplicate existing user metadata updates', function()
    local events = helpers.load_test_data(fixture_path)
    state.session.set_active(helpers.get_session_from_events(events))

    replay_event(events[1])
    replay_event(events[2])
    replay_event(events[3])
    local before = move_output_away_from_bottom()

    replay_event(events[4])

    assert_preserved_user_away('duplicate', before, capture_window())
  end)

  it('preserves user-away scroll when replaying external new user messages', function()
    local events = helpers.load_test_data(fixture_path)
    local session = helpers.get_session_from_events(events)
    state.session.set_active(session)

    replay_event(events[1])
    replay_event(events[2])
    local before = move_output_away_from_bottom()

    local new_user_message = vim.deepcopy(events[1])
    new_user_message.properties.info.id = 'msg_user_metadata_update_external'
    new_user_message.properties.info.time.created = 1700000000001

    replay_event(new_user_message)

    assert_preserved_user_away_after_growth(before, capture_window())
  end)

  it('keeps submit-follow for locally submitted new user messages', function()
    local events = helpers.load_test_data(fixture_path)
    local session = helpers.get_session_from_events(events)
    state.session.set_active(session)

    replay_event(events[1])
    replay_event(events[2])
    move_output_away_from_bottom()

    state.session.set_user_message_count({ [session.id] = 1 })

    local new_user_message = vim.deepcopy(events[1])
    new_user_message.properties.info.id = 'msg_user_metadata_update_new'
    new_user_message.properties.info.time.created = 1700000000001

    replay_event(new_user_message)

    assert_followed_bottom(capture_window())
  end)
end)
