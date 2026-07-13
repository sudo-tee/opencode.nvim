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
