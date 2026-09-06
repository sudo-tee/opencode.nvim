local Promise = require('opencode.promise')

describe('Promise settlement', function()
  for _, rejected in ipairs({ false, true }) do
    it('releases listeners and waiting coroutines after ' .. (rejected and 'rejection' or 'resolution'), function()
      local promise = Promise.new()
      local callbacks = 0
      local next_promise = promise
        :and_then(function(value)
          callbacks = callbacks + 1
          return value
        end)
        :catch(function(err)
          callbacks = callbacks + 1
          return err
        end)
      local awaiting = Promise.spawn(function()
        return promise:await()
      end)
      if rejected then
        promise:reject('result')
      else
        promise:resolve('result')
      end
      assert.same({}, promise._then_callbacks)
      assert.same({}, promise._catch_callbacks)
      assert.same({}, promise._coroutines)
      assert.equals('result', next_promise:wait())
      assert.equals(1, callbacks)
      assert.is_true(vim.wait(200, function()
        return awaiting:is_resolved()
      end))
      assert.equals(rejected, awaiting:is_rejected())
    end)
  end

  for _, reason in ipairs({ { value = false }, {} }) do
    for _, already_settled in ipairs({ false, true }) do
      it(
        'preserves falsy rejection through chaining, finally, wait and await ('
          .. tostring(reason.value)
          .. ', settled='
          .. tostring(already_settled)
          .. ')',
        function()
          local promise = Promise.new()
          if already_settled then
            promise:reject(reason.value)
          end
          local success_called = false
          local chained = promise:and_then(function()
            success_called = true
          end)
          local finally_called = false
          local finalized = chained:finally(function()
            finally_called = true
          end)
          local waiting = Promise.spawn(function()
            return promise:await()
          end)
          local caught = false
          local recovered = promise:catch(function(err)
            caught = true
            assert.equals(reason.value, err)
            return 'recovered'
          end)
          if not already_settled then
            promise:reject(reason.value)
          end
          assert.equals('recovered', recovered:wait())
          assert.is_true(vim.wait(200, function()
            return finalized:is_resolved() and waiting:is_resolved()
          end))
          assert.is_true(caught)
          assert.is_true(finally_called)
          assert.is_false(success_called)
          assert.is_true(finalized:is_rejected())
          assert.is_true(waiting:is_rejected())
          local ok, err = pcall(function()
            return promise:wait()
          end)
          assert.is_false(ok)
          assert.equals(reason.value, err)
        end
      )
    end
  end

  it('settles only once and accepts late success handlers', function()
    local promise = Promise.new():resolve(false)
    promise:reject('too late')
    assert.is_false(promise:is_rejected())
    assert.is_false(promise
      :and_then(function(value)
        return value
      end)
      :wait())
  end)
end)

describe('Promise error propagation', function()
  it('preserves the original error through nested coroutine boundaries', function()
    local first = Promise.new()
    local second = Promise.spawn(function()
      return first:await()
    end)
    local third = Promise.spawn(function()
      return second:await()
    end)
    first:reject('address already in use')
    local ok, err = pcall(function()
      third:wait()
    end)
    assert.is_false(ok)
    assert.equals('address already in use', err)
  end)
end)
