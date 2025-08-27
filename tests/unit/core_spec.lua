local core = require('opencode.core')
local state = require('opencode.state')
local ui = require('opencode.ui.ui')
local session = require('opencode.session')
local job = require('opencode.job')

describe('opencode.core', function()
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
  local original_state
  local original_system
  local original_executable

  before_each(function()
    original_state = vim.deepcopy(state)
    original_system = vim.system
    original_executable = vim.fn.executable

    -- Mock vim.system and executable for opencode_ok() calls
    vim.fn.executable = function(_)
      return 1
    end
    vim.system = function(_cmd, _opts)
      return {
        wait = function()
          return { stdout = 'opencode 0.4.3' }
        end,
      }
    end

    -- Mock required functions
    ui.create_windows = function()
      return {
        mock = 'windows',
        input_buf = 1,
        output_buf = 2,
        input_win = 3,
        output_win = 4,
      }
    end
    ui.clear_output = function() end
    ui.render_output = function() end
    ui.focus_input = function() end
    ui.focus_output = function() end
    ui.scroll_to_bottom = function() end
    ui.is_output_empty = function()
      return true
    end
    session.get_last_workspace_session = function()
      return { id = 'test-session' }
    end
    job.execute = function() end
  end)

  after_each(function()
    -- Restore state
    for k, v in pairs(original_state) do
      state[k] = v
    end
    -- Restore vim functions
    vim.system = original_system
    vim.fn.executable = original_executable
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
      ui.clear_output = function()
        ui_clear_called = true
      end

      core.open({ new_session = true, focus = 'input' })

      assert.is_nil(state.active_session)
      assert.is_true(ui_clear_called)
    end)

    it('focuses the appropriate window', function()
      state.windows = nil

      local input_focused = false
      local output_focused = false

      ui.focus_input = function()
        input_focused = true
      end
      ui.focus_output = function()
        output_focused = true
      end

      core.open({ new_session = false, focus = 'input' })
      assert.is_true(input_focused)
      assert.is_false(output_focused)

      -- Reset
      input_focused = false
      output_focused = false

      core.open({ new_session = false, focus = 'output' })
      assert.is_false(input_focused)
      assert.is_true(output_focused)
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

      -- Mock get_all_workspace_sessions to return our mock data
      session.get_all_workspace_sessions = function()
        return mock_sessions
      end

      -- Mock ui.select_session to simulate user selection
      local filtered_sessions_passed
      local callback_passed

      ui.select_session = function(sessions, callback)
        filtered_sessions_passed = sessions
        callback_passed = callback

        -- Simulate user selecting the third session
        callback(sessions[2]) -- This should be session3 after filtering
      end

      -- Mock render_output to verify it's called
      local render_output_called = false
      ui.render_output = function()
        render_output_called = true
      end

      local scroll_to_bottom_called = false
      ui.scroll_to_bottom = function()
        scroll_to_bottom_called = true
      end

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
    end)

    it('handles case where no windows exist', function()
      -- Mock sessions data
      local mock_sessions = {
        { name = 'session1', description = 'First session', modified = '2025-04-01' },
      }

      -- Mock get_all_workspace_sessions to return our mock data
      session.get_all_workspace_sessions = function()
        return mock_sessions
      end

      -- Mock ui.select_session to simulate user selection
      ui.select_session = function(sessions, callback)
        callback(sessions[1])
      end

      -- Mock functions that would be called by open()
      local open_called = false
      local original_open = core.open
      core.open = function()
        open_called = true
        state.windows = ui.create_windows()
      end

      -- Set up state for the test
      state.windows = nil
      state.active_session = nil

      -- Call the function being tested
      core.select_session()

      -- Restore original open function
      core.open = original_open

      -- Verify active session was set
      assert.truthy(state.active_session, 'Active session should be set')
      assert.equal('session1', state.active_session.name, 'Active session should match selected session')

      -- Verify open was called when windows don't exist
      assert.is_true(open_called, "core.open should be called when windows don't exist")
    end)
  end)

  describe('run', function()
    it('executes a job with the provided prompt', function()
      state.windows = { mock = 'windows' }

      local original_defer_fn = vim.defer_fn
      vim.defer_fn = function(callback, timeout)
        -- Execute the callback immediately for testing
        callback()
      end

      local job_execute_called = false
      local execute_prompt = nil
      local execute_handlers = nil

      job.execute = function(prompt, handlers)
        job_execute_called = true
        execute_prompt = prompt
        execute_handlers = handlers
        -- Call the start handler to simulate job start
        if handlers and handlers.on_start then
          handlers.on_start()
        end
      end

      core.run('test prompt')

      -- Restore original function
      vim.defer_fn = original_defer_fn

      assert.is_true(job_execute_called)
      assert.equal('test prompt', execute_prompt)
      assert.truthy(execute_handlers)
    end)

    it('creates UI when running a job even without ensure_ui option', function()
      state.windows = nil

      local windows_created = false
      ui.create_windows = function()
        windows_created = true
        return { mock = 'windows' }
      end

      core.run('test prompt')

      assert.is_true(windows_created)
      assert.truthy(state.windows)
    end)

    it('respects new_session option when creating UI', function()
      state.windows = nil
      state.active_session = { id = 'old-session' }

      local ui_clear_called = false
      ui.clear_output = function()
        ui_clear_called = true
      end

      core.run('test prompt', { new_session = true })

      assert.is_nil(state.active_session)
      assert.is_true(ui_clear_called)
    end)

    it('respects new_session option even when UI already exists', function()
      state.windows = { mock = 'windows' }
      state.active_session = { id = 'old-session' }

      core.run('test prompt', { new_session = true })

      assert.is_nil(state.active_session, 'Active session should be nil when new_session is true')
    end)

    it('defaults to creating a new session when active_session is nil', function()
      state.windows = nil
      state.active_session = nil

      local open_new_session_called = false
      local open_new_session_param = nil

      -- Save original open function
      local original_open = core.open

      -- Mock the open function
      core.open = function(opts)
        open_new_session_called = true
        open_new_session_param = opts.new_session

        -- Call the original to maintain functionality
        state.windows = ui.create_windows()
      end

      core.run('test prompt')

      -- Restore original open function
      core.open = original_open

      assert.is_true(open_new_session_called)
      assert.is_true(open_new_session_param)
    end)
  end)
end)
