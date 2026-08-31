local assert = require('luassert')
local stub = require('luassert.stub')
local Promise = require('opencode.promise')
local base_picker = require('opencode.ui.base_picker')
local session_runtime = require('opencode.services.session_runtime')
local session_tab_picker = require('opencode.ui.session_tab_picker')

describe('opencode.ui.session_tab_picker', function()
  local original_pick

  before_each(function()
    original_pick = base_picker.pick
  end)

  after_each(function()
    base_picker.pick = original_pick
  end)

  it('provides new and close actions', function()
    local captured_opts
    base_picker.pick = function(opts)
      captured_opts = opts
      return true
    end

    local tabs = { { id = 'tab-1', active_session = { title = 'One' } } }
    assert.is_true(session_tab_picker.pick(tabs, function() end))

    assert.is_table(captured_opts.actions.new)
    assert.is_table(captured_opts.actions.close)
    assert.same({ '<C-s>', desc = 'Create a new panel tab' }, captured_opts.actions.new.key)
    assert.same({ '<C-d>', desc = 'Close selected panel tab' }, captured_opts.actions.close.key)
  end)

  it('opens a new tab through new action and closes picker', function()
    local captured_opts
    base_picker.pick = function(opts)
      captured_opts = opts
      return true
    end

    session_tab_picker.pick({ { id = 'tab-1' } }, function() end)

    local open_stub = stub(session_runtime, 'open_session_tab').returns(Promise.new():resolve({ id = 'new' }))
    local closed = false
    captured_opts.actions.new
      .fn({}, {
        close = function()
          closed = true
        end,
      })
      :wait()

    assert.is_true(closed)
    assert.stub(open_stub).was_called()
    open_stub:revert()
  end)

  it('closes selected inactive tab without switching active tab', function()
    local captured_opts
    base_picker.pick = function(opts)
      captured_opts = opts
      return true
    end

    session_tab_picker.pick({ { id = 'tab-1' }, { id = 'tab-2' } }, function() end)

    local close_stub = stub(session_runtime, 'close_session_tab')
    local closed
    close_stub.invokes(function(tab_id)
      closed = tab_id
      return true
    end)

    local closed_picker = false
    captured_opts.actions.close.fn({ id = 'tab-2' }, {
      close = function()
        closed_picker = true
      end,
    })

    assert.is_true(closed_picker)
    assert.equal('tab-2', closed)

    close_stub:revert()
  end)
end)
