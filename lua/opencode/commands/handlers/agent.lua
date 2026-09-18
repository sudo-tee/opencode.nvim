local config_file = require('opencode.config_file')
---@type OpencodeState
local state = require('opencode.state')
local util = require('opencode.util')
local Promise = require('opencode.promise')
local agent_model = require('opencode.services.agent_model')
local ui = require('opencode.ui.ui')
local log = require('opencode.log')

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

---@param message? string Omitted when the picker was cancelled
local function finish_selection(message)
  if state.ui.is_visible() then
    ui.focus_input()
  elseif message then
    log.notify(message, vim.log.levels.INFO)
  end
end

function M.actions.configure_provider()
  require('opencode.model_picker').select(function(selection)
    if not selection then
      finish_selection()
      return
    end
    local model = agent_model.set_model(selection.provider, selection.model)
    finish_selection('Changed provider to ' .. model)
  end)
end

function M.actions.configure_variant()
  require('opencode.variant_picker').select(function(selection)
    if not selection then
      finish_selection()
      return
    end
    agent_model.set_variant(selection.value)
    finish_selection('Changed variant to ' .. selection.name)
  end)
end

function M.actions.cycle_variant()
  agent_model.cycle_variant()
end

function M.actions.agent_plan()
  agent_model.switch_to_mode('plan')
end

function M.actions.agent_build()
  agent_model.switch_to_mode('build')
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

    agent_model.switch_to_mode(selection)
  end)
end)

M.actions.switch_mode = Promise.async(function()
  local modes = config_file.get_opencode_agents():await() --[[@as string[] ]]
  local current_index = util.index_of(modes, state.store.get('current_mode'))

  if current_index == nil then
    current_index = 0
  end

  local next_index = (current_index % #modes) + 1
  agent_model.switch_to_mode(modes[next_index])
end)

M.actions.current_model = Promise.async(function()
  return agent_model.initialize_current_model()
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
        invalid_arguments('Invalid agent subcommand. Use: ' .. table.concat(agent_subcommands, ', '))
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
