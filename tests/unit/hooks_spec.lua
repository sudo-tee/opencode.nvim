local renderer = require('opencode.ui.renderer')
local stub = require('luassert.stub')
local config = require('opencode.config')
local state = require('opencode.state')
local session_runtime = require('opencode.services.session_runtime')
local events = require('opencode.ui.renderer.events')
local helpers = require('tests.helpers')
local ui = require('opencode.ui.ui')

local function expect_nil_hook_no_error(run)
  assert.has_no.errors(run)
end

local function expect_throwing_hook_no_crash(set_hook, run)
  set_hook(function()
    error('test error')
  end)
  assert.has_no.errors(run)
end

describe('hooks', function()
  before_each(function()
    helpers.replay_setup()
    config.hooks = {
      on_file_edited = nil,
      on_session_loaded = nil,
      on_done_thinking = nil,
      on_permission_requested = nil,
    }
  end)

  after_each(function()
    if state.windows then
      ui.close_windows(state.windows)
    end
    config.hooks = {
      on_file_edited = nil,
      on_session_loaded = nil,
      on_done_thinking = nil,
      on_permission_requested = nil,
    }
  end)

  describe('on_file_edited', function()
    it('should call hook when file is edited', function()
      local called = false
      local file_path = nil

      config.hooks.on_file_edited = function(file)
        called = true
        file_path = file
      end

      local test_event = { file = '/test/file.lua' }
      events.on_file_edited(test_event)

      assert.is_true(called)
      assert.are.equal('/test/file.lua', file_path)
    end)

    it('should not error when hook is nil', function()
      config.hooks.on_file_edited = nil
      local test_event = { file = '/test/file.lua' }
      expect_nil_hook_no_error(function()
        events.on_file_edited(test_event)
      end)
    end)

    it('should not crash when hook throws error', function()
      local test_event = { file = '/test/file.lua' }
      expect_throwing_hook_no_crash(function(fn)
        config.hooks.on_file_edited = fn
      end, function()
        events.on_file_edited(test_event)
      end)
    end)
  end)

  describe('on_session_loaded', function()
    it('should call hook when session is loaded', function()
      local called = false
      local session_data = nil

      config.hooks.on_session_loaded = function(session)
        called = true
        session_data = session
      end

      local events = helpers.load_test_data('tests/data/simple-session.json')
      state.session.set_active(helpers.get_session_from_events(events, true))
      local loaded_session = helpers.load_session_from_events(events)

      renderer._render_full_session_data(loaded_session)

      assert.is_true(called)
      assert.are.same(state.active_session, session_data)
    end)

    it('should not error when hook is nil', function()
      config.hooks.on_session_loaded = nil
      local events = helpers.load_test_data('tests/data/simple-session.json')
      state.session.set_active(helpers.get_session_from_events(events, true))
      local loaded_session = helpers.load_session_from_events(events)
      expect_nil_hook_no_error(function()
        renderer._render_full_session_data(loaded_session)
      end)
    end)

    it('should not crash when hook throws error', function()
      local events = helpers.load_test_data('tests/data/simple-session.json')
      state.session.set_active(helpers.get_session_from_events(events, true))
      local loaded_session = helpers.load_session_from_events(events)
      expect_throwing_hook_no_crash(function(fn)
        config.hooks.on_session_loaded = fn
      end, function()
        renderer._render_full_session_data(loaded_session)
      end)
    end)
  end)

  describe('on_done_thinking', function()
    it('should call hook when thinking is done', function()
      local called = false
      local called_session = nil

      config.hooks.on_done_thinking = function(session)
        called = true
        called_session = session
      end

      -- Mock session.get_all_workspace_sessions to return our test session
      local session_module = require('opencode.session')
      local original_get_all = session_module.get_all_workspace_sessions
      session_module.get_all_workspace_sessions = function()
        local promise = require('opencode.promise').new()
        promise:resolve({ { id = 'test-session', title = 'Test' } })
        return promise
      end

      state.store.subscribe('user_message_count', session_runtime._on_user_message_count_change)

      -- Simulate job count change from 1 to 0 (done thinking) for a specific session
      state.session.set_active({ id = 'test-session', title = 'Test' })
      state.session.set_user_message_count({ ['test-session'] = 1 })
      state.session.set_user_message_count({ ['test-session'] = 0 })

      -- Wait for async notification
      vim.wait(100, function()
        return called
      end)

      -- Restore original function
      session_module.get_all_workspace_sessions = original_get_all
      state.store.unsubscribe('user_message_count', session_runtime._on_user_message_count_change)

      assert.is_true(called)
      assert.are.equal(called_session.id, 'test-session')
    end)

    it('should not error when hook is nil', function()
      config.hooks.on_done_thinking = nil
      state.session.set_active({ id = 'test-session', title = 'Test' })
      state.session.set_user_message_count({ ['test-session'] = 1 })
      expect_nil_hook_no_error(function()
        state.session.set_user_message_count({ ['test-session'] = 0 })
      end)
    end)

    it('should not crash when hook throws error', function()
      state.session.set_active({ id = 'test-session', title = 'Test' })
      state.session.set_user_message_count({ ['test-session'] = 1 })
      expect_throwing_hook_no_crash(function(fn)
        config.hooks.on_done_thinking = fn
      end, function()
        state.session.set_user_message_count({ ['test-session'] = 0 })
      end)
    end)
  end)

  describe('on_permission_requested', function()
    it('should call hook when permission is requested', function()
      local called = false
      local called_session = nil

      config.hooks.on_permission_requested = function(session)
        called = true
        called_session = session
      end

      -- Mock session.get_by_id to return our test session
      local session_module = require('opencode.session')
      local original_get_by_id = session_module.get_by_id
      session_module.get_by_id = function(id)
        local promise = require('opencode.promise').new()
        promise:resolve({ id = id, title = 'Test' })
        return promise
      end

      -- Set up the subscription manually
      state.store.subscribe('pending_permissions', session_runtime._on_current_permission_change)

      -- Simulate permission change from nil to a value
      state.session.set_active({ id = 'test-session', title = 'Test' })
      state.renderer.set_pending_permissions({ { tool = 'test_tool', action = 'read' } })

      -- Wait for async notification
      vim.wait(100, function()
        return called
      end)

      -- Restore original function
      session_module.get_by_id = original_get_by_id
      state.store.unsubscribe('pending_permissions', session_runtime._on_current_permission_change)

      assert.is_true(called)
      assert.are.equal(called_session.id, 'test-session')
    end)

    it('should not error when hook is nil', function()
      config.hooks.on_permission_requested = nil
      expect_nil_hook_no_error(function()
        state.renderer.set_pending_permissions({ { tool = 'test_tool', action = 'read' } })
      end)
    end)

    it('should not crash when hook throws error', function()
      expect_throwing_hook_no_crash(function(fn)
        config.hooks.on_permission_requested = fn
      end, function()
        state.renderer.set_pending_permissions({ { tool = 'test_tool', action = 'read' } })
      end)
    end)
  end)
end)

describe('reference target local file lifecycle autocmds', function()
  local autocmds = require('opencode.ui.autocmds')

  it('invalidates rendered reference targets on local file writes, renames, unloads, and shell changes', function()
    local original_create_augroup = vim.api.nvim_create_augroup
    local original_create_autocmd = vim.api.nvim_create_autocmd
    local created = {}

    local invalidate_stub = stub(events, 'invalidate_reference_targets_for_file_change')
    local ok, err = pcall(function()
      vim.api.nvim_create_augroup = function()
        return 42
      end
      vim.api.nvim_create_autocmd = function(event, opts)
        created[#created + 1] = { event = event, opts = opts }
        return #created
      end

      autocmds.setup_autocmds({ input_win = 1, output_win = 2, footer_win = 3, input_buf = 4, output_buf = 5 })

      local file_lifecycle_autocmd
      for _, entry in ipairs(created) do
        if type(entry.event) == 'table' and vim.tbl_contains(entry.event, 'BufWritePost') then
          file_lifecycle_autocmd = entry
          break
        end
      end

      assert.is_not_nil(file_lifecycle_autocmd)
      assert.are.same(
        { 'BufWritePost', 'BufFilePost', 'BufDelete', 'BufWipeout', 'FileChangedShellPost' },
        file_lifecycle_autocmd.event
      )

      local file_buf = vim.api.nvim_create_buf(false, false)
      vim.bo[file_buf].buftype = ''
      file_lifecycle_autocmd.opts.callback({ file = '/repo/tests/unit/formatter_spec.lua', buf = file_buf })
      file_lifecycle_autocmd.opts.callback({ file = '', buf = file_buf })

      assert.stub(invalidate_stub).was_called(1)
    end)

    vim.api.nvim_create_augroup = original_create_augroup
    vim.api.nvim_create_autocmd = original_create_autocmd
    invalidate_stub:revert()
    if not ok then
      error(err)
    end
  end)
end)
