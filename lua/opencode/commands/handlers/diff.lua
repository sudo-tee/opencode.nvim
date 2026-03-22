local core = require('opencode.core')
local git_review = require('opencode.git_review')
local session_store = require('opencode.session')
---@type OpencodeState
local state = require('opencode.state')

local M = {
  actions = {},
}

local diff_subcommands = { 'open', 'next', 'prev', 'close' }

local function with_output_open(callback, open_if_closed)
  local open_fn = open_if_closed and core.open_if_closed or core.open
  return function(...)
    local args = { ... }
    open_fn({ new_session = false, focus = 'output' }):and_then(function()
      callback(unpack(args))
    end)
  end
end

---@param message string
local function invalid_arguments(message)
  error({
    code = 'invalid_arguments',
    message = message,
  }, 0)
end

---@param from_snapshot_id? string
---@param _to_snapshot_id? string|number
M.actions.diff_open = with_output_open(function(from_snapshot_id, _to_snapshot_id)
  git_review.review(from_snapshot_id)
end, true)

M.actions.diff_next = with_output_open(function()
  git_review.next_diff()
end, false)

M.actions.diff_prev = with_output_open(function()
  git_review.prev_diff()
end, false)

M.actions.diff_close = with_output_open(function()
  git_review.close_diff()
end, false)

---@param from_snapshot_id? string
M.actions.diff_revert_all = with_output_open(function(from_snapshot_id)
  git_review.revert_all(from_snapshot_id)
end, false)

---@param from_snapshot_id? string
---@param _to_snapshot_id? string
M.actions.diff_revert_selected_file = with_output_open(function(from_snapshot_id, _to_snapshot_id)
  git_review.revert_selected_file(from_snapshot_id)
end, false)

---@return string|nil
local function get_last_prompt_snapshot_id_or_warn()
  local snapshots = session_store.get_message_snapshot_ids(state.current_message)
  local snapshot_id = snapshots and snapshots[1]
  if not snapshot_id then
    vim.notify('No snapshots found for the current message', vim.log.levels.WARN)
    return nil
  end

  return snapshot_id
end

M.actions.diff_revert_all_last_prompt = with_output_open(function()
  local snapshot_id = get_last_prompt_snapshot_id_or_warn()
  if not snapshot_id then
    return
  end

  git_review.revert_all(snapshot_id)
end, false)

---@param snapshot_id? string
M.actions.diff_revert_this = with_output_open(function(snapshot_id)
  git_review.revert_current(snapshot_id)
end, false)

M.actions.diff_revert_this_last_prompt = with_output_open(function()
  local snapshot_id = get_last_prompt_snapshot_id_or_warn()
  if not snapshot_id then
    return
  end

  git_review.revert_current(snapshot_id)
end, false)

---@param restore_point_id? string
M.actions.diff_restore_snapshot_file = with_output_open(function(restore_point_id)
  git_review.restore_snapshot_file(restore_point_id)
end, false)

---@param restore_point_id? string
M.actions.diff_restore_snapshot_all = with_output_open(function(restore_point_id)
  git_review.restore_snapshot_all(restore_point_id)
end, false)

M.actions.set_review_breakpoint = with_output_open(function()
  git_review.create_snapshot()
end, false)

---@type table<string, fun(): any>
local diff_subcommand_actions = {
  open = M.actions.diff_open,
  next = M.actions.diff_next,
  prev = M.actions.diff_prev,
  close = M.actions.diff_close,
}

---@type table<string, table<string, fun(target?: string): any|nil>>
local revert_scope_actions = {
  all = {
    prompt = function(_)
      return M.actions.diff_revert_all_last_prompt()
    end,
    session = function(_)
      return M.actions.diff_revert_all(nil)
    end,
    default = function(target)
      return M.actions.diff_revert_all(target)
    end,
  },
  this = {
    prompt = function(_)
      return M.actions.diff_revert_this_last_prompt()
    end,
    session = function(_)
      return M.actions.diff_revert_this(nil)
    end,
    default = function(target)
      return M.actions.diff_revert_this(target)
    end,
  },
}

---@type table<string, fun(snapshot_id: string|nil): any>
local restore_scope_actions = {
  file = M.actions.diff_restore_snapshot_file,
  all = M.actions.diff_restore_snapshot_all,
}

M.command_defs = {
  diff = {
    desc = 'View file diffs (open/next/prev/close)',
    completions = diff_subcommands,
    nested_subcommand = { allow_empty = true },
    execute = function(args)
      local subcommand = args[1] or 'open'
      local action = diff_subcommand_actions[subcommand]
      if not action then
        invalid_arguments('Invalid diff subcommand')
      end
      return action()
    end,
  },
  revert = {
    desc = 'Revert changes (all/this, prompt/session)',
    completions = { 'all', 'this' },
    sub_completions = { 'prompt', 'session' },
    execute = function(args)
      local scope = args[1] --[[@as 'all'|'this'|nil]]
      local target = args[2]

      if scope ~= 'all' and scope ~= 'this' then
        invalid_arguments('Invalid revert scope. Use: all or this')
      end

      if not target then
        invalid_arguments('Invalid revert target. Use: prompt, session, or <snapshot_id>')
      end

      local scope_actions = revert_scope_actions[scope]
      local action = scope_actions[target] or scope_actions.default
      return action(target)
    end,
  },
  restore = {
    desc = 'Restore from snapshot (file/all)',
    completions = { 'file', 'all' },
    execute = function(args)
      local scope = args[1] --[[@as 'file'|'all'|nil]]
      local snapshot_id = args[2]

      if not snapshot_id then
        invalid_arguments('Snapshot ID required')
      end

      if scope ~= 'file' and scope ~= 'all' then
        invalid_arguments('Invalid restore scope. Use: file or all')
      end

      local action = restore_scope_actions[scope]
      return action(snapshot_id)
    end,
  },
  breakpoint = {
    desc = 'Set review breakpoint',
    execute = M.actions.set_review_breakpoint,
  },
  diff_revert_all = {
    desc = 'Revert all tracked changes (optional snapshot_id)',
    execute = function(args)
      return M.actions.diff_revert_all(args and args[1])
    end,
  },
  diff_revert_this = {
    desc = 'Revert current change (optional snapshot_id)',
    execute = function(args)
      return M.actions.diff_revert_this(args and args[1])
    end,
  },
  diff_restore_snapshot_file = {
    desc = 'Restore file from snapshot (optional snapshot_id)',
    execute = function(args)
      return M.actions.diff_restore_snapshot_file(args and args[1])
    end,
  },
  diff_restore_snapshot_all = {
    desc = 'Restore all files from snapshot (optional snapshot_id)',
    execute = function(args)
      return M.actions.diff_restore_snapshot_all(args and args[1])
    end,
  },
  -- action name aliases for keymap compatibility
  diff_open                    = { desc = 'Open diff view',              execute = M.actions.diff_open },
  diff_next                    = { desc = 'Next diff',                   execute = M.actions.diff_next },
  diff_prev                    = { desc = 'Previous diff',               execute = M.actions.diff_prev },
  diff_close                   = { desc = 'Close diff view',             execute = M.actions.diff_close },
  diff_revert_all_last_prompt  = { desc = 'Revert all (last prompt)',    execute = M.actions.diff_revert_all_last_prompt },
  diff_revert_this_last_prompt = { desc = 'Revert this (last prompt)',   execute = M.actions.diff_revert_this_last_prompt },
}

return M
