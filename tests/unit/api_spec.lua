local api = require('opencode.api')
local commands = require('opencode.commands')
local command_parse = require('opencode.commands.parse')
local slash = require('opencode.commands.slash')
local session_runtime = require('opencode.services.session_runtime')
local messaging = require('opencode.services.messaging')
local agent_model = require('opencode.services.agent_model')
local context = require('opencode.context')
local input_window = require('opencode.ui.input_window')
local ui = require('opencode.ui.ui')
local state = require('opencode.state')
local stub = require('luassert.stub')
local assert = require('luassert')
local Promise = require('opencode.promise')

---@param id string
---@return Session
local function mk_session(id)
  ---@type Session
  return {
    id = id,
    workspace = '/mock/workspace',
    title = id,
    time = { created = 0, updated = 0 },
    parentID = nil,
  }
end

---@return OpencodeApiClient
local function mk_api_client_for_test()
  ---@type OpencodeApiClient
  local client = {
    base_url = 'http://127.0.0.1:4000',
    create_message = function(_, _, _)
      local promise = Promise.new()
      promise:resolve({
        info = {
          id = 'message-1',
          sessionID = 'session-1',
          tokens = { reasoning = 0, input = 0, output = 0, cache = { write = 0, read = 0 } },
          system = {},
          time = { created = 0, completed = 0 },
          cost = 0,
          path = { cwd = '/mock/workspace', root = '/mock/workspace' },
          modelID = 'model',
          providerID = 'provider',
          role = 'assistant',
          system_role = nil,
          mode = nil,
          error = {},
        },
        parts = { { type = 'text', text = 'ok' } },
      })
      return promise
    end,
  }
  return client
end

---@generic T
---@param value T
---@return Promise<T>
local function resolved(value)
  return Promise.new():resolve(value)
end

---@param user_commands table<string, any>|nil
---@param fn fun()
local function with_user_commands(user_commands, fn)
  local config_file = require('opencode.config_file')
  local original_get_user_commands = config_file.get_user_commands

  config_file.get_user_commands = function()
    return resolved(user_commands)
  end

  local ok, err = pcall(fn)
  config_file.get_user_commands = original_get_user_commands
  if not ok then
    error(err)
  end
end

---@param config table
---@param fn fun()
local function with_opencode_config(config, fn)
  local config_file = require('opencode.config_file')
  local original_get_opencode_config = config_file.get_opencode_config

  config_file.get_opencode_config = function()
    return resolved(config)
  end

  local ok, err = pcall(fn)
  config_file.get_opencode_config = original_get_opencode_config
  if not ok then
    error(err)
  end
end

---@param fn fun()
local function with_model_runtime_snapshot(fn)
  local original_model = state.current_model
  local original_mode = state.current_mode
  local original_messages = state.messages

  local ok, err = pcall(fn)

  state.model.set_model(original_model)
  state.model.set_mode(original_mode)
  state.renderer.set_messages(original_messages)

  if not ok then
    error(err)
  end
end

---@param fn fun()
local function with_session_client_snapshot(fn)
  local original_active_session = state.active_session
  local original_api_client = state.api_client

  local ok, err = pcall(fn)

  state.session.set_active(original_active_session)
  state.jobs.set_api_client(original_api_client)

  if not ok then
    error(err)
  end
end

---@param commands_list table[]
---@param slash_name string
---@return table|nil
local function find_slash_command(commands_list, slash_name)
  for _, cmd in ipairs(commands_list) do
    if cmd.slash_cmd == slash_name then
      return cmd
    end
  end
  return nil
end

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
    stub(session_runtime, 'open').invokes(function()
      return resolved('done')
    end)

    stub(session_runtime, 'cancel')
    stub(messaging, 'send_message')
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
    local function assert_send_message_called_with(prompt, new_session)
      assert.stub(messaging.send_message).was_called()
      assert.stub(messaging.send_message).was_called_with(prompt, {
        new_session = new_session,
        focus = 'output',
      })
    end

    it('provides callable functions that match commands', function()
      assert.is_function(api.open_input, 'Should export open_input')
      api.open_input():wait()
      assert.stub(session_runtime.open).was_called()
      assert.stub(session_runtime.open).was_called_with({ new_session = false, focus = 'input', start_insert = true })

      local create_new_session_stub = stub(session_runtime, 'create_new_session').invokes(function()
        return resolved({ id = 'session-1' })
      end)
      local set_active_stub = stub(state.session, 'set_active')

      assert.is_function(api.open_input_new_session_with_title, 'Should export open_input_new_session_with_title')
      api.open_input_new_session_with_title('My Session'):wait()
      assert.stub(create_new_session_stub).was_called_with('My Session')
      assert.stub(set_active_stub).was_called_with({ id = 'session-1' })
      create_new_session_stub:revert()
      set_active_stub:revert()

      assert.is_function(api.run, 'Should export run')
      api.run('test prompt'):wait()
      assert_send_message_called_with('test prompt', false)

      assert.is_function(api.run_new_session, 'Should export run_new_session')
      api.run_new_session('test prompt new'):wait()
      assert_send_message_called_with('test prompt new', true)
    end)

    it('routes submit_input_prompt through handle_submit, send_message, and after_run', function()
      with_session_client_snapshot(function()
        with_model_runtime_snapshot(function()
          state.session.set_active(mk_session('session-1'))
          state.jobs.set_api_client(mk_api_client_for_test())

          stub(context, 'get_context').returns({ mentioned_files = {} })
          stub(context, 'load')
          stub(context, 'format_message').invokes(function()
            return resolved({ { type = 'text', text = 'hello' } })
          end)
          stub(agent_model, 'initialize_current_model').invokes(function()
            return resolved('provider/model')
          end)

          local after_run_stub = stub(messaging, 'after_run')
          local send_message_stub = stub(messaging, 'send_message').invokes(function(prompt)
            require('opencode.services.messaging').after_run(prompt)
            return true
          end)
          local handle_submit_stub = stub(input_window, 'handle_submit').invokes(function()
            require('opencode.services.messaging').send_message('hello')
            return true
          end)
          local is_hidden_stub = stub(input_window, 'is_hidden').returns(true)

          api.submit_input_prompt():wait()

          assert.stub(handle_submit_stub).was_called()
          assert.stub(send_message_stub).was_called_with('hello')
          assert.stub(after_run_stub).was_called_with('hello')

          send_message_stub:revert()
          after_run_stub:revert()
          handle_submit_stub:revert()
          agent_model.initialize_current_model:revert()
          context.format_message:revert()
          context.load:revert()
          context.get_context:revert()
          is_hidden_stub:revert()
        end)
      end)
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
      with_user_commands({
        ['build'] = { description = 'Build the project' },
        ['test'] = { description = 'Run tests' },
        ['deploy'] = { description = 'Deploy to production' },
      }, function()
        stub(ui, 'render_lines')

        api.commands_list():wait()

        assert.stub(session_runtime.open).was_called_with({ new_session = false, focus = 'input', start_insert = true })
        assert.stub(ui.render_lines).was_called()

        ---@diagnostic disable-next-line: undefined-field
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
      end)
    end)

    it('shows warning when no user commands exist', function()
      with_user_commands(nil, function()
        local notify_stub = stub(vim, 'notify')

        api.commands_list():wait()

        assert
          .stub(notify_stub)
          .was_called_with('No user commands found. Please check your opencode config file.', vim.log.levels.WARN)

        notify_stub:revert()
      end)
    end)
  end)

  describe('command autocomplete', function()
    it('filters user command completions by arg lead', function()
      with_user_commands({
        ['build'] = { description = 'Build the project' },
        ['deploy'] = { description = 'Deploy to production' },
      }, function()
        local completions = commands.complete_command('b', 'Opencode command b', 18)
        assert.same({ 'build' }, completions)
      end)
    end)

    it('provides sorted user command names for completion', function()
      with_user_commands({
        ['build'] = { description = 'Build the project' },
        ['test'] = { description = 'Run tests' },
        ['deploy'] = { description = 'Deploy to production' },
      }, function()
        local completions = commands.complete_command('', 'Opencode command ', 17)
        assert.same({ 'build', 'deploy', 'test' }, completions)
      end)
    end)

    it('returns empty array when no user commands exist', function()
      with_user_commands(nil, function()
        local completions = commands.complete_command('', 'Opencode command ', 17)
        assert.same({}, completions)
      end)
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
          return resolved('done')
        end)
      end)

      it('invokes run with correct model and agent', function()
        with_user_commands({
          ['test-with-model'] = {
            description = 'Run tests',
            template = 'Run tests with $ARGUMENTS',
            model = 'openai/gpt-4',
            agent = 'tester',
          },
        }, function()
          with_session_client_snapshot(function()
            state.session.set_active(mk_session('test-session'))

            local send_command_calls = {}
            state.jobs.set_api_client({
              base_url = 'http://127.0.0.1:4000',
              send_command = function(_self, session_id, command_data)
                table.insert(send_command_calls, { session_id = session_id, command_data = command_data })
                return {
                  and_then = function()
                    return {}
                  end,
                }
              end,
            })

            local slash_commands = slash.get_commands():wait()
            local test_with_model_cmd = find_slash_command(slash_commands, '/test-with-model')

            assert.truthy(test_with_model_cmd, 'Should find /test-with-model command')

            test_with_model_cmd.fn():wait()
            assert.equal(1, #send_command_calls)
            assert.equal('test-session', send_command_calls[1].session_id)
            assert.equal('test-with-model', send_command_calls[1].command_data.command)
            assert.equal('', send_command_calls[1].command_data.arguments)
            assert.equal('openai/gpt-4', send_command_calls[1].command_data.model)
            assert.equal('tester', send_command_calls[1].command_data.agent)
          end)
        end)
      end)
    end)

    it('uses default description when none provided', function()
      with_user_commands({ ['custom'] = {} }, function()
        local slash_commands = slash.get_commands():wait()
        local custom_cmd = find_slash_command(slash_commands, '/custom')

        assert.truthy(custom_cmd, 'Should include /custom command')
        assert.equal('User command', custom_cmd.desc)
      end)
    end)

    it('includes built-in slash commands alongside user commands', function()
      with_user_commands({
        ['build'] = { description = 'Build the project' },
      }, function()
        local slash_commands = slash.get_commands():wait()
        local help_cmd = find_slash_command(slash_commands, '/help')
        local build_cmd = find_slash_command(slash_commands, '/build')

        assert.truthy(help_cmd, 'Should include built-in /help command')
        assert.truthy(build_cmd, 'Should include user /build command')
      end)
    end)
  end)

  describe('current_model', function()
    it('returns the current model from state', function()
      with_model_runtime_snapshot(function()
        state.model.set_model('testmodel')

        local model = api.current_model():wait()
        assert.equal('testmodel', model)
      end)
    end)

    it('falls back to config file model when state.current_model is nil', function()
      with_model_runtime_snapshot(function()
        state.model.clear_model()
        state.model.clear_mode()
        state.renderer.set_messages(nil)

        with_opencode_config({ model = 'testmodel' }, function()
          local model = api.current_model():wait()
          assert.equal('testmodel', model)
        end)
      end)
    end)

    it('does not overwrite a user-selected model from prior session messages', function()
      with_model_runtime_snapshot(function()
        state.model.set_model('openai/gpt-4.1')
        state.model.set_mode('plan')
        state.renderer.set_messages({
          {
            info = {
              id = 'm1',
              providerID = 'anthropic',
              modelID = 'claude-3-opus',
              mode = 'build',
            },
          },
        })

        local model = api.current_model():wait()

        assert.equal('openai/gpt-4.1', model)
        assert.equal('openai/gpt-4.1', state.current_model)
        assert.equal('plan', state.current_mode)
      end)
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
