local helpers = require('tests.helpers')
local state = require('opencode.state')
local renderer = require('opencode.ui.renderer')
local flush = require('opencode.ui.renderer.flush')
local ctx = require('opencode.ui.renderer.ctx')
local output_window = require('opencode.ui.output_window')

describe('replay malformed todowrite session fixture', function()
  before_each(function()
    helpers.replay_setup()
  end)

  after_each(function()
    if ctx.bulk_mode then
      flush.end_bulk_mode()
    end
  end)

  it('renders real malformed todowrite payload without crashing', function()
    local session_data = helpers.load_test_data('tests/data/todowrite-malformed-session.json')

    assert.is_true(type(session_data) == 'table' and #session_data > 0)

    local malformed_found = false
    for _, msg in ipairs(session_data) do
      for _, part in ipairs(msg.parts or {}) do
        if part.tool == 'todowrite' then
          local todos = part.state and part.state.input and part.state.input.todos
          if type(todos) == 'string' then
            malformed_found = true
          end
        end
      end
    end
    assert.is_true(malformed_found)

    state.session.set_active({ id = session_data[1].info.sessionID })

    local ok, err = pcall(function()
      renderer._render_full_session_data(session_data)
    end)

    assert.is_true(ok, tostring(err))
    assert.is_false(ctx.bulk_mode)

    local actual = helpers.capture_output(state.windows and state.windows.output_buf, output_window.namespace)
    assert.is_true(#(actual.lines or {}) > 0)
  end)
end)
