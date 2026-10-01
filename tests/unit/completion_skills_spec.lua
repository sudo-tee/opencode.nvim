local assert = require('luassert')
local stub = require('luassert.stub')
local Promise = require('opencode.promise')
local completion = require('opencode.ui.completion')
local skills = require('opencode.ui.completion.skills')
local state = require('opencode.state')
local input_window = require('opencode.ui.input_window')
local messaging = require('opencode.services.messaging')
local session_runtime = require('opencode.services.session_runtime')

describe('skill completion', function()
  it('leaves the skill command editable instead of activating on selection', function()
    local previous_server = state.opencode_server
    local previous_sources = completion._sources
    state.jobs.set_server({
      operations = {
        list_skills = function()
          return Promise.new():resolve({ { name = 'skill-test', content = 'Test instructions' } })
        end,
      },
    })
    local source = skills.get_source()
    local items = source.complete({ trigger_char = '/', line = '/skill', input = '/skill', cursor_pos = 6 }):wait()
    state.jobs.set_server(previous_server)
    assert.equals(1, #items)
    assert.equals('/skill-test *', items[1].label)
    assert.equals('skill-test ', items[1].insert_text)

    local open = stub(session_runtime, 'open').returns(Promise.new():resolve(true))
    local send = stub(messaging, 'send_message').returns(Promise.new():resolve(true))
    local clear = stub(input_window, 'set_content')
    completion._sources = { source }
    completion.on_completion_done(items[1])
    vim.wait(30, function()
      return false
    end)

    assert.stub(open).was_not_called()
    assert.stub(send).was_not_called()
    assert.stub(clear).was_not_called()
    completion._sources = previous_sources
    clear:revert()
    send:revert()
    open:revert()
  end)
end)
