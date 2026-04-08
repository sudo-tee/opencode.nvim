local state = require('opencode.state')
local permission_window = require('opencode.ui.permission_window')
local events = require('opencode.ui.renderer.events')
local ctx = require('opencode.ui.renderer.ctx')
local output_window = require('opencode.ui.output_window')
local flush = require('opencode.ui.renderer.flush')
local helpers = require('tests.helpers')

describe('permission_integration', function()
  local mock_update_permission_from_part
  local captured_calls

  before_each(function()
    state.renderer.set_messages({})
    state.renderer.set_pending_permissions({})
    state.session.set_active({ id = 'session_123' })

    permission_window._permission_queue = {}
    permission_window._dialog = nil
    permission_window._processing = false

    ctx.render_state:reset()
    ctx.prev_line_count = 0

    captured_calls = {}
    mock_update_permission_from_part = permission_window.update_permission_from_part
    permission_window.update_permission_from_part = function(permission_id, part)
      table.insert(captured_calls, { permission_id = permission_id, part = part })
      return true
    end
  end)

  after_each(function()
    permission_window.update_permission_from_part = mock_update_permission_from_part
  end)

  describe('on_part_updated permission correlation', function()
    it('correlates part with pending permission by callID and messageID', function()
      state.renderer.set_pending_permissions({
        {
          id = 'per_test_123',
          permission = 'bash',
          tool = {
            messageID = 'msg_abc',
            callID = 'call_xyz',
          },
        },
      })

      local message = {
        info = { id = 'msg_abc', sessionID = 'session_123' },
        parts = {},
      }
      ctx.render_state:set_message(message, 1, 1)
      table.insert(state.messages, message)

      local part = {
        id = 'part_456',
        messageID = 'msg_abc',
        sessionID = 'session_123',
        callID = 'call_xyz',
        type = 'tool_use',
        state = {
          input = {
            description = 'Execute bash command',
            command = 'echo hello',
          },
        },
      }

      events.on_part_updated({ part = part })

      assert.are.equal(1, #captured_calls)
      assert.are.equal('per_test_123', captured_calls[1].permission_id)
      assert.are.equal(part, captured_calls[1].part)
    end)

    it('supports backward compatibility with root-level callID/messageID', function()
      state.renderer.set_pending_permissions({
        {
          id = 'per_legacy_456',
          permission = 'bash',
          messageID = 'msg_legacy',
          callID = 'call_legacy',
        },
      })

      local message = {
        info = { id = 'msg_legacy', sessionID = 'session_123' },
        parts = {},
      }
      ctx.render_state:set_message(message, 1, 1)
      table.insert(state.messages, message)

      local part = {
        id = 'part_789',
        messageID = 'msg_legacy',
        sessionID = 'session_123',
        callID = 'call_legacy',
        type = 'tool_use',
        state = {
          input = {
            description = 'Legacy permission',
          },
        },
      }

      events.on_part_updated({ part = part })

      assert.are.equal(1, #captured_calls)
      assert.are.equal('per_legacy_456', captured_calls[1].permission_id)
    end)

    it('does not call update_permission_from_part when callID does not match', function()
      state.renderer.set_pending_permissions({
        {
          id = 'per_test_123',
          permission = 'bash',
          tool = {
            messageID = 'msg_abc',
            callID = 'call_xyz',
          },
        },
      })

      local message = {
        info = { id = 'msg_abc', sessionID = 'session_123' },
        parts = {},
      }
      ctx.render_state:set_message(message, 1, 1)
      table.insert(state.messages, message)

      local part = {
        id = 'part_456',
        messageID = 'msg_abc',
        sessionID = 'session_123',
        callID = 'call_different',
        type = 'tool_use',
        state = {
          input = {
            description = 'Different command',
          },
        },
      }

      events.on_part_updated({ part = part })

      assert.are.equal(0, #captured_calls)
    end)

    it('does not call update_permission_from_part when messageID does not match', function()
      state.renderer.set_pending_permissions({
        {
          id = 'per_test_123',
          permission = 'bash',
          tool = {
            messageID = 'msg_abc',
            callID = 'call_xyz',
          },
        },
      })

      local message = {
        info = { id = 'msg_different', sessionID = 'session_123' },
        parts = {},
      }
      ctx.render_state:set_message(message, 1, 1)
      table.insert(state.messages, message)

      local part = {
        id = 'part_456',
        messageID = 'msg_different',
        sessionID = 'session_123',
        callID = 'call_xyz',
        type = 'tool_use',
        state = {
          input = {
            description = 'Different message',
          },
        },
      }

      events.on_part_updated({ part = part })

      assert.are.equal(0, #captured_calls)
    end)

    it('skips correlation when part has no callID', function()
      state.renderer.set_pending_permissions({
        {
          id = 'per_test_123',
          permission = 'bash',
          tool = {
            messageID = 'msg_abc',
            callID = 'call_xyz',
          },
        },
      })

      local message = {
        info = { id = 'msg_abc', sessionID = 'session_123' },
        parts = {},
      }
      ctx.render_state:set_message(message, 1, 1)
      table.insert(state.messages, message)

      local part = {
        id = 'part_456',
        messageID = 'msg_abc',
        sessionID = 'session_123',
        type = 'text',
        content = 'Some text content',
      }

      events.on_part_updated({ part = part })

      assert.are.equal(0, #captured_calls)
    end)

    it('skips iteration when no pending permissions', function()
      state.renderer.set_pending_permissions({})

      local message = {
        info = { id = 'msg_abc', sessionID = 'session_123' },
        parts = {},
      }
      ctx.render_state:set_message(message, 1, 1)
      table.insert(state.messages, message)

      local part = {
        id = 'part_456',
        messageID = 'msg_abc',
        sessionID = 'session_123',
        callID = 'call_xyz',
        type = 'tool_use',
        state = {
          input = {
            description = 'Some command',
          },
        },
      }

      events.on_part_updated({ part = part })

      assert.are.equal(0, #captured_calls)
    end)

    it('matches correct permission when multiple pending permissions exist', function()
      state.renderer.set_pending_permissions({
        {
          id = 'per_first',
          permission = 'bash',
          tool = {
            messageID = 'msg_first',
            callID = 'call_first',
          },
        },
        {
          id = 'per_second',
          permission = 'bash',
          tool = {
            messageID = 'msg_second',
            callID = 'call_second',
          },
        },
        {
          id = 'per_third',
          permission = 'bash',
          tool = {
            messageID = 'msg_third',
            callID = 'call_third',
          },
        },
      })

      local message = {
        info = { id = 'msg_second', sessionID = 'session_123' },
        parts = {},
      }
      ctx.render_state:set_message(message, 1, 1)
      table.insert(state.messages, message)

      local part = {
        id = 'part_789',
        messageID = 'msg_second',
        sessionID = 'session_123',
        callID = 'call_second',
        type = 'tool_use',
        state = {
          input = {
            description = 'Second command',
          },
        },
      }

      events.on_part_updated({ part = part })

      assert.are.equal(1, #captured_calls)
      assert.are.equal('per_second', captured_calls[1].permission_id)
    end)

    it('breaks after first match to avoid duplicate updates', function()
      state.renderer.set_pending_permissions({
        {
          id = 'per_first',
          permission = 'bash',
          tool = {
            messageID = 'msg_abc',
            callID = 'call_xyz',
          },
        },
        {
          id = 'per_second',
          permission = 'bash',
          tool = {
            messageID = 'msg_abc',
            callID = 'call_xyz',
          },
        },
      })

      local message = {
        info = { id = 'msg_abc', sessionID = 'session_123' },
        parts = {},
      }
      ctx.render_state:set_message(message, 1, 1)
      table.insert(state.messages, message)

      local part = {
        id = 'part_456',
        messageID = 'msg_abc',
        sessionID = 'session_123',
        callID = 'call_xyz',
        type = 'tool_use',
        state = {
          input = {
            description = 'Shared command',
          },
        },
      }

      events.on_part_updated({ part = part })

      assert.are.equal(1, #captured_calls)
      assert.are.equal('per_first', captured_calls[1].permission_id)
    end)

    it('prefers tool.callID over root callID when both present', function()
      state.renderer.set_pending_permissions({
        {
          id = 'per_test_123',
          permission = 'bash',
          callID = 'root_call_id',
          messageID = 'root_msg_id',
          tool = {
            messageID = 'tool_msg_id',
            callID = 'tool_call_id',
          },
        },
      })

      local message = {
        info = { id = 'tool_msg_id', sessionID = 'session_123' },
        parts = {},
      }
      ctx.render_state:set_message(message, 1, 1)
      table.insert(state.messages, message)

      local part = {
        id = 'part_456',
        messageID = 'tool_msg_id',
        sessionID = 'session_123',
        callID = 'tool_call_id',
        type = 'tool_use',
        state = {
          input = {
            description = 'Tool level match',
          },
        },
      }

      events.on_part_updated({ part = part })

      assert.are.equal(1, #captured_calls)
      assert.are.equal('per_test_123', captured_calls[1].permission_id)

      captured_calls = {}

      local part_root = {
        id = 'part_789',
        messageID = 'root_msg_id',
        sessionID = 'session_123',
        callID = 'root_call_id',
        type = 'tool_use',
        state = {
          input = {
            description = 'Root level no match',
          },
        },
      }

      events.on_part_updated({ part = part_root })

      assert.are.equal(0, #captured_calls)
    end)
  end)
end)

describe('permission and question display ordering', function()
  before_each(function()
    helpers.replay_setup()
    state.session.set_active({ id = 'session_123' })
  end)

  after_each(function()
    if state.windows then
      require('opencode.ui.ui').close_windows(state.windows)
    end
  end)

  it('keeps the permission display pinned below later messages', function()
    events.on_message_updated({
      info = {
        id = 'msg_user',
        sessionID = 'session_123',
        role = 'user',
      },
    })
    events.on_part_updated({
      part = {
        id = 'part_user',
        messageID = 'msg_user',
        sessionID = 'session_123',
        type = 'text',
        text = 'first',
      },
    })

    events.on_permission_updated({
      id = 'perm_1',
      permission = 'bash',
      title = 'Run command',
      metadata = {},
    })

    events.on_message_updated({
      info = {
        id = 'msg_assistant',
        sessionID = 'session_123',
        role = 'assistant',
      },
    })
    events.on_part_updated({
      part = {
        id = 'part_assistant',
        messageID = 'msg_assistant',
        sessionID = 'session_123',
        type = 'text',
        text = 'later message',
      },
    })

    flush.flush()

    local actual = helpers.capture_output(state.windows.output_buf, output_window.namespace)
    local permission_line = nil
    local assistant_line = nil
    for i, line in ipairs(actual.lines) do
      if line:find('Permission Required', 1, true) then
        permission_line = i
      elseif line == 'later message' then
        assistant_line = i
      end
    end

    assert.is_not_nil(permission_line)
    assert.is_not_nil(assistant_line)
    assert.is_true(permission_line > assistant_line)
  end)
end)

describe('permission prompt rendering', function()
  before_each(function()
    state.renderer.set_messages({})
    state.renderer.set_pending_permissions({})
    state.session.set_active({ id = 'session_123' })

    permission_window._permission_queue = {}
    permission_window._dialog = nil
    permission_window._processing = false

    ctx.render_state:reset()
    ctx.prev_line_count = 0
  end)

  it('tracks and renders permissions without message correlation metadata', function()
    events.on_permission_updated({
      id = 'perm_no_meta',
      permission = 'bash',
      title = 'Run command',
      metadata = {},
    })

    assert.are.equal(1, #state.pending_permissions)
    assert.are.equal('perm_no_meta', state.pending_permissions[1].id)
    assert.are.equal(1, permission_window.get_permission_count())
  end)
end)
