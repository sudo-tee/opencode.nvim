local timeline_picker = require('opencode.ui.timeline_picker')
local base_picker = require('opencode.ui.base_picker')
local commands = require('opencode.commands')
local dispatch = require('opencode.commands.dispatch')
local session = require('opencode.commands.handlers.session').actions
local config = require('opencode.config')
local stub = require('luassert.stub')

describe('timeline picker command actions', function()
  local picker_options
  local picker_stub
  local undo_stub
  local fork_stub
  local hooks
  local original_hooks

  before_each(function()
    original_hooks = config.hooks
    config.hooks = {}
    hooks = {}
    picker_stub = stub(base_picker, 'pick').invokes(function(opts)
      picker_options = opts
      return true
    end)
    undo_stub = stub(session, 'undo')
    fork_stub = stub(session, 'fork_session')
  end)

  after_each(function()
    for _, hook in ipairs(hooks) do
      dispatch.unregister_hook(hook.stage, hook.id)
    end
    picker_stub:revert()
    undo_stub:revert()
    fork_stub:revert()
    config.hooks = original_hooks
  end)

  for _, action in ipairs({ { 'undo', 'undo' }, { 'fork', 'fork_session' } }) do
    it('dispatches ' .. action[1] .. ' with the message ID and session lifecycle hooks', function()
      local events = {}
      for _, stage in ipairs({ 'before', 'after', 'finally' }) do
        local id = dispatch.register_hook(stage, function(ctx)
          events[#events + 1] = { stage, ctx.intent.name, ctx.args[1] }
        end, { command = 'session' })
        hooks[#hooks + 1] = { stage = stage, id = id }
      end
      local named_hook = dispatch.register_hook('before', function(ctx)
        events[#events + 1] = { 'named', ctx.intent.name, ctx.args[1] }
      end, { command = action[2] })
      hooks[#hooks + 1] = { stage = 'before', id = named_hook }

      assert.is_true(timeline_picker.pick({ { id = 'msg_selected' } }, function() end))
      picker_options.actions[action[1]].fn({ id = 'msg_selected' })

      if action[1] == 'undo' then
        assert.stub(undo_stub).was_called_with('msg_selected')
        assert.stub(fork_stub).was_not_called()
      else
        assert.stub(fork_stub).was_called_with('msg_selected', nil)
        assert.stub(undo_stub).was_not_called()
      end
      assert.same({
        { 'before', action[2], 'msg_selected' },
        { 'named', action[2], 'msg_selected' },
        { 'after', action[2], 'msg_selected' },
        { 'finally', action[2], 'msg_selected' },
      }, events)
      assert.is_false(picker_options.actions[action[1]].reload)
    end)
  end

  it('binds the fork command with its optional tab argument', function()
    commands.execute_command_opts({ args = 'fork_session msg_selected tab', range = 0 })
    assert.stub(fork_stub).was_called_with('msg_selected', 'tab')
  end)
end)
