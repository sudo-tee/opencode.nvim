local assert = require('luassert')
local Promise = require('opencode.promise')

describe('slash command mapping', function()
  local slash
  local original_notify
  local captured_parsed
  local captured_ctx
  local user_commands

  before_each(function()
    original_notify = vim.notify
    captured_parsed = {}
    captured_ctx = {}
    user_commands = nil

    package.loaded['opencode.commands'] = {
      get_commands = function()
        return {
          agent = { desc = 'Agent', nargs = '*' },
          review = { desc = 'Review', nargs = '*' },
          command = { desc = 'Command', nargs = '*' },
        }
      end,
      build_parsed_intent = function(name, args)
        local argv = { name }
        for _, arg in ipairs(args or {}) do
          table.insert(argv, tostring(arg))
        end
        return {
          ok = true,
          intent = {
            name = name,
            args = args or {},
            range = nil,
            source = {
              raw_args = table.concat(argv, ' '),
              argv = argv,
            },
          },
        }
      end,
      execute_parsed_intent = function(parsed)
        table.insert(captured_parsed, vim.deepcopy(parsed))
        local ctx = {
          parsed = parsed,
          intent = parsed.intent,
          args = parsed.intent.args,
          range = parsed.intent.range,
          execute = function() end,
        }
        table.insert(captured_ctx, ctx)
        return 'ok'
      end,
    }

    package.loaded['opencode.config_file'] = {
      get_user_commands = function()
        local p = Promise.new()
        p:resolve(user_commands)
        return p
      end,
    }

    package.loaded['opencode.log'] = {
      notify = function() end,
    }

    vim.notify = function() end

    package.loaded['opencode.commands.slash'] = nil
    slash = require('opencode.commands.slash')
  end)

  after_each(function()
    vim.notify = original_notify

    package.loaded['opencode.commands'] = nil
    package.loaded['opencode.commands.slash'] = nil
    package.loaded['opencode.config_file'] = nil
    package.loaded['opencode.log'] = nil
  end)

  it('maps builtin preset /agent to ParsedIntent and dispatches', function()
    local slash_commands = slash.get_commands():wait()
    local cmd
    for _, entry in ipairs(slash_commands) do
      if entry.slash_cmd == '/agent' then
        cmd = entry
        break
      end
    end

    assert.truthy(cmd)
    cmd.fn({ 'build' })

    assert.equal(1, #captured_parsed)
    assert.same('agent', captured_parsed[1].intent.name)
    assert.same({ 'select', 'build' }, captured_parsed[1].intent.args)
    assert.same({ 'agent', 'select', 'build' }, captured_parsed[1].intent.source.argv)
    assert.equal('agent select build', captured_parsed[1].intent.source.raw_args)
    assert.equal(1, #captured_ctx)
  end)

  it('maps user slash command to command intent and dispatches', function()
    user_commands = {
      build = { description = 'Build project' },
    }

    local slash_commands = slash.get_commands():wait()
    local cmd
    for _, entry in ipairs(slash_commands) do
      if entry.slash_cmd == '/build' then
        cmd = entry
        break
      end
    end

    assert.truthy(cmd)
    cmd.fn({ '--fast' })

    assert.equal(1, #captured_parsed)
    assert.same('command', captured_parsed[1].intent.name)
    assert.same({ 'build', '--fast' }, captured_parsed[1].intent.args)
    assert.same({ 'command', 'build', '--fast' }, captured_parsed[1].intent.source.argv)
    assert.equal('command build --fast', captured_parsed[1].intent.source.raw_args)
    assert.equal(1, #captured_ctx)
  end)
end)
