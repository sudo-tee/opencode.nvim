local event_scope = require('opencode.ui.event_scope')
local state = require('opencode.state')

describe('event_scope', function()
  before_each(function()
    state.session.set_active({ id = 'session_active' })
  end)

  after_each(function()
    state.session.set_active(nil)
  end)

  it('has a scope policy for every renderer event subscription', function()
    for _, sub in ipairs(require('opencode.ui.renderer').event_subscriptions()) do
      assert.is_true(event_scope.has_policy(sub[1]), 'Missing event scope policy for ' .. sub[1])
    end
  end)

  it('rejects events without an explicit policy', function()
    assert.is_false(event_scope.should_handle('unknown.event', {}))
  end)

  it('accepts active session events', function()
    assert.is_true(event_scope.should_handle('session.compacted', {
      sessionID = 'session_active',
    }))
  end)

  it('rejects unrelated session events', function()
    assert.is_false(event_scope.should_handle('session.compacted', {
      sessionID = 'session_other',
    }))
  end)

  it('rejects malformed session-scoped events', function()
    assert.is_false(event_scope.should_handle('session.compacted', {}))
  end)

  it('rejects message parts from unrelated sessions', function()
    assert.is_false(event_scope.should_handle('message.part.updated', {
      part = {
        id = 'part_other',
        messageID = 'message_other',
        sessionID = 'session_other',
        type = 'text',
      },
    }))
  end)

  it('accepts child-session tool parts before the parent task part is indexed', function()
    assert.is_true(event_scope.should_handle('message.part.updated', {
      part = {
        id = 'part_child_tool',
        messageID = 'message_child',
        sessionID = 'session_child',
        type = 'tool',
      },
    }))
  end)

  it('keeps legacy interactive ask events visible', function()
    assert.is_true(event_scope.should_handle('permission.asked', {
      id = 'permission_legacy',
    }))
  end)

  it('returns a stable wrapper for the same event and callback', function()
    local callback = function() end

    assert.are.equal(
      event_scope.scoped_callback('session.updated', callback),
      event_scope.scoped_callback('session.updated', callback)
    )
  end)
end)
