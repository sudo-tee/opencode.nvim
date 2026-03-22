local api = require('opencode.api')
local commands = require('opencode.commands')
local command_parse = require('opencode.commands.parse')
local slash = require('opencode.commands.slash')
local core = require('opencode.core')
local ui = require('opencode.ui.ui')
local state = require('opencode.state')
local stub = require('luassert.stub')
local assert = require('luassert')
local Promise = require('opencode.promise')

describe('opencode.api', function()
  local created_commands = {}

  before_each(function()
    created_commands = {}
    stub(vim.api, 'nvim_create_user_command').invokes(function(name, fn, opts)
      table.insert(created_commands, {
        name = name,
        fn = fn,
        opts = opts,
      })
    end)
    stub(core, 'open').invokes(function()
      return Promise.new():resolve('done')
    end)

    stub(core, 'run')
    stub(core, 'cancel')
    stub(core, 'send_message')
    stub(ui, 'close_windows')
  end)

  after_each(function()
    -- luassert.stub automatically restores originals after each test
  end)

  describe('command registry', function()
    it('contains the expected commands with proper structure', function()
      local defs = commands.get_commands()
      local required_commands = { 'open', 'session', 'run', 'toggle_zoom' }

      for cmd_name, cmd in pairs(defs) do
        assert.truthy(cmd_name, 'Command name should exist')
        assert.truthy(cmd.desc, 'Command should have a description')
        assert.is_function(cmd.execute, 'Command should have an execute function')
        assert.not_equal('function', type(cmd.completions), 'Registry should not carry runtime completion functions')
      end

      for _, cmd_name in ipairs(required_commands) do
        assert.truthy(defs[cmd_name], 'Command ' .. cmd_name .. ' should exist')
      end

      assert.equal('user_commands', defs.command.completion_provider_id)
    end)

    it('keeps slash command strings parseable against command schema', function()
      local command_defs = commands.get_commands()

      for slash_name, slash_def in pairs(slash.get_builtin_command_definitions()) do
        if slash_def.cmd_str then
          local parsed = command_parse.command({ args = slash_def.cmd_str, range = 0 }, command_defs)
          assert.is_true(parsed.ok, 'Slash command drift: ' .. slash_name)
        end
      end
    end)
  end)

  describe('command routing', function()
    it('reports invalid nested subcommand before execution', function()
      local notify_stub = stub(vim, 'notify')

      local result = commands.execute_command_opts({ args = 'agent unknown', range = 0 })

      assert.is_nil(result)
      assert
        .stub(notify_stub)
        .was_called_with('Invalid agent subcommand. Use: plan, build, select', vim.log.levels.ERROR)

      notify_stub:revert()
    end)

    it('notifies on unknown subcommand', function()
      local notify_stub = stub(vim, 'notify')

      local result = commands.execute_command_opts({ args = 'not_a_real_command', range = 0 })

      assert.is_nil(result)
      assert.stub(notify_stub).was_called_with('Unknown subcommand: not_a_real_command', vim.log.levels.ERROR)

      notify_stub:revert()
    end)
  end)

  describe('setup', function()
    it('registers the main Opencode command', function()
      commands.setup()

      assert.equal(1, #created_commands)
      assert.equal('Opencode', created_commands[1].name)
      assert.equal('Opencode.nvim main command with nested subcommands', created_commands[1].opts.desc)
    end)
  end)

  describe('public boundary', function()
    it('does not expose command layer APIs via opencode.api', function()
      assert.is_nil(api.setup)
      assert.is_nil(api.get_slash_commands)
      assert.is_nil(api.commands)
    end)
  end)

  describe('actions consolidation', function()
    it('keeps display/permission/history/session APIs callable from api', function()
      assert.is_nil(package.loaded['opencode.actions'])

      assert.is_function(api.close)
      assert.is_function(api.hide)
      assert.is_function(api.with_header)
      assert.is_function(api.help)
      assert.is_function(api.commands_list)
      assert.is_function(api.submit_input_prompt)
      assert.is_function(api.toggle_tool_output)
      assert.is_function(api.toggle_reasoning_output)

      assert.is_function(api.select_history)
      assert.is_function(api.prev_history)
      assert.is_function(api.next_history)
      assert.is_function(api.prev_prompt_history)
      assert.is_function(api.next_prompt_history)

      assert.is_function(api.respond_to_permission)
      assert.is_function(api.permission_accept)
      assert.is_function(api.permission_accept_all)
      assert.is_function(api.permission_deny)
      assert.is_function(api.question_answer)
      assert.is_function(api.question_other)

      assert.is_function(api.open_input_new_session_with_title)
    end)
  end)

  describe('Lua API', function()
    it('provides callable functions that match commands', function()
      assert.is_function(api.open_input, 'Should export open_input')
      api.open_input():wait()
      assert.stub(core.open).was_called()
      assert.stub(core.open).was_called_with({ new_session = false, focus = 'input', start_insert = true })

      local create_new_session_stub = stub(core, 'create_new_session').invokes(function()
        return Promise.new():resolve({ id = 'session-1' })
      end)
      local set_active_stub = stub(state.session, 'set_active')

      assert.is_function(api.open_input_new_session_with_title, 'Should export open_input_new_session_with_title')
      api.open_input_new_session_with_title('My Session'):wait()
      assert.stub(create_new_session_stub).was_called_with('My Session')
      assert.stub(set_active_stub).was_called_with({ id = 'session-1' })
      assert.stub(core.open).was_called_with({ new_session = false, focus = 'input', start_insert = true })
      create_new_session_stub:revert()
      set_active_stub:revert()

      assert.is_function(api.run, 'Should export run')
      api.run('test prompt'):wait()
      assert.stub(core.send_message).was_called()
      assert.stub(core.send_message).was_called_with('test prompt', {
        new_session = false,
        focus = 'output',
      })

      assert.is_function(api.run_new_session, 'Should export run_new_session')
      api.run_new_session('test prompt new'):wait()
      assert.stub(core.send_message).was_called()
      assert.stub(core.send_message).was_called_with('test prompt new', {
        new_session = true,
        focus = 'output',
      })
    end)
  end)

  describe('run command argument parsing', function()
    it('requires a prompt after prefixes', function()
      local notify_stub = stub(vim, 'notify')

      local result = commands.execute_command_opts({ args = 'run agent=plan', range = 0 })

      assert.is_nil(result)
      assert.stub(notify_stub).was_called_with('Prompt required', vim.log.levels.ERROR)

      notify_stub:revert()
    end)
  end)

  describe('/commands command', function()
    it('displays user commands when available', function()
      local config_file = require('opencode.config_file')
      local original_get_user_commands = config_file.get_user_commands

      config_file.get_user_commands = function()
        local p = Promise.new()
        p:resolve({
          ['build'] = { description = 'Build the project' },
          ['test'] = { description = 'Run tests' },
          ['deploy'] = { description = 'Deploy to production' },
        })
        return p
      end

      stub(ui, 'render_lines')

      api.commands_list():wait()

      assert.stub(core.open).was_called_with({ new_session = false, focus = 'input', start_insert = true })
      assert.stub(ui.render_lines).was_called()

      local render_args = ui.render_lines.calls[1].refs[1]
      local rendered_text = table.concat(render_args, '\n')

      assert.truthy(rendered_text:match('Available User Commands'))
      assert.truthy(rendered_text:match('Description'))
      assert.truthy(rendered_text:match('build'))
      assert.truthy(rendered_text:match('Build the project'))
      assert.truthy(rendered_text:match('test'))
      assert.truthy(rendered_text:match('Run tests'))
      assert.truthy(rendered_text:match('deploy'))
      assert.truthy(rendered_text:match('Deploy to production'))

      config_file.get_user_commands = original_get_user_commands
    end)

    it('shows warning when no user commands exist', function()
      local config_file = require('opencode.config_file')
      local original_get_user_commands = config_file.get_user_commands

      config_file.get_user_commands = function()
        local p = Promise.new()
        p:resolve(nil)
        return p
      end

      local notify_stub = stub(vim, 'notify')

      api.commands_list():wait()

      assert
        .stub(notify_stub)
        .was_called_with('No user commands found. Please check your opencode config file.', vim.log.levels.WARN)

      config_file.get_user_commands = original_get_user_commands
      notify_stub:revert()
    end)
  end)

  describe('command autocomplete', function()
    it('filters user command completions by arg lead', function()
      local config_file = require('opencode.config_file')
      local original_get_user_commands = config_file.get_user_commands

      config_file.get_user_commands = function()
        local p = Promise.new()
        p:resolve({
          ['build'] = { description = 'Build the project' },
          ['deploy'] = { description = 'Deploy to production' },
        })
        return p
      end

      local completions = commands.complete_command('b', 'Opencode command b', 18)

      assert.same({ 'build' }, completions)

      config_file.get_user_commands = original_get_user_commands
    end)

    it('provides sorted user command names for completion', function()
      local config_file = require('opencode.config_file')
      local original_get_user_commands = config_file.get_user_commands

      config_file.get_user_commands = function()
        local p = Promise.new()
        p:resolve({
          ['build'] = { description = 'Build the project' },
          ['test'] = { description = 'Run tests' },
          ['deploy'] = { description = 'Deploy to production' },
        })
        return p
      end

      local completions = commands.complete_command('', 'Opencode command ', 17)

      assert.same({ 'build', 'deploy', 'test' }, completions)

      config_file.get_user_commands = original_get_user_commands
    end)

    it('returns empty array when no user commands exist', function()
      local config_file = require('opencode.config_file')
      local original_get_user_commands = config_file.get_user_commands

      config_file.get_user_commands = function()
        local p = Promise.new()
        p:resolve(nil)
        return p
      end

      local completions = commands.complete_command('', 'Opencode command ', 17)

      assert.same({}, completions)

      config_file.get_user_commands = original_get_user_commands
    end)

    it('returns empty array for invalid provider id', function()
      local get_commands_stub = stub(commands, 'get_commands').returns({
        broken = {
          desc = 'Broken completion provider command',
          execute = function() end,
          completion_provider_id = 'missing_provider',
        },
      })

      assert.has_no.errors(function()
        local completions = commands.complete_command('', 'Opencode broken ', 16)
        assert.same({}, completions)
      end)

      get_commands_stub:revert()
    end)
  end)

  describe('slash commands with user commands', function()
    describe('user command model/agent selection', function()
      before_each(function()
        stub(api, 'open_input').invokes(function()
          return Promise.new():resolve('done')
        end)
      end)

      it('invokes run with correct model and agent', function()
        local config_file = require('opencode.config_file')
        local original_get_user_commands = config_file.get_user_commands

        config_file.get_user_commands = function()
          local p = Promise.new()
          p:resolve({
            ['test-with-model'] = {
              description = 'Run tests',
              template = 'Run tests with $ARGUMENTS',
              model = 'openai/gpt-4',
              agent = 'tester',
            },
          })
          return p
        end

        local original_active_session = state.active_session
        state.session.set_active({ id = 'test-session' })

        local original_api_client = state.api_client
        local send_command_calls = {}
        state.jobs.set_api_client({
          send_command = function(self, session_id, command_data)
            table.insert(send_command_calls, { session_id = session_id, command_data = command_data })
            return {
              and_then = function()
                return {}
              end,
            }
          end,
        })

        local slash_commands = slash.get_commands():wait()

        local test_with_model_cmd

        for _, cmd in ipairs(slash_commands) do
          if cmd.slash_cmd == '/test-with-model' then
            test_with_model_cmd = cmd
          end
        end

        assert.truthy(test_with_model_cmd, 'Should find /test-with-model command')

        test_with_model_cmd.fn():wait()
        assert.equal(1, #send_command_calls)
        assert.equal('test-session', send_command_calls[1].session_id)
        assert.equal('test-with-model', send_command_calls[1].command_data.command)
        assert.equal('', send_command_calls[1].command_data.arguments)
        assert.equal('openai/gpt-4', send_command_calls[1].command_data.model)
        assert.equal('tester', send_command_calls[1].command_data.agent)

        config_file.get_user_commands = original_get_user_commands
        state.session.set_active(original_active_session)
        state.jobs.set_api_client(original_api_client)
      end)
    end)

    it('uses default description when none provided', function()
      local config_file = require('opencode.config_file')
      local original_get_user_commands = config_file.get_user_commands

      config_file.get_user_commands = function()
        local p = Promise.new()
        p:resolve({
          ['custom'] = {},
        })
        return p
      end

      local slash_commands = slash.get_commands():wait()

      local custom_found = false
      for _, cmd in ipairs(slash_commands) do
        if cmd.slash_cmd == '/custom' then
          custom_found = true
          assert.equal('User command', cmd.desc)
        end
      end

      assert.truthy(custom_found, 'Should include /custom command')

      config_file.get_user_commands = original_get_user_commands
    end)

    it('includes built-in slash commands alongside user commands', function()
      local config_file = require('opencode.config_file')
      local original_get_user_commands = config_file.get_user_commands

      config_file.get_user_commands = function()
        local p = Promise.new()
        p:resolve({
          ['build'] = { description = 'Build the project' },
        })
        return p
      end

      local slash_commands = slash.get_commands():wait()

      local help_found = false
      local build_found = false

      for _, cmd in ipairs(slash_commands) do
        if cmd.slash_cmd == '/help' then
          help_found = true
        elseif cmd.slash_cmd == '/build' then
          build_found = true
        end
      end

      assert.truthy(help_found, 'Should include built-in /help command')
      assert.truthy(build_found, 'Should include user /build command')

      config_file.get_user_commands = original_get_user_commands
    end)
  end)

  describe('current_model', function()
    it('returns the current model from state', function()
      local original_model = state.current_model
      state.model.set_model('testmodel')

      local model = api.current_model():wait()
      assert.equal('testmodel', model)

      state.model.set_model(original_model)
    end)

    it('falls back to config file model when state.current_model is nil', function()
      local original_model = state.current_model
      state.model.clear_model()

      local config_file = require('opencode.config_file')
      local original_get_opencode_config = config_file.get_opencode_config

      config_file.get_opencode_config = function()
        local p = Promise.new()
        p:resolve({ model = 'testmodel' })
        return p
      end

      local model = api.current_model():wait()

      assert.equal('testmodel', model)

      config_file.get_opencode_config = original_get_opencode_config
      state.model.set_model(original_model)
    end)
  end)

  describe('toggle_zoom', function()
    it('calls ui.toggle_zoom when toggle_zoom is called', function()
      stub(ui, 'toggle_zoom')

      api.toggle_zoom()

      assert.stub(ui.toggle_zoom).was_called()
    end)

    it('is available in the commands table', function()
      local cmd = commands.get_commands()['toggle_zoom']
      assert.truthy(cmd, 'toggle_zoom command should exist')
      assert.equal('Toggle window zoom', cmd.desc)
      assert.is_function(cmd.execute)
    end)
  end)
end)
