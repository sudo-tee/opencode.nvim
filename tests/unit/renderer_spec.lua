local Promise = require('opencode.promise')
local renderer = require('opencode.ui.renderer')
local session = require('opencode.session')
local output_window = require('opencode.ui.output_window')
local state = require('opencode.state')
local stub = require('luassert.stub')

describe('renderer full session lifecycle', function()
  before_each(function()
    state.api_client = {}
    state.active_session = { id = 'sess-1' }
    renderer._full_render_in_flight = nil
    renderer._full_render_pending_opts = nil
  end)

  after_each(function()
    if output_window.mounted and output_window.mounted.revert then
      output_window.mounted:revert()
    end
    if session.get_messages and session.get_messages.revert then
      session.get_messages:revert()
    end
    if renderer._render_full_session_data and renderer._render_full_session_data.revert then
      renderer._render_full_session_data:revert()
    end
  end)

  it('coalesces concurrent full renders into one in-flight request', function()
    local first_request = Promise.new()
    local request_calls = 0

    stub(output_window, 'mounted').returns(true)
    stub(session, 'get_messages').invokes(function()
      request_calls = request_calls + 1
      if request_calls == 1 then
        return first_request
      end
      return Promise.new():resolve({})
    end)
    stub(renderer, '_render_full_session_data').returns(nil)

    local p1 = renderer.render_full_session()
    local p2 = renderer.render_full_session()

    assert.are.equal(1, request_calls)
    assert.are.same(p1, p2)

    first_request:resolve({})

    local ran_follow_up = vim.wait(200, function()
      return request_calls == 2 and renderer._full_render_in_flight == nil
    end)

    assert.is_true(ran_follow_up)
  end)
end)
