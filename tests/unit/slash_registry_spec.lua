local assert = require('luassert')
local stub = require('luassert.stub')
local Promise = require('opencode.promise')
local registry = require('opencode.services.slash_registry')
local slash = require('opencode.commands.slash')
local dispatch = require('opencode.commands.dispatch')

describe('custom slash registry', function()
  local user_commands

  before_each(function()
    user_commands = stub(require('opencode.config_file'), 'get_user_commands').returns(Promise.new():resolve({}))
  end)

  after_each(function()
    registry.unregister('worktree')
    user_commands:revert()
    dispatch.reset_hooks_for_test()
  end)

  it('rejects invalid names and builtin or registered collisions', function()
    local function register(name)
      registry.register({ name = name, desc = 'test', fn = function() end })
    end
    assert.has_error(function()
      register('/worktree')
    end)
    assert.has_error(function()
      register('help')
    end)
    register('worktree')
    assert.has_error(function()
      register('worktree')
    end)
    assert.is_true(registry.unregister('worktree'))
    assert.is_false(registry.unregister('worktree'))
  end)

  it('registers after slash module loading and uses dispatch hooks and arguments', function()
    local received, hook_name
    registry.register({
      name = 'worktree',
      desc = 'Worktree',
      args = true,
      fn = function(args)
        received = args
        return 'done'
      end,
    })
    dispatch.register_hook('before', function(ctx)
      hook_name = ctx.intent.name
    end, { command = '/worktree' })
    local command = slash.resolve_input('/worktree feature')
    assert.equal('done', command.fn({ 'feature' }))
    assert.same({ 'feature' }, received)
    assert.equal('/worktree', hook_name)
    slash.execute_builtin('/worktree')
    assert.same({}, received)
  end)

  it('shares live registrations with completion and unregisters them', function()
    registry.register({ name = 'worktree', desc = 'Worktree', args = true, fn = function() end })
    local source = require('opencode.ui.completion.commands').get_source(slash.execute_builtin)
    local context = { line = '/worktree', trigger_char = '/', input = 'worktree' }
    local items = source.complete(context):wait()
    assert.equal(1, #items)
    assert.equal('worktree ', items[1].insert_text)
    registry.unregister('worktree')
    assert.same({}, source.complete(context):wait())
  end)

  it('prefers local callbacks over server commands of the same name', function()
    user_commands:revert()
    user_commands = stub(require('opencode.config_file'), 'get_user_commands').returns(
      Promise.new():resolve({ worktree = { description = 'Server command' } })
    )
    registry.register({ name = 'worktree', desc = 'Local command', fn = function() end })
    local matches = vim.tbl_filter(function(command)
      return command.slash_cmd == '/worktree'
    end, slash.get_commands():wait())
    assert.equal(1, #matches)
    assert.equal('Local command', matches[1].desc)
  end)
end)
