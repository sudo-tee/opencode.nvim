local streaming_renderer = require('opencode.ui.streaming_renderer')
local state = require('opencode.state')
local ui = require('opencode.ui.ui')
local helpers = require('tests.helpers')
local output_renderer = require('opencode.ui.output_renderer')
local config_file = require('opencode.config_file')

describe('streaming_renderer', function()
  local restore_time_ago

  before_each(function()
    streaming_renderer.reset()

    -- disable the config_file apis because topbar uses them
    local empty_promise = require('opencode.promise').new():resolve(nil)
    config_file.config_promise = empty_promise
    config_file.project_promise = empty_promise
    config_file.providers_promise = empty_promise

    state.windows = ui.create_windows()

    -- we don't want output_renderer responding to setting
    -- the session id
    output_renderer._cleanup_subscriptions()

    restore_time_ago = helpers.mock_time_ago()

    local config = require('opencode.config')
    if not config.config then
      config.config = vim.deepcopy(config.defaults)
    end
  end)

  after_each(function()
    if state.windows then
      ui.close_windows(state.windows)
    end

    if restore_time_ago then
      restore_time_ago()
    end
  end)

  it('replays simple-session correctly', function()
    local events = helpers.load_test_data('tests/data/simple-session.json')
    state.active_session = helpers.get_session_from_events(events)
    local expected = helpers.load_test_data('tests/data/simple-session.expected.json')

    helpers.replay_events(events)

    vim.wait(100)

    local actual = helpers.capture_output(state.windows.output_buf, streaming_renderer._namespace)

    assert.same(expected.lines, actual.lines)
    assert.same(expected.extmarks, helpers.normalize_namespace_ids(actual.extmarks))
  end)

  it('replays updating-text correctly', function()
    local events = helpers.load_test_data('tests/data/updating-text.json')
    state.active_session = helpers.get_session_from_events(events)
    local expected = helpers.load_test_data('tests/data/updating-text.expected.json')

    helpers.replay_events(events)

    vim.wait(100)

    local actual = helpers.capture_output(state.windows.output_buf, streaming_renderer._namespace)

    assert.same(expected.lines, actual.lines)
    assert.same(expected.extmarks, helpers.normalize_namespace_ids(actual.extmarks))
  end)

  it('replays planning correctly', function()
    local events = helpers.load_test_data('tests/data/planning.json')
    state.active_session = helpers.get_session_from_events(events)
    local expected = helpers.load_test_data('tests/data/planning.expected.json')

    helpers.replay_events(events)

    vim.wait(100)

    local actual = helpers.capture_output(state.windows.output_buf, streaming_renderer._namespace)

    assert.same(expected.lines, actual.lines)
    assert.same(expected.extmarks, helpers.normalize_namespace_ids(actual.extmarks))
  end)

  it('replays permission correctly', function()
    local events = helpers.load_test_data('tests/data/permission.json')
    state.active_session = helpers.get_session_from_events(events)
    local expected = helpers.load_test_data('tests/data/permission.expected.json')

    helpers.replay_events(events)

    vim.wait(100)

    local actual = helpers.capture_output(state.windows.output_buf, streaming_renderer._namespace)

    assert.same(expected.lines, actual.lines)
    assert.same(expected.extmarks, helpers.normalize_namespace_ids(actual.extmarks))
  end)

  it('replays permission denied correctly', function()
    local events = helpers.load_test_data('tests/data/permission-denied.json')
    state.active_session = helpers.get_session_from_events(events)
    local expected = helpers.load_test_data('tests/data/permission-denied.expected.json')

    helpers.replay_events(events)

    vim.wait(100)

    local actual = helpers.capture_output(state.windows.output_buf, streaming_renderer._namespace)

    assert.same(expected.lines, actual.lines)
    assert.same(expected.extmarks, helpers.normalize_namespace_ids(actual.extmarks))
  end)

  it('replays diff correctly', function()
    local events = helpers.load_test_data('tests/data/diff.json')
    state.active_session = helpers.get_session_from_events(events)
    local expected = helpers.load_test_data('tests/data/diff.expected.json')

    helpers.replay_events(events)

    vim.wait(200)

    local actual = helpers.capture_output(state.windows.output_buf, streaming_renderer._namespace)

    assert.same(expected.lines, actual.lines)
    assert.same(expected.extmarks, helpers.normalize_namespace_ids(actual.extmarks))
  end)

  it('replays tool-invalid correctly', function()
    local events = helpers.load_test_data('tests/data/tool-invalid.json')
    state.active_session = helpers.get_session_from_events(events)
    local expected = helpers.load_test_data('tests/data/tool-invalid.expected.json')

    helpers.replay_events(events)

    vim.wait(200)

    local actual = helpers.capture_output(state.windows.output_buf, streaming_renderer._namespace)

    assert.same(expected.lines, actual.lines)
    assert.same(expected.extmarks, helpers.normalize_namespace_ids(actual.extmarks))
  end)
end)
