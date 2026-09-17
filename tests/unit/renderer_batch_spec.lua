local batch = require('opencode.ui.renderer.batch')

describe('renderer batch context lifetime', function()
  it('keeps a new context batch intact when an old callback arrives', function()
    local generation, observation = 1, {}
    local callbacks, reconciled = {}, {}
    local queue = batch.new({
      context = function()
        return generation, observation
      end,
      schedule = function(callback)
        callbacks[#callbacks + 1] = callback
      end,
      apply = function(resources)
        reconciled[#reconciled + 1] = resources
      end,
    })
    local old_child, new_child = {}, {}
    queue:enqueue(old_child, 'messages')
    generation, observation = 2, {}
    queue:enqueue(new_child, 'questions')
    callbacks[1]()
    assert.equals(0, #reconciled)
    callbacks[2]()
    assert.equals(1, #reconciled)
    assert.same({ questions = true }, reconciled[1][new_child])
    assert.is_nil(reconciled[1][old_child])
  end)

  it('drops an evicted child while retaining other pending children', function()
    local root, evicted, retained = {}, {}, {}
    local callback, reconciled
    local schedules = 0
    local queue = batch.new({
      context = function()
        return 1, root
      end,
      schedule = function(fn)
        callback = fn
        schedules = schedules + 1
      end,
      apply = function(resources)
        reconciled = resources
      end,
    })
    queue:enqueue(evicted, 'messages')
    queue:enqueue(retained, 'permissions')
    queue:discard(evicted)
    callback()
    assert.equals(1, schedules)
    assert.is_nil(reconciled[evicted])
    assert.same({ permissions = true }, reconciled[retained])
    queue:drain()
    assert.equals(1, schedules)
  end)
end)
