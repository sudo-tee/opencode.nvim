local config_file = require('opencode.config_file')
local assert = require('luassert')

describe('config_file.setup', function()
  local original_run_server_api

  before_each(function()
    config_file._cache = nil
    local core = require('opencode.core')
    original_run_server_api = core.run_server_api
    -- Set up mock immediately to prevent any real API calls
    core.run_server_api = function() end
  end)

  after_each(function()
    if original_run_server_api then
      local core = require('opencode.core')
      core.run_server_api = original_run_server_api
    end
    config_file._cache = nil
  end)

  it('calls core.run_server_api with correct parameters', function()
    local core = require('opencode.core')
    local api_calls = {}

    core.run_server_api = function(path, method, data, opts)
      table.insert(api_calls, {
        path = path,
        method = method,
        data = data,
        opts = opts,
      })
    end

    config_file.setup()

    vim.wait(10)

    assert.are.equal(1, #api_calls)
    assert.are.equal('/config', api_calls[1].path)
    assert.are.equal('GET', api_calls[1].method)
    assert.is_nil(api_calls[1].data)
    assert.True(api_calls[1].opts.background)
    assert.is_function(api_calls[1].opts.on_done)
    assert.is_function(api_calls[1].opts.on_error)
  end)

  it('caches response on successful API call', function()
    local core = require('opencode.core')
    local test_config = { agent = { ['test-agent'] = {} } }

    core.run_server_api = function(path, method, data, opts)
      vim.schedule(function()
        opts.on_done(test_config)
      end)
    end

    config_file.setup()

    vim.wait(50)

    assert.are.same(test_config, config_file._cache)
  end)

  it('handles API error correctly', function()
    local core = require('opencode.core')
    local notifications = {}

    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end

    core.run_server_api = function(path, method, data, opts)
      vim.schedule(function()
        opts.on_error('Connection failed')
      end)
    end

    config_file.setup()

    vim.wait(50)

    vim.notify = original_notify

    assert.are.equal(1, #notifications)
    assert.is_not_nil(string.find(notifications[1].msg, 'Error fetching config file from server'))
    assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
    assert.is_nil(config_file._cache)
  end)

  it('handles nil response correctly', function()
    local core = require('opencode.core')
    local notifications = {}

    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end

    core.run_server_api = function(path, method, data, opts)
      vim.schedule(function()
        opts.on_done(nil)
      end)
    end

    config_file.setup()

    vim.wait(50)

    vim.notify = original_notify

    assert.are.equal(1, #notifications)
    assert.is_not_nil(string.find(notifications[1].msg, 'Failed to parse config file from server response'))
    assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
    assert.is_nil(config_file._cache)
  end)
end)

describe('config_file.get_opencode_agents', function()
  before_each(function()
    config_file._cache = nil
  end)

  after_each(function()
    config_file._cache = nil
  end)

  it('returns empty table when no config is cached', function()
    local agents = config_file.get_opencode_agents()
    assert.are.same({}, agents)
  end)

  it('returns agents from cached config', function()
    config_file._cache = {
      agent = {
        ['custom-agent'] = {},
        ['another-agent'] = {},
      },
    }

    local agents = config_file.get_opencode_agents()
    assert.True(vim.tbl_contains(agents, 'custom-agent'))
    assert.True(vim.tbl_contains(agents, 'another-agent'))
    assert.True(vim.tbl_contains(agents, 'build'))
    assert.True(vim.tbl_contains(agents, 'plan'))
  end)

  it('includes default build and plan agents', function()
    config_file._cache = {}

    local agents = config_file.get_opencode_agents()
    assert.True(vim.tbl_contains(agents, 'build'))
    assert.True(vim.tbl_contains(agents, 'plan'))
  end)
end)
