local streaming_renderer = require('opencode.ui.streaming_renderer')
local state = require('opencode.state')
local ui = require('opencode.ui.ui')
local helpers = require('tests.helpers')

describe('streaming_renderer', function()
  local restore_time_ago

  before_each(function()
    streaming_renderer.reset()
    state.windows = ui.create_windows()

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
    local expected = helpers.load_test_data('tests/data/simple-session.expected.json')

    helpers.replay_events(events)

    vim.wait(100)

    local actual = helpers.capture_output(state.windows.output_buf, streaming_renderer._namespace)

    assert.same(expected.lines, actual.lines)
    assert.same(expected.extmarks, helpers.normalize_namespace_ids(actual.extmarks))
  end)

  it('replays updating-text correctly', function()
    local events = helpers.load_test_data('tests/data/updating-text.json')
    local expected = helpers.load_test_data('tests/data/updating-text.expected.json')

    helpers.replay_events(events)

    vim.wait(100)

    local actual = helpers.capture_output(state.windows.output_buf, streaming_renderer._namespace)

    assert.same(expected.lines, actual.lines)
    assert.same(expected.extmarks, helpers.normalize_namespace_ids(actual.extmarks))
  end)

  it('replays planning correctly', function()
    local events = helpers.load_test_data('tests/data/planning.json')
    local expected = helpers.load_test_data('tests/data/planning.expected.json')

    helpers.replay_events(events)

    vim.wait(100)

    local actual = helpers.capture_output(state.windows.output_buf, streaming_renderer._namespace)

    assert.same(expected.lines, actual.lines)
    assert.same(expected.extmarks, helpers.normalize_namespace_ids(actual.extmarks))
  end)

  it('replays permission correctly', function()
    local events = helpers.load_test_data('tests/data/permission.json')
    local expected = helpers.load_test_data('tests/data/permission.expected.json')

    helpers.replay_events(events)

    vim.wait(100)

    local actual = helpers.capture_output(state.windows.output_buf, streaming_renderer._namespace)

    assert.same(expected.lines, actual.lines)
    assert.same(expected.extmarks, helpers.normalize_namespace_ids(actual.extmarks))
  end)

  it('replays permission denied correctly', function()
    local events = helpers.load_test_data('tests/data/permission-denied.json')
    local expected = helpers.load_test_data('tests/data/permission-denied.expected.json')

    helpers.replay_events(events)

    vim.wait(100)

    local actual = helpers.capture_output(state.windows.output_buf, streaming_renderer._namespace)

    assert.same(expected.lines, actual.lines)
    assert.same(expected.extmarks, helpers.normalize_namespace_ids(actual.extmarks))
  end)

  it('replays diff correctly', function()
    local events = helpers.load_test_data('tests/data/diff.json')
    local expected = helpers.load_test_data('tests/data/diff.expected.json')

    helpers.replay_events(events)

    vim.wait(200)

    local actual = helpers.capture_output(state.windows.output_buf, streaming_renderer._namespace)

    assert.same(expected.lines, actual.lines)
    assert.same(expected.extmarks, helpers.normalize_namespace_ids(actual.extmarks))
  end)
end)
