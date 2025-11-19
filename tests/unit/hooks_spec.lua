local renderer = require('opencode.ui.renderer')
local config = require('opencode.config')
local state = require('opencode.state')
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

      config.hooks.on_done_thinking = function()
        called = true
      end

      -- Simulate job count change from 1 to 0 (done thinking)
      state.user_message_count = 1
      state.user_message_count = 0

      assert.is_true(called)
    end)

    it('should not error when hook is nil', function()
      config.hooks.on_done_thinking = nil
      state.user_message_count = 1
      assert.has_no.errors(function()
        state.user_message_count = 0
      end)
    end)

    it('should not crash when hook throws error', function()
      config.hooks.on_done_thinking = function()
        error('test error')
      end

      state.user_message_count = 1
      assert.has_no.errors(function()
        state.user_message_count = 0
      end)
    end)
  end)

  describe('on_permission_requested', function()
    it('should call hook when permission is requested', function()
      local called = false

      config.hooks.on_permission_requested = function()
        called = true
      end

      -- Simulate permission change from nil to a value
      state.current_permission = nil
      state.current_permission = { tool = 'test_tool', action = 'read' }

      assert.is_true(called)
    end)

    it('should not error when hook is nil', function()
      config.hooks.on_permission_requested = nil
      state.current_permission = nil
      assert.has_no.errors(function()
        state.current_permission = { tool = 'test_tool', action = 'read' }
      end)
    end)

    it('should not crash when hook throws error', function()
      config.hooks.on_permission_requested = function()
        error('test error')
      end

      state.current_permission = nil
      assert.has_no.errors(function()
        state.current_permission = { tool = 'test_tool', action = 'read' }
      end)
    end)
  end)
end)
