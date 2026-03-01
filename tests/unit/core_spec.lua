local core = require('opencode.core')
local config_file = require('opencode.config_file')
local config = require('opencode.config')
local state = require('opencode.state')
local ui = require('opencode.ui.ui')
local session = require('opencode.session')
local Promise = require('opencode.promise')
local stub = require('luassert.stub')
local assert = require('luassert')

-- Provide a mock api_client for tests that need it
local function mock_api_client()
  state.api_client = {
    create_session = function(_, params)
      return Promise.new():resolve({ id = params and params.title or 'new-session' })
    end,
    create_message = function(_, sess_id, _params)
      return Promise.new():resolve({ id = 'm1', sessionID = sess_id })
    end,
    abort_session = function(_, _id)
      return Promise.new():resolve(true)
    end,
    get_current_project = function()
      return Promise.new():resolve({ id = 'test-project-id' })
    end,
    get_config = function()
      return Promise.new():resolve({ model = 'gpt-4' })
    end,
  }
end

describe('opencode.core', function()
  local original_state
  local original_system
  local original_executable
  local original_schedule

  before_each(function()
    original_state = vim.deepcopy(state)
    original_system = vim.system
    original_executable = vim.fn.executable
    original_schedule = vim.schedule

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
    vim.schedule = function(fn)
      fn()
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
    stub(ui, 'is_output_empty').returns(true)
    stub(session, 'get_last_workspace_session').invokes(function()
      local p = Promise.new()
      p:resolve({ id = 'test-session' })
      return p
    end)
    if session.get_by_id and type(session.get_by_id) == 'function' then
      -- stub get_by_id to return a simple session object without filesystem access
      stub(session, 'get_by_id').invokes(function(id)
        local p = Promise.new()
        if not id then
          p:resolve(nil)
        else
          p:resolve({ id = id, title = id, modified = os.time(), parentID = nil })
        end
        return p
      end)
      -- stub get_by_name to return a simple session object without filesystem access
      stub(session, 'get_by_name').invokes(function(name)
        local p = Promise.new()
        if not name then
          p:resolve(nil)
        else
          p:resolve({ id = name, title = name, modified = os.time(), parentID = nil })
        end
        return p
      end)
    end
    mock_api_client()

    -- Mock server job to avoid trying to start real server
    state.opencode_server = {
      is_running = function()
        return true
      end,
      shutdown = function() end,
      url = 'http://127.0.0.1:4000',
    }

    -- Config is now loaded lazily, so no need to pre-seed promises
  end)

  after_each(function()
    for k, v in pairs(original_state) do
      state[k] = v
    end
    vim.system = original_system
    vim.fn.executable = original_executable
    vim.schedule = original_schedule

    for _, fn in ipairs({
      'create_windows',
      'clear_output',
      'render_output',
      'focus_input',
      'focus_output',
      'is_output_empty',
    }) do
      if ui[fn] and ui[fn].revert then
        ui[fn]:revert()
      end
    end
    if session.get_last_workspace_session.revert then
      session.get_last_workspace_session:revert()
    end
    if session.get_by_id and session.get_by_id.revert then
      session.get_by_id:revert()
    end
    if session.get_by_name and session.get_by_name.revert then
      session.get_by_name:revert()
    end
  end)

  describe('open', function()
    it("creates windows if they don't exist", function()
      state.windows = nil
      core.open({ new_session = false, focus = 'input' }):wait()
      assert.truthy(state.windows)
      assert.same({
        mock = 'windows',
        input_buf = 1,
        output_buf = 2,
        input_win = 3,
        output_win = 4,
      }, state.windows)
    end)

    it('ensure the current cwd is correct when opening', function()
      local cwd = vim.fn.getcwd()
      state.current_cwd = nil
      core.open({ new_session = false, focus = 'input' }):wait()
      assert.equal(cwd, state.current_cwd)
    end)

    it('reload the active_session if cwd has changed since last session', function()
      local original_getcwd = vim.fn.getcwd

      state.windows = nil
      state.active_session = { id = 'old-session' }
      state.current_cwd = '/some/old/path'
      vim.fn.getcwd = function()
        return '/some/new/path'
      end
      session.get_last_workspace_session:revert()
      stub(session, 'get_last_workspace_session').invokes(function()
        local p = Promise.new()
        p:resolve({ id = 'new_cwd-test-session' })
        return p
      end)

      core.open({ new_session = false, focus = 'input' }):wait()

      assert.truthy(state.active_session)
      assert.equal('new_cwd-test-session', state.active_session.id)
      -- Restore original cwd function
      vim.fn.getcwd = original_getcwd
    end)

    it('handles new session properly', function()
      state.windows = nil
      state.active_session = { id = 'old-session' }
      core.open({ new_session = true, focus = 'input' }):wait()
      assert.truthy(state.active_session)
    end)

    it('focuses the appropriate window', function()
      state.windows = nil
      ui.focus_input:revert()
      ui.focus_output:revert()
      local input_focused, output_focused = false, false
      stub(ui, 'focus_input').invokes(function()
        input_focused = true
      end)
      stub(ui, 'focus_output').invokes(function()
        output_focused = true
      end)

      core.open({ new_session = false, focus = 'input' }):wait()
      assert.is_true(input_focused)
      assert.is_false(output_focused)

      input_focused, output_focused = false, false
      core.open({ new_session = false, focus = 'output' }):wait()
      assert.is_false(input_focused)
      assert.is_true(output_focused)
    end)

    it('creates a new session when no active session and no last session exists', function()
      state.windows = nil
      state.active_session = nil
      session.get_last_workspace_session:revert()
      stub(session, 'get_last_workspace_session').invokes(function()
        local p = Promise.new()
        p:resolve(nil)
        return p
      end)

      core.open({ new_session = false, focus = 'input' }):wait()

      assert.truthy(state.active_session)
      assert.truthy(state.active_session.id)
    end)

    it('resets is_opening flag when error occurs', function()
      state.windows = nil
      state.is_opening = false

      -- Simply cause an error by stubbing a function that will be called
      local original_create_new_session = core.create_new_session
      core.create_new_session = function()
        error('Test error in create_new_session')
      end

      local notify_stub = stub(vim, 'notify')
      local result_promise = core.open({ new_session = true, focus = 'input' })

      -- Wait for async operations to complete
      local ok, err = pcall(function()
        result_promise:wait()
      end)

      -- Should fail due to the error
      assert.is_false(ok)
      assert.truthy(err)

      -- is_opening should be reset to false even when error occurs
      assert.is_false(state.is_opening)

      -- Should have notified about the error
      assert.stub(notify_stub).was_called()

      -- Restore original function
      core.create_new_session = original_create_new_session
      notify_stub:revert()
    end)
  end)

  describe('select_session', function()
    it('filters sessions by title and parentID', function()
      local mock_sessions = {
        { id = 'session1', title = 'First session', modified = 1, parentID = nil },
        { id = 'session2', title = '', modified = 2, parentID = nil },
        { id = 'session3', title = 'Third session', modified = 3, parentID = nil },
      }
      stub(session, 'get_all_workspace_sessions').invokes(function()
        local p = Promise.new()
        p:resolve(mock_sessions)
        return p
      end)
      local passed
      stub(ui, 'select_session').invokes(function(sessions, cb)
        passed = sessions
        cb(sessions[2]) -- expect session3 after filtering
      end)
      ui.render_output:revert()
      stub(ui, 'render_output')

      state.windows = { input_buf = 1, output_buf = 2 }
      core.select_session(nil):wait()
      assert.equal(2, #passed)
      assert.equal('session3', passed[2].id)
      assert.truthy(state.active_session)
      assert.equal('session3', state.active_session.id)
    end)
  end)

  describe('send_message', function()
    it('sends a message via api_client', function()
      state.windows = { mock = 'windows' }
      state.active_session = { id = 'sess1' }

      local create_called = false
      local orig = state.api_client.create_message
      state.api_client.create_message = function(_, sid, params)
        create_called = true
        assert.equal('sess1', sid)
        assert.truthy(params.parts)
        return Promise.new():resolve({ id = 'm1' })
      end

      core.send_message('hello world')
      vim.wait(50, function()
        return create_called
      end)
      assert.True(create_called)
      state.api_client.create_message = orig
    end)

    it('creates new session when none active', function()
      state.windows = { mock = 'windows' }
      state.active_session = nil

      local created_session
      local orig_session = state.api_client.create_session
      state.api_client.create_session = function(_, _params)
        created_session = true
        return Promise.new():resolve({ id = 'sess-new' })
      end

      -- override create_new_session to use api_client path synchronously
      local new = core.create_new_session('title'):wait()
      assert.True(created_session)
      assert.truthy(new)
      assert.equal('sess-new', new.id)
      state.api_client.create_session = orig_session
    end)

    it('persist options in state when sending message', function()
      local orig = state.api_client.create_message
      state.windows = { mock = 'windows' }
      state.active_session = { id = 'sess1' }

      state.api_client.create_message = function(_, sid, params)
        create_called = true
        assert.equal('sess1', sid)
        assert.truthy(params.parts)
        return Promise.new():resolve({ id = 'm1' })
      end

      core.send_message(
        'hello world',
        { context = { current_file = { enabled = false } }, agent = 'plan', model = 'test/model' }
      )
      assert.same(state.current_context_config, { current_file = { enabled = false } })
      assert.equal(state.current_mode, 'plan')
      assert.equal(state.current_model, 'test/model')
      state.api_client.create_message = orig
    end)

    it('increments and decrements user_message_count correctly', function()
      state.windows = { mock = 'windows' }
      state.active_session = { id = 'sess1' }
      state.user_message_count = {}

      -- Capture the count at different stages
      local count_before = state.user_message_count['sess1'] or 0
      local count_during = nil
      local count_after = nil

      local orig = state.api_client.create_message
      state.api_client.create_message = function(_, sid, params)
        -- Capture count while message is in flight
        count_during = state.user_message_count['sess1']
        return Promise.new():resolve({
          id = 'm1',
          info = { id = 'm1' },
          parts = {},
        })
      end

      core.send_message('hello world')

      -- Wait for promise to resolve
      vim.wait(50, function()
        count_after = state.user_message_count['sess1'] or 0
        return count_after == 0
      end)

      -- Verify: starts at 0, increments to 1, then back to 0
      assert.equal(0, count_before)
      assert.equal(1, count_during)
      assert.equal(0, count_after)

      state.api_client.create_message = orig
    end)

    it('decrements user_message_count on error', function()
      state.windows = { mock = 'windows' }
      state.active_session = { id = 'sess1' }
      state.user_message_count = {}

      -- Capture the count at different stages
      local count_before = state.user_message_count['sess1'] or 0
      local count_during = nil
      local count_after = nil

      local orig = state.api_client.create_message
      state.api_client.create_message = function(_, sid, params)
        -- Capture count while message is in flight
        count_during = state.user_message_count['sess1']
        return Promise.new():reject('Test error')
      end

      -- Stub cancel to prevent it from trying to abort the session
      local orig_cancel = core.cancel
      stub(core, 'cancel')

      core.send_message('hello world')

      -- Wait for promise to reject
      vim.wait(50, function()
        count_after = state.user_message_count['sess1'] or 0
        return count_after == 0
      end)

      -- Verify: starts at 0, increments to 1, then back to 0 even on error
      assert.equal(0, count_before)
      assert.equal(1, count_during)
      assert.equal(0, count_after)

      state.api_client.create_message = orig
      core.cancel = orig_cancel
    end)
  end)

  describe('cancel', function()
    it('aborts running session even when ui is not visible', function()
      state.windows = nil
      state.active_session = { id = 'sess1' }
      state.job_count = 1

      local abort_stub = stub(state.api_client, 'abort_session').invokes(function()
        return Promise.new():resolve(true)
      end)

      core.cancel():wait()

      assert.stub(abort_stub).was_called()
      assert.stub(ui.focus_input).was_not_called()

      abort_stub:revert()
    end)
  end)

  describe('opencode_ok (version checks)', function()
    local original_system
    local original_executable
    local original_runtime
    local saved_cli

    local function mock_vim_system(result)
      return function(_cmd, _opts, on_exit)
        if on_exit then
          result.code = 0
          on_exit(result)
        end

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
      original_runtime = vim.deepcopy(config.runtime)
      saved_cli = state.opencode_cli_version
    end)

    after_each(function()
      vim.system = original_system
      vim.fn.executable = original_executable
      state.opencode_cli_version = saved_cli
      config.runtime = original_runtime
    end)

    it('returns false when opencode executable is missing', function()
      vim.fn.executable = function(_)
        return 0
      end
      assert.is_false(core.opencode_ok():await())
    end)

    it('returns true in remote runtime mode without local executable', function()
      config.runtime.connection = 'remote'
      config.runtime.remote_url = 'http://127.0.0.1:4096'
      vim.fn.executable = function(_)
        return 0
      end

      assert.is_true(core.opencode_ok():await())
    end)

    it('returns false in remote runtime mode when remote_url is missing', function()
      config.runtime.connection = 'remote'
      config.runtime.remote_url = nil

      assert.is_false(core.opencode_ok():await())
    end)

    it('returns true when runtime command is configured and executable exists', function()
      config.runtime.command = { 'wsl.exe', '-e', 'opencode' }
      vim.fn.executable = function(cmd)
        if cmd == 'wsl.exe' then
          return 1
        end
        return 0
      end
      vim.system = mock_vim_system({ stdout = 'opencode 0.6.3' })
      state.opencode_cli_version = nil
      state.required_version = '0.6.3'
      assert.is_true(core.opencode_ok():await())
    end)

    it('checks the first runtime command token for executability', function()
      config.runtime.command = { 'custom-opencode' }
      local checked = {}
      vim.fn.executable = function(cmd)
        checked[cmd] = true
        if cmd == config.runtime.command[1] then
          return 1
        end
        return 0
      end

      vim.system = mock_vim_system({ stdout = 'opencode 0.6.3' })
      state.opencode_cli_version = nil
      state.required_version = '0.6.3'

      assert.is_true(core.opencode_ok():await())
      assert.is_true(checked[config.runtime.command[1]] == true)
    end)

    it('returns false when version is below required', function()
      vim.fn.executable = function(_)
        return 1
      end
      vim.system = mock_vim_system({ stdout = 'opencode 0.4.1' })
      state.opencode_cli_version = nil
      state.required_version = '0.4.2'
      assert.is_false(core.opencode_ok():await())
    end)

    it('returns true when version equals required', function()
      vim.fn.executable = function(_)
        return 1
      end
      vim.system = mock_vim_system({ stdout = 'opencode 0.4.2' })
      state.opencode_cli_version = nil
      state.required_version = '0.4.2'
      assert.is_true(core.opencode_ok():await())
    end)

    it('returns true when version is above required', function()
      vim.fn.executable = function(_)
        return 1
      end
      vim.system = mock_vim_system({ stdout = 'opencode 0.5.0' })
      state.opencode_cli_version = nil
      state.required_version = '0.4.2'
      assert.is_true(core.opencode_ok():await())
    end)
  end)

  describe('handle_directory_change', function()
    local server_job
    local context

    before_each(function()
      server_job = require('opencode.server_job')
      context = require('opencode.context')

      stub(context, 'unload_attachments')
    end)

    after_each(function()
      context.unload_attachments:revert()
    end)

    it('clears active session and context', function()
      state.active_session = { id = 'old-session' }
      state.last_sent_context = { some = 'context' }

      core.handle_directory_change():wait()

      -- Should be set to the new session from get_last_workspace_session stub
      assert.truthy(state.active_session)
      assert.equal('test-session', state.active_session.id)
      assert.is_nil(state.last_sent_context)
      assert.stub(context.unload_attachments).was_called()
    end)

    it('loads last workspace session for new directory', function()
      core.handle_directory_change():wait()

      assert.truthy(state.active_session)
      assert.equal('test-session', state.active_session.id)
      assert.stub(session.get_last_workspace_session).was_called()
    end)

    it('creates new session when no last session exists', function()
      -- Override stub to return nil (no last session)
      session.get_last_workspace_session:revert()
      stub(session, 'get_last_workspace_session').invokes(function()
        local p = Promise.new()
        p:resolve(nil)
        return p
      end)

      core.handle_directory_change():wait()

      assert.truthy(state.active_session)
      assert.truthy(state.active_session.id)
    end)
  end)

  describe('switch_to_mode', function()
    it('sets current model from config file when mode has a model configured', function()
      local Promise = require('opencode.promise')
      local agents_promise = Promise.new()
      agents_promise:resolve({ 'plan', 'build', 'custom' })
      local config_promise = Promise.new()
      config_promise:resolve({
        agent = {
          custom = {
            model = 'anthropic/claude-3-opus',
          },
        },
        model = 'gpt-4',
      })

      stub(config_file, 'get_opencode_agents').returns(agents_promise)
      stub(config_file, 'get_opencode_config').returns(config_promise)

      state.current_mode = nil
      state.current_model = nil
      state.user_mode_model_map = {}

      local promise = core.switch_to_mode('custom')
      local success = promise:wait()

      assert.is_true(success)
      assert.equal('custom', state.current_mode)
      assert.equal('anthropic/claude-3-opus', state.current_model)

      config_file.get_opencode_agents:revert()
      config_file.get_opencode_config:revert()
    end)

    it('returns false when mode is invalid', function()
      local Promise = require('opencode.promise')
      local agents_promise = Promise.new()
      agents_promise:resolve({ 'plan', 'build' })

      stub(config_file, 'get_opencode_agents').returns(agents_promise)

      local promise = core.switch_to_mode('nonexistent')
      local success = promise:wait()

      assert.is_false(success)

      config_file.get_opencode_agents:revert()
    end)

    it('returns false when mode is empty', function()
      local promise = core.switch_to_mode('')
      local success = promise:wait()
      assert.is_false(success)

      promise = core.switch_to_mode(nil)
      success = promise:wait()
      assert.is_false(success)
    end)

    it('respects user_mode_model_map priority: uses model stored in mode_model_map for mode', function()
      local Promise = require('opencode.promise')
      local agents_promise = Promise.new()
      agents_promise:resolve({ 'plan', 'build' })
      local config_promise = Promise.new()
      config_promise:resolve({
        agent = {
          plan = { model = 'gpt-4' },
        },
        model = 'gpt-3',
      })
      stub(config_file, 'get_opencode_agents').returns(agents_promise)
      stub(config_file, 'get_opencode_config').returns(config_promise)

      state.current_mode = nil
      state.current_model = 'should-be-overridden'
      state.user_mode_model_map = { plan = 'anthropic/claude-3-haiku' }

      local promise = core.switch_to_mode('plan')
      local success = promise:wait()
      assert.is_true(success)
      assert.equal('plan', state.current_mode)
      assert.equal('anthropic/claude-3-haiku', state.current_model)

      config_file.get_opencode_agents:revert()
      config_file.get_opencode_config:revert()
    end)

    it('falls back to config model if nothing else matches', function()
      local Promise = require('opencode.promise')
      local agents_promise = Promise.new()
      agents_promise:resolve({ 'plan', 'build' })
      local config_promise = Promise.new()
      config_promise:resolve({
        agent = {
          plan = {},
        },
        model = 'default-model',
      })
      stub(config_file, 'get_opencode_agents').returns(agents_promise)
      stub(config_file, 'get_opencode_config').returns(config_promise)
      state.current_mode = nil
      state.current_model = 'old-model'
      state.user_mode_model_map = {}
      local promise = core.switch_to_mode('plan')
      local success = promise:wait()
      assert.is_true(success)
      assert.equal('plan', state.current_mode)
      assert.equal('default-model', state.current_model)
      config_file.get_opencode_agents:revert()
      config_file.get_opencode_config:revert()
    end)
  end)
end)
