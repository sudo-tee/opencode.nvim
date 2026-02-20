local assert = require('luassert')

describe('opencode.ui.completion', function()
  local completion
  local mock_config

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
    package.loaded['opencode.ui.completion'] = nil
    package.loaded['opencode.ui.completion.files'] = nil
    package.loaded['opencode.ui.completion.subagents'] = nil
    package.loaded['opencode.ui.completion.commands'] = nil
    package.loaded['opencode.ui.completion.context'] = nil

    completion = require('opencode.ui.completion')
    completion._sources = {}
    completion._pending = {}
    completion._last_line = ''
    completion._last_col = 0
  end)

  after_each(function()
    package.loaded['opencode.config'] = nil
    package.loaded['opencode.ui.completion'] = nil
    package.loaded['opencode.ui.completion.files'] = nil
    package.loaded['opencode.ui.completion.subagents'] = nil
    package.loaded['opencode.ui.completion.commands'] = nil
    package.loaded['opencode.ui.completion.context'] = nil
  end)

  describe('setup', function()
    it('registers all four built-in sources', function()
      local registered = {}

      package.loaded['opencode.ui.completion.files'] = {
        get_source = function()
          return { name = 'files', priority = 10, complete = function() end }
        end,
      }
      package.loaded['opencode.ui.completion.subagents'] = {
        get_source = function()
          return { name = 'subagents', priority = 5, complete = function() end }
        end,
      }
      package.loaded['opencode.ui.completion.commands'] = {
        get_source = function()
          return { name = 'commands', priority = 8, complete = function() end }
        end,
      }
      package.loaded['opencode.ui.completion.context'] = {
        get_source = function()
          return { name = 'context', priority = 1, complete = function() end }
        end,
      }

      package.loaded['opencode.ui.completion'] = nil
      completion = require('opencode.ui.completion')
      completion._sources = {}

      completion.setup()

      local sources = completion.get_sources()
      assert.are.equal(4, #sources)

      for _, s in ipairs(sources) do
        registered[s.name] = true
      end
      assert.is_true(registered['files'])
      assert.is_true(registered['subagents'])
      assert.is_true(registered['commands'])
      assert.is_true(registered['context'])
    end)

    it('sorts sources in descending priority order after setup', function()
      package.loaded['opencode.ui.completion.files'] = {
        get_source = function()
          return { name = 'files', priority = 10, complete = function() end }
        end,
      }
      package.loaded['opencode.ui.completion.subagents'] = {
        get_source = function()
          return { name = 'subagents', priority = 5, complete = function() end }
        end,
      }
      package.loaded['opencode.ui.completion.commands'] = {
        get_source = function()
          return { name = 'commands', priority = 8, complete = function() end }
        end,
      }
      package.loaded['opencode.ui.completion.context'] = {
        get_source = function()
          return { name = 'context', priority = 1, complete = function() end }
        end,
      }

      package.loaded['opencode.ui.completion'] = nil
      completion = require('opencode.ui.completion')
      completion._sources = {}

      completion.setup()

      local sources = completion.get_sources()
      for i = 1, #sources - 1 do
        assert.is_true((sources[i].priority or 0) >= (sources[i + 1].priority or 0))
      end
    end)

    it('sources without priority are treated as priority 0', function()
      package.loaded['opencode.ui.completion.files'] = {
        get_source = function()
          return { name = 'files', complete = function() end } -- no priority
        end,
      }
      package.loaded['opencode.ui.completion.subagents'] = {
        get_source = function()
          return { name = 'subagents', priority = 5, complete = function() end }
        end,
      }
      package.loaded['opencode.ui.completion.commands'] = {
        get_source = function()
          return { name = 'commands', complete = function() end } -- no priority
        end,
      }
      package.loaded['opencode.ui.completion.context'] = {
        get_source = function()
          return { name = 'context', complete = function() end } -- no priority
        end,
      }

      package.loaded['opencode.ui.completion'] = nil
      completion = require('opencode.ui.completion')
      completion._sources = {}

      assert.has_no.errors(function()
        completion.setup()
      end)

      local sources = completion.get_sources()
      assert.are.equal(4, #sources)
    end)
  end)

  describe('on_insert_enter', function()
    before_each(function()
      vim.api = vim.api or {}
      vim.api.nvim_get_current_line = function()
        return 'hello world'
      end
      vim.api.nvim_win_get_cursor = function()
        return { 1, 7 }
      end
    end)

    it('captures the current line', function()
      completion.on_insert_enter()
      assert.are.equal('hello world', completion._last_line)
    end)

    it('captures the current cursor column', function()
      completion.on_insert_enter()
      assert.are.equal(7, completion._last_col)
    end)

    it('updates state on subsequent calls', function()
      completion.on_insert_enter()
      assert.are.equal('hello world', completion._last_line)
      assert.are.equal(7, completion._last_col)

      vim.api.nvim_get_current_line = function()
        return 'new line'
      end
      vim.api.nvim_win_get_cursor = function()
        return { 1, 3 }
      end

      completion.on_insert_enter()
      assert.are.equal('new line', completion._last_line)
      assert.are.equal(3, completion._last_col)
    end)
  end)
end)
