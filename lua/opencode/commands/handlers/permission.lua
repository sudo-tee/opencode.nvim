---@type OpencodeState
local state = require('opencode.state')

local M = {
  actions = {},
}

local permission_subcommands = { 'accept', 'accept_all', 'deny' }

---@param message string
local function invalid_arguments(message)
  error({
    code = 'invalid_arguments',
    message = message,
  }, 0)
end

---@param answer? 'once'|'always'|'reject'
---@param permission? OpencodePermission
function M.actions.respond_to_permission(answer, permission)
  answer = answer or 'once'

  local permission_window = require('opencode.ui.permission_window')
  local current_permission = permission or permission_window.get_current_permission()
  if not current_permission then
    vim.notify('No permission request to accept', vim.log.levels.WARN)
    return
  end

  state.api_client
    :respond_to_permission(current_permission.sessionID, current_permission.id, { response = answer })
    :catch(function(err)
      vim.schedule(function()
        vim.notify('Failed to reply to permission: ' .. vim.inspect(err), vim.log.levels.ERROR)
      end)
    end)
end

---@param permission? OpencodePermission
function M.actions.permission_accept(permission)
  M.actions.respond_to_permission('once', permission)
end

---@param permission? OpencodePermission
function M.actions.permission_accept_all(permission)
  M.actions.respond_to_permission('always', permission)
end

---@param permission? OpencodePermission
function M.actions.permission_deny(permission)
  M.actions.respond_to_permission('reject', permission)
end

function M.actions.question_answer()
  local question_window = require('opencode.ui.question_window')
  local question_info = question_window.get_current_question_info()
  if question_info and question_info.options and question_info.options[1] then
    question_window._answer_with_option(1)
  end
end

function M.actions.question_other()
  local question_window = require('opencode.ui.question_window')
  if question_window.has_question() then
    question_window._answer_with_custom()
  end
end

---@type table<string, fun(permission?: OpencodePermission): nil>
local permission_subcommand_actions = {
  accept = M.actions.permission_accept,
  accept_all = M.actions.permission_accept_all,
  deny = M.actions.permission_deny,
}

M.command_defs = {
  permission = {
    desc = 'Respond to permissions (accept/accept_all/deny)',
    completions = permission_subcommands,
    nested_subcommand = { allow_empty = false },
    execute = function(args)
      local subcmd = args[1]
      local index = tonumber(args[2])
      local permission = nil

      if index then
        local permission_window = require('opencode.ui.permission_window')
        local permissions = permission_window.get_all_permissions()
        if not permissions or not permissions[index] then
          error({
            code = 'invalid_arguments',
            message = 'Invalid permission index: ' .. tostring(index),
          }, 0)
        end

        permission = permissions[index]
      end

      local action = permission_subcommand_actions[subcmd]
      if not action then
        invalid_arguments('Invalid permission subcommand. Use: accept, accept_all, or deny')
      end

      action(permission)
    end,
  },
}

return M
