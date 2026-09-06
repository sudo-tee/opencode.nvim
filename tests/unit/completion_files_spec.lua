local Promise = require('opencode.promise')
local config = require('opencode.config')
local state = require('opencode.state')

describe('file completion responsiveness', function()
  local original_system, original_executable, original_client, original_config
  local source

  before_each(function()
    original_system = vim.system
    original_executable = vim.fn.executable
    original_client = state.api_client
    original_config = vim.deepcopy(config.ui.completion.file_sources)
    config.ui.completion.file_sources.preferred_cli_tool = 'server'
    config.ui.completion.file_sources.enabled = true
    config.ui.completion.file_sources.ignore_patterns = {}
    package.loaded['opencode.ui.completion.files'] = nil
    source = require('opencode.ui.completion.files').get_source()
  end)

  after_each(function()
    vim.system = original_system
    vim.fn.executable = original_executable
    state.jobs.set_api_client(original_client)
    config.ui.completion.file_sources = original_config
    package.loaded['opencode.ui.completion.files'] = nil
  end)

  local function complete()
    return source.complete({ input = 'file', trigger_char = source.get_trigger_character() })
  end

  it('returns control while the server search is pending', function()
    local search = Promise.new()
    state.jobs.set_api_client({
      find_files = function()
        return search
      end,
    })
    local result = complete()
    assert.is_false(result:is_resolved())
    search:resolve({ 'file.lua' })
    assert.equals('file.lua', result:wait()[1].insert_text)
  end)

  it('falls back asynchronously when the server search rejects', function()
    state.jobs.set_api_client({
      find_files = function()
        return Promise.new():reject('offline')
      end,
    })
    vim.fn.executable = function(tool)
      return tool == 'fd' and 1 or 0
    end
    local on_exit
    vim.system = function(_, _, cb)
      on_exit = cb
      return {}
    end
    local result = complete()
    assert.is_function(on_exit)
    assert.is_false(result:is_resolved())
    on_exit({ code = 0, stdout = 'file.lua\n' })
    assert.equals('file.lua', result:wait()[1].insert_text)
  end)

  it('skips unavailable executables and limits server results', function()
    config.ui.completion.file_sources.preferred_cli_tool = 'fd'
    config.ui.completion.file_sources.max_files = 1
    package.loaded['opencode.ui.completion.files'] = nil
    source = require('opencode.ui.completion.files').get_source()
    vim.fn.executable = function()
      return 0
    end
    vim.system = function()
      error('unavailable tools must not run')
    end
    state.jobs.set_api_client({
      find_files = function()
        return Promise.new():resolve({ 'file.lua', 'file2.lua' })
      end,
    })
    assert.equals(1, #complete():wait())
  end)
end)
