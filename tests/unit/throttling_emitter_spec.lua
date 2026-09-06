local ThrottlingEmitter = require('opencode.throttling_emitter')

describe('ThrottlingEmitter', function()
  local original_defer, pending

  before_each(function()
    original_defer = vim.defer_fn
    pending = {}
    vim.defer_fn = function(callback)
      pending[#pending + 1] = callback
    end
  end)

  after_each(function()
    vim.defer_fn = original_defer
  end)

  it('does not let a cancelled drain consume a newer batch', function()
    local batches = {}
    local emitter = ThrottlingEmitter.new(function(items)
      batches[#batches + 1] = items
    end)
    emitter:enqueue('old')
    emitter:clear()
    emitter:enqueue('new')
    pending[1]()
    assert.same({}, batches)
    assert.is_true(emitter.drain_scheduled)
    pending[2]()
    assert.same({ { 'new' } }, batches)
  end)

  it('schedules a single follow-up batch for events enqueued during processing', function()
    local batches = {}
    local emitter
    emitter = ThrottlingEmitter.new(function(items)
      batches[#batches + 1] = items
      if #batches == 1 then
        emitter:enqueue('second')
        emitter:enqueue('third')
      end
    end)
    emitter:enqueue('first')
    pending[1]()
    assert.equals(2, #pending)
    pending[2]()
    assert.same({ { 'first' }, { 'second', 'third' } }, batches)
  end)
end)
