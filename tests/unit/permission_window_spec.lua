local permission_window = require('opencode.ui.permission_window')
local Output = require('opencode.ui.output')

describe('permission_window', function()
  after_each(function()
    permission_window._permission_queue = {}
    permission_window._dialog = nil
    permission_window._processing = false
  end)

  describe('format_display', function()
    local function setup_mock_dialog()
      local captured_opts = nil
      permission_window._dialog = {
        format_dialog = function(_, _, opts)
          captured_opts = opts
        end,
      }
      return captured_opts
    end

    it('renders patterns in a fenced block when title and description are missing', function()
      local captured_opts = nil
      permission_window._dialog = {
        format_dialog = function(_, _, opts)
          captured_opts = opts
        end,
      }

      permission_window._permission_queue = {
        {
          id = 'per_test',
          permission = 'bash',
          patterns = {
            "python3 - <<'PY'\nprint('hello')\nPY",
          },
        },
      }

      local output = Output.new()
      permission_window.format_display(output)

      assert.is_not_nil(captured_opts)
      assert.is_not_nil(captured_opts.content)
      assert.are.equal(5, #captured_opts.content)
      assert.is_true(captured_opts.content[1]:find('*bash*', 1, true) ~= nil)
      assert.are.equal('```bash', captured_opts.content[2])
      assert.are.equal("python3 - <<'PY'\nprint('hello')\nPY", captured_opts.content[3])
      assert.are.equal('```', captured_opts.content[4])
      assert.are.equal('', captured_opts.content[5])
    end)

    it('displays description when available', function()
      local captured_opts = nil
      permission_window._dialog = {
        format_dialog = function(_, _, opts)
          captured_opts = opts
        end,
      }

      permission_window._permission_queue = {
        {
          id = 'per_test',
          permission = 'bash',
          title = 'Some Title',
          patterns = { 'some pattern' },
          _description = 'Run Python script to analyze data',
        },
      }

      local output = Output.new()
      permission_window.format_display(output)

      assert.is_not_nil(captured_opts)
      assert.is_not_nil(captured_opts.content)
      assert.are.equal(2, #captured_opts.content)
      assert.is_true(captured_opts.content[1]:find('Run Python script to analyze data', 1, true) ~= nil)
      assert.are.equal('', captured_opts.content[2])
    end)

    it('displays command on second line when available', function()
      local captured_opts = nil
      permission_window._dialog = {
        format_dialog = function(_, _, opts)
          captured_opts = opts
        end,
      }

      permission_window._permission_queue = {
        {
          id = 'per_test',
          permission = 'bash',
          title = 'Some Title',
          _command = 'python3 analyze.py --input data.csv',
        },
      }

      local output = Output.new()
      permission_window.format_display(output)

      assert.is_not_nil(captured_opts)
      assert.is_not_nil(captured_opts.content)
      assert.are.equal(5, #captured_opts.content)
      assert.is_true(captured_opts.content[1]:find('Some Title', 1, true) ~= nil)
      assert.are.equal('', captured_opts.content[2])
      assert.are.equal('```bash', captured_opts.content[3])
      assert.are.equal('python3 analyze.py --input data.csv', captured_opts.content[4])
      assert.are.equal('```', captured_opts.content[5])
    end)

    it('displays both description and command when available', function()
      local captured_opts = nil
      permission_window._dialog = {
        format_dialog = function(_, _, opts)
          captured_opts = opts
        end,
      }

      permission_window._permission_queue = {
        {
          id = 'per_test',
          permission = 'bash',
          _description = 'Run Python script to analyze data',
          _command = 'python3 analyze.py --input data.csv',
        },
      }

      local output = Output.new()
      permission_window.format_display(output)

      assert.is_not_nil(captured_opts)
      assert.is_not_nil(captured_opts.content)
      assert.are.equal(5, #captured_opts.content)
      assert.is_true(captured_opts.content[1]:find('Run Python script to analyze data', 1, true) ~= nil)
      assert.are.equal('', captured_opts.content[2])
      assert.are.equal('```bash', captured_opts.content[3])
      assert.are.equal('python3 analyze.py --input data.csv', captured_opts.content[4])
      assert.are.equal('```', captured_opts.content[5])
    end)

    it('falls back to title when description is not available', function()
      local captured_opts = nil
      permission_window._dialog = {
        format_dialog = function(_, _, opts)
          captured_opts = opts
        end,
      }

      permission_window._permission_queue = {
        {
          id = 'per_test',
          permission = 'bash',
          title = 'My Permission Title',
          patterns = { 'some pattern' },
        },
      }

      local output = Output.new()
      permission_window.format_display(output)

      assert.is_not_nil(captured_opts)
      assert.is_not_nil(captured_opts.content)
      assert.are.equal(2, #captured_opts.content)
      assert.is_true(captured_opts.content[1]:find('My Permission Title', 1, true) ~= nil)
      assert.are.equal('', captured_opts.content[2])
    end)

    it('falls back to patterns when neither description nor title available', function()
      local captured_opts = nil
      permission_window._dialog = {
        format_dialog = function(_, _, opts)
          captured_opts = opts
        end,
      }

      permission_window._permission_queue = {
        {
          id = 'per_test',
          permission = 'bash',
          patterns = { 'pattern1', 'pattern2' },
        },
      }

      local output = Output.new()
      permission_window.format_display(output)

      assert.is_not_nil(captured_opts)
      assert.is_not_nil(captured_opts.content)
      assert.are.equal(6, #captured_opts.content)
      assert.is_true(captured_opts.content[1]:find('*bash*', 1, true) ~= nil)
      assert.are.equal('```bash', captured_opts.content[2])
      assert.are.equal('pattern1', captured_opts.content[3])
      assert.are.equal('pattern2', captured_opts.content[4])
      assert.are.equal('```', captured_opts.content[5])
      assert.are.equal('', captured_opts.content[6])
    end)

    it('renders multiline commands as separate lines in fenced block', function()
      local captured_opts = nil
      permission_window._dialog = {
        format_dialog = function(_, _, opts)
          captured_opts = opts
        end,
      }

      permission_window._permission_queue = {
        {
          id = 'per_test',
          permission = 'bash',
          _command = "echo 'line1'\necho 'line2'",
        },
      }

      local output = Output.new()
      permission_window.format_display(output)

      assert.is_not_nil(captured_opts)
      assert.is_not_nil(captured_opts.content)
      assert.are.equal(8, #captured_opts.content)
      local command_start = #captured_opts.content - 3
      assert.are.equal('```bash', captured_opts.content[command_start])
      assert.are.equal("echo 'line1'", captured_opts.content[command_start + 1])
      assert.are.equal("echo 'line2'", captured_opts.content[command_start + 2])
      assert.are.equal('```', captured_opts.content[command_start + 3])
    end)
  end)

  describe('update_permission_from_part', function()
    it('updates permission with description and command from part', function()
      permission_window._permission_queue = {
        {
          id = 'per_test',
          permission = 'bash',
          title = 'Original Title',
        },
      }

      local part = {
        state = {
          input = {
            description = 'Execute Python script',
            command = 'python3 script.py',
          },
        },
      }

      local result = permission_window.update_permission_from_part('per_test', part)

      assert.is_true(result)
      assert.are.equal('Execute Python script', permission_window._permission_queue[1]._description)
      assert.are.equal('python3 script.py', permission_window._permission_queue[1]._command)
    end)

    it('returns true when permission found and updated', function()
      permission_window._permission_queue = {
        {
          id = 'per_test',
          permission = 'bash',
        },
      }

      local part = {
        state = {
          input = {
            description = 'Some description',
          },
        },
      }

      local result = permission_window.update_permission_from_part('per_test', part)
      assert.is_true(result)
    end)

    it('returns false when permission not found', function()
      permission_window._permission_queue = {
        {
          id = 'per_other',
          permission = 'bash',
        },
      }

      local part = {
        state = {
          input = {
            description = 'Some description',
          },
        },
      }

      local result = permission_window.update_permission_from_part('per_test', part)
      assert.is_false(result)
    end)

    it('returns false when part has no state.input', function()
      permission_window._permission_queue = {
        {
          id = 'per_test',
          permission = 'bash',
        },
      }

      local result = permission_window.update_permission_from_part('per_test', {})
      assert.is_false(result)
    end)

    it('returns true when permission found even with empty description/command', function()
      permission_window._permission_queue = {
        {
          id = 'per_test',
          permission = 'bash',
        },
      }

      local part = {
        state = {
          input = {
            other_field = 'value',
          },
        },
      }

      local result = permission_window.update_permission_from_part('per_test', part)
      assert.is_true(result)
      assert.is_nil(permission_window._permission_queue[1]._description)
      assert.is_nil(permission_window._permission_queue[1]._command)
    end)

    it('handles nil permission_id gracefully', function()
      local result = permission_window.update_permission_from_part(nil, { state = { input = {} } })
      assert.is_false(result)
    end)

    it('handles nil part gracefully', function()
      permission_window._permission_queue = {
        {
          id = 'per_test',
          permission = 'bash',
        },
      }

      local result = permission_window.update_permission_from_part('per_test', nil)
      assert.is_false(result)
    end)
  end)

  describe('add_permission correlation', function()
    it('stores messageID and callID from permission.tool', function()
      local permission = {
        id = 'per_test',
        permission = 'bash',
        tool = {
          messageID = 'msg_123',
          callID = 'call_456',
        },
      }

      permission_window.add_permission(permission)

      assert.are.equal('msg_123', permission_window._permission_queue[1]._message_id)
      assert.are.equal('call_456', permission_window._permission_queue[1]._call_id)
    end)

    it('handles permission without tool field', function()
      local permission = {
        id = 'per_test',
        permission = 'bash',
      }

      permission_window.add_permission(permission)

      assert.is_nil(permission_window._permission_queue[1]._message_id)
      assert.is_nil(permission_window._permission_queue[1]._call_id)
    end)

    it('handles permission.tool without messageID or callID', function()
      local permission = {
        id = 'per_test',
        permission = 'bash',
        tool = {
          name = 'some_tool',
        },
      }

      permission_window.add_permission(permission)

      assert.is_nil(permission_window._permission_queue[1]._message_id)
      assert.is_nil(permission_window._permission_queue[1]._call_id)
    end)
  end)
end)
