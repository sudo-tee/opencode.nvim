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

  it('bootstraps child tools delivered before the child observation subscribes', function()
    assert.is_true(replay.load_events('tests/data/explore.json'))
    helpers.wait_for_replay_ready()
    local session = require('opencode.ui.renderer.ctx').current().render_session
    local child_id = 'ses_341f3e676ffez6WUF6zpok7dUZ'
    assert.is_nil(session:child(child_id))
    local connection = state.opencode_server
    local root_id = state.active_session.id
    assert.same({}, connection.operations.list_children(connection, root_id):wait())
    assert.same({}, connection.operations.list_messages(connection, child_id):wait())

    replay.replay_all(0)

    local observed = assert(session:child(child_id)):read()
    assert.equals('current', observed.sync.messages.state)
    assert.equals(11, #observed.entry_order)
    local tools = 0
    for _, entry in pairs(observed.entries_by_id) do
      for _, content in ipairs(entry.content) do
        if content.kind == 'tool' then
          tools = tools + 1
          assert.equals('completed', content.state)
        end
      end
    end
    assert.equals(18, tools)
    local lines = vim.api.nvim_buf_get_lines(state.windows.output_buf, 0, -1, false)
    local summaries = 0
    for _, line in ipairs(lines) do
      if line:match('^ %*%*') then
        summaries = summaries + 1
      end
    end
    assert.equals(18, summaries)
  end)

  it('rehydrates an unidentified early delta only from an authoritative part update', function()
    assert.is_true(replay.load_events('tests/data/part-before-message-delta.json'))
    replay.replay_next(#replay.events - 1)

    local observation = assert(state.session.active_observation())
    local assistant_id = 'msg_0000000000002'
    assert.same({}, observation:read().entries_by_id[assistant_id].content)

    replay.replay_next(1)

    local content = observation:read().entries_by_id[assistant_id].content
    assert.equals(1, #content)
    assert.equals('text', content[1].kind)
    assert.equals('Sure, I can help with that.', content[1].text)
  end)

  it('keeps explicit empty tool input authoritative in replay bootstrap snapshots', function()
    assert.is_true(replay.load_events('tests/data/mcp-tool.json'))
    local final_update = vim.deepcopy(replay.events[7])
    final_update.properties.part.state.input = {}
    local events = {}
    for index = 1, 6 do
      events[index] = replay.events[index]
    end
    events[7] = final_update
    helpers.replay_events(events)

    local connection = state.opencode_server
    local messages = connection.operations.list_messages(connection, 'ses_mcp_test_1'):wait()
    local tool
    for _, message in ipairs(messages) do
      for _, part in ipairs(message.parts) do
        if part.id == 'prt_mcp_tool1' then
          tool = part
        end
      end
    end
    assert.same({}, assert(tool).state.input)
    assert.equals('completed', tool.state.status)

    local entries = helpers.load_session_from_events(events)
    local content = entries[2].content
    assert.equals('prt_mcp_tool1', content[2].id)
    assert.same({}, content[2].input)
  end)
end)
