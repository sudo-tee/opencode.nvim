local Timer = require('opencode.ui.timer')

local function make_fake_timer()
  local ft = {
    _started = false,
    _stopped = false,
    _closed = false,
    _interval = nil,
    _repeat_interval = nil,
    _callback = nil,
  }
  function ft:start(interval, repeat_interval, callback)
    ft._interval = interval
    ft._repeat_interval = repeat_interval
    ft._callback = callback
    ft._started = true
  end
  function ft:stop()
    ft._stopped = true
  end
  function ft:close()
    ft._closed = true
  end
  function ft:fire()
    if ft._callback then
      ft._callback()
    end
  end
  return ft
end

describe('Timer', function()
  local timer
  local orig_new_timer
  local orig_schedule_wrap

  before_each(function()
    orig_new_timer = vim.uv.new_timer
    orig_schedule_wrap = vim.schedule_wrap
    vim.uv.new_timer = function()
      return make_fake_timer()
    end
    vim.schedule_wrap = function(fn)
      return fn
    end
  end)

  after_each(function()
    vim.uv.new_timer = orig_new_timer
    vim.schedule_wrap = orig_schedule_wrap
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

      timer._uv_timer:fire()
      timer._uv_timer:fire()
      timer._uv_timer:fire()

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

      timer._uv_timer:fire()

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
      timer._uv_timer:fire()

      assert.are.same({ 'test', 42, true }, received_args)
    end)

    it('stops timer when on_tick returns false', function()
      local tick_count = 0
      timer = Timer.new({
        interval = 10,
        on_tick = function()
          tick_count = tick_count + 1
          return tick_count < 2
        end,
      })

      timer:start()

      timer._uv_timer:fire()
      timer._uv_timer:fire()

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

      timer._uv_timer:fire()
      timer._uv_timer:fire()

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

      timer.on_tick = function()
        second_running = true
      end
      timer:start()

      timer._uv_timer:fire()

      assert.is_true(second_running)
      assert.is_false(first_running)
    end)

    it('throws error when timer creation fails', function()
      local orig_new_timer = vim.uv.new_timer
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

      vim.uv.new_timer = orig_new_timer
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
      assert.are.equal(0, tick_count)
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

      timer._uv_timer:fire()

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

      timer:start()
      timer._uv_timer:fire()
      timer._uv_timer:fire()
      assert.is_true(tick_count >= 2)
      timer:stop()

      local count_after_stop = tick_count

      timer:start()
      timer._uv_timer:fire()

      assert.is_true(tick_count > count_after_stop)
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
