local loaded = rawget(_G, '__opencode_service_spec_loaded') or {}
_G.__opencode_service_spec_loaded = loaded
if loaded.services_session_runtime_spec then
  return
end
loaded.services_session_runtime_spec = true

local session_runtime = require('opencode.services.session_runtime')
local messaging = require('opencode.services.messaging')
local agent_model = require('opencode.services.agent_model')
local config_file = require('opencode.config_file')
local state = require('opencode.state')
local store = require('opencode.state.store')
local ui = require('opencode.ui.ui')
local session = require('opencode.session')
local Promise = require('opencode.promise')
local stub = require('luassert.stub')
local assert = require('luassert')
local flush = require('opencode.ui.renderer.flush')
local support = require('tests.unit.services_spec_support')

describe('opencode.services.session_runtime', function()
  local original

  before_each(function()
    original = support.snapshot_state()

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
      stub(session, 'get_by_id').invokes(function(id)
        local p = Promise.new()
        if not id then
          p:resolve(nil)
        else
          p:resolve({ id = id, title = id, modified = os.time(), parentID = nil })
        end
        return p
      end)
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
    support.mock_api_client()

    store.set('opencode_server', {
      is_running = function()
        return true
      end,
      shutdown = function() end,
      url = 'http://127.0.0.1:4000',
    })
  end)

  after_each(function()
    support.restore_state(original)

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
      state.ui.set_windows(nil)
      session_runtime.open({ new_session = false, focus = 'input' }):wait()
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
      state.context.set_current_cwd(nil)
      session_runtime.open({ new_session = false, focus = 'input' }):wait()
      assert.equal(cwd, state.current_cwd)
    end)

    it('reload the active_session if cwd has changed since last session', function()
      local original_getcwd = vim.fn.getcwd

      state.ui.set_windows(nil)
      state.session.set_active({ id = 'old-session' })
      state.context.set_current_cwd('/some/old/path')
      vim.fn.getcwd = function()
        return '/some/new/path'
      end
      session.get_last_workspace_session:revert()
      stub(session, 'get_last_workspace_session').invokes(function()
        local p = Promise.new()
        p:resolve({ id = 'new_cwd-test-session' })
        return p
      end)

      session_runtime.open({ new_session = false, focus = 'input' }):wait()

      assert.truthy(state.active_session)
      assert.equal('new_cwd-test-session', state.active_session.id)
      vim.fn.getcwd = original_getcwd
    end)

    it('handles new session properly', function()
      state.ui.set_windows(nil)
      state.session.set_active({ id = 'old-session' })
      session_runtime.open({ new_session = true, focus = 'input' }):wait()
      assert.truthy(state.active_session)
    end)

    it('focuses the appropriate window', function()
      state.ui.set_windows(nil)
      ui.focus_input:revert()
      ui.focus_output:revert()
      local input_focused, output_focused = false, false
      stub(ui, 'focus_input').invokes(function()
        input_focused = true
      end)
      stub(ui, 'focus_output').invokes(function()
        output_focused = true
      end)

      session_runtime.open({ new_session = false, focus = 'input' }):wait()
      assert.is_true(input_focused)
      assert.is_false(output_focused)

      input_focused, output_focused = false, false
      session_runtime.open({ new_session = false, focus = 'output' }):wait()
      assert.is_false(input_focused)
      assert.is_true(output_focused)
    end)

    it('creates a new session when no active session and no last session exists', function()
      state.ui.set_windows(nil)
      state.session.set_active(nil)
      session.get_last_workspace_session:revert()
      stub(session, 'get_last_workspace_session').invokes(function()
        local p = Promise.new()
        p:resolve(nil)
        return p
      end)

      session_runtime.open({ new_session = false, focus = 'input' }):wait()

      assert.truthy(state.active_session)
      assert.truthy(state.active_session.id)
    end)

    it('resets is_opening flag when error occurs', function()
      state.ui.set_windows(nil)
      store.set('is_opening', false)

      local original_create_new_session = session_runtime.create_new_session
      session_runtime.create_new_session = function()
        error('Test error in create_new_session')
      end

      local notify_stub = stub(vim, 'notify')
      local result_promise = session_runtime.open({ new_session = true, focus = 'input' })

      local ok, err = pcall(function()
        result_promise:wait()
      end)

      assert.is_false(ok)
      assert.truthy(err)
      assert.is_false(state.is_opening)
      assert.stub(notify_stub).was_called()

      session_runtime.create_new_session = original_create_new_session
      notify_stub:revert()
    end)
  end)

  describe('setup', function()
    it('registers key subscriptions only once across repeated setup calls', function()
      local original_opencode = package.loaded['opencode']
      package.loaded['opencode'] = nil

      local opencode = require('opencode')
      local config = require('opencode.config')
      local highlight = require('opencode.ui.highlight')
      local commands = require('opencode.commands')
      local completion = require('opencode.ui.completion')
      local keymap = require('opencode.keymap')
      local event_manager = require('opencode.event_manager')
      local context = require('opencode.context')
      local context_bar = require('opencode.ui.context_bar')
      local reference_picker = require('opencode.ui.reference_picker')
      local subscriptions = {}

      local original_subscribe = state.store.subscribe
      state.store.subscribe = function(key, cb)
        table.insert(subscriptions, key)
        return cb
      end

      local stubs = {
        stub(config, 'setup'),
        stub(highlight, 'setup'),
        stub(commands, 'setup'),
        stub(completion, 'setup'),
        stub(keymap, 'setup'),
        stub(event_manager, 'setup'),
        stub(context, 'setup'),
        stub(context_bar, 'setup'),
        stub(reference_picker, 'setup'),
        stub(session_runtime, 'opencode_ok').returns(true),
      }

      opencode.setup()
      local first_count = #subscriptions
      opencode.setup()

      for _, item in ipairs(stubs) do
        if item.revert then
          item:revert()
        end
      end
      state.store.subscribe = original_subscribe
      package.loaded['opencode'] = original_opencode

      assert.is_true(first_count > 0)
      assert.are.equal(first_count, #subscriptions)
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
        cb(sessions[2])
      end)
      ui.render_output:revert()
      stub(ui, 'render_output')

      state.ui.set_windows({ input_buf = 1, output_buf = 2 })
      session_runtime.select_session(nil):wait()
      assert.equal(2, #passed)
      assert.equal('session3', passed[2].id)
      assert.truthy(state.active_session)
      assert.equal('session3', state.active_session.id)
    end)

    it('filters child sessions by parentID', function()
      local mock_sessions = {
        { id = 'root1', title = 'Root', modified = 1, parentID = nil },
        { id = 'child1', title = 'Child 1', modified = 2, parentID = 'root1' },
        { id = 'child2', title = 'Child 2', modified = 3, parentID = 'root1' },
        { id = 'child3', title = 'Child of other', modified = 4, parentID = 'root2' },
      }
      stub(session, 'get_all_workspace_sessions').invokes(function()
        return Promise.new():resolve(mock_sessions)
      end)
      local passed
      stub(ui, 'select_session').invokes(function(sessions, cb)
        passed = sessions
        cb(nil)
      end)

      state.ui.set_windows({ input_buf = 1, output_buf = 2 })
      session_runtime.select_session('root1'):wait()
      assert.equal(2, #passed)
      assert.equal('child1', passed[1].id)
      assert.equal('child2', passed[2].id)
    end)
  end)

  describe('send_message', function()
    it('delegates message-sending coverage to services_messaging_spec', function()
      -- This spec focuses on session_runtime responsibilities.
      -- Message pipeline behavior is owned and asserted in services_messaging_spec.lua.
      assert.is_true(true)
    end)
  end)

  describe('_on_user_message_count_change', function()
    it('flushes deferred markdown render when thinking completes', function()
      local flush_stub = stub(flush, 'flush_pending_on_data_rendered')

      session_runtime._on_user_message_count_change(nil, { sess1 = 0 }, { sess1 = 1 }):wait()

      assert.stub(flush_stub).was_called()
      flush_stub:revert()
    end)

    it('restores a pending question after a full session render', function()
      local renderer = require('opencode.ui.renderer')
      local question_window = require('opencode.ui.question_window')

      state.session.set_active({ id = 'sess1' })
      state.ui.set_windows({ output_buf = 1, output_win = 2 })

      local mounted_stub = stub(require('opencode.ui.output_window'), 'mounted').returns(true)
      local fetch_stub = stub(session, 'get_messages').invokes(function()
        return Promise.new():resolve({})
      end)
      local render_stub = stub(renderer, '_render_full_session_data')
      local list_questions_stub = stub(state.api_client, 'list_questions').invokes(function()
        return Promise.new():resolve({
          {
            id = 'q1',
            sessionID = 'sess1',
            questions = {
              {
                question = 'Pick one',
                header = 'Test',
                options = { { label = 'One', description = 'first' } },
              },
            },
          },
        })
      end)
      local show_stub = stub(question_window, 'show_question')

      renderer.render_full_session():wait()

      assert.stub(show_stub).was_called()

      show_stub:revert()
      list_questions_stub:revert()
      render_stub:revert()
      fetch_stub:revert()
      mounted_stub:revert()
      state.ui.set_windows(nil)
    end)

    it('restores pending permissions after a full session render', function()
      local renderer = require('opencode.ui.renderer')
      local permission_window = require('opencode.ui.permission_window')
      local events = require('opencode.ui.renderer.events')

      state.session.set_active({ id = 'sess1' })
      state.ui.set_windows({ output_buf = 1, output_win = 2 })

      local mounted_stub = stub(require('opencode.ui.output_window'), 'mounted').returns(true)
      local fetch_stub = stub(session, 'get_messages').invokes(function()
        return Promise.new():resolve({})
      end)
      local render_stub = stub(renderer, '_render_full_session_data')
      local list_questions_stub = stub(state.api_client, 'list_questions').invokes(function()
        return Promise.new():resolve({})
      end)
      local list_permissions_stub = stub(state.api_client, 'list_permissions').invokes(function()
        return Promise.new():resolve({
          {
            id = 'perm1',
            sessionID = 'sess1',
            permission = 'bash',
            patterns = { 'echo hello' },
          },
        })
      end)
      local on_permission_stub = stub(events, 'on_permission_updated')

      renderer.render_full_session():wait()

      assert.stub(on_permission_stub).was_called_with({
        id = 'perm1',
        sessionID = 'sess1',
        permission = 'bash',
        patterns = { 'echo hello' },
      })

      on_permission_stub:revert()
      list_permissions_stub:revert()
      list_questions_stub:revert()
      render_stub:revert()
      fetch_stub:revert()
      mounted_stub:revert()
      state.ui.set_windows(nil)
    end)
  end)

  describe('markdown rendering metadata', function()
    it('stores the markdown namespace on the output buffer before rendering', function()
      local output_window = require('opencode.ui.output_window')
      local buf = vim.api.nvim_create_buf(false, true)
      local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        width = 20,
        height = 5,
        row = 0,
        col = 0,
        style = 'minimal',
      })

      state.ui.set_windows({ output_buf = buf, output_win = win })
      vim.api.nvim_buf_set_var(buf, 'opencode_markdown_namespace', 0)

      local defer_stub = stub(vim, 'defer_fn').invokes(function(cb)
        cb()
        return 1
      end)
      local original_exists = vim.fn.exists
      vim.fn.exists = function(name)
        if name == ':RenderMarkdown' then
          return 2
        end
        return original_exists(name)
      end
      local cmd_stub = stub(vim, 'cmd')

      flush.trigger_on_data_rendered()

      assert.equals(output_window.markdown_namespace, vim.b[buf].opencode_markdown_namespace)
      assert.stub(cmd_stub).was_called_with(':RenderMarkdown buf_enable')

      cmd_stub:revert()
      defer_stub:revert()
      vim.fn.exists = original_exists
      state.ui.set_windows(nil)
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)
  end)

  describe('cancel', function()
    it('aborts running session even when ui is not visible', function()
      state.ui.set_windows(nil)
      state.session.set_active({ id = 'sess1' })
      store.set('job_count', 1)

      local abort_stub = stub(state.api_client, 'abort_session').invokes(function()
        return Promise.new():resolve(true)
      end)

      session_runtime.cancel():wait()

      assert.stub(abort_stub).was_called()
      assert.stub(ui.focus_input).was_not_called()

      abort_stub:revert()
    end)
  end)

  describe('opencode_ok (version checks)', function()
    local original_system
    local original_executable
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
      saved_cli = state.opencode_cli_version
    end)

    after_each(function()
      vim.system = original_system
      vim.fn.executable = original_executable
      state.jobs.set_opencode_cli_version(saved_cli)
    end)

    it('returns false when opencode executable is missing', function()
      vim.fn.executable = function(_)
        return 0
      end
      assert.is_false(session_runtime.opencode_ok():await())
    end)

    it('returns false when version is below required', function()
      vim.fn.executable = function(_)
        return 1
      end
      vim.system = mock_vim_system({ stdout = 'opencode 0.4.1' })
      state.jobs.set_opencode_cli_version(nil)
      store.set('required_version', '0.4.2')
      assert.is_false(session_runtime.opencode_ok():await())
    end)

    it('returns true when version equals required', function()
      vim.fn.executable = function(_)
        return 1
      end
      vim.system = mock_vim_system({ stdout = 'opencode 0.4.2' })
      state.jobs.set_opencode_cli_version(nil)
      store.set('required_version', '0.4.2')
      assert.is_true(session_runtime.opencode_ok():await())
    end)

    it('returns true when version is above required', function()
      vim.fn.executable = function(_)
        return 1
      end
      vim.system = mock_vim_system({ stdout = 'opencode 0.5.0' })
      state.jobs.set_opencode_cli_version(nil)
      store.set('required_version', '0.4.2')
      assert.is_true(session_runtime.opencode_ok():await())
    end)
  end)

  describe('handle_directory_change', function()
    local context

    before_each(function()
      context = require('opencode.context')
      stub(context, 'unload_attachments')
    end)

    after_each(function()
      context.unload_attachments:revert()
    end)

    it('clears active session and context', function()
      state.session.set_active({ id = 'old-session' })
      state.session.set_last_sent_context({ some = 'context' })

      session_runtime.handle_directory_change():wait()

      assert.truthy(state.active_session)
      assert.equal('test-session', state.active_session.id)
      assert.is_nil(state.last_sent_context)
      assert.stub(context.unload_attachments).was_called()
    end)

    it('loads last workspace session for new directory', function()
      session_runtime.handle_directory_change():wait()

      assert.truthy(state.active_session)
      assert.equal('test-session', state.active_session.id)
      assert.stub(session.get_last_workspace_session).was_called()
    end)

    it('creates new session when no last session exists', function()
      session.get_last_workspace_session:revert()
      stub(session, 'get_last_workspace_session').invokes(function()
        local p = Promise.new()
        p:resolve(nil)
        return p
      end)

      session_runtime.handle_directory_change():wait()

      assert.truthy(state.active_session)
      assert.truthy(state.active_session.id)
    end)
  end)

  describe('switch_to_mode', function()
    it('delegates model/mode switch coverage to services_agent_model_spec', function()
      assert.is_true(true)
    end)
  end)

  describe('initialize_current_model', function()
    -- Keep only integration-level guardrails here; detailed behavior stays in services_agent_model_spec.lua.
    it('keeps the current user-selected model and mode by default', function()
      state.model.set_model('openai/gpt-4.1')
      state.model.set_mode('plan')
      state.renderer.set_messages({
        {
          info = {
            id = 'm1',
            providerID = 'anthropic',
            modelID = 'claude-3-opus',
            mode = 'build',
          },
        },
      })

      local model = agent_model.initialize_current_model():wait()

      assert.equal('openai/gpt-4.1', model)
      assert.equal('openai/gpt-4.1', state.current_model)
      assert.equal('plan', state.current_mode)
    end)

    it('restores the latest session model and mode when explicitly requested', function()
      state.model.set_model('openai/gpt-4.1')
      state.model.set_mode('plan')
      state.renderer.set_messages({
        {
          info = {
            id = 'm1',
            providerID = 'anthropic',
            modelID = 'claude-3-opus',
            mode = 'build',
          },
        },
      })

      local model = agent_model.initialize_current_model({ restore_from_messages = true }):wait()

      assert.equal('anthropic/claude-3-opus', model)
      assert.equal('anthropic/claude-3-opus', state.current_model)
      assert.equal('build', state.current_mode)
    end)
  end)
end)
