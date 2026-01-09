local renderer = require('opencode.ui.renderer')
local config = require('opencode.config')
local state = require('opencode.state')
local core = require('opencode.core')
local helpers = require('tests.helpers')
local ui = require('opencode.ui.ui')

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
      renderer.on_file_edited(test_event)

      assert.is_true(called)
      assert.are.equal('/test/file.lua', file_path)
    end)

    it('should not error when hook is nil', function()
      config.hooks.on_file_edited = nil

      local test_event = { file = '/test/file.lua' }
      assert.has_no.errors(function()
        renderer.on_file_edited(test_event)
      end)
    end)

    it('should not crash when hook throws error', function()
      config.hooks.on_file_edited = function()
        error('test error')
      end

      local test_event = { file = '/test/file.lua' }
      assert.has_no.errors(function()
        renderer.on_file_edited(test_event)
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
      state.active_session = helpers.get_session_from_events(events, true)
      local loaded_session = helpers.load_session_from_events(events)

      renderer._render_full_session_data(loaded_session)

      assert.is_true(called)
      assert.are.same(state.active_session, session_data)
    end)

    it('should not error when hook is nil', function()
      config.hooks.on_session_loaded = nil

      local events = helpers.load_test_data('tests/data/simple-session.json')
      state.active_session = helpers.get_session_from_events(events, true)
      local loaded_session = helpers.load_session_from_events(events)

      assert.has_no.errors(function()
        renderer._render_full_session_data(loaded_session)
      end)
    end)

    it('should not crash when hook throws error', function()
      config.hooks.on_session_loaded = function()
        error('test error')
      end

      local events = helpers.load_test_data('tests/data/simple-session.json')
      state.active_session = helpers.get_session_from_events(events, true)
      local loaded_session = helpers.load_session_from_events(events)

      assert.has_no.errors(function()
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

      state.subscribe('user_message_count', core._on_user_message_count_change)

      -- Simulate job count change from 1 to 0 (done thinking) for a specific session
      state.active_session = { id = 'test-session', title = 'Test' }
      state.user_message_count = { ['test-session'] = 1 }
      state.user_message_count = { ['test-session'] = 0 }

      -- Wait for async notification
      vim.wait(100, function()
        return called
      end)

      -- Restore original function
      session_module.get_all_workspace_sessions = original_get_all
      state.unsubscribe('user_message_count', core._on_user_message_count_change)

      assert.is_true(called)
      assert.are.equal(called_session.id, 'test-session')
    end)

    it('should not error when hook is nil', function()
      config.hooks.on_done_thinking = nil
      state.active_session = { id = 'test-session', title = 'Test' }
      state.user_message_count = { ['test-session'] = 1 }
      assert.has_no.errors(function()
        state.user_message_count = { ['test-session'] = 0 }
      end)
    end)

    it('should not crash when hook throws error', function()
      config.hooks.on_done_thinking = function()
        error('test error')
      end

      state.active_session = { id = 'test-session', title = 'Test' }
      state.user_message_count = { ['test-session'] = 1 }
      assert.has_no.errors(function()
        state.user_message_count = { ['test-session'] = 0 }
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
      state.subscribe('pending_permissions', core._on_current_permission_change)

      -- Simulate permission change from nil to a value
      state.active_session = { id = 'test-session', title = 'Test' }
      state.pending_permissions = { { tool = 'test_tool', action = 'read' } }

      -- Wait for async notification
      vim.wait(100, function()
        return called
      end)

      -- Restore original function
      session_module.get_by_id = original_get_by_id
      state.unsubscribe('pending_permissions', core._on_current_permission_change)

      assert.is_true(called)
      assert.are.equal(called_session.id, 'test-session')
    end)

    it('should not error when hook is nil', function()
      config.hooks.on_permission_requested = nil
      state.pending_permissions = {}
      assert.has_no.errors(function()
        state.current_permission = { { tool = 'test_tool', action = 'read' } }
      end)
    end)

    it('should not crash when hook throws error', function()
      config.hooks.on_permission_requested = function()
        error('test error')
      end

      state.pending_permissions = {}
      assert.has_no.errors(function()
        state.current_permission = { { tool = 'test_tool', action = 'read' } }
      end)
    end)
  end)
end)
