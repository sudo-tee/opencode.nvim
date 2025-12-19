local input_window = require('opencode.ui.input_window')
local state = require('opencode.state')

describe('input_window', function()
  describe('shell command execution', function()
    local original_system
    local original_schedule
    local original_ui_select

    before_each(function()
      original_system = vim.system
      original_schedule = vim.schedule
      original_ui_select = vim.ui.select

      vim.schedule = function(fn)
        fn()
      end
    end)

    after_each(function()
      vim.system = original_system
      vim.schedule = original_schedule
      vim.ui.select = original_ui_select
    end)

    it('should detect shell commands starting with !', function()
      local executed = false
      vim.system = function(cmd, opts, callback)
        executed = true
        assert.are.same({ vim.o.shell, '-c', 'echo test' }, cmd)
        vim.schedule(function()
          callback({ code = 0, stdout = 'test\n', stderr = '' })
        end)
      end

      vim.ui.select = function(choices, opts, callback)
        callback('No')
      end

      local input_buf = vim.api.nvim_create_buf(false, true)
      local output_buf = vim.api.nvim_create_buf(false, true)
      local input_win = vim.api.nvim_open_win(input_buf, true, {
        relative = 'editor',
        width = 80,
        height = 10,
        row = 0,
        col = 0,
      })
      local output_win = vim.api.nvim_open_win(output_buf, false, {
        relative = 'editor',
        width = 80,
        height = 10,
        row = 11,
        col = 0,
      })

      state.windows = {
        input_buf = input_buf,
        input_win = input_win,
        output_buf = output_buf,
        output_win = output_win,
      }

      vim.api.nvim_buf_set_lines(state.windows.input_buf, 0, -1, false, { '!echo test' })

      input_window.handle_submit()

      assert.is_true(executed)

      vim.api.nvim_win_close(input_win, true)
      vim.api.nvim_win_close(output_win, true)
      vim.api.nvim_buf_delete(input_buf, { force = true })
      vim.api.nvim_buf_delete(output_buf, { force = true })
      state.windows = nil
    end)

    it('should display command output in output window', function()
      local output_lines = nil
      local output_window = require('opencode.ui.output_window')
      local original_set_lines = output_window.set_lines

      output_window.set_lines = function(lines)
        output_lines = lines
      end

      vim.system = function(cmd, opts, callback)
        vim.schedule(function()
          callback({ code = 0, stdout = 'hello world\n', stderr = '' })
        end)
      end

      vim.ui.select = function(choices, opts, callback)
        callback('No')
      end

      local input_buf = vim.api.nvim_create_buf(false, true)
      local output_buf = vim.api.nvim_create_buf(false, true)
      local input_win = vim.api.nvim_open_win(input_buf, true, {
        relative = 'editor',
        width = 80,
        height = 10,
        row = 0,
        col = 0,
      })
      local output_win = vim.api.nvim_open_win(output_buf, false, {
        relative = 'editor',
        width = 80,
        height = 10,
        row = 11,
        col = 0,
      })

      state.windows = {
        input_buf = input_buf,
        input_win = input_win,
        output_buf = output_buf,
        output_win = output_win,
      }

      vim.api.nvim_buf_set_lines(state.windows.input_buf, 0, -1, false, { '!echo "hello world"' })

      input_window.handle_submit()

      assert.is_not_nil(output_lines)
      assert.are.same('$ echo "hello world"', output_lines[1])
      assert.are.same('hello world', output_lines[2])

      output_window.set_lines = original_set_lines
      vim.api.nvim_win_close(input_win, true)
      vim.api.nvim_win_close(output_win, true)
      vim.api.nvim_buf_delete(input_buf, { force = true })
      vim.api.nvim_buf_delete(output_buf, { force = true })
      state.windows = nil
    end)

    it('should prompt user to add output to input', function()
      local prompt_shown = false
      local prompt_text = nil

      vim.system = function(cmd, opts, callback)
        vim.schedule(function()
          callback({ code = 0, stdout = 'output\n', stderr = '' })
        end)
      end

      vim.ui.select = function(choices, opts, callback)
        prompt_shown = true
        prompt_text = opts.prompt
        assert.are.same({ 'Yes', 'No' }, choices)
        callback('No')
      end

      local input_buf = vim.api.nvim_create_buf(false, true)
      local output_buf = vim.api.nvim_create_buf(false, true)
      local input_win = vim.api.nvim_open_win(input_buf, true, {
        relative = 'editor',
        width = 80,
        height = 10,
        row = 0,
        col = 0,
      })
      local output_win = vim.api.nvim_open_win(output_buf, false, {
        relative = 'editor',
        width = 80,
        height = 10,
        row = 11,
        col = 0,
      })

      state.windows = {
        input_buf = input_buf,
        input_win = input_win,
        output_buf = output_buf,
        output_win = output_win,
      }

      vim.api.nvim_buf_set_lines(state.windows.input_buf, 0, -1, false, { '!ls' })

      input_window.handle_submit()

      assert.is_true(prompt_shown)
      assert.are.equal('Add command + output to context?', prompt_text)

      vim.api.nvim_win_close(input_win, true)
      vim.api.nvim_win_close(output_win, true)
      vim.api.nvim_buf_delete(input_buf, { force = true })
      vim.api.nvim_buf_delete(output_buf, { force = true })
      state.windows = nil
    end)

    it('should append formatted output to input when user selects Yes', function()
      vim.system = function(cmd, opts, callback)
        vim.schedule(function()
          callback({ code = 0, stdout = 'test output\n', stderr = '' })
        end)
      end

      vim.ui.select = function(choices, opts, callback)
        callback('Yes')
      end

      local input_buf = vim.api.nvim_create_buf(false, true)
      local output_buf = vim.api.nvim_create_buf(false, true)
      local input_win = vim.api.nvim_open_win(input_buf, true, {
        relative = 'editor',
        width = 80,
        height = 10,
        row = 0,
        col = 0,
      })
      local output_win = vim.api.nvim_open_win(output_buf, false, {
        relative = 'editor',
        width = 80,
        height = 10,
        row = 11,
        col = 0,
      })

      state.windows = {
        input_buf = input_buf,
        input_win = input_win,
        output_buf = output_buf,
        output_win = output_win,
      }

      vim.api.nvim_buf_set_lines(state.windows.input_buf, 0, -1, false, { '!echo test' })

      input_window.handle_submit()

      local input_lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
      local input_text = table.concat(input_lines, '\n')

      assert.is_true(input_text:find('Command: `echo test`', 1, true) ~= nil)
      assert.is_true(input_text:find('Exit code: 0', 1, true) ~= nil)
      assert.is_true(input_text:find('Output:', 1, true) ~= nil)
      assert.is_true(input_text:find('```', 1, true) ~= nil)
      assert.is_true(input_text:find('test output', 1, true) ~= nil)

      local output_lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
      assert.are.same({ '' }, output_lines)

      vim.api.nvim_win_close(input_win, true)
      vim.api.nvim_win_close(output_win, true)
      vim.api.nvim_buf_delete(input_buf, { force = true })
      vim.api.nvim_buf_delete(output_buf, { force = true })
      state.windows = nil
    end)

    it('should handle command errors', function()
      local error_notified = false

      vim.system = function(cmd, opts, callback)
        vim.schedule(function()
          callback({ code = 1, stdout = '', stderr = 'command not found\n' })
        end)
      end

      vim.ui.select = function(choices, opts, callback)
        callback('No')
      end

      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if msg:match('failed with exit code') then
          error_notified = true
        end
      end

      local input_buf = vim.api.nvim_create_buf(false, true)
      local output_buf = vim.api.nvim_create_buf(false, true)
      local input_win = vim.api.nvim_open_win(input_buf, true, {
        relative = 'editor',
        width = 80,
        height = 10,
        row = 0,
        col = 0,
      })
      local output_win = vim.api.nvim_open_win(output_buf, false, {
        relative = 'editor',
        width = 80,
        height = 10,
        row = 11,
        col = 0,
      })

      state.windows = {
        input_buf = input_buf,
        input_win = input_win,
        output_buf = output_buf,
        output_win = output_win,
      }

      vim.api.nvim_buf_set_lines(state.windows.input_buf, 0, -1, false, { '!invalid_command' })

      input_window.handle_submit()

      assert.is_true(error_notified)

      vim.notify = original_notify
      vim.api.nvim_win_close(input_win, true)
      vim.api.nvim_win_close(output_win, true)
      vim.api.nvim_buf_delete(input_buf, { force = true })
      vim.api.nvim_buf_delete(output_buf, { force = true })
      state.windows = nil
    end)
  end)
end)
