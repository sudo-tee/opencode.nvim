local assert = require('luassert')
local config = require('opencode.config')
local event_capture = require('opencode.event_capture')
local helpers = require('tests.helpers')
local replay = require('tests.manual.renderer_replay')
local state = require('opencode.state')
local ui = require('opencode.ui.ui')

describe('V2 streamed event capture replay', function()
  local original_capture
  local capture_file

  before_each(function()
    original_capture = config.debug.capture_streamed_events
    helpers.replay_setup()
    event_capture.clear()
    config.debug.capture_streamed_events = true
  end)

  after_each(function()
    config.debug.capture_streamed_events = original_capture
    event_capture.clear()
    if capture_file then
      vim.fn.delete(capture_file)
      capture_file = nil
    end
    if state.active_session then
      state.session.clear_active()
    end
    if state.opencode_server then
      state.opencode_server:close()
      state.jobs.clear_server()
    end
    if state.windows then
      ui.close_windows(state.windows)
    end
  end)

  it('saves native event timestamps and replays through V2 observation', function()
    local session_id = 'ses-v2-capture-replay'
    local message_id = 'msg-v2-capture-replay'
    local connection = helpers.new_v2_replay_connection()
    state.opencode_server:close()
    state.jobs.set_server(connection)
    state.session.set_active({ id = session_id, location = { directory = helpers.MOCK_CWD } })
    helpers.wait_for_replay_ready()

    local native_events = {
      {
        id = 'evt-step',
        type = 'session.step.started',
        created = 100,
        data = {
          sessionID = session_id,
          assistantMessageID = message_id,
          agent = 'build',
          model = { providerID = 'provider', id = 'model' },
        },
      },
      {
        id = 'evt-text-started',
        type = 'session.text.started',
        created = 101,
        data = { sessionID = session_id, assistantMessageID = message_id, ordinal = 0 },
      },
      {
        id = 'evt-text-delta',
        type = 'session.text.delta',
        created = 102,
        data = { sessionID = session_id, assistantMessageID = message_id, ordinal = 0, delta = 'Captured ' },
      },
      {
        id = 'evt-text-ended',
        type = 'session.text.ended',
        created = 103,
        data = { sessionID = session_id, assistantMessageID = message_id, ordinal = 0, text = 'Captured V2 output' },
      },
    }
    for _, event in ipairs(native_events) do
      helpers._replay_stream.on_chunk('data: ' .. vim.json.encode(event) .. '\n\n')
    end

    local captured = event_capture.get()
    assert.equals(#native_events, #captured)
    assert.equals('v2', captured[1].protocol)
    assert.equals(native_events[1].created, captured[1].created)
    assert.same(native_events[1].data, captured[1].data)

    capture_file = vim.fn.tempname() .. '.json'
    assert.equals(#native_events, event_capture.save(capture_file))
    config.debug.capture_streamed_events = false

    assert.is_true(replay.load_events(capture_file))
    assert.equals('v2', state.opencode_server.protocol)
    replay.replay_all(0)
    assert.is_true(replay.wait_for_idle())

    local lines = vim.api.nvim_buf_get_lines(state.windows.output_buf, 0, -1, false)
    assert.is_truthy(table.concat(lines, '\n'):find('Captured V2 output', 1, true))
    local entries = helpers.load_session_from_events(replay.events)
    assert.equals('Captured V2 output', entries[1].content[1].text)
  end)
end)
