local core = require('opencode.core')
local config_file = require('opencode.config_file')
local state = require('opencode.state')
local ui = require('opencode.ui.ui')
local session = require('opencode.session')
local Promise = require('opencode.promise')
local stub = require('luassert.stub')

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
    stub(ui, 'scroll_to_bottom')
    stub(ui, 'is_output_empty').returns(true)
    stub(session, 'get_last_workspace_session').returns({ id = 'test-session' })
    if session.get_by_id and type(session.get_by_id) == 'function' then
      -- stub get_by_id to return a simple session object without filesystem access
      stub(session, 'get_by_id').invokes(function(id)
        if not id then
          return nil
        end
        return { id = id, description = id, modified = os.time(), parentID = nil }
      end)
      -- stub get_by_name to return a simple session object without filesystem access
      stub(session, 'get_by_name').invokes(function(name)
        if not name then
          return nil
        end
        return { id = name, description = name, modified = os.time(), parentID = nil }
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
      'scroll_to_bottom',
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
      core.open({ new_session = false, focus = 'input' })
      assert.truthy(state.windows)
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
      core.open({ new_session = true, focus = 'input' })
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

      core.open({ new_session = false, focus = 'input' })
      assert.is_true(input_focused)
      assert.is_false(output_focused)

      input_focused, output_focused = false, false
      core.open({ new_session = false, focus = 'output' })
      assert.is_false(input_focused)
      assert.is_true(output_focused)
    end)
  end)

  describe('select_session', function()
    it('filters sessions by description and parentID', function()
      local mock_sessions = {
        { id = 'session1', description = 'First session', modified = 1, parentID = nil },
        { id = 'session2', description = '', modified = 2, parentID = nil },
        { id = 'session3', description = 'Third session', modified = 3, parentID = nil },
      }
      stub(session, 'get_all_workspace_sessions').returns(mock_sessions)
      local passed
      stub(ui, 'select_session').invokes(function(sessions, cb)
        passed = sessions
        cb(sessions[2]) -- expect session3 after filtering
      end)
      ui.render_output:revert()
      stub(ui, 'render_output')
      ui.scroll_to_bottom:revert()
      stub(ui, 'scroll_to_bottom')

      state.windows = { input_buf = 1, output_buf = 2 }
      core.select_session(nil)
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
      local new = core.create_new_session('title')
      assert.True(created_session)
      assert.truthy(new)
      assert.equal('sess-new', new.id)
      state.api_client.create_session = orig_session
    end)
  end)

  describe('opencode_ok (version checks)', function()
    local original_system
    local original_executable
    local saved_cli

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
      saved_cli = state.opencode_cli_version
    end)

    after_each(function()
      vim.system = original_system
      vim.fn.executable = original_executable
      state.opencode_cli_version = saved_cli
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
  end)
end)
