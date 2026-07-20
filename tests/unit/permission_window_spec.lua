local permission_window = require('opencode.ui.permission_window')
local Output = require('opencode.ui.output')
local stub = require('luassert.stub')

describe('permission_window', function()
  after_each(function()
    permission_window._permission_queue = {}
    permission_window._dialog = nil
    permission_window._processing = false
    permission_window._interaction = nil
  end)

  describe('format_display', function()
    local state = require('opencode.state')

    after_each(function()
      state.session.clear_active()
    end)

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
      assert.are.equal(7, #captured_opts.content)
      assert.is_true(captured_opts.content[1]:find('*bash*', 1, true) ~= nil)
      assert.are.equal('```bash', captured_opts.content[2])
      assert.are.equal("python3 - <<'PY'", captured_opts.content[3])
      assert.are.equal("print('hello')", captured_opts.content[4])
      assert.are.equal('PY', captured_opts.content[5])
      assert.are.equal('```', captured_opts.content[6])
      assert.are.equal('', captured_opts.content[7])
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

    it('adds the existing session action for a child-session permission', function()
      local renderer_ctx = require('opencode.ui.renderer.ctx')
      local child_lookup = stub(renderer_ctx.render_state, 'get_task_part_by_child_session').returns('task-part')
      state.session.set_active({ id = 'ses_parent' })
      setup_mock_dialog()
      permission_window._permission_queue = {
        { id = 'per_child', sessionID = 'ses_child', permission = 'bash' },
      }

      local output = Output.new()
      permission_window.format_display(output)

      assert.are.same({
        text = '[S] Open this Session',
        type = 'navigate_session_tree',
        args = { 'ses_child' },
        key = 'S',
        display_line = 0,
        range = { from = 0, to = 0 },
      }, output.actions[1])
      child_lookup:revert()
    end)

    it('covers every line produced by the permission dialog', function()
      local Dialog = require('opencode.ui.dialog')
      local input_window = require('opencode.ui.input_window')
      local renderer_ctx = require('opencode.ui.renderer.ctx')
      local child_lookup = stub(renderer_ctx.render_state, 'get_task_part_by_child_session').returns('task-part')
      local hide = stub(input_window, '_hide')
      local show = stub(input_window, '_show')
      local buf = vim.api.nvim_create_buf(false, true)
      state.session.set_active({ id = 'ses_parent' })
      permission_window._dialog = Dialog.new({
        buffer = buf,
        on_select = function() end,
        get_option_count = function()
          return 3
        end,
        check_focused = function()
          return true
        end,
        keymaps = { dismiss = '' },
      })
      permission_window._dialog:setup()
      permission_window._permission_queue = {
        { id = 'per_child', sessionID = 'ses_child', permission = 'bash' },
      }

      local output = Output.new()
      permission_window.format_display(output)
      local action = output.actions[1]

      assert.are.equal(0, action.display_line)
      assert.are.same({ from = 0, to = output:get_line_count() - 1 }, action.range)
      permission_window._dialog:teardown()
      vim.api.nvim_buf_delete(buf, { force = true })
      child_lookup:revert()
      hide:revert()
      show:revert()
    end)

    it('does not add a session action for the active-session permission', function()
      local renderer_ctx = require('opencode.ui.renderer.ctx')
      local child_lookup = stub(renderer_ctx.render_state, 'get_task_part_by_child_session').returns('task-part')
      state.session.set_active({ id = 'ses_main' })
      setup_mock_dialog()
      permission_window._permission_queue = {
        { id = 'per_main', sessionID = 'ses_main', permission = 'bash' },
      }

      local output = Output.new()
      permission_window.format_display(output)

      assert.are.equal(0, #output.actions)
      child_lookup:revert()
    end)

    it('does not add a session action without a matching child task', function()
      local renderer_ctx = require('opencode.ui.renderer.ctx')
      local child_lookup = stub(renderer_ctx.render_state, 'get_task_part_by_child_session').returns(nil)
      state.session.set_active({ id = 'ses_parent' })
      setup_mock_dialog()
      permission_window._permission_queue = {
        { id = 'per_other', sessionID = 'ses_other', permission = 'bash' },
      }

      local output = Output.new()
      permission_window.format_display(output)

      assert.are.equal(0, #output.actions)
      child_lookup:revert()
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

  describe('restore_pending_permissions', function()
    local Promise = require('opencode.promise')
    local state = require('opencode.state')
    local events = require('opencode.ui.renderer.events')

    after_each(function()
      state.jobs.set_api_client(nil)
      state.renderer.set_messages({})
    end)

    it('skips permissions whose tool part has completed status', function()
      state.jobs.set_api_client({
        list_permissions = function()
          return Promise.new():resolve({
            {
              id = 'perm_resolved',
              sessionID = 'sess1',
              tool = { messageID = 'msg_1', callID = 'call_1' },
            },
          })
        end,
      })
      state.renderer.set_messages({
        {
          info = { id = 'msg_1' },
          parts = {
            { callID = 'call_1', state = { status = 'completed' } },
          },
        },
      })

      local on_permission_stub = stub(events, 'on_permission_updated')

      permission_window.restore_pending_permissions('sess1'):wait()

      assert.stub(on_permission_stub).was_not_called()
      on_permission_stub:revert()
    end)

    it('skips permissions whose tool part has error status', function()
      state.jobs.set_api_client({
        list_permissions = function()
          return Promise.new():resolve({
            {
              id = 'perm_error',
              sessionID = 'sess1',
              tool = { messageID = 'msg_1', callID = 'call_1' },
            },
          })
        end,
      })
      state.renderer.set_messages({
        {
          info = { id = 'msg_1' },
          parts = {
            { callID = 'call_1', state = { status = 'error' } },
          },
        },
      })

      local on_permission_stub = stub(events, 'on_permission_updated')

      permission_window.restore_pending_permissions('sess1'):wait()

      assert.stub(on_permission_stub).was_not_called()
      on_permission_stub:revert()
    end)

    it('restores permissions whose tool part is still pending', function()
      state.jobs.set_api_client({
        list_permissions = function()
          return Promise.new():resolve({
            {
              id = 'perm_pending',
              sessionID = 'sess1',
              tool = { messageID = 'msg_1', callID = 'call_1' },
            },
          })
        end,
      })
      state.renderer.set_messages({
        {
          info = { id = 'msg_1' },
          parts = {
            { callID = 'call_1', state = { status = 'pending' } },
          },
        },
      })

      local on_permission_stub = stub(events, 'on_permission_updated')

      permission_window.restore_pending_permissions('sess1'):wait()

      assert.stub(on_permission_stub).was_called(1)
      on_permission_stub:revert()
    end)

    it('restores permissions whose tool part is running', function()
      state.jobs.set_api_client({
        list_permissions = function()
          return Promise.new():resolve({
            {
              id = 'perm_running',
              sessionID = 'sess1',
              tool = { messageID = 'msg_1', callID = 'call_1' },
            },
          })
        end,
      })
      state.renderer.set_messages({
        {
          info = { id = 'msg_1' },
          parts = {
            { callID = 'call_1', state = { status = 'running' } },
          },
        },
      })

      local on_permission_stub = stub(events, 'on_permission_updated')

      permission_window.restore_pending_permissions('sess1'):wait()

      assert.stub(on_permission_stub).was_called(1)
      on_permission_stub:revert()
    end)

    it('restores permissions when no matching message part is found', function()
      state.jobs.set_api_client({
        list_permissions = function()
          return Promise.new():resolve({
            {
              id = 'perm_no_part',
              sessionID = 'sess1',
              tool = { messageID = 'msg_unknown', callID = 'call_unknown' },
            },
          })
        end,
      })
      state.renderer.set_messages({})

      local on_permission_stub = stub(events, 'on_permission_updated')

      permission_window.restore_pending_permissions('sess1'):wait()

      assert.stub(on_permission_stub).was_called(1)
      on_permission_stub:revert()
    end)

    it('restores permissions without tool identifiers', function()
      state.jobs.set_api_client({
        list_permissions = function()
          return Promise.new():resolve({
            {
              id = 'perm_no_tool',
              sessionID = 'sess1',
            },
          })
        end,
      })
      state.renderer.set_messages({})

      local on_permission_stub = stub(events, 'on_permission_updated')

      permission_window.restore_pending_permissions('sess1'):wait()

      assert.stub(on_permission_stub).was_called(1)
      on_permission_stub:revert()
    end)

    it('handles mix of resolved and pending permissions', function()
      state.jobs.set_api_client({
        list_permissions = function()
          return Promise.new():resolve({
            {
              id = 'perm_done',
              sessionID = 'sess1',
              tool = { messageID = 'msg_1', callID = 'call_1' },
            },
            {
              id = 'perm_active',
              sessionID = 'sess1',
              tool = { messageID = 'msg_2', callID = 'call_2' },
            },
          })
        end,
      })
      state.renderer.set_messages({
        {
          info = { id = 'msg_1' },
          parts = {
            { callID = 'call_1', state = { status = 'completed' } },
          },
        },
        {
          info = { id = 'msg_2' },
          parts = {
            { callID = 'call_2', state = { status = 'pending' } },
          },
        },
      })

      local on_permission_stub = stub(events, 'on_permission_updated')

      permission_window.restore_pending_permissions('sess1'):wait()

      assert.stub(on_permission_stub).was_called(1)
      assert.stub(on_permission_stub).was_called_with({
        id = 'perm_active',
        sessionID = 'sess1',
        tool = { messageID = 'msg_2', callID = 'call_2' },
      })
      on_permission_stub:revert()
    end)

    it('uses root-level callID/messageID when tool field is absent', function()
      state.jobs.set_api_client({
        list_permissions = function()
          return Promise.new():resolve({
            {
              id = 'perm_root_ids',
              sessionID = 'sess1',
              messageID = 'msg_1',
              callID = 'call_1',
            },
          })
        end,
      })
      state.renderer.set_messages({
        {
          info = { id = 'msg_1' },
          parts = {
            { callID = 'call_1', state = { status = 'completed' } },
          },
        },
      })

      local on_permission_stub = stub(events, 'on_permission_updated')

      permission_window.restore_pending_permissions('sess1'):wait()

      assert.stub(on_permission_stub).was_not_called()
      on_permission_stub:revert()
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

  describe('interaction lifecycle', function()
    local state = require('opencode.state')
    local ui = require('opencode.ui.ui')
    local input_window = require('opencode.ui.input_window')
    local original_windows
    local original_schedule
    local original_defer_fn
    local output_buf
    local output_win

    before_each(function()
      original_windows = state.windows
      original_schedule = vim.schedule
      original_defer_fn = vim.defer_fn
      output_buf = vim.api.nvim_create_buf(false, true)
      output_win = vim.api.nvim_open_win(output_buf, true, {
        relative = 'editor',
        row = 0,
        col = 0,
        width = 40,
        height = 10,
        style = 'minimal',
      })
      state.ui.set_windows({ output_buf = output_buf, output_win = output_win })
      stub(ui, 'is_opencode_focused').returns(true)
      stub(input_window, '_hide')
      stub(input_window, '_show')
    end)

    after_each(function()
      permission_window.clear_all()
      state.ui.set_windows(original_windows)
      vim.schedule = original_schedule
      vim.defer_fn = original_defer_fn
      if ui.is_opencode_focused.revert then
        ui.is_opencode_focused:revert()
      end
      if input_window._hide.revert then
        input_window._hide:revert()
      end
      if input_window._show.revert then
        input_window._show:revert()
      end
      if vim.api.nvim_win_is_valid(output_win) then
        vim.api.nvim_win_close(output_win, true)
      end
      if vim.api.nvim_buf_is_valid(output_buf) then
        vim.api.nvim_buf_delete(output_buf, { force = true })
      end
    end)

    it('responds once when the same choice is triggered repeatedly', function()
      local api = require('opencode.api')
      local accept = stub(api, 'permission_accept')
      local scheduled = {}
      vim.schedule = function(callback)
        table.insert(scheduled, callback)
      end

      permission_window.add_permission({ id = 'per_once', permission = 'bash' })
      local dialog = permission_window._dialog
      dialog:select()
      dialog:select()

      for _, callback in ipairs(scheduled) do
        callback()
      end

      assert.stub(accept).was_called(1)
      accept:revert()
    end)

    it('keeps a permission pending when feedback input is cancelled', function()
      local api = require('opencode.api')
      local inline_input = require('opencode.ui.inline_input')
      local deny = stub(api, 'permission_deny')
      local cancel
      local open = stub(inline_input, 'open').invokes(function(opts)
        cancel = opts.on_cancel
        return { close = function() end }
      end)

      vim.schedule = function(fn)
        fn()
      end
      permission_window.add_permission({ id = 'per_cancelled_feedback', permission = 'bash' })
      permission_window._dialog:set_selection(2)
      permission_window._dialog:select()
      cancel()

      assert.stub(deny).was_not_called()
      assert.are.equal('per_cancelled_feedback', permission_window.get_current_permission().id)
      open:revert()
      deny:revert()
    end)

    it('closes feedback and rejects its stale submit callback when permission disappears', function()
      local api = require('opencode.api')
      local inline_input = require('opencode.ui.inline_input')
      local renderer_ctx = require('opencode.ui.renderer.ctx')
      local deny = stub(api, 'permission_deny')
      local submit
      local closed = 0
      local open = stub(inline_input, 'open').invokes(function(opts)
        submit = opts.on_submit
        return {
          close = function()
            closed = closed + 1
          end,
        }
      end)
      local part = stub(renderer_ctx.render_state, 'get_part').returns({ line_start = 0 })

      vim.schedule = function(fn)
        fn()
      end
      permission_window.add_permission({ id = 'per_inline', permission = 'bash' })
      permission_window.format_display(Output.new())
      permission_window._dialog:set_selection(2)
      permission_window._dialog:select()
      permission_window.remove_permission('per_inline')
      submit('use a safer command')

      assert.are.equal(1, closed)
      assert.stub(deny).was_not_called()
      part:revert()
      open:revert()
      deny:revert()
    end)

    it('stops the old double-escape timer before showing the next permission', function()
      local timer_callback
      local stopped = 0
      vim.defer_fn = function(callback)
        timer_callback = callback
        return {
          stop = function()
            stopped = stopped + 1
          end,
          close = function() end,
        }
      end

      permission_window.add_permission({ id = 'per_first', permission = 'bash' })
      permission_window._dialog:dismiss()
      permission_window.add_permission({ id = 'per_second', permission = 'bash' })
      permission_window.remove_permission('per_first')
      timer_callback()

      assert.are.equal(1, stopped)
      assert.are.equal('per_second', permission_window._interaction.permission_id)
      assert.is_false(permission_window._interaction.deny_armed)
    end)

    it('ignores an expired timer callback after feedback starts', function()
      local inline_input = require('opencode.ui.inline_input')
      local renderer_events = require('opencode.ui.renderer.events')
      local timer_callback
      local timer
      local render_count = 0
      local renders = stub(renderer_events, 'render_permissions_display').invokes(function()
        render_count = render_count + 1
      end)
      local open = stub(inline_input, 'open').returns({ close = function() end })
      vim.defer_fn = function(callback)
        timer_callback = callback
        timer = {
          stop = function() end,
          close = function() end,
        }
        return timer
      end
      vim.schedule = function(fn)
        fn()
      end

      permission_window.add_permission({ id = 'per_timer_feedback', permission = 'bash' })
      permission_window._dialog:dismiss()
      permission_window._dialog:set_selection(2)
      permission_window._dialog:select()
      local renders_before_stale_callback = render_count
      timer_callback()

      assert.are.equal(renders_before_stale_callback, render_count)
      assert.is_nil(permission_window._interaction.timer)
      local output = Output.new()
      permission_window.format_display(output)
      assert.is_true(output:get_line_count() > 0)
      open:revert()
      renders:revert()
    end)

    it('rejects the current permission once on the second escape', function()
      local api = require('opencode.api')
      local deny = stub(api, 'permission_deny')
      vim.defer_fn = function()
        return {
          stop = function() end,
          close = function() end,
        }
      end

      permission_window.add_permission({ id = 'per_double_escape', permission = 'bash' })
      permission_window._dialog:dismiss()
      permission_window._dialog:dismiss()

      assert.stub(deny).was_called(1)
      assert.is_nil(permission_window.get_current_permission())
      deny:revert()
    end)

    it('removes the permission escape mapping with its dialog', function()
      permission_window.add_permission({ id = 'per_mapping', permission = 'bash' })
      assert.is_not_nil(vim.fn.maparg('<Esc>', 'n', false, true).callback)

      permission_window.clear_all()

      assert.is_nil(vim.fn.maparg('<Esc>', 'n', false, true).callback)
    end)
  end)
end)
