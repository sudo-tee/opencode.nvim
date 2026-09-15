local permission_window = require('opencode.ui.permission_window')
local Output = require('opencode.ui.output')
local Promise = require('opencode.promise')
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

    it('displays the frozen request message when available', function()
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
          patterns = { 'some pattern' },
          message = 'Run Python script to analyze data',
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

    it('renders multiple resource patterns from the frozen request', function()
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

    it('adds the existing session action for a child-session permission', function()
      local renderer_ctx = require('opencode.ui.renderer.ctx')
      local child_lookup = stub(renderer_ctx.render_state, 'get_task_part_by_child_session').returns('task-part')
      state.session.set_active({ id = 'ses_parent' })
      setup_mock_dialog()
      permission_window._permission_queue = {
        { id = 'per_child', session_id = 'ses_child', permission = 'bash' },
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
        { id = 'per_child', session_id = 'ses_child', permission = 'bash' },
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
        { id = 'per_main', session_id = 'ses_main', permission = 'bash' },
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
        { id = 'per_other', session_id = 'ses_other', permission = 'bash' },
      }

      local output = Output.new()
      permission_window.format_display(output)

      assert.are.equal(0, #output.actions)
      child_lookup:revert()
    end)
  end)

  it('routes each observed permission reply to its owning Observation', function()
    local replies = {}
    local function observed(session_id, request_id)
      return {
        read = function()
          return {
            permission_requests_by_id = {
              [request_id] = { id = request_id, session_id = session_id, status = 'pending', permission = 'bash' },
            },
          }
        end,
        reply_permission = function(_, id)
          replies[#replies + 1] = session_id .. ':' .. id
          return Promise.new():resolve(true)
        end,
      }
    end
    local first = observed('ses_a', 'per_a')
    local second = observed('ses_b', 'per_b')
    permission_window.sync({ first, second })

    permission_window.reply(permission_window.get_all_permissions()[2], 'once'):await()

    assert.are.same({ 'ses_b:per_b' }, replies)
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
    local replies

    before_each(function()
      original_windows = state.windows
      original_schedule = vim.schedule
      original_defer_fn = vim.defer_fn
      replies = {}
      local observation = {
        reply_permission = function(_, request_id, reply)
          replies[#replies + 1] = { request_id = request_id, reply = reply }
          return Promise.new():resolve(true)
        end,
      }
      permission_window._observations = setmetatable({}, {
        __index = function()
          return observation
        end,
      })
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
      local scheduled = {}
      vim.schedule = function(callback)
        table.insert(scheduled, callback)
      end

      permission_window.add_permission({ id = 'per_once', permission = 'bash', status = 'pending' })
      local dialog = permission_window._dialog
      dialog:select()
      dialog:select()

      for _, callback in ipairs(scheduled) do
        callback()
      end

      assert.are.same({ { request_id = 'per_once', reply = { choice = 'once' } } }, replies)
    end)

    it('keeps a permission pending when feedback input is cancelled', function()
      local inline_input = require('opencode.ui.inline_input')
      local cancel
      local open = stub(inline_input, 'open').invokes(function(opts)
        cancel = opts.on_cancel
        return { close = function() end }
      end)

      vim.schedule = function(fn)
        fn()
      end
      permission_window.add_permission({ id = 'per_cancelled_feedback', permission = 'bash', status = 'pending' })
      permission_window._dialog:set_selection(2)
      permission_window._dialog:select()
      cancel()

      assert.are.equal(0, #replies)
      assert.are.equal('per_cancelled_feedback', permission_window.get_current_permission().id)
      open:revert()
    end)

    it('closes feedback and rejects its stale submit callback when permission disappears', function()
      local inline_input = require('opencode.ui.inline_input')
      local renderer_ctx = require('opencode.ui.renderer.ctx')
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
      permission_window.add_permission({ id = 'per_inline', permission = 'bash', status = 'pending' })
      permission_window.format_display(Output.new())
      permission_window._dialog:set_selection(2)
      permission_window._dialog:select()
      permission_window.remove_permission('per_inline')
      submit('use a safer command')

      assert.are.equal(1, closed)
      assert.are.equal(0, #replies)
      part:revert()
      open:revert()
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
          is_closing = function()
            return false
          end,
          close = function() end,
        }
      end

      permission_window.add_permission({ id = 'per_first', permission = 'bash', status = 'pending' })
      permission_window._dialog:dismiss()
      permission_window.add_permission({ id = 'per_second', permission = 'bash', status = 'pending' })
      permission_window.remove_permission('per_first')
      timer_callback()

      assert.are.equal(1, stopped)
      assert.are.equal('per_second', permission_window._interaction.permission_id)
      assert.is_false(permission_window._interaction.deny_armed)
    end)

    it('ignores an expired timer callback after feedback starts', function()
      local inline_input = require('opencode.ui.inline_input')
      local renderer = require('opencode.ui.renderer')
      local timer_callback
      local timer
      local render_count = 0
      local renders = stub(renderer, 'refresh_prompts').invokes(function()
        render_count = render_count + 1
      end)
      local open = stub(inline_input, 'open').returns({ close = function() end })
      vim.defer_fn = function(callback)
        timer_callback = callback
        timer = {
          stop = function() end,
          is_closing = function()
            return false
          end,
          close = function() end,
        }
        return timer
      end
      vim.schedule = function(fn)
        fn()
      end

      permission_window.add_permission({ id = 'per_timer_feedback', permission = 'bash', status = 'pending' })
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
      vim.defer_fn = function()
        return {
          stop = function() end,
          is_closing = function()
            return false
          end,
          close = function() end,
        }
      end

      permission_window.add_permission({ id = 'per_double_escape', permission = 'bash', status = 'pending' })
      permission_window._dialog:dismiss()
      permission_window._dialog:dismiss()

      assert.are.same({ { request_id = 'per_double_escape', reply = { choice = 'reject' } } }, replies)
      vim.wait(100, function()
        return permission_window.get_current_permission() == nil
      end)
      assert.is_nil(permission_window.get_current_permission())
    end)

    it('removes the permission escape mapping with its dialog', function()
      permission_window.add_permission({ id = 'per_mapping', permission = 'bash', status = 'pending' })
      assert.is_not_nil(vim.fn.maparg('<Esc>', 'n', false, true).callback)

      permission_window.clear_all()

      assert.is_nil(vim.fn.maparg('<Esc>', 'n', false, true).callback)
    end)
  end)
end)
