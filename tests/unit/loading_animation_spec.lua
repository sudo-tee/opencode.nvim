local state = require('opencode.state')
local loading_animation = require('opencode.ui.loading_animation')
local stub = require('luassert.stub')
local assert = require('luassert')

local function reset()
  if loading_animation._animation.timer then
    loading_animation._animation.timer:stop()
    loading_animation._animation.timer = nil
  end
  vim.wait(0) -- drain any pending vim.schedule emits from prior tests
  state.jobs.set_count(0)
  state.session.clear_active()
  vim.wait(0) -- drain the clear_active emit
  state.store.set_raw('windows', nil)
  loading_animation._animation.status_data = nil
  loading_animation._animation.status_session_id = nil
  loading_animation._animation.last_status_map = {}
  loading_animation._animation.current_frame = 1
  loading_animation._animation.extmark_id = nil
end

describe('loading_animation', function()
  before_each(reset)
  after_each(reset)

  describe('_format_status_text', function()
    it('returns the spinner text for busy', function()
      assert.are.equal('Thinking... ', loading_animation._format_status_text({ type = 'busy' }))
    end)

    it('returns nil for idle', function()
      assert.is_nil(loading_animation._format_status_text({ type = 'idle' }))
    end)

    it('formats retry with attempt and seconds-until-next', function()
      local text = loading_animation._format_status_text({
        type = 'retry',
        attempt = 2,
        message = 'Provider overloaded',
        next = os.time() * 1000 + 5000,
      })
      assert.is_truthy(text:find('Provider overloaded'))
      assert.is_truthy(text:find('retry 2'))
      assert.is_truthy(text:find('in 5s'))
    end)
  end)

  describe('_should_animate', function()
    it('returns false when status_data is nil', function()
      assert.is_false(loading_animation._should_animate())
    end)

    it('returns false when status is idle', function()
      state.session.set_active({ id = 'ses_a' })
      loading_animation._animation.status_data = { type = 'idle' }
      loading_animation._animation.status_session_id = 'ses_a'
      assert.is_false(loading_animation._should_animate())
    end)

    it('returns false when there is no active session', function()
      loading_animation._animation.status_data = { type = 'busy' }
      loading_animation._animation.status_session_id = 'ses_a'
      assert.is_false(loading_animation._should_animate())
    end)

    it('returns true when busy on the active session', function()
      state.session.set_active({ id = 'ses_a' })
      loading_animation._animation.status_data = { type = 'busy' }
      loading_animation._animation.status_session_id = 'ses_a'
      assert.is_true(loading_animation._should_animate())
    end)

    it('returns false when busy on a different session', function()
      state.session.set_active({ id = 'ses_a' })
      loading_animation._animation.status_data = { type = 'busy' }
      loading_animation._animation.status_session_id = 'ses_b'
      assert.is_false(loading_animation._should_animate())
    end)
  end)

  describe('M.refresh', function()
    it('starts the spinner when should_animate transitions to true', function()
      state.session.set_active({ id = 'ses_a' })
      state.store.set_raw('windows', { output_buf = 1, footer_buf = 1 })
      loading_animation._animation.status_data = { type = 'busy' }
      loading_animation._animation.status_session_id = 'ses_a'

      loading_animation.refresh()

      assert.is_true(loading_animation.is_running())
    end)

    it('stops the spinner when should_animate transitions to false', function()
      state.session.set_active({ id = 'ses_a' })
      state.store.set_raw('windows', { output_buf = 1, footer_buf = 1 })
      loading_animation._animation.status_data = { type = 'busy' }
      loading_animation._animation.status_session_id = 'ses_a'
      loading_animation.refresh() -- start it
      assert.is_true(loading_animation.is_running())

      state.session.clear_active() -- now should_animate is false
      loading_animation.refresh()

      assert.is_false(loading_animation.is_running())
    end)

    it('is a no-op without state.windows', function()
      state.session.set_active({ id = 'ses_a' })
      loading_animation._animation.status_data = { type = 'busy' }
      loading_animation._animation.status_session_id = 'ses_a'

      loading_animation.refresh()

      assert.is_false(loading_animation.is_running())
    end)
  end)

  describe('on_session_status (SSE)', function()
    it('updates the cache for any session, active or not', function()
      loading_animation.on_session_status({
        sessionID = 'ses_a',
        status = { type = 'busy' },
      })
      loading_animation.on_session_status({
        sessionID = 'ses_b',
        status = { type = 'idle' },
      })

      assert.are.equal('busy', loading_animation._animation.last_status_map.ses_a.type)
      assert.are.equal('idle', loading_animation._animation.last_status_map.ses_b.type)
    end)

    it('mirrors status_data only for the active session', function()
      state.session.set_active({ id = 'ses_a' })
      loading_animation.on_session_status({
        sessionID = 'ses_b',
        status = { type = 'busy' },
      })
      assert.is_nil(loading_animation._animation.status_data)

      loading_animation.on_session_status({
        sessionID = 'ses_a',
        status = { type = 'busy' },
      })
      assert.are.equal('busy', loading_animation._animation.status_data.type)
    end)

    it('starts the spinner when busy arrives for the active session', function()
      local start_stub = stub(loading_animation, 'start')
      state.session.set_active({ id = 'ses_a' })
      state.store.set_raw('windows', { output_buf = 1, footer_buf = 1 })

      loading_animation.on_session_status({
        sessionID = 'ses_a',
        status = { type = 'busy' },
      })

      assert.stub(start_stub).was_called(1)
      start_stub:revert()
    end)

    it('does not start the spinner when busy arrives for a non-active session', function()
      local start_stub = stub(loading_animation, 'start')
      state.session.set_active({ id = 'ses_a' })
      state.store.set_raw('windows', { output_buf = 1, footer_buf = 1 })

      loading_animation.on_session_status({
        sessionID = 'ses_other',
        status = { type = 'busy' },
      })

      assert.stub(start_stub).was_not_called()
      start_stub:revert()
    end)

    it('stops the spinner when idle arrives for the active session', function()
      state.session.set_active({ id = 'ses_a' })
      state.store.set_raw('windows', { output_buf = 1, footer_buf = 1 })
      loading_animation._animation.status_data = { type = 'busy' }
      loading_animation._animation.status_session_id = 'ses_a'
      loading_animation.refresh()
      assert.is_true(loading_animation.is_running())

      loading_animation.on_session_status({
        sessionID = 'ses_a',
        status = { type = 'idle' },
      })

      assert.is_false(loading_animation.is_running())
    end)

    it('also animates for retry (not just busy)', function()
      local start_stub = stub(loading_animation, 'start')
      state.session.set_active({ id = 'ses_a' })
      state.store.set_raw('windows', { output_buf = 1, footer_buf = 1 })

      loading_animation.on_session_status({
        sessionID = 'ses_a',
        status = { type = 'retry', message = 'overloaded', attempt = 1, next = 0 },
      })

      assert.stub(start_stub).was_called(1)
      start_stub:revert()
    end)
  end)

  describe('on_active_session_change', function()
    it('replays the active session from the cache (handles sync-before-set_active)', function()
      loading_animation._animation.last_status_map.ses_x = { type = 'busy' }
      state.store.subscribe('active_session', loading_animation._on_active_session_change)

      state.session.set_active({ id = 'ses_x' })
      vim.wait(200, function()
        return loading_animation._animation.status_data ~= nil
      end)

      assert.are.equal('busy', loading_animation._animation.status_data.type)
      assert.are.equal('ses_x', loading_animation._animation.status_session_id)
    end)

    it('clears status_data on actual session switch', function()
      state.session.set_active({ id = 'ses_old' })
      loading_animation._animation.status_data = { type = 'busy' }
      loading_animation._animation.status_session_id = 'ses_old'
      state.store.subscribe('active_session', loading_animation._on_active_session_change)

      state.session.set_active({ id = 'ses_new' })
      vim.wait(200, function()
        return loading_animation._animation.status_data == nil
          or loading_animation._animation.status_session_id == 'ses_new'
      end)

      assert.is_nil(loading_animation._animation.status_data)
      assert.is_nil(loading_animation._animation.status_session_id)
    end)

    it('keeps status_data on first assignment (nil -> X)', function()
      loading_animation._animation.status_data = { type = 'busy' }
      loading_animation._animation.status_session_id = 'ses_x'
      state.store.subscribe('active_session', loading_animation._on_active_session_change)

      state.session.set_active({ id = 'ses_x' })
      vim.wait(200, function()
        return loading_animation._animation.status_session_id == 'ses_x'
      end)

      assert.are.equal('busy', loading_animation._animation.status_data.type)
    end)
  end)

  describe('sync_from_server (cache merge + replay)', function()
    it('merges the response into the cache (only fills missing entries)', function()
      state.jobs.set_api_client({
        list_session_status = function()
          local p = require('opencode.promise').new()
          p:resolve({ ses_x = { type = 'busy' } })
          return p
        end,
      })

      loading_animation._animation.last_status_map.ses_x = { type = 'idle' } -- SSE won
      loading_animation._animation.last_status_map.ses_y = { type = 'busy' } -- already cached

      loading_animation.sync_from_server()
      vim.wait(200, function()
        return false
      end)

      assert.are.equal('idle', loading_animation._animation.last_status_map.ses_x.type) -- SSE preserved
      assert.are.equal('busy', loading_animation._animation.last_status_map.ses_y.type)
    end)

    it('replays only the active session after sync', function()
      state.session.set_active({ id = 'ses_a' })
      state.jobs.set_api_client({
        list_session_status = function()
          local p = require('opencode.promise').new()
          p:resolve({ ses_a = { type = 'busy' }, ses_b = { type = 'busy' } })
          return p
        end,
      })

      loading_animation.sync_from_server()
      vim.wait(200, function()
        return loading_animation._animation.status_data ~= nil
      end)

      assert.are.equal('ses_a', loading_animation._animation.status_session_id)
      assert.are.equal('busy', loading_animation._animation.last_status_map.ses_a.type)
      assert.are.equal('busy', loading_animation._animation.last_status_map.ses_b.type)
    end)

    it('does not regress to busy when sync returns a stale snapshot after SSE idle', function()
      -- SSE already updated cache and status_data to idle for the active
      -- session. sync's GET response arrives late with a stale busy
      -- snapshot. The replay must not overwrite the fresher SSE state.
      state.session.set_active({ id = 'ses_a' })
      state.store.set_raw('windows', { output_buf = 1, footer_buf = 1 })
      loading_animation._animation.last_status_map.ses_a = { type = 'idle' }
      loading_animation._animation.status_data = { type = 'idle' }
      loading_animation._animation.status_session_id = 'ses_a'

      state.jobs.set_api_client({
        list_session_status = function()
          local p = require('opencode.promise').new()
          p:resolve({ ses_a = { type = 'busy' } }) -- stale
          return p
        end,
      })

      loading_animation.sync_from_server()
      vim.wait(200, function()
        return false
      end)

      assert.are.equal('idle', loading_animation._animation.status_data.type)
      assert.is_false(loading_animation.is_running())
    end)
  end)

  describe('setup / teardown', function()
    it('hydrates via sync on setup, even when SSE has not seen this session yet', function()
      state.session.set_active({ id = 'ses_x' })
      state.jobs.set_api_client({
        list_session_status = function()
          local p = require('opencode.promise').new()
          p:resolve({ ses_x = { type = 'busy' } })
          return p
        end,
      })

      loading_animation.setup()
      vim.wait(200, function()
        return loading_animation._animation.status_data ~= nil
      end)

      assert.are.equal('busy', loading_animation._animation.status_data.type)
    end)

    it('clears all state on teardown so stale data does not survive a hide', function()
      state.session.set_active({ id = 'ses_a' })
      loading_animation._animation.status_data = { type = 'busy' }
      loading_animation._animation.status_session_id = 'ses_a'
      loading_animation._animation.last_status_map.ses_a = { type = 'busy' }

      loading_animation.teardown()

      assert.is_nil(loading_animation._animation.status_data)
      assert.is_nil(loading_animation._animation.status_session_id)
      assert.is_nil(loading_animation._animation.timer)
      assert.are.same({}, loading_animation._animation.last_status_map)
    end)

    it('does not leave a stale spinner running when the model finishes during a hide', function()
      state.session.set_active({ id = 'ses_a' })
      state.store.set_raw('windows', { output_buf = 1, footer_buf = 1 })
      loading_animation._animation.last_status_map.ses_a = { type = 'busy' }
      loading_animation._animation.status_data = { type = 'busy' }
      loading_animation._animation.status_session_id = 'ses_a'

      loading_animation.teardown()
      -- ...the model finishes while the footer is hidden, the SSE
      -- event goes nowhere...

      state.jobs.set_api_client({
        list_session_status = function()
          local p = require('opencode.promise').new()
          p:resolve({ ses_a = { type = 'idle' } })
          return p
        end,
      })

      loading_animation.setup()
      vim.wait(200, function()
        return loading_animation._animation.status_data ~= nil
          and loading_animation._animation.status_data.type == 'idle'
      end)

      assert.are.equal('idle', loading_animation._animation.status_data.type)
      assert.is_false(loading_animation.is_running())
    end)
  end)
end)
