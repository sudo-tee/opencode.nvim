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
local config = require('opencode.config')
local state = require('opencode.state')
local store = require('opencode.state.store')
local ui = require('opencode.ui.ui')
local Promise = require('opencode.promise')
local stub = require('luassert.stub')
local assert = require('luassert')
local flush = require('opencode.ui.renderer.flush')
local support = require('tests.unit.services_spec_support')

describe('opencode.services.session_runtime', function()
  local original

  local function set_session_fact(session_id, parent_id)
    local connection = state.opencode_server
    connection.session_facts[session_id] = { id = session_id, parentID = parent_id }
    connection.observations[session_id] = nil
  end

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
    support.mock_connection()
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
      state.opencode_server.operations.list_sessions_project = function()
        return Promise.new():resolve({
          { id = 'new_cwd-test-session', title = 'new', time = { updated = 3 } },
        })
      end

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
      state.opencode_server.operations.list_sessions_project = function()
        return Promise.new():resolve({})
      end

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
        { id = 'session1', title = 'First session', time = { updated = 1 }, parentID = nil },
        { id = 'session2', title = '', time = { updated = 2 }, parentID = nil },
        { id = 'session3', title = 'Third session', time = { updated = 3 }, parentID = nil },
      }
      state.opencode_server.operations.list_sessions_project = function()
        return Promise.new():resolve(mock_sessions)
      end
      local passed
      stub(require('opencode.ui.session_picker'), 'select').invokes(function(sessions, cb)
        passed = sessions
        cb(sessions[1])
      end)
      ui.render_output:revert()
      stub(ui, 'render_output')

      state.ui.set_windows({ input_buf = 1, output_buf = 2 })
      session_runtime.select_session(nil):wait()
      assert.equal(2, #passed)
      assert.equal('session3', passed[1].id)
      assert.truthy(state.active_session)
      assert.equal('session3', state.active_session.id)
    end)

    it('filters child sessions by parentID', function()
      local mock_sessions = {
        { id = 'root1', title = 'Root', time = { updated = 1 }, parentID = nil },
        { id = 'child1', title = 'Child 1', time = { updated = 2 }, parentID = 'root1' },
        { id = 'child2', title = 'Child 2', time = { updated = 3 }, parentID = 'root1' },
        { id = 'child3', title = 'Child of other', time = { updated = 4 }, parentID = 'root2' },
      }
      state.opencode_server.operations.list_sessions_project = function()
        return Promise.new():resolve(mock_sessions)
      end
      local passed
      stub(require('opencode.ui.session_picker'), 'select').invokes(function(sessions, cb)
        passed = sessions
        cb(nil)
      end)

      state.ui.set_windows({ input_buf = 1, output_buf = 2 })
      session_runtime.select_session('root1'):wait()
      assert.equal(2, #passed)
      assert.equal('child2', passed[1].id)
      assert.equal('child1', passed[2].id)
    end)
  end)

  describe('list_sessions_by_scope', function()
    it('starts the server when listing sessions before the panel opens', function()
      local server_job = require('opencode.server_job')
      local connection = state.opencode_server
      local ensure_server = stub(server_job, 'ensure_server').returns(Promise.new():resolve(connection))
      state.jobs.clear_server()

      local sessions = session_runtime.list_sessions_by_scope('project'):wait()

      assert.is_table(sessions)
      assert.stub(ensure_server).was_called()
      ensure_server:revert()
    end)
  end)

  describe('switch_session', function()
    local input_window = require('opencode.ui.input_window')

    it('hides input window when switching to a child session', function()
      set_session_fact('child1', 'parent1')
      state.ui.set_windows({ mock = 'windows', input_buf = 1, output_buf = 2, input_win = 3, output_win = 4 })
      local orig_is_visible = state.ui.is_visible
      state.ui.is_visible = function()
        return true
      end
      stub(input_window, 'is_hidden').returns(false)
      stub(input_window, '_hide')

      session_runtime.switch_session('child1'):wait()

      assert.stub(input_window._hide).was_called()
      assert.stub(ui.focus_output).was_called()

      input_window.is_hidden:revert()
      input_window._hide:revert()
      state.ui.is_visible = orig_is_visible
    end)

    it('shows input window when switching to a non-child session', function()
      set_session_fact('root1', nil)
      state.ui.set_windows({ mock = 'windows', input_buf = 1, output_buf = 2, input_win = 3, output_win = 4 })
      local orig_is_visible = state.ui.is_visible
      state.ui.is_visible = function()
        return true
      end
      stub(input_window, 'is_hidden').returns(true)
      stub(input_window, '_show')

      session_runtime.switch_session('root1'):wait()

      assert.stub(input_window._show).was_called()
      assert.stub(ui.focus_input).was_called()

      input_window.is_hidden:revert()
      input_window._show:revert()
      state.ui.is_visible = orig_is_visible
    end)

    it('does not hide input when already hidden on child session switch', function()
      set_session_fact('child1', 'parent1')
      state.ui.set_windows({ mock = 'windows', input_buf = 1, output_buf = 2, input_win = 3, output_win = 4 })
      local orig_is_visible = state.ui.is_visible
      state.ui.is_visible = function()
        return true
      end
      stub(input_window, 'is_hidden').returns(true)
      stub(input_window, '_hide')

      session_runtime.switch_session('child1'):wait()

      assert.stub(input_window._hide).was_not_called()
      assert.stub(ui.focus_output).was_called()

      input_window.is_hidden:revert()
      input_window._hide:revert()
      state.ui.is_visible = orig_is_visible
    end)
  end)

  describe('cancel', function()
    after_each(function()
      vim.g.opencode_abort_count = nil
    end)

    it('interrupts the captured active Observation', function()
      state.session.set_active({ id = 'session_to_interrupt' })
      local observation = state.session.active_observation()
      local interrupt = stub(observation, 'interrupt').returns(Promise.new():resolve(true))
      vim.g.opencode_abort_count = 0

      session_runtime.cancel():wait()

      assert.stub(interrupt).was_called(1)
      interrupt:revert()
    end)
  end)

  describe('child session UI guards', function()
    local input_window = require('opencode.ui.input_window')

    after_each(function()
      state.session.clear_active()
    end)

    it('toggle_pane does not show input when in a child session', function()
      set_session_fact('child1', 'parent1')
      state.session.set_active({ id = 'child1' })
      stub(input_window, 'focus_input')

      -- Simulate being in the output window (not input)
      state.ui.set_windows({
        input_win = -1,
        output_win = vim.api.nvim_get_current_win(),
        input_buf = 1,
        output_buf = 2,
      })

      ui.toggle_pane()

      assert.stub(input_window.focus_input).was_not_called()
      input_window.focus_input:revert()
    end)

    it('focus_input is a no-op when in a child session', function()
      set_session_fact('child1', 'parent1')
      state.session.set_active({ id = 'child1' })
      stub(input_window, 'is_hidden').returns(true)
      stub(input_window, '_show')

      ui.focus_input()

      assert.stub(input_window._show).was_not_called()
      input_window.is_hidden:revert()
      input_window._show:revert()
    end)

    it('toggle_pane shows input when child_readonly is false', function()
      set_session_fact('child1', 'parent1')
      state.session.set_active({ id = 'child1' })
      local config = require('opencode.config')
      local orig_readonly = config.values.child_readonly
      config.values.child_readonly = false
      stub(input_window, 'focus_input')

      state.ui.set_windows({
        input_win = -1,
        output_win = vim.api.nvim_get_current_win(),
        input_buf = 1,
        output_buf = 2,
      })

      ui.toggle_pane()

      assert.stub(input_window.focus_input).was_called()
      input_window.focus_input:revert()
      config.values.child_readonly = orig_readonly
    end)

    it('focus_input works when child_readonly is false', function()
      state.ui.set_windows({ mock = 'windows', input_buf = 1, output_buf = 2 })
      set_session_fact('child1', 'parent1')
      state.session.set_active({ id = 'child1' })
      local config = require('opencode.config')
      local orig_readonly = config.values.child_readonly
      config.values.child_readonly = false

      -- Revert the before_each stub so we call the real focus_input
      ui.focus_input:revert()

      local reached_is_hidden = false
      local orig_is_hidden = input_window.is_hidden
      input_window.is_hidden = function()
        reached_is_hidden = true
        return true
      end
      local orig_show = input_window._show
      input_window._show = function() end

      ui.focus_input()

      assert.is_true(reached_is_hidden)
      input_window.is_hidden = orig_is_hidden
      input_window._show = orig_show
      config.values.child_readonly = orig_readonly
      -- Re-stub for after_each cleanup
      stub(ui, 'focus_input')
    end)

    it('switch_session does not hide input when child_readonly is false', function()
      set_session_fact('child1', 'parent1')
      state.ui.set_windows({ mock = 'windows', input_buf = 1, output_buf = 2, input_win = 3, output_win = 4 })
      local orig_is_visible = state.ui.is_visible
      state.ui.is_visible = function()
        return true
      end
      local config = require('opencode.config')
      local orig_readonly = config.values.child_readonly
      config.values.child_readonly = false

      stub(input_window, 'is_hidden').returns(false)
      stub(input_window, '_hide')

      session_runtime.switch_session('child1'):wait()

      assert.stub(input_window._hide).was_not_called()
      assert.stub(ui.focus_input).was_called()

      input_window.is_hidden:revert()
      input_window._hide:revert()
      state.ui.is_visible = orig_is_visible
      config.values.child_readonly = orig_readonly
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
  end)

  describe('markdown rendering metadata', function()
    it('defers markdown rendering until the output tab becomes current', function()
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

      local output_tab = vim.api.nvim_get_current_tabpage()
      vim.cmd('tabnew')
      local current_tab = vim.api.nvim_get_current_tabpage()
      local current_win = vim.api.nvim_get_current_win()

      local defer_stub = stub(vim, 'defer_fn').invokes(function(cb)
        cb()
        return {
          is_closing = function()
            return false
          end,
          close = function() end,
        }
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
      assert.stub(cmd_stub).was_not_called()
      assert.equals(current_tab, vim.api.nvim_get_current_tabpage())
      assert.equals(current_win, vim.api.nvim_get_current_win())

      vim.api.nvim_set_current_tabpage(output_tab)
      flush.flush_pending_on_data_rendered()

      assert.stub(cmd_stub).was_called_with(':RenderMarkdown buf_enable')

      cmd_stub:revert()
      defer_stub:revert()
      vim.fn.exists = original_exists
      state.ui.set_windows(nil)
      vim.api.nvim_set_current_tabpage(current_tab)
      vim.cmd('tabclose')
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)

    it('defers output buffer writes while the output window is in another tab', function()
      local ctx = require('opencode.ui.renderer.ctx').current()
      local buf = vim.api.nvim_create_buf(false, true)
      local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        width = 20,
        height = 5,
        row = 0,
        col = 0,
        style = 'minimal',
      })
      local output_tab = vim.api.nvim_get_current_tabpage()

      state.ui.set_windows({ output_buf = buf, output_win = win })
      ctx:reset()
      flush.begin_bulk_mode()
      ctx.bulk_buffer_lines = { 'deferred output' }

      vim.cmd('tabnew')
      local background_tab = vim.api.nvim_get_current_tabpage()
      flush.end_bulk_mode()

      assert.same({ '' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.is_true(ctx.bulk_mode)

      vim.api.nvim_set_current_tabpage(output_tab)
      require('opencode.ui.renderer').resume_deferred_rendering()

      assert.same({ 'deferred output', '' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.is_false(ctx.bulk_mode)

      ctx:reset()
      state.ui.set_windows(nil)
      vim.api.nvim_set_current_tabpage(background_tab)
      vim.cmd('tabclose')
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)
  end)

  describe('cancel', function()
    it('aborts running session even when ui is not visible', function()
      state.ui.set_windows(nil)
      state.session.set_active({ id = 'sess1' })
      store.set('job_count', 1)
      local observation = state.session.active_observation()
      local interrupt = stub(observation, 'interrupt').returns(Promise.new():resolve(true))

      session_runtime.cancel():wait()

      assert.stub(interrupt).was_called()
      assert.stub(ui.focus_input).was_not_called()
      interrupt:revert()
    end)

    it('aborts when the model is processing on the server but no client request is in flight', function()
      state.session.set_active({ id = 'sess1' })
      store.set('job_count', 0)
      local observation = state.session.active_observation()
      local interrupt = stub(observation, 'interrupt').returns(Promise.new():resolve(true))

      session_runtime.cancel():wait()

      assert.stub(interrupt).was_called()
      interrupt:revert()
    end)

    it('does not count cancel toward the server-restart threshold when no client request is in flight', function()
      state.session.set_active({ id = 'sess1' })
      store.set('job_count', 0)
      vim.g.opencode_abort_count = 0

      for _ = 1, 5 do
        session_runtime.cancel():wait()
      end

      assert.is_equal(0, vim.g.opencode_abort_count)

      store.set('job_count', 1)
      vim.g.opencode_abort_count = 0
      session_runtime.cancel():wait()
      assert.is_equal(1, vim.g.opencode_abort_count)
    end)

    it('counts automatic cancellation even after the pending request count is cleared', function()
      state.session.set_active({ id = 'sess1' })
      store.set('job_count', 0)
      vim.g.opencode_abort_count = 0

      session_runtime.cancel('sess1', nil, { count_abort = true }):wait()

      assert.is_equal(1, vim.g.opencode_abort_count)
    end)

    it('does not release a Connection without process-release capability', function()
      local server_job = require('opencode.server_job')
      local connection = state.opencode_server
      local close = stub(connection, 'close').returns(Promise.new():resolve(true))
      local ensure_server = stub(server_job, 'ensure_server').returns(Promise.new():resolve(connection))
      state.session.set_active({ id = 'sess1' })
      store.set('job_count', 1)
      vim.g.opencode_abort_count = 0

      for _ = 1, 3 do
        session_runtime.cancel():wait()
      end

      assert.equals(connection, state.opencode_server)
      assert.stub(close).was_not_called()
      assert.stub(ensure_server).was_not_called()
      close:revert()
      ensure_server:revert()    end)
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
      local calls = 0
      state.opencode_server.operations.list_sessions_project = function()
        calls = calls + 1
        return Promise.new():resolve({ { id = 'test-session', title = 'test', time = { updated = 2 } } })
      end
      session_runtime.handle_directory_change():wait()

      assert.truthy(state.active_session)
      assert.equal('test-session', state.active_session.id)
      assert.equal(1, calls)
    end)

    it('creates new session when no last session exists', function()
      state.opencode_server.operations.list_sessions_project = function()
        return Promise.new():resolve({})
      end

      session_runtime.handle_directory_change():wait()

      assert.truthy(state.active_session)
      assert.truthy(state.active_session.id)
    end)

    it('preserves active session when locked', function()
      session_runtime.set_session_lock(true)
      state.session.set_active({ id = 'locked-session' })

      session_runtime.handle_directory_change():wait()

      assert.equal('locked-session', state.active_session.id)
      assert.stub(context.unload_attachments).was_not_called()
      session_runtime.set_session_lock(false)
    end)

    it('toggle_session_lock overrides config.lock_session_to_directory=true', function()
      local original = config.lock_session_to_directory
      config.lock_session_to_directory = true
      state.session.set_locked(nil)

      assert.is_true(session_runtime.is_session_locked())

      local new_value = session_runtime.toggle_session_lock()
      assert.is_false(new_value)
      assert.is_false(session_runtime.is_session_locked())

      new_value = session_runtime.toggle_session_lock()
      assert.is_true(new_value)
      assert.is_true(session_runtime.is_session_locked())

      config.lock_session_to_directory = original
      state.session.set_locked(nil)
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
      state.session.set_active({ id = 'session-model' })
      local observed = state.session.active_observation():read()
      observed.entry_order = { 'm1' }
      observed.entries_by_id.m1 = {
        id = 'm1',
        session_id = 'session-model',
        kind = 'assistant',
        content = {},
        model = { providerID = 'anthropic', modelID = 'claude-3-opus' },
        agent = 'build',
      }

      local model = agent_model.initialize_current_model():wait()

      assert.equal('openai/gpt-4.1', model)
      assert.equal('openai/gpt-4.1', state.current_model)
      assert.equal('plan', state.current_mode)
    end)

    it('restores the latest session model and mode when explicitly requested', function()
      state.model.set_model('openai/gpt-4.1')
      state.model.set_mode('plan')

      stub(config_file, 'get_opencode_agents').returns(Promise.new():resolve({ 'plan', 'build' }))

      state.session.set_active({ id = 'session-model' })
      local observed = state.session.active_observation():read()
      observed.entry_order = { 'm1' }
      observed.entries_by_id.m1 = {
        id = 'm1',
        session_id = 'session-model',
        kind = 'assistant',
        content = {},
        model = { providerID = 'anthropic', modelID = 'claude-3-opus' },
        agent = 'build',
      }

      local model = agent_model.initialize_current_model({ restore_from_messages = true }):wait()

      assert.equal('anthropic/claude-3-opus', model)
      assert.equal('anthropic/claude-3-opus', state.current_model)
      assert.equal('build', state.current_mode)

      config_file.get_opencode_agents:revert()
    end)
  end)
end)
