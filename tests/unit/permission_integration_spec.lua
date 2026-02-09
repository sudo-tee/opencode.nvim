local renderer = require('opencode.ui.renderer')
local state = require('opencode.state')
local permission_window = require('opencode.ui.permission_window')

describe('permission_integration', function()
  local mock_update_permission_from_part
  local captured_calls

  before_each(function()
    state.messages = {}
    state.pending_permissions = {}
    state.active_session = { id = 'session_123' }

    permission_window._permission_queue = {}
    permission_window._dialog = nil
    permission_window._processing = false

    renderer._render_state:reset()
    renderer._prev_line_count = 0

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
      state.pending_permissions = {
        {
          id = 'per_test_123',
          permission = 'bash',
          tool = {
            messageID = 'msg_abc',
            callID = 'call_xyz',
          },
        },
      }

      local message = {
        info = { id = 'msg_abc', sessionID = 'session_123' },
        parts = {},
      }
      renderer._render_state:set_message(message, 1, 1)
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

      renderer.on_part_updated({ part = part })

      assert.are.equal(1, #captured_calls)
      assert.are.equal('per_test_123', captured_calls[1].permission_id)
      assert.are.equal(part, captured_calls[1].part)
    end)

    it('supports backward compatibility with root-level callID/messageID', function()
      state.pending_permissions = {
        {
          id = 'per_legacy_456',
          permission = 'bash',
          messageID = 'msg_legacy',
          callID = 'call_legacy',
        },
      }

      local message = {
        info = { id = 'msg_legacy', sessionID = 'session_123' },
        parts = {},
      }
      renderer._render_state:set_message(message, 1, 1)
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

      renderer.on_part_updated({ part = part })

      assert.are.equal(1, #captured_calls)
      assert.are.equal('per_legacy_456', captured_calls[1].permission_id)
    end)

    it('does not call update_permission_from_part when callID does not match', function()
      state.pending_permissions = {
        {
          id = 'per_test_123',
          permission = 'bash',
          tool = {
            messageID = 'msg_abc',
            callID = 'call_xyz',
          },
        },
      }

      local message = {
        info = { id = 'msg_abc', sessionID = 'session_123' },
        parts = {},
      }
      renderer._render_state:set_message(message, 1, 1)
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

      renderer.on_part_updated({ part = part })

      assert.are.equal(0, #captured_calls)
    end)

    it('does not call update_permission_from_part when messageID does not match', function()
      state.pending_permissions = {
        {
          id = 'per_test_123',
          permission = 'bash',
          tool = {
            messageID = 'msg_abc',
            callID = 'call_xyz',
          },
        },
      }

      local message = {
        info = { id = 'msg_different', sessionID = 'session_123' },
        parts = {},
      }
      renderer._render_state:set_message(message, 1, 1)
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

      renderer.on_part_updated({ part = part })

      assert.are.equal(0, #captured_calls)
    end)

    it('skips correlation when part has no callID', function()
      state.pending_permissions = {
        {
          id = 'per_test_123',
          permission = 'bash',
          tool = {
            messageID = 'msg_abc',
            callID = 'call_xyz',
          },
        },
      }

      local message = {
        info = { id = 'msg_abc', sessionID = 'session_123' },
        parts = {},
      }
      renderer._render_state:set_message(message, 1, 1)
      table.insert(state.messages, message)

      local part = {
        id = 'part_456',
        messageID = 'msg_abc',
        sessionID = 'session_123',
        type = 'text',
        content = 'Some text content',
      }

      renderer.on_part_updated({ part = part })

      assert.are.equal(0, #captured_calls)
    end)

    it('skips iteration when no pending permissions', function()
      state.pending_permissions = {}

      local message = {
        info = { id = 'msg_abc', sessionID = 'session_123' },
        parts = {},
      }
      renderer._render_state:set_message(message, 1, 1)
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

      renderer.on_part_updated({ part = part })

      assert.are.equal(0, #captured_calls)
    end)

    it('matches correct permission when multiple pending permissions exist', function()
      state.pending_permissions = {
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
      }

      local message = {
        info = { id = 'msg_second', sessionID = 'session_123' },
        parts = {},
      }
      renderer._render_state:set_message(message, 1, 1)
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

      renderer.on_part_updated({ part = part })

      assert.are.equal(1, #captured_calls)
      assert.are.equal('per_second', captured_calls[1].permission_id)
    end)

    it('breaks after first match to avoid duplicate updates', function()
      state.pending_permissions = {
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
      }

      local message = {
        info = { id = 'msg_abc', sessionID = 'session_123' },
        parts = {},
      }
      renderer._render_state:set_message(message, 1, 1)
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

      renderer.on_part_updated({ part = part })

      assert.are.equal(1, #captured_calls)
      assert.are.equal('per_first', captured_calls[1].permission_id)
    end)

    it('prefers tool.callID over root callID when both present', function()
      state.pending_permissions = {
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
      }

      local message = {
        info = { id = 'tool_msg_id', sessionID = 'session_123' },
        parts = {},
      }
      renderer._render_state:set_message(message, 1, 1)
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

      renderer.on_part_updated({ part = part })

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

      renderer.on_part_updated({ part = part_root })

      assert.are.equal(0, #captured_calls)
    end)
  end)
end)
