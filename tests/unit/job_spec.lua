local job = require('opencode.job')
local config = require('opencode.config')
local state = require('opencode.state')
local Job = require('plenary.job')
local helpers = require('tests.helpers')

describe('opencode.job', function()
  local test_file, buf_id
  local original_config
  local original_state

  -- Save original functions and config before each test
  before_each(function()
    original_config = vim.deepcopy(config.values)
    original_state = vim.deepcopy(state)

    -- Create a temporary test file
    test_file = helpers.create_temp_file('Test file content\nLine 2\nLine 3')
    buf_id = helpers.open_buffer(test_file)

    -- Set up state for testing
    state.current_file = test_file
    state.active_session = nil
  end)

  -- Restore original functions and config after each test
  after_each(function()
    config.values = original_config

    -- Restore state
    for k, v in pairs(original_state) do
      state[k] = v
    end

    -- Clean up
    pcall(function()
      if buf_id and vim.api.nvim_buf_is_valid(buf_id) then
        helpers.close_buffer(buf_id)
      end
      if test_file then
        helpers.delete_temp_file(test_file)
      end
    end)
    helpers.reset_editor()
  end)

  it('builds a command with the provided prompt', function()
    local prompt = 'Help me understand this code'
    local args = job.build_args(prompt)

    -- Check basic components are in the args table
    assert.is_not_nil(args)
    assert.truthy(#args >= 2, 'Args table should have at least 2 elements')
    assert.equal('run', args[1])
    assert.equal(prompt, args[2])
  end)

  it('builds a command with the provided session opt', function()
    local test_session = {
      name = 'test-session-123',
      path = '/mock/session/path',
      modified = '2025-04-04',
    }
    -- Set up the active session
    state.active_session = test_session

    local prompt = 'Help me understand this code'
    local args = job.build_args(prompt)

    -- Find the "-s" argument and check value
    local name_index = nil
    local resume_found = false

    for i, arg in ipairs(args) do
      if arg == '-s' then
        name_index = i
      end
    end

    assert.truthy(name_index, 'Should include -s argument')
    assert.equal('test-session-123', args[name_index + 1], 'Session ID should match active session name')
  end)

  it('properly stops a running job', function()
    -- Create a mock job
    local mock_job = {
      handle = {},
      pid = 12345,
      shutdown = function() end,
    }

    -- Set up spies
    local process_kill_called = false
    local shutdown_called = false

    -- Save original functions
    local original_process_kill = vim.uv and vim.uv.process_kill or vim.loop.process_kill

    -- Mock function for process_kill
    if vim.uv then
      vim.uv.process_kill = function(handle)
        process_kill_called = true
        assert.equal(mock_job.handle, handle, 'Should use the correct handle')
      end
    else
      vim.loop.process_kill = function(handle)
        process_kill_called = true
        assert.equal(mock_job.handle, handle, 'Should use the correct handle')
      end
    end

    -- Mock shutdown method
    mock_job.shutdown = function()
      shutdown_called = true
    end

    -- Set the mock job in the state
    state.opencode_run_job = mock_job

    -- Call the function we're testing
    job.stop(mock_job)

    -- Restore original function
    if vim.uv then
      vim.uv.process_kill = original_process_kill
    else
      vim.loop.process_kill = original_process_kill
    end

    -- Verify results
    assert.is_true(process_kill_called, 'process_kill should be called')
    assert.is_true(shutdown_called, 'job:shutdown should be called')
  end)
end)
