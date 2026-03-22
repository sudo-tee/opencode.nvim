local dispatch = require('opencode.commands.dispatch')
local window = require('opencode.commands.handlers.window').actions
local session = require('opencode.commands.handlers.session').actions
local diff = require('opencode.commands.handlers.diff').actions
local surface = require('opencode.commands.handlers.surface').actions
local workflow = require('opencode.commands.handlers.workflow').actions
local permission = require('opencode.commands.handlers.permission').actions
local agent = require('opencode.commands.handlers.agent').actions

-- Routes an action through the dispatch pipeline so lifecycle hooks fire.
-- TODO: hooks (on_command_before/after/error/finally) are not yet in config
-- defaults — activate them when the event unification work lands.
local function via_dispatch(action_fn, ...)
  local args = { ... }
  return dispatch.dispatch_intent({
    ok = true,
    intent = { execute = function() return action_fn(unpack(args)) end, args = {}, range = nil },
  }).result
end

---@type OpencodeCommandApi
local M = {}

-- All dispatch-wrapped actions. Generated into M via the loop below.
-- Read-only queries (get_window_state, with_header, current_model) are defined after.
-- stylua: ignore
local actions = {
  -- window
  swap_position              = window.swap_position,
  toggle_zoom                = window.toggle_zoom,
  toggle_input               = window.toggle_input,
  open_input                 = window.open_input,
  open_output                = window.open_output,
  close                      = window.close,
  hide                       = window.hide,
  toggle_pane                = window.toggle_pane,
  focus_input                = window.focus_input,
  cancel                     = window.cancel,
  toggle_focus               = window.toggle_focus,    -- (new_sess)
  toggle                     = window.toggle,          -- (new_sess)
  -- session
  open_input_new_session              = session.open_input_new_session,
  select_child_session                = session.select_child_session,
  share                               = session.share,
  unshare                             = session.unshare,
  initialize                          = session.initialize,
  timeline                            = session.timeline,
  redo                                = session.redo,
  select_session                      = session.select_session,              -- (parent_id)
  compact_session                     = session.compact_session,             -- (s)
  open_input_new_session_with_title   = session.open_input_new_session_with_title, -- (title)
  rename_session                      = session.rename_session,              -- (s, title)
  undo                                = session.undo,                        -- (msg_id)
  fork_session                        = session.fork_session,                -- (msg_id)
  -- diff
  diff_next                      = diff.diff_next,
  diff_prev                      = diff.diff_prev,
  diff_close                     = diff.diff_close,
  diff_revert_all_last_prompt    = diff.diff_revert_all_last_prompt,
  diff_revert_this_last_prompt   = diff.diff_revert_this_last_prompt,
  set_review_breakpoint          = diff.set_review_breakpoint,
  diff_open                      = diff.diff_open,                   -- (from, to)
  diff_revert_all                = diff.diff_revert_all,             -- (snap)
  diff_revert_selected_file      = diff.diff_revert_selected_file,   -- (s, t)
  diff_restore_snapshot_file     = diff.diff_restore_snapshot_file,  -- (id)
  diff_restore_snapshot_all      = diff.diff_restore_snapshot_all,   -- (id)
  diff_revert_this               = diff.diff_revert_this,            -- (snap)
  -- workflow
  paste_image             = workflow.paste_image,
  select_history          = workflow.select_history,
  prev_history            = workflow.prev_history,
  next_history            = workflow.next_history,
  prev_prompt_history     = workflow.prev_prompt_history,
  next_prompt_history     = workflow.next_prompt_history,
  next_message            = workflow.next_message,
  prev_message            = workflow.prev_message,
  mention_file            = workflow.mention_file,
  mention                 = workflow.mention,
  context_items           = workflow.context_items,
  slash_commands          = workflow.slash_commands,
  references              = workflow.references,
  debug_output            = workflow.debug_output,
  debug_message           = workflow.debug_message,
  debug_session           = workflow.debug_session,
  toggle_tool_output      = workflow.toggle_tool_output,
  toggle_reasoning_output = workflow.toggle_reasoning_output,
  submit_input_prompt     = workflow.submit_input_prompt,
  run                     = workflow.run,              -- (prompt, opts)
  run_new_session         = workflow.run_new_session,  -- (prompt, opts)
  quick_chat              = workflow.quick_chat,       -- (msg, range)
  run_user_command        = workflow.run_user_command, -- (name, args)
  review                  = workflow.review,           -- (args, range)
  add_visual_selection        = workflow.add_visual_selection,        -- (opts, range)
  add_visual_selection_inline = workflow.add_visual_selection_inline, -- (o, r)
  -- surface
  help          = surface.help,
  mcp           = surface.mcp,
  commands_list = surface.commands_list,
  -- permission
  question_answer       = permission.question_answer,
  question_other        = permission.question_other,
  respond_to_permission = permission.respond_to_permission, -- (answer, perm)
  permission_accept     = permission.permission_accept,     -- (perm)
  permission_accept_all = permission.permission_accept_all, -- (perm)
  permission_deny       = permission.permission_deny,       -- (perm)
  -- agent
  configure_provider = agent.configure_provider,
  configure_variant  = agent.configure_variant,
  cycle_variant      = agent.cycle_variant,
  agent_plan         = agent.agent_plan,
  agent_build        = agent.agent_build,
  select_agent       = agent.select_agent,
  switch_mode        = agent.switch_mode,
}

for name, fn in pairs(actions) do
  M[name] = function(...) return via_dispatch(fn, ...) end
end

-- Read-only queries: bypass dispatch, no side effects
function M.get_window_state() return window.get_window_state() end
function M.current_model() return agent.current_model() end
function M.with_header(lines, show_welcome) return surface.with_header(lines, show_welcome) end

return M
