local stub = require('luassert.stub')
local state = require('opencode.state')
local ctx = require('opencode.ui.renderer.ctx')
local reference_facts = require('opencode.ui.reference_facts')
local symbol_snapshot = require('opencode.ui.symbol_snapshot')
local symbol_refresh = require('opencode.ui.renderer.symbol_refresh')

describe('renderer symbol refresh', function()
  local original_defer_fn
  local original_schedule

  before_each(function()
    ctx:reset()
    state.session.set_active({ id = 'ses_test', title = 'Test Session' })
    original_defer_fn = vim.defer_fn
    original_schedule = vim.schedule
  end)

  after_each(function()
    vim.defer_fn = original_defer_fn
    vim.schedule = original_schedule
    ctx:reset()
  end)

  it('cancels an active refresh when symbol data is invalidated', function()
    local refresh_stub = stub(reference_facts, 'refresh_current_files')
    local cycle = {}
    ctx.symbol_refresh_pending = true
    ctx.symbol_refresh_cycle = cycle
    local refresh_token = ctx.symbol_refresh_token

    symbol_refresh.invalidate()

    assert.equal(refresh_token + 1, ctx.symbol_refresh_token)
    assert.is_false(ctx.symbol_refresh_pending)
    assert.is_nil(ctx.symbol_refresh_cycle)
    assert.stub(refresh_stub).was_called(1)
    refresh_stub:revert()
  end)

  it('finishes a refresh when warming a candidate throws', function()
    local callbacks = {}
    vim.defer_fn = function(callback)
      callbacks[#callbacks + 1] = callback
    end
    vim.schedule = function(callback)
      callback()
    end

    local refresh_stub = stub(reference_facts, 'refresh_current_files')
    local files_stub = stub(reference_facts, 'available_files').returns({ 'broken.lua', 'valid.lua' })
    local warmed = {}
    local cycle = {
      warm_path = function(_, path)
        warmed[#warmed + 1] = path
        if path == 'broken.lua' then
          error('failed to warm snapshot')
        end
      end,
    }
    local cycle_stub = stub(symbol_snapshot, 'new_cycle').returns(cycle)

    symbol_refresh.refresh()
    while #callbacks > 0 do
      table.remove(callbacks, 1)()
    end

    assert.same({ 'broken.lua', 'valid.lua' }, warmed)
    assert.is_false(ctx.symbol_refresh_pending)
    assert.is_nil(ctx.symbol_refresh_cycle)

    cycle_stub:revert()
    files_stub:revert()
    refresh_stub:revert()
  end)
end)
