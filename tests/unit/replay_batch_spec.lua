local assert = require('luassert')
local stub = require('luassert.stub')
local helpers = require('tests.helpers')
local replay = require('tests.manual.renderer_replay')
local state = require('opencode.state')
local ui = require('opencode.ui.ui')
local output_window = require('opencode.ui.output_window')
local config = require('opencode.config')

describe('replay event batching', function()
  local original_show_ids
  local wait_stub
  local single_event_stub

  before_each(function()
    original_show_ids = config.debug.show_ids
    config.debug.show_ids = true
    helpers.replay_setup()
    assert.is_true(replay.load_events('tests/data/simple-session.json'))
    helpers.wait_for_replay_ready()
  end)

  after_each(function()
    if wait_stub then
      wait_stub:revert()
      wait_stub = nil
    end
    if single_event_stub then
      single_event_stub:revert()
      single_event_stub = nil
    end
    config.debug.show_ids = original_show_ids
    ui.close_windows(state.windows)
  end)

  it('waits once for a native event batch and preserves its final snapshot', function()
    local wait = vim.wait
    wait_stub = stub(vim, 'wait').invokes(wait)

    helpers.replay_events(replay.events)

    assert.stub(wait_stub).was_called(1)
    local expected_file = 'tests/data/simple-session.expected.json'
    local expected = helpers.load_test_data(expected_file)
    local actual = helpers.output_snapshot(state.windows.output_buf, output_window.namespace, expected_file)
    expected.window, actual.window = nil, nil
    assert.same(expected, actual)
  end)

  it('batches multi-step playback rather than calling the single-event helper', function()
    single_event_stub = stub(helpers, 'replay_event')

    replay.replay_next(#replay.events)

    assert.stub(single_event_stub).was_not_called()
    assert.equals(#replay.events, replay.event_index)
    assert.is_true(replay.wait_for_idle())
    assert.is_true(#vim.api.nvim_buf_get_lines(state.windows.output_buf, 0, -1, false) > 1)
  end)

  it('retains the settling single-event helper for interactive stepping', function()
    single_event_stub = stub(helpers, 'replay_event')

    replay.replay_next(1)

    assert.stub(single_event_stub).was_called_with(replay.events[1])
    assert.equals(1, replay.event_index)
  end)

  it('keeps events after a session directory update inside the same batch', function()
    helpers.replay_setup()
    assert.is_true(replay.load_events('tests/data/question-multiple-choices.json'))

    replay.replay_all(0)

    local observed = assert(state.session.active_observation()):read()
    local user = observed.entries_by_id['msg_f5bf094d40010EarsFjD5WvW47']
    assert.is_not_nil(user)
    assert.equals('user', user.kind)
    assert.is_truthy(
      table
        .concat(vim.api.nvim_buf_get_lines(state.windows.output_buf, 0, -1, false), '\n')
        :find('Can you ask me a question', 1, true)
    )
  end)
end)
