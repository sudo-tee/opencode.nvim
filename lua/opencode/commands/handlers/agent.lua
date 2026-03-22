local core = require('opencode.core')
local config_file = require('opencode.config_file')
---@type OpencodeState
local state = require('opencode.state')
local util = require('opencode.util')
local Promise = require('opencode.promise')

local M = {
  actions = {},
}

---@param message string
local function invalid_arguments(message)
  error({
    code = 'invalid_arguments',
    message = message,
  }, 0)
end

function M.actions.configure_provider()
  core.configure_provider()
end

function M.actions.configure_variant()
  core.configure_variant()
end

function M.actions.cycle_variant()
  core.cycle_variant()
end

function M.actions.agent_plan()
  core.switch_to_mode('plan')
end

function M.actions.agent_build()
  core.switch_to_mode('build')
end

M.actions.select_agent = Promise.async(function()
  local modes = config_file.get_opencode_agents():await()
  local picker = require('opencode.ui.picker')
  picker.select(modes, {
    prompt = 'Select mode:',
  }, function(selection)
    if not selection then
      return
    end

    core.switch_to_mode(selection)
  end)
end)

M.actions.switch_mode = Promise.async(function()
  local modes = config_file.get_opencode_agents():await() --[[@as string[] ]]
  local current_index = util.index_of(modes, state.store.get('current_mode'))

  if current_index == -1 then
    current_index = 0
  end

  local next_index = (current_index % #modes) + 1
  core.switch_to_mode(modes[next_index])
end)

M.actions.current_model = Promise.async(function()
  return core.initialize_current_model()
end)

local agent_subcommands = { 'plan', 'build', 'select' }

---@type table<string, fun(): any>
local agent_subcommand_calls = {
  plan = M.actions.agent_plan,
  build = M.actions.agent_build,
  select = M.actions.select_agent,
}

M.command_defs = {
  agent = {
    desc = 'Manage agents (plan/build/select)',
    completions = agent_subcommands,
    nested_subcommand = { allow_empty = false },
    execute = function(args)
      local action = agent_subcommand_calls[args[1]]
      if not action then
        invalid_arguments('Invalid agent subcommand')
      end
      return action()
    end,
  },
  models = {
    desc = 'Switch provider/model',
    execute = M.actions.configure_provider,
  },
  -- action name aliases for keymap compatibility
  configure_provider = { desc = 'Configure provider',     execute = M.actions.configure_provider },
  configure_variant  = { desc = 'Configure model variant', execute = M.actions.configure_variant },
  variant = {
    desc = 'Switch model variant',
    execute = M.actions.configure_variant,
  },
  cycle_variant = {
    desc = 'Cycle model variant',
    execute = M.actions.cycle_variant,
  },
  switch_mode = {
    desc = 'Cycle agent mode',
    execute = M.actions.switch_mode,
  },
}

return M
