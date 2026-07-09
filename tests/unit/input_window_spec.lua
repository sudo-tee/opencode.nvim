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

      state.ui.set_windows({
        input_buf = input_buf,
        input_win = input_win,
        output_buf = output_buf,
        output_win = output_win,
      })

      vim.api.nvim_buf_set_lines(state.windows.input_buf, 0, -1, false, { '!echo test' })

      input_window.handle_submit()

      assert.is_true(executed)

      vim.api.nvim_win_close(input_win, true)
      vim.api.nvim_win_close(output_win, true)
      vim.api.nvim_buf_delete(input_buf, { force = true })
      vim.api.nvim_buf_delete(output_buf, { force = true })
      state.ui.clear_windows()
    end)

    it('should display command output in output window', function()
      local output_lines = nil
      local output_window = require('opencode.ui.output_window')
      local original_set_lines = output_window.set_lines
      local original_clear = output_window.clear

      output_window.set_lines = function(lines)
        output_lines = lines
      end

      output_window.clear = function() end

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

      state.ui.set_windows({
        input_buf = input_buf,
        input_win = input_win,
        output_buf = output_buf,
        output_win = output_win,
      })

      vim.api.nvim_buf_set_lines(state.windows.input_buf, 0, -1, false, { '!echo "hello world"' })

      input_window.handle_submit()

      assert.is_not_nil(output_lines)
      assert.are.same('$ echo "hello world"', output_lines[1])
      assert.are.same('hello world', output_lines[2])

      output_window.set_lines = original_set_lines
      output_window.clear = original_clear
      vim.api.nvim_win_close(input_win, true)
      vim.api.nvim_win_close(output_win, true)
      vim.api.nvim_buf_delete(input_buf, { force = true })
      vim.api.nvim_buf_delete(output_buf, { force = true })
      state.ui.clear_windows()
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

      state.ui.set_windows({
        input_buf = input_buf,
        input_win = input_win,
        output_buf = output_buf,
        output_win = output_win,
      })

      vim.api.nvim_buf_set_lines(state.windows.input_buf, 0, -1, false, { '!ls' })

      input_window.handle_submit()

      assert.is_true(prompt_shown)
      assert.are.equal('Add command + output to context?', prompt_text)

      vim.api.nvim_win_close(input_win, true)
      vim.api.nvim_win_close(output_win, true)
      vim.api.nvim_buf_delete(input_buf, { force = true })
      vim.api.nvim_buf_delete(output_buf, { force = true })
      state.ui.clear_windows()
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

      state.ui.set_windows({
        input_buf = input_buf,
        input_win = input_win,
        output_buf = output_buf,
        output_win = output_win,
      })

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
      state.ui.clear_windows()
    end)

    it('should clear output window when user selects No', function()
      vim.system = function(cmd, opts, callback)
        vim.schedule(function()
          callback({ code = 0, stdout = 'test output\n', stderr = '' })
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

      state.ui.set_windows({
        input_buf = input_buf,
        input_win = input_win,
        output_buf = output_buf,
        output_win = output_win,
      })

      vim.api.nvim_buf_set_lines(state.windows.input_buf, 0, -1, false, { '!echo test' })

      input_window.handle_submit()

      local output_lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
      assert.are.same({ '' }, output_lines)

      vim.api.nvim_win_close(input_win, true)
      vim.api.nvim_win_close(output_win, true)
      vim.api.nvim_buf_delete(input_buf, { force = true })
      vim.api.nvim_buf_delete(output_buf, { force = true })
      state.ui.clear_windows()
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

      state.ui.set_windows({
        input_buf = input_buf,
        input_win = input_win,
        output_buf = output_buf,
        output_win = output_win,
      })

      vim.api.nvim_buf_set_lines(state.windows.input_buf, 0, -1, false, { '!invalid_command' })

      input_window.handle_submit()

      assert.is_true(error_notified)

      vim.notify = original_notify
      vim.api.nvim_win_close(input_win, true)
      vim.api.nvim_win_close(output_win, true)
      vim.api.nvim_buf_delete(input_buf, { force = true })
      vim.api.nvim_buf_delete(output_buf, { force = true })
      state.ui.clear_windows()
    end)
  end)

  describe('auto-hide behavior', function()
    local input_buf, output_buf, input_win, output_win
    local original_config

    before_each(function()
      local config = require('opencode.config')
      original_config = vim.deepcopy(config.ui)

      input_buf = vim.api.nvim_create_buf(false, true)
      output_buf = vim.api.nvim_create_buf(false, true)
      input_win = vim.api.nvim_open_win(input_buf, true, {
        relative = 'editor',
        width = 80,
        height = 10,
        row = 0,
        col = 0,
      })
      output_win = vim.api.nvim_open_win(output_buf, false, {
        relative = 'editor',
        width = 80,
        height = 10,
        row = 11,
        col = 0,
      })

      state.ui.set_windows({
        input_buf = input_buf,
        input_win = input_win,
        output_buf = output_buf,
        output_win = output_win,
      })
      state.ui.set_input_content({ '' })
      state.ui.clear_display_route()

      config.ui.input.auto_hide = true
    end)

    after_each(function()
      local config = require('opencode.config')
      config.ui = original_config

      pcall(vim.api.nvim_win_close, input_win, true)
      pcall(vim.api.nvim_win_close, output_win, true)
      pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
      pcall(vim.api.nvim_buf_delete, output_buf, { force = true })
      state.ui.clear_windows()
      state.ui.set_input_content(nil)
      state.ui.clear_display_route()
      input_window._hidden = false
    end)

    it('should NOT auto-hide when output window is empty (new session)', function()
      vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { '' })

      local group = vim.api.nvim_create_augroup('test_input_window_autohide', { clear = true })
      input_window.setup_autocmds(state.windows, group)

      vim.api.nvim_exec_autocmds('WinLeave', {
        buffer = input_buf,
        modeline = false,
      })

      assert.is_false(input_window.is_hidden())
      assert.is_true(vim.api.nvim_win_is_valid(input_win))

      vim.api.nvim_del_augroup_by_id(group)
    end)

    it('should auto-hide when output window has content and input is empty', function()
      vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { 'User message', 'Assistant response' })

      local group = vim.api.nvim_create_augroup('test_input_window_autohide', { clear = true })
      input_window.setup_autocmds(state.windows, group)

      vim.api.nvim_exec_autocmds('WinLeave', {
        buffer = input_buf,
        modeline = false,
      })

      assert.is_true(input_window.is_hidden())

      vim.api.nvim_del_augroup_by_id(group)
    end)

    it('should NOT auto-hide when input has content', function()
      vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { 'User message', 'Assistant response' })
      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { 'user typing...' })
      state.ui.set_input_content({ 'user typing...' })

      local group = vim.api.nvim_create_augroup('test_input_window_autohide', { clear = true })
      input_window.setup_autocmds(state.windows, group)

      vim.api.nvim_exec_autocmds('WinLeave', {
        buffer = input_buf,
        modeline = false,
      })

      assert.is_false(input_window.is_hidden())
      assert.is_true(vim.api.nvim_win_is_valid(input_win))

      vim.api.nvim_del_augroup_by_id(group)
    end)

    it('should NOT auto-hide when display_route is active', function()
      vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { 'User message', 'Assistant response' })
      state.ui.set_display_route(true)

      local group = vim.api.nvim_create_augroup('test_input_window_autohide', { clear = true })
      input_window.setup_autocmds(state.windows, group)

      vim.api.nvim_exec_autocmds('WinLeave', {
        buffer = input_buf,
        modeline = false,
      })

      assert.is_false(input_window.is_hidden())
      assert.is_true(vim.api.nvim_win_is_valid(input_win))

      vim.api.nvim_del_augroup_by_id(group)
    end)
  end)

  describe('auto-show when hidden', function()
    local input_buf, output_buf, input_win, output_win

    before_each(function()
      input_buf = vim.api.nvim_create_buf(false, true)
      output_buf = vim.api.nvim_create_buf(false, true)
      input_win = vim.api.nvim_open_win(input_buf, true, {
        relative = 'editor',
        width = 80,
        height = 10,
        row = 0,
        col = 0,
      })
      output_win = vim.api.nvim_open_win(output_buf, false, {
        relative = 'editor',
        width = 80,
        height = 10,
        row = 11,
        col = 0,
      })

      state.ui.set_windows({
        input_buf = input_buf,
        input_win = input_win,
        output_buf = output_buf,
        output_win = output_win,
      })
    end)

    after_each(function()
      pcall(vim.api.nvim_win_close, input_win, true)
      pcall(vim.api.nvim_win_close, output_win, true)
      pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
      pcall(vim.api.nvim_buf_delete, output_buf, { force = true })
      state.ui.clear_windows()
      input_window._hidden = false
    end)

    it('should auto-show when set_content is called with non-empty content while hidden', function()
      input_window._hidden = true
      pcall(vim.api.nvim_win_close, input_win, true)
      state.windows.input_win = nil

      input_window.set_content('test content')

      assert.is_false(input_window._hidden)
    end)

    it('should not auto-show when set_content is called with empty content while hidden', function()
      input_window._hidden = true
      pcall(vim.api.nvim_win_close, input_win, true)
      state.windows.input_win = nil

      input_window.set_content('')

      assert.is_true(input_window._hidden)
    end)

    it('should auto-show when _append_to_input is called while hidden', function()
      input_window._hidden = true
      pcall(vim.api.nvim_win_close, input_win, true)
      state.windows.input_win = nil

      input_window._append_to_input('appended content')

      assert.is_false(input_window._hidden)
    end)
  end)

  describe('child session input visibility', function()
    after_each(function()
      state.session.clear_active()
    end)

    it('_show() is a no-op when active session is a child session', function()
      state.session.set_active({ id = 'child1', parentID = 'parent1' })
      input_window._hidden = true

      input_window._show()

      assert.is_true(input_window._hidden)
    end)

    it('_show() proceeds when active session is a root session', function()
      state.session.set_active({ id = 'root1' })
      input_window._hidden = true

      -- _show will early-return due to missing windows, but it should pass the guard
      input_window._show()

      -- _hidden remains true because windows are nil, but the parentID guard was passed
      assert.is_true(input_window._hidden)
    end)

    it('_show() proceeds for child session when child_readonly is false', function()
      state.session.set_active({ id = 'child1', parentID = 'parent1' })
      local config = require('opencode.config')
      local orig_readonly = config.values.child_readonly
      config.values.child_readonly = false
      input_window._hidden = true

      -- _show will early-return due to missing windows, but it should pass the guard
      input_window._show()

      -- _hidden remains true because windows are nil, but the parentID guard was passed
      assert.is_true(input_window._hidden)
      config.values.child_readonly = orig_readonly
    end)
  end)

  local function make_message(parts)
    return {
      info = { id = 'msg_1', sessionID = 'ses_1', role = 'user' },
      parts = parts,
    }
  end

  describe('build_prompt_from_message', function()
    it('returns nil when given a nil message', function()
      assert.is_nil(input_window.build_prompt_from_message(nil))
    end)

    it('returns nil when the message has no parts', function()
      assert.is_nil(input_window.build_prompt_from_message(make_message({})))
    end)

    it('emits the raw text from a single non-synthetic text part', function()
      local prompt = input_window.build_prompt_from_message(make_message({
        { type = 'text', text = 'hello world' },
      }))
      assert.same({ 'hello world' }, prompt.lines)
      assert.same({}, prompt.mention_paths)
    end)

    it('skips synthetic text parts', function()
      local prompt = input_window.build_prompt_from_message(make_message({
        { type = 'text', synthetic = true, text = 'should be dropped' },
        { type = 'text', text = 'keep me' },
      }))
      assert.same({ 'keep me' }, prompt.lines)
    end)

    it('emits @<path> tokens for file parts using filename', function()
      local prompt = input_window.build_prompt_from_message(make_message({
        { type = 'text', text = 'look at' },
        { type = 'file', filename = 'lua/opencode/foo.lua' },
        { type = 'text', text = 'thanks' },
      }))
      assert.same({ 'look at', '@lua/opencode/foo.lua ', 'thanks' }, prompt.lines)
      assert.same({ 'lua/opencode/foo.lua' }, prompt.mention_paths)
    end)

    it('falls back to source.path when filename is missing', function()
      local prompt = input_window.build_prompt_from_message(make_message({
        { type = 'file', source = { path = 'src/main.lua' } },
      }))
      assert.same({ '@src/main.lua ' }, prompt.lines)
      assert.same({ 'src/main.lua' }, prompt.mention_paths)
    end)

    it('emits @<name> tokens for agent parts', function()
      local prompt = input_window.build_prompt_from_message(make_message({
        { type = 'text', text = 'use' },
        { type = 'agent', name = 'build' },
        { type = 'text', text = 'to compile' },
      }))
      assert.same({ 'use', '@build ', 'to compile' }, prompt.lines)
      assert.same({ 'build' }, prompt.mention_paths)
    end)

    it('skips tool, step-start, and patch parts', function()
      local prompt = input_window.build_prompt_from_message(make_message({
        { type = 'text', text = 'first' },
        { type = 'tool', text = 'should be dropped' },
        { type = 'step-start' },
        { type = 'patch', text = 'also dropped' },
        { type = 'text', text = 'last' },
      }))
      assert.same({ 'first', 'last' }, prompt.lines)
      assert.same({}, prompt.mention_paths)
    end)

    it('splits text parts on embedded newlines into separate lines', function()
      local prompt = input_window.build_prompt_from_message(make_message({
        { type = 'text', text = 'line1\nline2' },
      }))
      assert.same({ 'line1', 'line2' }, prompt.lines)
    end)

    it('splits text parts on embedded newlines interleaved with mentions', function()
      local prompt = input_window.build_prompt_from_message(make_message({
        { type = 'text', text = 'before' },
        { type = 'file', filename = 'a.lua' },
        { type = 'text', text = 'middle\nmore' },
        { type = 'agent', name = 'build' },
        { type = 'text', text = 'after' },
      }))
      assert.same({
        'before',
        '@a.lua ',
        'middle',
        'more',
        '@build ',
        'after',
      }, prompt.lines)
      assert.same({ 'a.lua', 'build' }, prompt.mention_paths)
    end)

    it('handles nil and non-string fields defensively', function()
      local prompt = input_window.build_prompt_from_message(make_message({
        { type = 'text', text = nil },
        { type = 'text' },
        { type = 'text', text = 'safe' },
        { type = 'file', filename = nil },
        { type = 'agent', name = '' },
      }))
      assert.same({ 'safe' }, prompt.lines)
      assert.same({}, prompt.mention_paths)
    end)
  end)

  describe('refill_prompt_from_message', function()
    local function open_input_window()
      local input_buf = vim.api.nvim_create_buf(false, true)
      local output_buf = vim.api.nvim_create_buf(false, true)
      local output_win = vim.api.nvim_open_win(output_buf, false, {
        relative = 'editor',
        width = 80,
        height = 5,
        row = 0,
        col = 0,
      })
      local input_win = vim.api.nvim_open_win(input_buf, true, {
        relative = 'editor',
        width = 80,
        height = 5,
        row = 6,
        col = 0,
      })
      state.ui.set_windows({
        input_buf = input_buf,
        input_win = input_win,
        output_buf = output_buf,
        output_win = output_win,
      })
      vim.api.nvim_set_current_win(output_win)
      input_window._hidden = false
      return input_buf, input_win, output_buf, output_win
    end

    local function cleanup(input_buf, input_win, output_buf, output_win)
      pcall(vim.api.nvim_win_close, input_win, true)
      pcall(vim.api.nvim_win_close, output_win, true)
      pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
      pcall(vim.api.nvim_buf_delete, output_buf, { force = true })
      state.ui.clear_windows()
    end

    it('parks the cursor at the end of the refilled text', function()
      local input_buf, input_win, output_buf, output_win = open_input_window()
      local message = make_message({
        { type = 'text', text = 'refactor this' },
      })
      input_window.refill_prompt_from_message(message)
      local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
      local cursor = vim.api.nvim_win_get_cursor(input_win)
      assert.equals(#lines, cursor[1])
      assert.equals(#lines[#lines] - 1, cursor[2])
      assert.same({ 'refactor this' }, lines)
      cleanup(input_buf, input_win, output_buf, output_win)
    end)

    it('parks the cursor on the last line of a multi-line refill', function()
      local input_buf, input_win, output_buf, output_win = open_input_window()
      local message = make_message({
        { type = 'text', text = 'line1' },
        { type = 'text', text = 'line2' },
        { type = 'text', text = 'line3' },
      })
      input_window.refill_prompt_from_message(message)
      local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
      local cursor = vim.api.nvim_win_get_cursor(input_win)
      assert.equals(#lines, cursor[1])
      assert.equals(#lines[#lines] - 1, cursor[2])
      assert.same({ 'line1', 'line2', 'line3' }, lines)
      cleanup(input_buf, input_win, output_buf, output_win)
    end)

    it('parks the cursor after the mention token when a file is attached', function()
      local input_buf, input_win, output_buf, output_win = open_input_window()
      local message = make_message({
        { type = 'text', text = 'look at' },
        { type = 'file', filename = 'lua/opencode/foo.lua' },
        { type = 'text', text = 'thanks' },
      })
      input_window.refill_prompt_from_message(message)
      local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
      local cursor = vim.api.nvim_win_get_cursor(input_win)
      assert.equals(#lines, cursor[1])
      assert.equals(#lines[#lines] - 1, cursor[2])
      assert.equals('thanks', lines[#lines])
      cleanup(input_buf, input_win, output_buf, output_win)
    end)

    it('returns false and does not touch the buffer when there is nothing to refill', function()
      local input_buf, input_win, output_buf, output_win = open_input_window()
      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { 'untouched' })
      local filled = input_window.refill_prompt_from_message(make_message({}))
      assert.is_false(filled)
      assert.same({ 'untouched' }, vim.api.nvim_buf_get_lines(input_buf, 0, -1, false))
      cleanup(input_buf, input_win, output_buf, output_win)
    end)
  end)
end)
