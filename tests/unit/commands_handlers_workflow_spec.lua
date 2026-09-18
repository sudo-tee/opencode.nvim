local assert = require('luassert')
local stub = require('luassert.stub')

describe('opencode.commands.handlers.workflow', function()
  local workflow

  before_each(function()
    package.loaded['opencode.commands.handlers.workflow'] = nil
    workflow = require('opencode.commands.handlers.workflow')
  end)

  after_each(function()
    package.loaded['opencode.commands.handlers.workflow'] = nil
  end)

  describe('submit_input_prompt', function()
    local state = require('opencode.state')
    local config = require('opencode.config')
    local input_window = require('opencode.ui.input_window')
    local Promise = require('opencode.promise')
    local original_windows, original_route, original_buf, original_auto_hide
    local buf, send_message, hide, hidden, get_key, get_commands, system, notify
    local slash_args

    before_each(function()
      original_windows = state.windows
      original_route = state.display_route
      original_buf = vim.api.nvim_get_current_buf()
      original_auto_hide = config.ui.input.auto_hide
      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      state.store.set_raw('windows', { input_buf = buf, input_win = vim.api.nvim_get_current_win() })
      state.store.set_raw('display_route', nil)
      config.ui.input.auto_hide = true
      send_message = stub(require('opencode.services.messaging'), 'send_message').returns(false)
      hide = stub(input_window, '_hide')
      hidden = stub(input_window, 'is_hidden').returns(false)
      get_key = stub(config, 'get_key_for_function').returns('/')
      slash_args = nil
      get_commands = stub(require('opencode.commands.slash'), 'get_commands').returns(Promise.new():resolve({
        {
          slash_cmd = '/test',
          fn = function(args)
            slash_args = args
          end,
        },
      }))
      system = stub(vim, 'system')
      notify = stub(vim, 'notify')
    end)

    after_each(function()
      send_message:revert()
      hide:revert()
      hidden:revert()
      get_key:revert()
      get_commands:revert()
      system:revert()
      notify:revert()
      config.ui.input.auto_hide = original_auto_hide
      state.store.set_raw('windows', original_windows)
      state.store.set_raw('display_route', original_route)
      vim.api.nvim_set_current_buf(original_buf)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    local function submit(lines)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      workflow.actions.submit_input_prompt():await()
      assert.same({ '' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end

    it('sends multiline input and retains auto-hide after requesting a send', function()
      submit({ 'hello', 'world' })
      assert.stub(send_message).was_called_with('hello\nworld')
      assert.stub(hide).was_called(1)
    end)

    it('clears empty input without sending or hiding', function()
      submit({ '' })
      assert.stub(send_message).was_not_called()
      assert.stub(hide).was_not_called()
    end)

    it('runs shell input without sending or hiding', function()
      system.invokes(function(cmd, opts, callback)
        assert.same({ vim.o.shell, '-c', 'echo test' }, cmd)
        assert.same({ text = true }, opts)
        assert.is_function(callback)
      end)
      submit({ '! echo test ' })
      assert.stub(system).was_called(1)
      assert.stub(send_message).was_not_called()
      assert.stub(hide).was_not_called()
    end)

    it('resolves slash input and passes its arguments without sending or hiding', function()
      submit({ '/test first second' })
      assert.same({ 'first', 'second' }, slash_args)
      assert.stub(send_message).was_not_called()
      assert.stub(hide).was_not_called()
    end)

    it('reports unknown slash input after clearing it', function()
      submit({ '/missing' })
      assert.stub(notify).was_called_with('Unknown command: missing', vim.log.levels.WARN)
      assert.stub(send_message).was_not_called()
      assert.stub(hide).was_not_called()
    end)
  end)

  describe('prev_prompt_history (<up>)', function()
    local get_lines
    local get_cursor
    local feedkeys
    local buf_line_count
    local get_key
    local prev_hist
    local history

    before_each(function()
      get_lines = stub(vim.api, 'nvim_buf_get_lines')
      get_cursor = stub(vim.api, 'nvim_win_get_cursor')
      feedkeys = stub(vim.api, 'nvim_feedkeys')
      buf_line_count = stub(vim.api, 'nvim_buf_line_count')

      local config = require('opencode.config')
      get_key = stub(config, 'get_key_for_function').returns('<up>')

      prev_hist = stub(workflow.actions, 'prev_history')

      history = require('opencode.history')
      history.index = nil
    end)

    after_each(function()
      get_lines:revert()
      get_cursor:revert()
      feedkeys:revert()
      buf_line_count:revert()
      get_key:revert()
      prev_hist:revert()
      history.index = nil
    end)

    it('passes <up> through when not at first line', function()
      get_cursor.returns({ 3, 0 })

      workflow.actions.prev_prompt_history()

      assert.stub(feedkeys).was_called()
      assert.stub(prev_hist).was_not_called()
    end)

    it('enters history when at first line with empty buffer', function()
      get_cursor.returns({ 1, 0 })
      get_lines.returns({ '' })

      workflow.actions.prev_prompt_history()

      assert.stub(prev_hist).was_called()
      assert.stub(feedkeys).was_not_called()
    end)

    it('stops at first line when user typed text (not browsing)', function()
      get_cursor.returns({ 1, 0 })
      get_lines.returns({ 'user typed something' })

      workflow.actions.prev_prompt_history()

      assert.stub(prev_hist).was_not_called()
      assert.stub(feedkeys).was_not_called()
    end)

    it('delegates to prev_history when key is not <up>', function()
      get_key:revert()
      local config = require('opencode.config')
      get_key = stub(config, 'get_key_for_function').returns('<C-p>')

      workflow.actions.prev_prompt_history()

      assert.stub(prev_hist).was_called()
    end)
  end)

  describe('next_prompt_history (<down>)', function()
    local get_lines
    local get_cursor
    local feedkeys
    local buf_line_count
    local get_key
    local next_hist
    local history

    before_each(function()
      get_lines = stub(vim.api, 'nvim_buf_get_lines')
      get_cursor = stub(vim.api, 'nvim_win_get_cursor')
      feedkeys = stub(vim.api, 'nvim_feedkeys')
      buf_line_count = stub(vim.api, 'nvim_buf_line_count')

      local config = require('opencode.config')
      get_key = stub(config, 'get_key_for_function').returns('<down>')

      next_hist = stub(workflow.actions, 'next_history')

      history = require('opencode.history')
      history.index = nil
    end)

    after_each(function()
      get_lines:revert()
      get_cursor:revert()
      feedkeys:revert()
      buf_line_count:revert()
      get_key:revert()
      next_hist:revert()
      history.index = nil
    end)

    it('passes <down> through when not at last line', function()
      get_cursor.returns({ 2, 0 })
      buf_line_count.returns(5)

      workflow.actions.next_prompt_history()

      assert.stub(feedkeys).was_called()
      assert.stub(next_hist).was_not_called()
    end)

    it('enters history when at last line with empty buffer', function()
      get_cursor.returns({ 3, 0 })
      buf_line_count.returns(3)
      get_lines.returns({ '' })

      workflow.actions.next_prompt_history()

      assert.stub(next_hist).was_called()
      assert.stub(feedkeys).was_not_called()
    end)

    it('stops at last line when user typed text (not browsing)', function()
      get_cursor.returns({ 5, 0 })
      buf_line_count.returns(5)
      get_lines.returns({ 'user text' })

      workflow.actions.next_prompt_history()

      assert.stub(next_hist).was_not_called()
      assert.stub(feedkeys).was_not_called()
    end)

    it('delegates to next_history when key is not <down>', function()
      get_key:revert()
      local config = require('opencode.config')
      get_key = stub(config, 'get_key_for_function').returns('<C-n>')

      workflow.actions.next_prompt_history()

      assert.stub(next_hist).was_called()
    end)
  end)

  describe('browsing history with content modification', function()
    local get_lines
    local get_cursor
    local feedkeys
    local buf_line_count
    local prev_hist
    local next_hist
    local history
    local read_stub

    before_each(function()
      get_lines = stub(vim.api, 'nvim_buf_get_lines')
      get_cursor = stub(vim.api, 'nvim_win_get_cursor')
      feedkeys = stub(vim.api, 'nvim_feedkeys')
      buf_line_count = stub(vim.api, 'nvim_buf_line_count')

      history = require('opencode.history')
      history.index = 1

      prev_hist = stub(workflow.actions, 'prev_history')
      next_hist = stub(workflow.actions, 'next_history')
    end)

    after_each(function()
      get_lines:revert()
      get_cursor:revert()
      feedkeys:revert()
      buf_line_count:revert()
      prev_hist:revert()
      next_hist:revert()
      if read_stub then read_stub:revert() end
      history.index = nil
    end)

    it('<up> continues cycling when content matches history entry', function()
      local config = require('opencode.config')
      local get_key = stub(config, 'get_key_for_function').returns('<up>')
      get_cursor.returns({ 1, 0 })
      get_lines.returns({ 'match entry' })
      read_stub = stub(history, 'read').returns({ 'match entry' })

      workflow.actions.prev_prompt_history()

      assert.stub(prev_hist).was_called()
      get_key:revert()
    end)

    it('<up> stops cycling when content differs from history entry', function()
      local config = require('opencode.config')
      local get_key = stub(config, 'get_key_for_function').returns('<up>')
      get_cursor.returns({ 1, 0 })
      get_lines.returns({ 'modified entry' })
      read_stub = stub(history, 'read').returns({ 'original entry' })

      workflow.actions.prev_prompt_history()

      assert.stub(prev_hist).was_not_called()
      get_key:revert()
    end)

    it('<down> continues cycling when content matches history entry', function()
      local config = require('opencode.config')
      local get_key = stub(config, 'get_key_for_function').returns('<down>')
      get_cursor.returns({ 1, 0 })
      buf_line_count.returns(1)
      get_lines.returns({ 'match entry' })
      read_stub = stub(history, 'read').returns({ 'match entry' })

      workflow.actions.next_prompt_history()

      assert.stub(next_hist).was_called()
      get_key:revert()
    end)

    it('<down> stops cycling when content differs from history entry', function()
      local config = require('opencode.config')
      local get_key = stub(config, 'get_key_for_function').returns('<down>')
      get_cursor.returns({ 1, 0 })
      buf_line_count.returns(1)
      get_lines.returns({ 'modified entry' })
      read_stub = stub(history, 'read').returns({ 'original entry' })

      workflow.actions.next_prompt_history()

      assert.stub(next_hist).was_not_called()
      get_key:revert()
    end)

    it('<up> matches multi-line content correctly against history entry', function()
      local config = require('opencode.config')
      local get_key = stub(config, 'get_key_for_function').returns('<up>')
      get_cursor.returns({ 1, 0 })
      get_lines.returns({ 'hello', 'world' })
      read_stub = stub(history, 'read').returns({ 'hello\nworld' })

      workflow.actions.prev_prompt_history()

      assert.stub(prev_hist).was_called()
      get_key:revert()
    end)

    it('<up> stops cycling when multi-line content differs', function()
      local config = require('opencode.config')
      local get_key = stub(config, 'get_key_for_function').returns('<up>')
      get_cursor.returns({ 1, 0 })
      get_lines.returns({ 'hello', 'world!' })
      read_stub = stub(history, 'read').returns({ 'hello\nworld' })

      workflow.actions.prev_prompt_history()

      assert.stub(prev_hist).was_not_called()
      get_key:revert()
    end)
  end)
end)
