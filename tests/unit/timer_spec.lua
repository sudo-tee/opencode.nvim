local Timer = require('opencode.ui.timer')

describe('Timer', function()
  local timer

  after_each(function()
    if timer then
      timer:stop()
      timer = nil
    end
  end)

  describe('Timer.new', function()
    it('creates a new timer with required options', function()
      timer = Timer.new({
        interval = 100,
        on_tick = function() end,
      })

      assert.are.equal(100, timer.interval)
      assert.is_function(timer.on_tick)
      assert.is_true(timer.repeat_timer)
      assert.are.same({}, timer.args)
      assert.is_nil(timer._uv_timer)
    end)

    it('sets repeat_timer to false when explicitly disabled', function()
      timer = Timer.new({
        interval = 100,
        on_tick = function() end,
        repeat_timer = false,
      })

      assert.is_false(timer.repeat_timer)
    end)

    it('stores optional parameters', function()
      local on_stop = function() end
      local args = { 'arg1', 'arg2' }

      timer = Timer.new({
        interval = 100,
        on_tick = function() end,
        on_stop = on_stop,
        args = args,
      })

      assert.are.equal(on_stop, timer.on_stop)
      assert.are.same(args, timer.args)
    end)
  end)

  describe('Timer:start', function()
    it('starts a repeating timer', function()
      local tick_count = 0
      timer = Timer.new({
        interval = 100,
        on_tick = function()
          tick_count = tick_count + 1
        end,
      })

      timer:start()
      assert.is_true(timer:is_running())

      -- Wait for multiple ticks
      vim.wait(1000, function()
        return tick_count >= 3
      end)

      assert.is_true(tick_count >= 3)
    end)

    it('starts a one-shot timer', function()
      local tick_count = 0
      timer = Timer.new({
        interval = 10,
        repeat_timer = false,
        on_tick = function()
          tick_count = tick_count + 1
        end,
      })

      timer:start()
      assert.is_true(timer:is_running())

      -- Wait for timer to complete
      vim.wait(30, function()
        return not timer:is_running()
      end)

      assert.are.equal(1, tick_count)
      assert.is_false(timer:is_running())
    end)

    it('passes arguments to on_tick function', function()
      local received_args
      timer = Timer.new({
        interval = 10,
        repeat_timer = false,
        args = { 'test', 42, true },
        on_tick = function(...)
          received_args = { ... }
        end,
      })

      timer:start()

      vim.wait(30, function()
        return received_args ~= nil
      end)

      assert.are.same({ 'test', 42, true }, received_args)
    end)

    it('stops timer when on_tick returns false', function()
      local tick_count = 0
      timer = Timer.new({
        interval = 10,
        on_tick = function()
          tick_count = tick_count + 1
          return tick_count < 2 -- Stop after 2 ticks
        end,
      })

      timer:start()

      vim.wait(50, function()
        return not timer:is_running()
      end)

      assert.are.equal(2, tick_count)
      assert.is_false(timer:is_running())
    end)

    it('stops timer when on_tick throws an error', function()
      local tick_count = 0
      timer = Timer.new({
        interval = 10,
        on_tick = function()
          tick_count = tick_count + 1
          if tick_count >= 2 then
            error('test error')
          end
        end,
      })

      timer:start()

      vim.wait(50, function()
        return not timer:is_running()
      end)

      assert.are.equal(2, tick_count)
      assert.is_false(timer:is_running())
    end)

    it('stops previous timer before starting new one', function()
      local first_running = false
      local second_running = false

      timer = Timer.new({
        interval = 10,
        on_tick = function()
          first_running = true
        end,
      })

      timer:start()
      assert.is_true(timer:is_running())

      -- Change the on_tick and start again
      timer.on_tick = function()
        second_running = true
      end
      timer:start()

      vim.wait(30, function()
        return second_running
      end)

      assert.is_true(second_running)
      -- First callback should not be called after restart
      first_running = false
      vim.wait(30)
      assert.is_false(first_running)
    end)

    it('throws error when timer creation fails', function()
      -- Mock vim.uv.new_timer to return nil
      local original_new_timer = vim.uv.new_timer
      vim.uv.new_timer = function()
        return nil
      end

      timer = Timer.new({
        interval = 100,
        on_tick = function() end,
      })

      assert.has_error(function()
        timer:start()
      end, 'failed to create uv timer')

      -- Restore original function
      vim.uv.new_timer = original_new_timer
    end)
  end)

  describe('Timer:stop', function()
    it('stops a running timer', function()
      local tick_count = 0
      timer = Timer.new({
        interval = 10,
        on_tick = function()
          tick_count = tick_count + 1
        end,
      })

      timer:start()
      assert.is_true(timer:is_running())

      timer:stop()
      assert.is_false(timer:is_running())

      local count_before_wait = tick_count
      vim.wait(30)
      assert.are.equal(count_before_wait, tick_count)
    end)

    it('calls on_stop callback when provided', function()
      local stop_called = false
      timer = Timer.new({
        interval = 100,
        on_tick = function() end,
        on_stop = function()
          stop_called = true
        end,
      })

      timer:start()
      timer:stop()

      assert.is_true(stop_called)
    end)

    it('does nothing when timer is not running', function()
      timer = Timer.new({
        interval = 100,
        on_tick = function() end,
      })

      -- Should not error
      timer:stop()
      assert.is_false(timer:is_running())
    end)

    it('handles errors in on_stop callback gracefully', function()
      timer = Timer.new({
        interval = 100,
        on_tick = function() end,
        on_stop = function()
          error('stop error')
        end,
      })

      timer:start()
      -- Should not throw error
      assert.has_no.errors(function()
        timer:stop()
      end)

      assert.is_false(timer:is_running())
    end)
  end)

  describe('Timer:is_running', function()
    it('returns false when timer is not started', function()
      timer = Timer.new({
        interval = 100,
        on_tick = function() end,
      })

      assert.is_false(timer:is_running())
    end)

    it('returns true when timer is running', function()
      timer = Timer.new({
        interval = 100,
        on_tick = function() end,
      })

      timer:start()
      assert.is_true(timer:is_running())
    end)

    it('returns false after timer is stopped', function()
      timer = Timer.new({
        interval = 100,
        on_tick = function() end,
      })

      timer:start()
      timer:stop()
      assert.is_false(timer:is_running())
    end)

    it('returns false after one-shot timer completes', function()
      timer = Timer.new({
        interval = 10,
        repeat_timer = false,
        on_tick = function() end,
      })

      timer:start()
      assert.is_true(timer:is_running())

      vim.wait(30, function()
        return not timer:is_running()
      end)

      assert.is_false(timer:is_running())
    end)
  end)

  describe('Integration tests', function()
    it('can restart a stopped timer', function()
      local tick_count = 0
      timer = Timer.new({
        interval = 10,
        on_tick = function()
          tick_count = tick_count + 1
        end,
      })

      -- Start, wait for ticks, then stop
      timer:start()
      vim.wait(30, function()
        return tick_count >= 2
      end)
      timer:stop()

      local count_after_stop = tick_count

      -- Restart and verify it works again
      timer:start()
      vim.wait(30, function()
        return tick_count > count_after_stop + 1
      end)

      assert.is_true(tick_count > count_after_stop + 1)
      assert.is_true(timer:is_running())
    end)

    it('handles rapid start/stop cycles', function()
      timer = Timer.new({
        interval = 100,
        on_tick = function() end,
      })

      for _ = 1, 5 do
        timer:start()
        assert.is_true(timer:is_running())
        timer:stop()
        assert.is_false(timer:is_running())
      end
    end)
  end)
end)
