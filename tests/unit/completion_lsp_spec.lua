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
    package.loaded['opencode.lsp.opencode_completion_ls'] = nil
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

    describe('store_completion_items', function()
      before_each(function()
        vim.api = vim.api or {}
        vim.api.nvim_get_current_line = function()
          return 'test line'
        end
        vim.api.nvim_win_get_cursor = function()
          return { 1, 5 }
        end
      end)

      it('stores items indexed by insertText', function()
        local items = {
          { insertText = 'file.lua', label = 'file.lua', source_name = 'files' },
          { insertText = 'other.lua', label = 'other.lua', source_name = 'files' },
        }

        completion.store_completion_items(items)

        assert.is_not_nil(completion._pending['file.lua'])
        assert.is_not_nil(completion._pending['other.lua'])
      end)

      it('ignores items without insertText', function()
        local items = {
          { label = 'no_insert_text', source_name = 'files' },
        }

        completion.store_completion_items(items)

        -- Should not be in pending since no insertText
        local count = 0
        for _ in pairs(completion._pending) do
          count = count + 1
        end
        assert.are.equal(0, count)
      end)

      it('clears previous pending items', function()
        completion._pending = { old_item = { insertText = 'old' } }

        completion.store_completion_items({})

        local count = 0
        for _ in pairs(completion._pending) do
          count = count + 1
        end
        assert.are.equal(0, count)
      end)

      it('handles nil items gracefully', function()
        assert.has_no.errors(function()
          completion.store_completion_items(nil)
        end)
      end)
    end)

    describe('is_visible', function()
      it('returns true when there are pending items', function()
        completion._pending = { some_key = {} }
        assert.is_true(completion.is_visible())
      end)

      it('returns false when pending is empty', function()
        completion._pending = {}
        assert.is_false(completion.is_visible())
      end)
    end)

    describe('has_completion_engine', function()
      it('returns true when preferred_completion_engine is set to non-vim_complete', function()
        mock_config.preferred_completion_engine = 'nvim-cmp'
        local result = completion.has_completion_engine()
        assert.is_true(result)
      end)

      it('returns false when preferred_completion_engine is vim_complete', function()
        mock_config.preferred_completion_engine = 'vim_complete'
        -- Make sure no other engines are loaded
        package.loaded['cmp'] = nil
        package.loaded['blink.cmp'] = nil
        package.loaded['completion'] = nil
        package.loaded['mini.completion'] = nil
        package.loaded['minuet'] = nil
        local result = completion.has_completion_engine()
        assert.is_false(result)
      end)

      it('returns true when a known engine package is loaded', function()
        mock_config.preferred_completion_engine = nil
        -- Simulate cmp being loaded
        package.loaded['cmp'] = {}
        local result = completion.has_completion_engine()
        assert.is_true(result)
        package.loaded['cmp'] = nil
      end)

      it('returns false when no engine is present', function()
        mock_config.preferred_completion_engine = nil
        package.loaded['cmp'] = nil
        package.loaded['blink.cmp'] = nil
        package.loaded['completion'] = nil
        package.loaded['mini.completion'] = nil
        package.loaded['minuet'] = nil
        local result = completion.has_completion_engine()
        assert.is_false(result)
      end)
    end)

    describe('on_text_changed', function()
      before_each(function()
        vim.api = vim.api or {}
        vim.api.nvim_get_current_line = function()
          return 'test '
        end
        vim.api.nvim_win_get_cursor = function()
          return { 1, 5 }
        end
      end)

      it('does nothing when no pending items', function()
        completion._pending = {}
        assert.has_no.errors(function()
          completion.on_text_changed()
        end)
      end)

      it('triggers on_completion_done when inserted text matches pending item', function()
        local on_done_called = false
        local received_item = nil

        completion._sources = {}
        completion.register_source({
          name = 'test',
          priority = 1,
          complete = function() end,
          on_complete = function(item)
            on_done_called = true
            received_item = item
          end,
        })

        local original_item = { source_name = 'test', label = 'file.lua' }
        local lsp_item = {
          insertText = 'file.lua',
          data = { _opencode_item = original_item },
        }

        completion._last_col = 0
        completion._last_line = ''
        completion._pending = { ['file.lua'] = lsp_item }

        vim.api.nvim_get_current_line = function()
          return 'file.lua'
        end
        vim.api.nvim_win_get_cursor = function()
          return { 1, 8 }
        end

        completion.on_text_changed()

        assert.is_true(on_done_called)
        assert.are.equal(original_item, received_item)
      end)
    end)
  end)

  describe('opencode_completion_ls module', function()
    local ls

    before_each(function()
      package.loaded['opencode.lsp.opencode_completion_ls'] = nil
      ls = require('opencode.lsp.opencode_completion_ls')
    end)

    after_each(function()
      package.loaded['opencode.lsp.opencode_completion_ls'] = nil
    end)

    describe('create_config', function()
      it('returns a valid LSP client config', function()
        local config = ls.create_config()

        assert.is_not_nil(config)
        assert.are.equal('opencode_completion_ls', config.name)
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

        package.loaded['opencode.lsp.opencode_completion_ls'] = nil
        ls = require('opencode.lsp.opencode_completion_ls')

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
        assert.are.equal('opencode_completion_ls', result.serverInfo.name)
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

        package.loaded['opencode.lsp.opencode_completion_ls'] = nil
        ls = require('opencode.lsp.opencode_completion_ls')
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

      it('stores completion items after returning results', function()
        completion._pending = {}
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
        server.request('textDocument/completion', {
          position = { line = 0, character = 5 },
        }, function()
          done = true
        end)

        vim.wait(200, function()
          return done
        end)

        -- The completion items should have been stored in pending
        assert.is_not_nil(completion._pending)
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

    describe('unregistered handler', function()
      it('does not error when an unknown method is called', function()
        package.loaded['opencode.lsp.opencode_completion_ls'] = nil
        ls = require('opencode.lsp.opencode_completion_ls')

        local config_obj = ls.create_config()
        local server = config_obj.cmd({}, {})

        assert.has_no.errors(function()
          server.request('unknown/method', {}, function() end)
        end)
      end)
    end)

    describe('to_lsp_item conversion', function()
      it('includes kind_icon when blink.cmp is present', function()
        -- Simulate blink.cmp being available
        package.loaded['blink.cmp'] = {}
        package.loaded['opencode.lsp.opencode_completion_ls'] = nil
        ls = require('opencode.lsp.opencode_completion_ls')

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
        -- When blink.cmp is present, label should not have kind_icon prefix
        assert.are.equal('BlinkItem', item.label)
        assert.is_not_nil(item.kind_icon)

        package.loaded['blink.cmp'] = nil
      end)

      it('prefixes label with kind_icon when blink.cmp is absent', function()
        package.loaded['blink.cmp'] = nil
        package.loaded['opencode.lsp.opencode_completion_ls'] = nil
        ls = require('opencode.lsp.opencode_completion_ls')

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
        -- When blink.cmp is absent, label should be prefixed with kind_icon
        assert.is_true(item.label:find('MyFile') ~= nil)
        assert.is_nil(item.kind_icon)
      end)

      it('sets insertText from item.insert_text', function()
        package.loaded['blink.cmp'] = nil
        package.loaded['opencode.lsp.opencode_completion_ls'] = nil
        ls = require('opencode.lsp.opencode_completion_ls')

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
        package.loaded['opencode.lsp.opencode_completion_ls'] = nil
        ls = require('opencode.lsp.opencode_completion_ls')

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
