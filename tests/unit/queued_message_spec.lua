local assert = require('luassert')
local events = require('opencode.ui.renderer.events')
local flush = require('opencode.ui.renderer.flush')
local loading_animation = require('opencode.ui.loading_animation')
local state = require('opencode.state')

describe('queued message marker', function()
  local original_mark_message_dirty
  local user_message

  before_each(function()
    original_mark_message_dirty = flush.mark_message_dirty
    flush.mark_message_dirty = function() end
    state.renderer.set_messages({})
    state.session.set_active({ id = 'ses_1' })
    loading_animation._animation.last_status_map.ses_1 = { type = 'busy' }
  end)

  after_each(function()
    flush.mark_message_dirty = original_mark_message_dirty
    loading_animation._animation.last_status_map.ses_1 = nil
    state.renderer.set_messages(nil)
    state.session.set_active(nil)
  end)

  it('clears a queued prompt when its assistant starts', function()
    user_message = {
      info = {
        id = 'msg_user',
        sessionID = 'ses_1',
        role = 'user',
      },
      parts = {},
    }
    events.on_message_updated(user_message)
    assert.is_true(user_message.info.queued)

    events.on_message_updated({
      info = {
        id = 'msg_assistant',
        sessionID = 'ses_1',
        role = 'assistant',
        parentID = 'msg_user',
      },
    }, 1)

    assert.is_nil(user_message.info.queued)
  end)
end)
