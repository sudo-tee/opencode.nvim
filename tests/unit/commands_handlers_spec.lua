local assert = require('luassert')
local stub = require('luassert.stub')

describe('opencode.commands.handlers', function()
  local tracked_modules = {
    'opencode.core',
    'opencode.state',
    'opencode.promise',
    'opencode.commands',
    'opencode.commands.handlers.window',
    'opencode.commands.handlers.agent',
    'opencode.commands.handlers.surface',
    'opencode.commands.handlers.workflow',
    'opencode.commands.handlers.session',
    'opencode.commands.handlers.diff',
    'opencode.commands.handlers.permission',
  }

  local original_loaded = {}
  local original_preload = {}

  before_each(function()
    original_loaded = {}
    original_preload = {}
    for _, module_name in ipairs(tracked_modules) do
      original_loaded[module_name] = package.loaded[module_name]
      original_preload[module_name] = package.preload[module_name]
      package.loaded[module_name] = nil
      package.preload[module_name] = nil
    end
  end)

  after_each(function()
    for _, module_name in ipairs(tracked_modules) do
      package.loaded[module_name] = original_loaded[module_name]
      package.preload[module_name] = original_preload[module_name]
    end
  end)

  it('fails fast when duplicate command_def key is registered across handler modules', function()
    package.preload['opencode.commands.handlers.window'] = function()
      return {
        command_defs = {
          duplicate = { desc = 'dup', execute = function() end },
        },
      }
    end
    package.preload['opencode.commands.handlers.session'] = function()
      return {
        command_defs = {
          duplicate = { desc = 'dup', execute = function() end },
        },
      }
    end
    package.preload['opencode.commands.handlers.diff'] = function()
      return { command_defs = {} }
    end
    package.preload['opencode.commands.handlers.permission'] = function()
      return { command_defs = {} }
    end
    package.preload['opencode.commands.handlers.agent'] = function()
      return { command_defs = {} }
    end
    package.preload['opencode.commands.handlers.workflow'] = function()
      return { command_defs = {} }
    end
    package.preload['opencode.commands.handlers.surface'] = function()
      return { command_defs = {} }
    end

    local ok, err = pcall(require, 'opencode.commands')

    assert.is_false(ok)
    assert.match("Duplicate command definition 'duplicate'", err)
  end)

  it('exposes command_defs with completions and nested_subcommand from handler modules', function()
    local commands = require('opencode.commands')
    local defs = commands.get_commands()

    assert.same({ 'plan', 'build', 'select' }, defs.agent.completions)
    assert.same({ allow_empty = false }, defs.agent.nested_subcommand)

    assert.same({ 'open', 'next', 'prev', 'close' }, defs.diff.completions)
    assert.same({ allow_empty = true }, defs.diff.nested_subcommand)

    assert.same({ 'all', 'this' }, defs.revert.completions)
    assert.same({ 'prompt', 'session' }, defs.revert.sub_completions)

    assert.same({ 'file', 'all' }, defs.restore.completions)

    assert.same({ 'accept', 'accept_all', 'deny' }, defs.permission.completions)
    assert.same({ allow_empty = false }, defs.permission.nested_subcommand)

    assert.same({ 'new', 'select', 'child', 'compact', 'share', 'unshare', 'agents_init', 'rename' }, defs.session.completions)
    assert.same({ allow_empty = false }, defs.session.nested_subcommand)

    assert.same({ 'input', 'output' }, defs.open.completions)
    assert.equal('user_commands', defs.command.completion_provider_id)

  end)

  it('keeps command semantic validation in window handler (open target)', function()
    local window = require('opencode.commands.handlers.window')
    local ok, err = pcall(window.command_defs.open.execute, { 'sideways' })

    assert.is_false(ok)
    assert.same({
      code = 'invalid_arguments',
      message = 'Invalid target. Use: input or output',
    }, err)
  end)

  it('returns actionable invalid subcommand errors for agent/session/diff handlers', function()
    local agent = require('opencode.commands.handlers.agent')
    local session = require('opencode.commands.handlers.session')
    local diff = require('opencode.commands.handlers.diff')

    local ok_agent, err_agent = pcall(agent.command_defs.agent.execute, { 'unknown' })
    local ok_session, err_session = pcall(session.command_defs.session.execute, { 'unknown' })
    local ok_diff, err_diff = pcall(diff.command_defs.diff.execute, { 'unknown' })

    assert.is_false(ok_agent)
    assert.same({
      code = 'invalid_arguments',
      message = 'Invalid agent subcommand. Use: ' .. table.concat(agent.command_defs.agent.completions, ', '),
    }, err_agent)

    assert.is_false(ok_session)
    assert.same({
      code = 'invalid_arguments',
      message = 'Invalid session subcommand. Use: ' .. table.concat(session.command_defs.session.completions, ', '),
    }, err_session)

    assert.is_false(ok_diff)
    assert.same({
      code = 'invalid_arguments',
      message = 'Invalid diff subcommand. Use: ' .. table.concat(diff.command_defs.diff.completions, ', '),
    }, err_diff)
  end)

  it('keeps help rendering stable in narrow output windows', function()
    local surface = require('opencode.commands.handlers.surface')
    local window = require('opencode.commands.handlers.window')
    local state = require('opencode.state')
    local ui = require('opencode.ui.ui')

    local open_input_stub = stub(window.actions, 'open_input')
    local is_visible_stub = stub(state.ui, 'is_visible').returns(true)
    local set_route_stub = stub(state.ui, 'set_display_route')
    local render_lines_stub = stub(ui, 'render_lines')
    local width_stub = stub(vim.api, 'nvim_win_get_width').returns(20)

    local original_windows = state.store.get('windows')
    local test_windows = vim.deepcopy(original_windows or {})
    test_windows.output_win = 1
    state.store.set_raw('windows', test_windows)

    local ok = pcall(surface.actions.help)

    state.store.set_raw('windows', original_windows)
    open_input_stub:revert()
    is_visible_stub:revert()
    set_route_stub:revert()
    render_lines_stub:revert()
    width_stub:revert()

    assert.is_true(ok)
    assert.stub(render_lines_stub).was_called()
  end)

  it('keeps command semantic routing in diff revert handler (session target -> nil snapshot)', function()
    local called = {}
    local diff = require('opencode.commands.handlers.diff')
    local original_revert_all = diff.actions.diff_revert_all
    local original_revert_this = diff.actions.diff_revert_this
    local original_revert_all_last_prompt = diff.actions.diff_revert_all_last_prompt
    local original_revert_this_last_prompt = diff.actions.diff_revert_this_last_prompt

    diff.actions.diff_revert_all = function(snapshot_id)
      called.scope = 'all'
      called.snapshot_id = snapshot_id
    end
    diff.actions.diff_revert_this = function(_)
      error('should not call diff_revert_this for all scope')
    end
    diff.actions.diff_revert_all_last_prompt = function()
      error('should not call last_prompt path for session target')
    end
    diff.actions.diff_revert_this_last_prompt = function()
      error('should not call last_prompt path for session target')
    end

    diff.command_defs.revert.execute({ 'all', 'session' })

    diff.actions.diff_revert_all = original_revert_all
    diff.actions.diff_revert_this = original_revert_this
    diff.actions.diff_revert_all_last_prompt = original_revert_all_last_prompt
    diff.actions.diff_revert_this_last_prompt = original_revert_this_last_prompt

    assert.equal('all', called.scope)
    assert.is_nil(called.snapshot_id)
  end)
end)
