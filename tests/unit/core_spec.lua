local core = require('opencode.core')
local state = require('opencode.state')
local ui = require('opencode.ui.ui')
local session = require('opencode.session')
local job = require('opencode.server_job')
local api = require('opencode.api')
local Promise = require('opencode.promise')
local stub = require('luassert.stub')

describe('opencode.core', function()
  local original_api_create_session

  local original_state
  local original_system
  local original_executable

  before_each(function()
    original_state = vim.deepcopy(state)
    original_system = vim.system
    original_executable = vim.fn.executable
    original_api_create_session = api.create_session

    -- Mock vim.system and executable for opencode_ok() calls
    vim.fn.executable = function(_)
      return 1
    end
    vim.system = function(_cmd, _opts)
      return {
        wait = function()
          return { stdout = 'opencode 0.6.3' }
        end,
      }
    end

    stub(ui, 'create_windows').returns({
      mock = 'windows',
      input_buf = 1,
      output_buf = 2,
      input_win = 3,
      output_win = 4,
    })
    stub(ui, 'clear_output')
    stub(ui, 'render_output')
    stub(ui, 'focus_input')
    stub(ui, 'focus_output')
    stub(ui, 'scroll_to_bottom')
    stub(ui, 'is_output_empty').returns(true)
    stub(session, 'get_last_workspace_session').returns({ id = 'test-session' })
    stub(job, 'execute')
  end)

  after_each(function()
    -- Restore state
    for k, v in pairs(original_state) do
      state[k] = v
    end
    -- Restore vim functions
    vim.system = original_system
    vim.fn.executable = original_executable
    api.create_session = original_api_create_session
    -- Revert all stubs
    if ui.create_windows.revert then
      ui.create_windows:revert()
    end
    if ui.clear_output.revert then
      ui.clear_output:revert()
    end
    if ui.render_output.revert then
      ui.render_output:revert()
    end
    if ui.focus_input.revert then
      ui.focus_input:revert()
    end
    if ui.focus_output.revert then
      ui.focus_output:revert()
    end
    if ui.scroll_to_bottom.revert then
      ui.scroll_to_bottom:revert()
    end
    if ui.is_output_empty.revert then
      ui.is_output_empty:revert()
    end
    if session.get_last_workspace_session.revert then
      session.get_last_workspace_session:revert()
    end
    if job.execute.revert then
      job.execute:revert()
    end
  end)

  describe('open', function()
    it("creates windows if they don't exist", function()
      state.windows = nil

      core.open({ new_session = false, focus = 'input' })

      assert.truthy(state.windows, 'Windows should be created')
      -- Fix the expected output to match mocked window structure
      assert.same({
        mock = 'windows',
        input_buf = 1,
        output_buf = 2,
        input_win = 3,
        output_win = 4,
      }, state.windows)
    end)

    it('handles new session properly', function()
      state.windows = nil
      state.active_session = { id = 'old-session' }

      local ui_clear_called = false
      ui.clear_output:revert() -- Remove previous stub
      stub(ui, 'clear_output').invokes(function()
        ui_clear_called = true
      end)

      core.open({ new_session = true, focus = 'input' })

      assert.is_nil(state.active_session)
      assert.is_true(ui_clear_called)
      ui.clear_output:revert()
      stub(ui, 'clear_output')
    end)

    it('focuses the appropriate window', function()
      state.windows = nil

      local input_focused = false
      local output_focused = false

      ui.focus_input:revert()
      ui.focus_output:revert()
      stub(ui, 'focus_input').invokes(function()
        input_focused = true
      end)
      stub(ui, 'focus_output').invokes(function()
        output_focused = true
      end)

      core.open({ new_session = false, focus = 'input' })
      assert.is_true(input_focused)
      assert.is_false(output_focused)

      -- Reset
      input_focused = false
      output_focused = false

      core.open({ new_session = false, focus = 'output' })
      assert.is_false(input_focused)
      assert.is_true(output_focused)
      ui.focus_input:revert()
      ui.focus_output:revert()
      stub(ui, 'focus_input')
      stub(ui, 'focus_output')
    end)
  end)

  describe('select_session', function()
    it('filters sessions and sets the active session based on user selection', function()
      -- Mock sessions data
      local mock_sessions = {
        { name = 'session1', description = 'First session', modified = '2025-04-01' },
        { name = 'session2', description = '', modified = '2025-04-02' }, -- This one should be filtered out
        { name = 'session3', description = 'Third session', modified = '2025-04-03' },
      }

      stub(session, 'get_all_workspace_sessions').returns(mock_sessions)

      -- Mock ui.select_session to simulate user selection
      local filtered_sessions_passed
      stub(ui, 'select_session').invokes(function(sessions, callback)
        filtered_sessions_passed = sessions
        -- Simulate user selecting the third session
        callback(sessions[2]) -- This should be session3 after filtering
      end)

      -- Mock render_output to verify it's called
      local render_output_called = false
      stub(ui, 'render_output').invokes(function()
        render_output_called = true
      end)

      local scroll_to_bottom_called = false
      stub(ui, 'scroll_to_bottom').invokes(function()
        scroll_to_bottom_called = true
      end)

      -- Set up state for the test
      state.windows = {
        input_buf = 1,
        output_buf = 2,
        input_win = 3,
        output_win = 4,
      }
      state.active_session = nil

      -- Call the function being tested
      core.select_session()

      -- Verify results
      assert.truthy(filtered_sessions_passed, 'Sessions should be passed to UI select')
      assert.equal(2, #filtered_sessions_passed, 'Empty descriptions should be filtered out')
      assert.equal('session3', filtered_sessions_passed[2].name, 'Session should be in filtered list')

      -- Verify active session was set
      assert.truthy(state.active_session, 'Active session should be set')
      assert.equal('session3', state.active_session.name, 'Active session should match selected session')

      -- Verify output is rendered
      assert.is_true(render_output_called, 'Output should be rendered')
      assert.is_true(scroll_to_bottom_called, 'Windows should scroll to bottom')

      -- After test, revert stubs
      session.get_all_workspace_sessions:revert()
      ui.select_session:revert()
      ui.render_output:revert()
      ui.scroll_to_bottom:revert()
    end)

    it('handles case where no windows exist', function()
      -- Mock sessions data
      local mock_sessions = {
        { name = 'session1', description = 'First session', modified = '2025-04-01' },
      }

      stub(session, 'get_all_workspace_sessions').returns(mock_sessions)

      stub(ui, 'select_session').invokes(function(sessions, callback)
        callback(sessions[1])
      end)

      -- Mock functions that would be called by open()
      local open_called = false
      stub(core, 'open').invokes(function()
        open_called = true
        state.windows = ui.create_windows()
      end)

      -- Set up state for the test
      state.windows = nil
      state.active_session = nil

      -- Call the function being tested
      core.select_session()

      -- Verify active session was set
      assert.truthy(state.active_session, 'Active session should be set')
      assert.equal('session1', state.active_session.name, 'Active session should match selected session')

      -- Verify open was called when windows don't exist
      assert.is_true(open_called, "core.open should be called when windows don't exist")

      -- After test, revert stubs
      session.get_all_workspace_sessions:revert()
      ui.select_session:revert()
      core.open:revert()
    end)
  end)

  describe('send_message', function()
    it('executes a job with the provided prompt', function()
      state.windows = { mock = 'windows' }
      state.active_session = { name = 'test-session' }

      local job_execute_called = false
      local execute_endpoint = nil
      local execute_handlers = nil
      local execute_method = nil

      stub(job, 'run').invokes(function(endpoint, method, body, handlers)
        job_execute_called = true
        execute_endpoint = endpoint
        execute_handlers = handlers
        execute_method = method
        -- Call the start handler to simulate job start
        if handlers and handlers.on_ready then
          handlers.on_ready(nil, 'http://localhost:1234')
        end
      end)

      core.send_message('test prompt')

      assert.is_true(job_execute_called)
      assert.equal('/session/test-session/message', execute_endpoint)
      assert.equal('POST', execute_method)
      assert.truthy(execute_handlers)

      job.run:revert()
    end)

    it('respects new_session option even when session already exists', function()
      state.active_session = { id = 'old-session' }
      stub(core, 'create_new_session').returns(Promise.new():resolve({ name = 'new-session' }))

      stub(job, 'run').invokes(function(endpoint, method, body, handlers)
        if handlers and handlers.on_ready then
          handlers.on_ready(nil, 'http://localhost:1234')
        end
      end)

      core.send_message('test prompt', { new_session = true })

      assert.are_equal('new-session', state.active_session.name)
      job.run:revert()
      core.create_new_session:revert()
    end)

    it('defaults to creating a new session when active_session is nil', function()
      state.windows = nil
      state.active_session = nil
      stub(core, 'create_new_session').returns(Promise.new():resolve({ name = 'new-session' }))

      stub(job, 'run').invokes(function(endpoint, method, body, handlers)
        if handlers and handlers.on_ready then
          handlers.on_ready(nil, 'http://localhost:1234')
        end
      end)

      core.send_message('test prompt')
      assert.are_equal('new-session', state.active_session.name)
      job.run:revert()
      core.create_new_session:revert()
    end)
  end)

  describe('opencode_ok (version checks)', function()
    local original_system
    local original_executable
    local original_state

    local function mock_vim_system(result)
      return function(_cmd, _opts)
        return {
          wait = function()
            return result
          end,
        }
      end
    end

    before_each(function()
      original_system = vim.system
      original_executable = vim.fn.executable
      original_state = { cli = state.opencode_cli_version, req = state.required_version }
    end)

    after_each(function()
      vim.system = original_system
      vim.fn.executable = original_executable
      state.opencode_cli_version = original_state.cli
      state.required_version = original_state.req
    end)

    it('returns false when opencode executable is missing', function()
      vim.fn.executable = function(_)
        return 0
      end
      assert.is_false(core.opencode_ok())
    end)

    it('returns false when version is below required', function()
      vim.fn.executable = function(_)
        return 1
      end
      vim.system = mock_vim_system({ stdout = 'opencode 0.4.1' })
      state.opencode_cli_version = nil
      state.required_version = '0.4.2'
      assert.is_false(core.opencode_ok())
    end)

    it('returns true when version equals required', function()
      vim.fn.executable = function(_)
        return 1
      end
      vim.system = mock_vim_system({ stdout = 'opencode 0.4.2' })
      state.opencode_cli_version = nil
      state.required_version = '0.4.2'
      assert.is_true(core.opencode_ok())
    end)

    it('returns true when version is above required', function()
      vim.fn.executable = function(_)
        return 1
      end
      vim.system = mock_vim_system({ stdout = 'opencode 0.5.0' })
      state.opencode_cli_version = nil
      state.required_version = '0.4.2'
      assert.is_true(core.opencode_ok())
    end)

    it('caches detected CLI version', function()
      vim.fn.executable = function(_)
        return 1
      end
      local calls = 0
      vim.system = function(_)
        calls = calls + 1
        return mock_vim_system({ stdout = '0.4.3' })()
      end
      state.opencode_cli_version = nil
      state.required_version = '0.4.2'
      assert.is_true(core.opencode_ok())
      assert.is_true(core.opencode_ok())
      assert.equal(1, calls)
    end)
  end)
end)
