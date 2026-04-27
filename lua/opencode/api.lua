local commands = require('opencode.commands')
local window = require('opencode.commands.handlers.window').actions
local session = require('opencode.commands.handlers.session').actions
local diff = require('opencode.commands.handlers.diff').actions
local surface = require('opencode.commands.handlers.surface').actions
local workflow = require('opencode.commands.handlers.workflow').actions
local permission = require('opencode.commands.handlers.permission').actions
local agent = require('opencode.commands.handlers.agent').actions

-- Route API actions through the same command execution axis.
---@param hook_key? string
local function dispatch_action(name, action_fn, hook_key, ...)
  local parsed = commands.build_parsed_intent(name, vim.deepcopy({ ... }))
  if hook_key and parsed and parsed.ok and parsed.intent then
    parsed.intent.hook_key = hook_key
  end

  return commands.execute_parsed_intent(parsed, function(resolved_args)
    return action_fn(unpack(resolved_args or {}))
  end)
end

---@type OpencodeCommandApi
local M = {}

local action_groups = {
  window = {
    swap_position = window.swap_position,
    toggle_zoom = window.toggle_zoom,
    toggle_input = window.toggle_input,
    open_input = window.open_input,
    open_output = window.open_output,
    close = window.close,
    hide = window.hide,
    toggle_pane = window.toggle_pane,
    focus_input = window.focus_input,
    cancel = window.cancel,
    toggle_focus = window.toggle_focus,
    toggle = window.toggle,
  },

  session = {
    open_input_new_session = session.open_input_new_session,
    select_child_session = session.select_child_session,
    select_sibling_session = session.select_sibling_session,
    select_parent_session = session.select_parent_session,
    share = session.share,
    unshare = session.unshare,
    initialize = session.initialize,
    timeline = session.timeline,
    redo = session.redo,
    select_session = session.select_session,
    compact_session = session.compact_session,
    open_input_new_session_with_title = session.open_input_new_session_with_title,
    rename_session = session.rename_session,
    undo = session.undo,
    fork_session = session.fork_session,
  },

  diff = {
    diff_next = diff.diff_next,
    diff_prev = diff.diff_prev,
    diff_close = diff.diff_close,
    diff_revert_all_last_prompt = diff.diff_revert_all_last_prompt,
    diff_revert_this_last_prompt = diff.diff_revert_this_last_prompt,
    set_review_breakpoint = diff.set_review_breakpoint,
    diff_open = diff.diff_open,
    diff_revert_all = diff.diff_revert_all,
    diff_revert_selected_file = diff.diff_revert_selected_file,
    diff_restore_snapshot_file = diff.diff_restore_snapshot_file,
    diff_restore_snapshot_all = diff.diff_restore_snapshot_all,
    diff_revert_this = diff.diff_revert_this,
  },

  workflow = {
    paste_image = workflow.paste_image,
    select_history = workflow.select_history,
    prev_history = workflow.prev_history,
    next_history = workflow.next_history,
    prev_prompt_history = workflow.prev_prompt_history,
    next_prompt_history = workflow.next_prompt_history,
    next_message = workflow.next_message,
    prev_message = workflow.prev_message,
    mention_file = workflow.mention_file,
    mention = workflow.mention,
    context_items = workflow.context_items,
    slash_commands = workflow.slash_commands,
    references = workflow.references,
    debug_output = workflow.debug_output,
    debug_message = workflow.debug_message,
    debug_session = workflow.debug_session,
    toggle_tool_output = workflow.toggle_tool_output,
    toggle_reasoning_output = workflow.toggle_reasoning_output,
    toggle_max_messages = workflow.toggle_max_messages,
    submit_input_prompt = workflow.submit_input_prompt,
    run = workflow.run,
    run_new_session = workflow.run_new_session,
    quick_chat = workflow.quick_chat,
    run_user_command = workflow.run_user_command,
    review = workflow.review,
    add_visual_selection = workflow.add_visual_selection,
    add_visual_selection_inline = workflow.add_visual_selection_inline,
  },

  surface = {
    help = surface.help,
    mcp = surface.mcp,
    commands_list = surface.commands_list,
  },

  permission = {
    question_answer = permission.question_answer,
    question_other = permission.question_other,
    respond_to_permission = permission.respond_to_permission,
    permission_accept = permission.permission_accept,
    permission_accept_all = permission.permission_accept_all,
    permission_deny = permission.permission_deny,
  },

  agent = {
    configure_provider = agent.configure_provider,
    configure_variant = agent.configure_variant,
    cycle_variant = agent.cycle_variant,
    agent_plan = agent.agent_plan,
    agent_build = agent.agent_build,
    select_agent = agent.select_agent,
    switch_mode = agent.switch_mode,
  },

  query = {
    get_window_state = window.get_window_state,
    current_model = agent.current_model,
    with_header = surface.with_header,
  },
}

---@param group_name string
---@param exports table<string, function>
local function register_exports(group_name, exports)
  for name, fn in pairs(exports) do
    M[name] = function(...)
      return dispatch_action(name, fn, group_name, ...)
    end
  end
end

for group_name, exports in pairs(action_groups) do
  register_exports(group_name, exports)
end

return M
