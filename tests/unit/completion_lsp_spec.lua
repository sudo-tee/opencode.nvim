local assert = require('luassert')
local Promise = require('opencode.promise')

describe('opencode LSP completion', function()
  local mock_config
  local mock_completion
  local mock_promise

  before_each(function()
    mock_config = {
      get_key_for_function = function(category, key)
        local keys = {
          input_window = {
            mention = '@',
            slash_commands = '/',
            context_items = '#',
          },
        }
        return keys[category] and keys[category][key]
      end,
      ui = {
        completion = {
          file_sources = {
            enabled = true,
            max_files = 10,
            ignore_patterns = {},
          },
        },
      },
    }

    package.loaded['opencode.config'] = mock_config
    package.loaded['blink.cmp'] = nil -- ensure blink.cmp is not loaded by default
  end)

  after_each(function()
    package.loaded['opencode.config'] = nil
    package.loaded['opencode.ui.completion'] = nil
    package.loaded['opencode.lsp.opencode_ls'] = nil
    package.loaded['blink.cmp'] = nil
  end)

  describe('completion module', function()
    local completion

    before_each(function()
      package.loaded['opencode.ui.completion'] = nil
      package.loaded['opencode.ui.completion.files'] = nil
      package.loaded['opencode.ui.completion.subagents'] = nil
      package.loaded['opencode.ui.completion.commands'] = nil
      package.loaded['opencode.ui.completion.context'] = nil
      completion = require('opencode.ui.completion')
    end)

    after_each(function()
      package.loaded['opencode.ui.completion'] = nil
    end)

    describe('register_source', function()
      it('registers a completion source', function()
        local source = {
          name = 'test_source',
          priority = 5,
          complete = function() end,
        }

        completion.register_source(source)

        local sources = completion.get_sources()
        local found = false
        for _, s in ipairs(sources) do
          if s.name == 'test_source' then
            found = true
            break
          end
        end
        assert.is_true(found)
      end)

      it('returns all registered sources', function()
        completion._sources = {}

        local source1 = { name = 'source1', priority = 1, complete = function() end }
        local source2 = { name = 'source2', priority = 2, complete = function() end }

        completion.register_source(source1)
        completion.register_source(source2)

        local sources = completion.get_sources()
        assert.are.equal(2, #sources)
      end)
    end)

    describe('get_source_by_name', function()
      it('returns the correct source by name', function()
        completion._sources = {}
        local source = { name = 'my_source', priority = 1, complete = function() end }
        completion.register_source(source)

        local found = completion.get_source_by_name('my_source')
        assert.is_not_nil(found)
        assert.are.equal('my_source', found.name)
      end)

      it('returns nil when source not found', function()
        completion._sources = {}
        local result = completion.get_source_by_name('nonexistent')
        assert.is_nil(result)
      end)
    end)

    describe('get_trigger_characters', function()
      it('returns trigger characters from all sources', function()
        completion._sources = {}
        completion.register_source({
          name = 'source1',
          priority = 1,
          complete = function() end,
          get_trigger_character = function()
            return '@'
          end,
        })
        completion.register_source({
          name = 'source2',
          priority = 1,
          complete = function() end,
          get_trigger_character = function()
            return '/'
          end,
        })

        local triggers = completion.get_trigger_characters()
        assert.are.equal(2, #triggers)
        assert.is_true(vim.tbl_contains(triggers, '@'))
        assert.is_true(vim.tbl_contains(triggers, '/'))
      end)

      it('skips sources without get_trigger_character', function()
        completion._sources = {}
        completion.register_source({
          name = 'source1',
          priority = 1,
          complete = function() end,
          -- no get_trigger_character
        })
        completion.register_source({
          name = 'source2',
          priority = 1,
          complete = function() end,
          get_trigger_character = function()
            return '#'
          end,
        })

        local triggers = completion.get_trigger_characters()
        assert.are.equal(1, #triggers)
        assert.are.equal('#', triggers[1])
      end)

      it('returns empty table when no sources have trigger characters', function()
        completion._sources = {}
        local triggers = completion.get_trigger_characters()
        assert.are.same({}, triggers)
      end)
    end)

    describe('on_completion_done', function()
      it('calls on_complete on the matching source', function()
        completion._sources = {}
        local on_complete_called = false
        local received_item = nil

        completion.register_source({
          name = 'test_source',
          priority = 1,
          complete = function() end,
          on_complete = function(item)
            on_complete_called = true
            received_item = item
          end,
        })

        local item = { source_name = 'test_source', label = 'test_item' }
        completion.on_completion_done(item)

        assert.is_true(on_complete_called)
        assert.are.equal(item, received_item)
      end)

      it('does nothing when source_name is missing', function()
        completion._sources = {}
        local on_complete_called = false

        completion.register_source({
          name = 'test_source',
          priority = 1,
          complete = function() end,
          on_complete = function()
            on_complete_called = true
          end,
        })

        local item = { label = 'test_item' } -- no source_name
        assert.has_no.errors(function()
          completion.on_completion_done(item)
        end)
        assert.is_false(on_complete_called)
      end)

      it('does nothing when no matching source is found', function()
        completion._sources = {}
        local item = { source_name = 'nonexistent_source', label = 'test' }
        assert.has_no.errors(function()
          completion.on_completion_done(item)
        end)
      end)

      it('does nothing when source has no on_complete callback', function()
        completion._sources = {}
        completion.register_source({
          name = 'source_no_callback',
          priority = 1,
          complete = function() end,
          -- no on_complete
        })

        local item = { source_name = 'source_no_callback', label = 'test' }
        assert.has_no.errors(function()
          completion.on_completion_done(item)
        end)
      end)
    end)
  end)

  describe('opencode_ls module', function()
    local ls

    before_each(function()
      package.loaded['opencode.lsp.opencode_ls'] = nil
      ls = require('opencode.lsp.opencode_ls')
    end)

    after_each(function()
      package.loaded['opencode.lsp.opencode_ls'] = nil
    end)

    describe('create_config', function()
      it('returns a valid LSP client config', function()
        local config = ls.create_config()

        assert.is_not_nil(config)
        assert.are.equal('opencode_ls', config.name)
        assert.is_function(config.cmd)
      end)

      it('cmd function returns a valid server interface', function()
        local config = ls.create_config()
        local server = config.cmd({}, {})

        assert.is_function(server.request)
        assert.is_function(server.notify)
        assert.is_function(server.is_closing)
        assert.is_function(server.terminate)
      end)

      it('server is_closing returns false', function()
        local config = ls.create_config()
        local server = config.cmd({}, {})
        assert.is_false(server.is_closing())
      end)
    end)

    describe('initialize handler', function()
      it('returns capabilities with trigger characters from completion sources', function()
        package.loaded['opencode.ui.completion'] = nil
        local completion = require('opencode.ui.completion')
        completion._sources = {}
        completion.register_source({
          name = 'source1',
          priority = 1,
          complete = function() end,
          get_trigger_character = function()
            return '@'
          end,
        })
        completion.register_source({
          name = 'source2',
          priority = 1,
          complete = function() end,
          get_trigger_character = function()
            return '/'
          end,
        })

        package.loaded['opencode.lsp.opencode_ls'] = nil
        ls = require('opencode.lsp.opencode_ls')

        local config_obj = ls.create_config()
        local server = config_obj.cmd({}, {})

        local result = nil
        server.request('initialize', {}, function(err, res)
          result = res
        end)

        assert.is_not_nil(result)
        assert.is_not_nil(result.capabilities)
        assert.is_not_nil(result.capabilities.completionProvider)
        local triggers = result.capabilities.completionProvider.triggerCharacters
        assert.is_true(vim.tbl_contains(triggers, '@'))
        assert.is_true(vim.tbl_contains(triggers, '/'))
        assert.are.equal('opencode_ls', result.serverInfo.name)
      end)
    end)

    describe('textDocument_completion handler', function()
      local completion

      before_each(function()
        package.loaded['opencode.ui.completion'] = nil
        completion = require('opencode.ui.completion')
        completion._sources = {}

        vim.api = vim.api or {}
        vim.api.nvim_get_current_buf = function()
          return 1
        end
        vim.api.nvim_buf_get_lines = function(bufnr, start, end_, strict)
          return { '@test' }
        end
        vim.api.nvim_get_current_line = function()
          return '@test'
        end
        vim.api.nvim_win_get_cursor = function()
          return { 1, 5 }
        end

        package.loaded['opencode.lsp.opencode_ls'] = nil
        ls = require('opencode.lsp.opencode_ls')
      end)

      it('returns completion items from registered sources', function()
        local items_returned = false
        completion.register_source({
          name = 'test_source',
          priority = 1,
          complete = function(context)
            return Promise.new():resolve({
              {
                label = 'TestItem',
                kind = 'test',
                kind_icon = '',
                insert_text = 'TestItem',
                source_name = 'test_source',
                data = {},
              },
            })
          end,
          get_trigger_character = function()
            return '@'
          end,
        })

        local config_obj = ls.create_config()
        local server = config_obj.cmd({}, {})

        local callback_result = nil
        server.request('textDocument/completion', {
          position = { line = 0, character = 5 },
        }, function(err, result)
          callback_result = result
          items_returned = true
        end)

        -- wait for async resolution
        vim.wait(200, function()
          return items_returned
        end)

        assert.is_not_nil(callback_result)
        assert.is_not_nil(callback_result.items)
        assert.are.equal(1, #callback_result.items)
        assert.are.equal('TestItem', callback_result.items[1].filterText)
      end)

      it('sets isIncomplete based on source is_incomplete flag', function()
        completion.register_source({
          name = 'incomplete_source',
          priority = 1,
          is_incomplete = true,
          complete = function(context)
            return Promise.new():resolve({
              {
                label = 'IncompleteItem',
                kind = 'file',
                kind_icon = '',
                insert_text = 'IncompleteItem',
                source_name = 'incomplete_source',
                data = {},
              },
            })
          end,
          get_trigger_character = function()
            return '@'
          end,
        })

        local config_obj = ls.create_config()
        local server = config_obj.cmd({}, {})

        local done = false
        local callback_result = nil
        server.request('textDocument/completion', {
          position = { line = 0, character = 5 },
        }, function(err, result)
          callback_result = result
          done = true
        end)

        vim.wait(200, function()
          return done
        end)

        assert.is_not_nil(callback_result)
        assert.is_true(callback_result.isIncomplete)
      end)

      it('returns isIncomplete=false when no source has is_incomplete', function()
        completion.register_source({
          name = 'complete_source',
          priority = 1,
          -- no is_incomplete flag
          complete = function(context)
            return Promise.new():resolve({
              {
                label = 'Item',
                kind = 'command',
                kind_icon = '',
                insert_text = 'Item',
                source_name = 'complete_source',
                data = {},
              },
            })
          end,
          get_trigger_character = function()
            return '/'
          end,
        })

        local config_obj = ls.create_config()
        local server = config_obj.cmd({}, {})

        local done = false
        local callback_result = nil
        server.request('textDocument/completion', {
          position = { line = 0, character = 5 },
        }, function(err, result)
          callback_result = result
          done = true
        end)

        vim.wait(200, function()
          return done
        end)

        assert.is_not_nil(callback_result)
        assert.is_false(callback_result.isIncomplete)
      end)

      it('returns items with executeCommand for completion_done', function()
        completion.register_source({
          name = 'store_test',
          priority = 1,
          complete = function(context)
            return Promise.new():resolve({
              {
                label = 'StoredItem',
                kind = 'file',
                kind_icon = '',
                insert_text = 'StoredItem',
                source_name = 'store_test',
                data = {},
              },
            })
          end,
          get_trigger_character = function()
            return '@'
          end,
        })

        local config_obj = ls.create_config()
        local server = config_obj.cmd({}, {})

        local done = false
        local callback_result = nil
        server.request('textDocument/completion', {
          position = { line = 0, character = 5 },
        }, function(err, result)
          callback_result = result
          done = true
        end)

        vim.wait(200, function()
          return done
        end)

        assert.is_not_nil(callback_result)
        assert.are.equal(1, #callback_result.items)
        local cmd = callback_result.items[1].command
        assert.is_not_nil(cmd)
        assert.are.equal('opencode.completion_done', cmd.command)
      end)

      it('calls callback with empty result on error', function()
        completion.register_source({
          name = 'error_source',
          priority = 1,
          complete = function(context)
            return Promise.new():reject('test error')
          end,
          get_trigger_character = function()
            return '@'
          end,
        })

        -- Mock log to suppress error output
        package.loaded['opencode.log'] = { error = function() end }

        local config_obj = ls.create_config()
        local server = config_obj.cmd({}, {})

        local done = false
        local callback_result = nil
        server.request('textDocument/completion', {
          position = { line = 0, character = 5 },
        }, function(err, result)
          callback_result = result
          done = true
        end)

        vim.wait(200, function()
          return done
        end)

        assert.is_not_nil(callback_result)
        package.loaded['opencode.log'] = nil
      end)
    end)

    describe('workspace_executeCommand handler', function()
      local completion

      before_each(function()
        package.loaded['opencode.ui.completion'] = nil
        completion = require('opencode.ui.completion')
        completion._sources = {}

        package.loaded['opencode.lsp.opencode_ls'] = nil
        ls = require('opencode.lsp.opencode_ls')
      end)

      it('calls on_completion_done when command is opencode.completion_done', function()
        local on_complete_called = false
        local received_item = nil

        completion.register_source({
          name = 'cmd_source',
          priority = 1,
          complete = function() end,
          on_complete = function(item)
            on_complete_called = true
            received_item = item
          end,
        })

        local config_obj = ls.create_config()
        local server = config_obj.cmd({}, {})

        local original_item = { label = 'CmdItem', source_name = 'cmd_source', data = {} }
        local cb_err, cb_result
        server.request('workspace/executeCommand', {
          command = 'opencode.completion_done',
          arguments = { original_item },
        }, function(err, result)
          cb_err = err
          cb_result = result
        end)

        assert.is_nil(cb_err)
        assert.is_nil(cb_result)
        assert.is_true(on_complete_called)
        assert.are.equal(original_item, received_item)
      end)

      it('does not call on_completion_done when _completion_done_handled is true', function()
        local on_complete_called = false

        completion.register_source({
          name = 'dedup_source',
          priority = 1,
          complete = function() end,
          on_complete = function()
            on_complete_called = true
          end,
        })

        ls._completion_done_handled = true

        local config_obj = ls.create_config()
        local server = config_obj.cmd({}, {})

        server.request('workspace/executeCommand', {
          command = 'opencode.completion_done',
          arguments = { { label = 'Item', source_name = 'dedup_source', data = {} } },
        }, function() end)

        assert.is_false(on_complete_called)
        assert.is_false(ls._completion_done_handled)
      end)

      it('resets _completion_done_handled to false after skipping', function()
        ls._completion_done_handled = true

        local config_obj = ls.create_config()
        local server = config_obj.cmd({}, {})

        server.request('workspace/executeCommand', {
          command = 'opencode.completion_done',
          arguments = { { label = 'X', source_name = 'any', data = {} } },
        }, function() end)

        assert.is_false(ls._completion_done_handled)
      end)

      it('returns method-not-found error for unknown commands', function()
        local config_obj = ls.create_config()
        local server = config_obj.cmd({}, {})

        local cb_err, cb_result
        server.request('workspace/executeCommand', {
          command = 'unknown.command',
        }, function(err, result)
          cb_err = err
          cb_result = result
        end)

        assert.is_not_nil(cb_err)
        assert.are.equal(-32601, cb_err.code)
        assert.is_nil(cb_result)
      end)

      it('does nothing when arguments are missing', function()
        local config_obj = ls.create_config()
        local server = config_obj.cmd({}, {})

        assert.has_no.errors(function()
          server.request('workspace/executeCommand', {
            command = 'opencode.completion_done',
            -- no arguments
          }, function() end)
        end)
      end)
    end)

    describe('CompleteDonePre autocmd', function()
      local completion

      before_each(function()
        package.loaded['opencode.ui.completion'] = nil
        completion = require('opencode.ui.completion')
        completion._sources = {}

        package.loaded['opencode.lsp.opencode_ls'] = nil
        ls = require('opencode.lsp.opencode_ls')

        ls.start(0)
      end)

      after_each(function()
        vim.api.nvim_clear_autocmds({ event = 'CompleteDonePre', buffer = 0 })
      end)

      local function fire_autocmd(user_data)
        vim.v.completed_item = { user_data = user_data }
        vim.api.nvim_exec_autocmds('CompleteDonePre', { buffer = 0 })
      end

      it('sets _completion_done_handled to true when fired', function()
        ls._completion_done_handled = false

        fire_autocmd({
          nvim = {
            lsp = {
              completion_item = {
                data = { _opencode_item = { source_name = 'test', label = 'test', data = {} } },
              },
            },
          },
        })

        assert.is_true(ls._completion_done_handled)
      end)

      it('calls on_completion_done via nvim lsp user_data path', function()
        local on_complete_called = false
        local received_item = nil
        local original_item = { label = 'AutoItem', source_name = 'autocmd_source', data = {} }

        completion.register_source({
          name = 'autocmd_source',
          priority = 1,
          complete = function() end,
          on_complete = function(item)
            on_complete_called = true
            received_item = item
          end,
        })

        fire_autocmd({
          nvim = {
            lsp = {
              completion_item = {
                data = { _opencode_item = original_item },
              },
            },
          },
        })

        assert.is_true(on_complete_called)
        assert.are.same(original_item, received_item)
      end)

      it('calls on_completion_done via lsp.item user_data path', function()
        local on_complete_called = false
        local received_item = nil
        local original_item = { label = 'AutoItem2', source_name = 'autocmd_source2', data = {} }

        completion.register_source({
          name = 'autocmd_source2',
          priority = 1,
          complete = function() end,
          on_complete = function(item)
            on_complete_called = true
            received_item = item
          end,
        })

        fire_autocmd({
          lsp = {
            item = {
              data = { _opencode_item = original_item },
            },
          },
        })

        assert.is_true(on_complete_called)
        assert.are.same(original_item, received_item)
      end)

      it('does not error when user_data has no _opencode_item', function()
        assert.has_no.errors(function()
          fire_autocmd({ nvim = { lsp = { completion_item = { data = {} } } } })
        end)
      end)

      it('does not error when completed_item has no user_data', function()
        assert.has_no.errors(function()
          vim.api.nvim_exec_autocmds('CompleteDonePre', { buffer = 0 })
        end)
      end)

      it('prevents executeCommand from firing on_completion_done a second time', function()
        local call_count = 0
        local original_item = { label = 'DedupItem', source_name = 'dedup_autocmd', data = {} }

        completion.register_source({
          name = 'dedup_autocmd',
          priority = 1,
          complete = function() end,
          on_complete = function()
            call_count = call_count + 1
          end,
        })

        -- Fire CompleteDonePre; this sets _completion_done_handled and calls on_complete once
        fire_autocmd({
          nvim = {
            lsp = {
              completion_item = {
                data = { _opencode_item = original_item },
              },
            },
          },
        })

        assert.are.equal(1, call_count)

        -- Simulate the completion engine then sending workspace/executeCommand.
        -- Because _completion_done_handled is true, it should skip the second call.
        local config_obj = ls.create_config()
        local server = config_obj.cmd({}, {})
        server.request('workspace/executeCommand', {
          command = 'opencode.completion_done',
          arguments = { original_item },
        }, function() end)

        assert.are.equal(1, call_count)
        assert.is_false(ls._completion_done_handled)
      end)
    end)

    describe('unregistered handler', function()
      it('does not error when an unknown method is called', function()
        package.loaded['opencode.lsp.opencode_ls'] = nil
        ls = require('opencode.lsp.opencode_ls')

        local config_obj = ls.create_config()
        local server = config_obj.cmd({}, {})

        assert.has_no.errors(function()
          server.request('unknown/method', {}, function() end)
        end)
      end)
    end)

    describe('to_lsp_item conversion', function()
      it('includes kind_icon when float completion engine is detected', function()
        -- Simulate a float-based engine (blink.cmp) being available
        package.loaded['blink.cmp'] = {
          is_visible = function()
            return false
          end,
        }
        package.loaded['opencode.lsp.opencode_ls'] = nil
        ls = require('opencode.lsp.opencode_ls')

        package.loaded['opencode.ui.completion'] = nil
        local completion = require('opencode.ui.completion')
        completion._sources = {}
        completion.register_source({
          name = 'blink_source',
          priority = 1,
          complete = function()
            return Promise.new():resolve({
              {
                label = 'BlinkItem',
                kind = 'file',
                kind_icon = '',
                insert_text = 'BlinkItem',
                source_name = 'blink_source',
                data = {},
              },
            })
          end,
          get_trigger_character = function()
            return '@'
          end,
        })

        vim.api.nvim_buf_get_lines = function()
          return { '@test' }
        end
        vim.api.nvim_get_current_line = function()
          return '@test'
        end
        vim.api.nvim_win_get_cursor = function()
          return { 1, 5 }
        end

        local config_obj = ls.create_config()
        local server = config_obj.cmd({}, {})

        local done = false
        local callback_result = nil
        server.request('textDocument/completion', {
          position = { line = 0, character = 5 },
        }, function(err, result)
          callback_result = result
          done = true
        end)

        vim.wait(200, function()
          return done
        end)

        assert.is_not_nil(callback_result)
        assert.is_not_nil(callback_result.items)
        assert.are.equal(1, #callback_result.items)

        local item = callback_result.items[1]
        -- When a float engine is detected, label should not have kind_icon prefix
        assert.are.equal('BlinkItem', item.label)
        assert.is_not_nil(item.kind_icon)
      end)

      it('prefixes label with kind_icon when no float completion engine is detected', function()
        -- Ensure no float engine is present
        package.loaded['blink.cmp'] = nil
        package.loaded['cmp'] = nil
        package.loaded['opencode.lsp.opencode_ls'] = nil
        ls = require('opencode.lsp.opencode_ls')

        package.loaded['opencode.ui.completion'] = nil
        local completion = require('opencode.ui.completion')
        completion._sources = {}
        completion.register_source({
          name = 'no_blink_source',
          priority = 1,
          complete = function()
            return Promise.new():resolve({
              {
                label = 'MyFile',
                kind = 'file',
                kind_icon = '',
                insert_text = 'MyFile',
                source_name = 'no_blink_source',
                data = {},
              },
            })
          end,
          get_trigger_character = function()
            return '@'
          end,
        })

        vim.api.nvim_buf_get_lines = function()
          return { '@test' }
        end
        vim.api.nvim_get_current_line = function()
          return '@test'
        end
        vim.api.nvim_win_get_cursor = function()
          return { 1, 5 }
        end

        local config_obj = ls.create_config()
        local server = config_obj.cmd({}, {})

        local done = false
        local callback_result = nil
        server.request('textDocument/completion', {
          position = { line = 0, character = 5 },
        }, function(err, result)
          callback_result = result
          done = true
        end)

        vim.wait(200, function()
          return done
        end)

        assert.is_not_nil(callback_result)
        assert.is_not_nil(callback_result.items)
        assert.are.equal(1, #callback_result.items)

        local item = callback_result.items[1]
        -- When no float engine is detected, label should be prefixed with kind_icon
        assert.is_true(item.label:find('MyFile') ~= nil)
        assert.is_true(item.label:find('') ~= nil) -- kind_icon is prepended to label
      end)

      it('sets insertText from item.insertText or item.label', function()
        package.loaded['blink.cmp'] = nil
        package.loaded['opencode.lsp.opencode_ls'] = nil
        ls = require('opencode.lsp.opencode_ls')

        package.loaded['opencode.ui.completion'] = nil
        local completion = require('opencode.ui.completion')
        completion._sources = {}
        completion.register_source({
          name = 'insert_test_source',
          priority = 1,
          complete = function()
            return Promise.new():resolve({
              {
                label = '/compact',
                kind = 'command',
                kind_icon = '',
                insert_text = 'compact',
                source_name = 'insert_test_source',
                data = {},
              },
            })
          end,
          get_trigger_character = function()
            return '/'
          end,
        })

        vim.api.nvim_buf_get_lines = function()
          return { '/test' }
        end
        vim.api.nvim_get_current_line = function()
          return '/test'
        end
        vim.api.nvim_win_get_cursor = function()
          return { 1, 5 }
        end

        local config_obj = ls.create_config()
        local server = config_obj.cmd({}, {})

        local done = false
        local callback_result = nil
        server.request('textDocument/completion', {
          position = { line = 0, character = 5 },
        }, function(err, result)
          callback_result = result
          done = true
        end)

        vim.wait(200, function()
          return done
        end)

        assert.is_not_nil(callback_result)
        assert.are.equal(1, #callback_result.items)
        assert.are.equal('compact', callback_result.items[1].insertText)
      end)

      it('embeds the original item in data._opencode_item', function()
        package.loaded['blink.cmp'] = nil
        package.loaded['opencode.lsp.opencode_ls'] = nil
        ls = require('opencode.lsp.opencode_ls')

        package.loaded['opencode.ui.completion'] = nil
        local completion = require('opencode.ui.completion')
        completion._sources = {}

        local original_item = {
          label = 'OriginalItem',
          kind = 'file',
          kind_icon = '',
          insert_text = 'OriginalItem',
          source_name = 'data_test_source',
          data = { custom = 'value' },
        }

        completion.register_source({
          name = 'data_test_source',
          priority = 1,
          complete = function()
            return Promise.new():resolve({ original_item })
          end,
          get_trigger_character = function()
            return '@'
          end,
        })

        vim.api.nvim_buf_get_lines = function()
          return { '@test' }
        end
        vim.api.nvim_get_current_line = function()
          return '@test'
        end
        vim.api.nvim_win_get_cursor = function()
          return { 1, 5 }
        end

        local config_obj = ls.create_config()
        local server = config_obj.cmd({}, {})

        local done = false
        local callback_result = nil
        server.request('textDocument/completion', {
          position = { line = 0, character = 5 },
        }, function(err, result)
          callback_result = result
          done = true
        end)

        vim.wait(200, function()
          return done
        end)

        assert.is_not_nil(callback_result)
        assert.are.equal(1, #callback_result.items)
        local lsp_item = callback_result.items[1]
        assert.is_not_nil(lsp_item.data)
        assert.is_not_nil(lsp_item.data._opencode_item)
        assert.are.equal(original_item.label, lsp_item.data._opencode_item.label)
        assert.are.equal('value', lsp_item.data._opencode_item.data.custom)
      end)
    end)
  end)
end)
