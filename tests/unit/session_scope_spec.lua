local session_scope = require('opencode.ui.session_scope')
local state = require('opencode.state')
local ctx = require('opencode.ui.renderer.ctx')

describe('session_scope', function()
  before_each(function()
    state.session.set_active({ id = 'session_active' })
    state.renderer.set_messages({})
    ctx.render_state:reset()
  end)

  after_each(function()
    state.session.set_active(nil)
    state.renderer.set_messages({})
    ctx.render_state:reset()
  end)

  it('matches requests from the active session', function()
    assert.is_true(session_scope.belongs_to_active_session({
      id = 'request_active',
      sessionID = 'session_active',
    }))
  end)

  it('matches requests whose tool message is in the current session', function()
    state.renderer.set_messages({
      {
        info = {
          id = 'message_current',
          sessionID = 'session_active',
        },
        parts = {},
      },
    })

    assert.is_true(session_scope.belongs_to_active_session({
      id = 'request_with_message',
      sessionID = 'session_other',
      tool = {
        messageID = 'message_current',
      },
    }))
  end)

  it('matches requests from rendered child task sessions', function()
    ctx.render_state:set_part({
      id = 'task_part',
      messageID = 'message_task',
      tool = 'task',
      state = {
        metadata = {
          sessionId = 'session_child',
        },
      },
    }, 1, 1)

    assert.is_true(session_scope.belongs_to_active_session({
      id = 'request_child',
      sessionID = 'session_child',
    }))
  end)

  it('rejects requests from unrelated sessions', function()
    assert.is_false(session_scope.belongs_to_active_session({
      id = 'request_other',
      sessionID = 'session_other',
    }))
  end)

  it('keeps legacy requests without a session id visible for the active session', function()
    assert.is_true(session_scope.belongs_to_active_session({
      id = 'request_legacy',
    }))
  end)
end)
