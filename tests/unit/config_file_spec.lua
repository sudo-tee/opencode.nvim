local config_file = require('opencode.config_file')
local state = require('opencode.state')
local tmpfile = '/tmp/opencode_test_config.json'
local tmpdir = '/tmp/opencode_test_agents'
local local_tmpdir = '/tmp/opencode_test_local_agents'

local function cleanup()
  os.remove(tmpfile)
  vim.fn.delete(tmpdir, 'rf')
  vim.fn.delete(local_tmpdir, 'rf')
  vim.fn.delete('.opencode', 'rf')
end

describe('config_file.get_opencode_agents', function()
  before_each(function()
    cleanup()
    -- Create test directories
    vim.fn.mkdir(tmpdir, 'p')
    vim.fn.mkdir(local_tmpdir, 'p')
  end)

  after_each(function()
    cleanup()
  end)

  it('returns empty table when no config file exists', function()
    config_file.config_file = '/nonexistent/path'
    local agents = config_file.get_opencode_agents()
    assert.are.same({}, agents)
  end)

  it('returns agents from config file', function()
    -- Write config with agent definitions
    local f = assert(io.open(tmpfile, 'w'))
    f:write('{"agent": {"custom-agent": {}, "another-agent": {}}}')
    f:close()
    config_file.config_file = tmpfile

    local agents = config_file.get_opencode_agents()
    assert.True(vim.tbl_contains(agents, 'custom-agent'))
    assert.True(vim.tbl_contains(agents, 'another-agent'))
    assert.True(vim.tbl_contains(agents, 'build'))
    assert.True(vim.tbl_contains(agents, 'plan'))
  end)

  it('includes default build and plan agents', function()
    -- Write minimal config
    local f = assert(io.open(tmpfile, 'w'))
    f:write('{}')
    f:close()
    config_file.config_file = tmpfile

    local agents = config_file.get_opencode_agents()
    assert.True(vim.tbl_contains(agents, 'build'))
    assert.True(vim.tbl_contains(agents, 'plan'))
  end)

  it('discovers agents from filesystem directories', function()
    -- Write minimal config
    local f = assert(io.open(tmpfile, 'w'))
    f:write('{}')
    f:close()
    config_file.config_file = tmpfile

    -- Create the expected directory structure
    local home_agent_dir = tmpdir .. '/.config/opencode/agent'
    local local_agent_dir = '.opencode/agent'

    vim.fn.mkdir(home_agent_dir, 'p')
    vim.fn.mkdir(local_agent_dir, 'p')

    -- Create agent files
    local agent1 = home_agent_dir .. '/file-agent.md'
    local agent2 = home_agent_dir .. '/code-reviewer.md'
    local agent3 = local_agent_dir .. '/local-agent.md'
    local non_agent = home_agent_dir .. '/not-an-agent.txt'

    vim.fn.writefile({ '# File Agent' }, agent1)
    vim.fn.writefile({ '# Code Reviewer' }, agent2)
    vim.fn.writefile({ '# Local Agent' }, agent3)
    vim.fn.writefile({ 'Not an agent file' }, non_agent)

    -- Mock the home directory
    local original_homedir = vim.uv.os_homedir
    vim.uv.os_homedir = function()
      return tmpdir
    end

    local agents = config_file.get_opencode_agents()

    -- Restore original function
    vim.uv.os_homedir = original_homedir

    -- Clean up the local directory we created
    vim.fn.delete('.opencode', 'rf')

    assert.True(vim.tbl_contains(agents, 'file-agent'))
    assert.True(vim.tbl_contains(agents, 'code-reviewer'))
    assert.True(vim.tbl_contains(agents, 'local-agent'))
    assert.False(vim.tbl_contains(agents, 'not-an-agent'))
  end)

  it('deduplicates agent names', function()
    -- Write config with agent that also exists as file
    local f = assert(io.open(tmpfile, 'w'))
    f:write('{"agent": {"duplicate-agent": {}}}')
    f:close()
    config_file.config_file = tmpfile

    -- Create the expected directory structure
    local home_agent_dir = tmpdir .. '/.config/opencode/agent'
    vim.fn.mkdir(home_agent_dir, 'p')

    -- Create agent file with same name
    local agent_file = home_agent_dir .. '/duplicate-agent.md'
    vim.fn.writefile({ '# Duplicate Agent' }, agent_file)

    -- Mock homedir to point to our test directory
    local original_homedir = vim.uv.os_homedir
    vim.uv.os_homedir = function()
      return tmpdir
    end

    local agents = config_file.get_opencode_agents()

    -- Restore original function
    vim.uv.os_homedir = original_homedir

    -- Count occurrences of the duplicate agent
    local count = 0
    for _, agent in ipairs(agents) do
      if agent == 'duplicate-agent' then
        count = count + 1
      end
    end

    assert.are.equal(1, count)
  end)
end)
