local core = require('opencode.core')
local util = require('opencode.util')
local config_file = require('opencode.config_file')
---@type OpencodeState
local state = require('opencode.state')
local quick_chat = require('opencode.quick_chat')
local history = require('opencode.history')
local window_handler = require('opencode.commands.handlers.window')
local config = require('opencode.config')
local Promise = require('opencode.promise')
local input_window = require('opencode.ui.input_window')
local ui = require('opencode.ui.ui')
local nvim = vim['api']

local M = {
  actions = {},
}

---@param message string
---@return Session|nil
local function get_active_session_or_warn(message)
  local active_session = state.active_session
  if not active_session then
    vim.notify(message, vim.log.levels.WARN)
    return nil
  end

  return active_session
end

---@param command string
---@param args string[]|nil
local function schedule_slash_history(command, args)
  local joined_args = args and table.concat(args, ' ') or ''
  vim.schedule(function()
    history.write('/' .. command .. ' ' .. joined_args)
  end)
end

---@param args string[]|nil
---@return string
local function join_args(args)
  if not args then
    return ''
  end
  return table.concat(args, ' ')
end

---@param prompt string
---@param opts SendMessageOpts
local function run_with_opts(prompt, opts)
  return core.open(opts):and_then(function()
    return core.send_message(prompt, opts)
  end)
end

---@param prompt string
---@param opts? SendMessageOpts
function M.actions.run(prompt, opts)
  opts = vim.tbl_deep_extend('force', { new_session = false, focus = 'output' }, opts or {})
  return run_with_opts(prompt, opts)
end

---@param prompt string
---@param opts? SendMessageOpts
function M.actions.run_new_session(prompt, opts)
  opts = vim.tbl_deep_extend('force', { new_session = true, focus = 'output' }, opts or {})
  return run_with_opts(prompt, opts)
end

---@param debug_action string
local function run_debug_action(debug_action)
  if not config.debug.enabled then
    vim.notify('Debugging is not enabled in the config', vim.log.levels.WARN)
    return
  end

  local debug_helper = require('opencode.ui.debug_helper')
  return debug_helper[debug_action]()
end

---@param message string|string[]|nil
---@param range? OpencodeSelectionRange
function M.actions.quick_chat(message, range)
  if not range then
    if vim.fn.mode():match('[vV\022]') then
      local visual_range = util.get_visual_range()
      if visual_range then
        range = {
          start = visual_range.start_line,
          stop = visual_range.end_line,
        }
      end
    end
  end

  if type(message) == 'table' then
    message = table.concat(message, ' ')
  end

  if not message or #message == 0 then
    local scope = range and ('[selection: ' .. range.start .. '-' .. range.stop .. ']')
      or '[line: ' .. tostring(nvim.nvim_win_get_cursor(0)[1]) .. ']'
    vim.ui.input({ prompt = 'Quick Chat Message: ' .. scope, win = { relative = 'cursor' } }, function(input)
      if input and input ~= '' then
        local prompt, ctx = util.parse_quick_context_args(input)
        quick_chat.quick_chat(prompt, { context_config = ctx }, range)
      end
    end)
    return
  end

  local prompt, ctx = util.parse_quick_context_args(message)
  quick_chat.quick_chat(prompt, { context_config = ctx }, range)
end

function M.actions.select_history()
  require('opencode.ui.history_picker').pick()
end

---@param prompt string|nil
local function restore_prompt_history_entry(prompt)
  if not prompt then
    return
  end

  input_window.set_content(prompt)
  require('opencode.ui.mention').restore_mentions(state.windows.input_buf)
end

function M.actions.prev_history()
  if not state.ui.is_visible() then
    return
  end

  local prev_prompt = history.prev()
  restore_prompt_history_entry(prev_prompt)
end

function M.actions.next_history()
  if not state.ui.is_visible() then
    return
  end

  local next_prompt = history.next()
  restore_prompt_history_entry(next_prompt)
end

function M.actions.prev_prompt_history()
  local key = config.get_key_for_function('input_window', 'prev_prompt_history')
  if key ~= '<up>' then
    return M.actions.prev_history()
  end

  local current_line = nvim.nvim_win_get_cursor(0)[1]
  local at_boundary = current_line <= 1

  if at_boundary then
    return M.actions.prev_history()
  end

  nvim.nvim_feedkeys(nvim.nvim_replace_termcodes(key, true, false, true), 'n', false)
end

function M.actions.next_prompt_history()
  local key = config.get_key_for_function('input_window', 'next_prompt_history')
  if key ~= '<down>' then
    return M.actions.next_history()
  end

  local current_line = nvim.nvim_win_get_cursor(0)[1]
  local at_boundary = current_line >= nvim.nvim_buf_line_count(0)

  if at_boundary then
    return M.actions.next_history()
  end

  nvim.nvim_feedkeys(nvim.nvim_replace_termcodes(key, true, false, true), 'n', false)
end

function M.actions.references()
  require('opencode.ui.reference_picker').pick()
end

for _, action_name in ipairs({ 'debug_output', 'debug_message', 'debug_session' }) do
  M.actions[action_name] = function()
    return run_debug_action(action_name)
  end
end

function M.actions.paste_image()
  core.paste_image_from_clipboard()
end

M.actions.submit_input_prompt = Promise.async(function()
  if state.display_route then
    state.ui.clear_display_route()
    ui.render_output(true)
  end

  local message_sent = input_window.handle_submit()
  if message_sent and config.ui.input.auto_hide and not input_window.is_hidden() then
    input_window._hide()
  end
end)

---@param key_fn string
local function trigger_input_key(key_fn)
  local char = config.get_key_for_function('input_window', key_fn)
  ui.focus_input({ restore_position = false, start_insert = true })
  nvim.nvim_feedkeys(nvim.nvim_replace_termcodes(char, true, false, true), 'n', false)
end

for _, action_name in ipairs({ 'mention', 'context_items', 'slash_commands' }) do
  M.actions[action_name] = function()
    trigger_input_key(action_name)
  end
end

function M.actions.mention_file()
  local picker = require('opencode.ui.file_picker')
  local context = require('opencode.context')
  require('opencode.ui.mention').mention(function(mention_cb)
    picker.pick(function(file)
      mention_cb(file.path)
      context.add_file(file.path)
    end)
  end)
end

--- Runs a user-defined command by name.
---@param name string
---@param args? string[]
M.actions.run_user_command = Promise.async(function(name, args)
  return window_handler.actions.open_input():and_then(function()
    local user_commands = config_file.get_user_commands():await()
    local command_cfg = user_commands and user_commands[name]
    if not command_cfg then
      vim.notify('Unknown user command: ' .. name, vim.log.levels.WARN)
      return
    end

    local model = command_cfg.model or state.current_model
    local agent = command_cfg.agent or state.current_mode

    local active_session = get_active_session_or_warn('No active session')
    if not active_session then
      return
    end

    state.api_client
      :send_command(active_session.id, {
        command = name,
        arguments = join_args(args),
        model = model,
        agent = agent,
      })
      :and_then(function()
        schedule_slash_history(name, args)
      end)
  end) --[[@as Promise<void> ]]
end)

function M.actions.next_message()
  require('opencode.ui.navigation').goto_next_message()
end

function M.actions.prev_message()
  require('opencode.ui.navigation').goto_prev_message()
end

function M.actions.toggle_tool_output()
  local action_text = config.ui.output.tools.show_output and 'Hiding' or 'Showing'
  vim.notify(action_text .. ' tool output display', vim.log.levels.INFO)
  config.values.ui.output.tools.show_output = not config.ui.output.tools.show_output
  ui.render_output()
end

function M.actions.toggle_reasoning_output()
  local action_text = config.ui.output.tools.show_reasoning_output and 'Hiding' or 'Showing'
  vim.notify(action_text .. ' reasoning output display', vim.log.levels.INFO)
  config.values.ui.output.tools.show_reasoning_output = not config.ui.output.tools.show_reasoning_output
  ui.render_output()
end

local original_max_messages = config.ui.output.max_messages
function M.actions.toggle_max_messages()
  local current = config.ui.output.max_messages
  local next_val
  if type(current) == 'number' and current > 0 then
    next_val = nil
  else
    next_val = original_max_messages or 20
  end

  local action_text = next_val == nil and 'Disabling' or 'Enabling'
  local val_text = next_val == nil and 'none' or tostring(next_val)
  vim.notify(action_text .. ' message limit to ' .. val_text, vim.log.levels.INFO)
  config.values.ui.output.max_messages = next_val
end

M.actions.review = Promise.async(function(args)
  local new_session = core.create_new_session('Code review checklist for diffs and PRs'):await()
  if not new_session then
    vim.notify('Failed to create new session', vim.log.levels.ERROR)
    return
  end
  if not core.initialize_current_model():await() or not state.current_model then
    vim.notify('No model selected', vim.log.levels.ERROR)
    return
  end

  state.session.set_active(new_session)
  window_handler.actions.open_input():await()
  state.api_client
    :send_command(state.active_session.id, {
      command = 'review',
      arguments = join_args(args),
      model = state.current_model,
    })
    :and_then(function()
      schedule_slash_history('review', args)
    end)
end)

M.actions.add_visual_selection = Promise.async(
  ---@param opts? {open_input?: boolean}
  ---@param range OpencodeSelectionRange
  function(opts, range)
    opts = vim.tbl_extend('force', { open_input = true }, opts or {})
    local context = require('opencode.context')
    local added = context.add_visual_selection(range)

    if added and opts.open_input then
      window_handler.actions.open_input():await()
    end
  end
)

M.actions.add_visual_selection_inline = Promise.async(
  ---@param opts? {open_input?: boolean}
  ---@param range OpencodeSelectionRange
  function(opts, range)
    opts = vim.tbl_extend('force', { open_input = true }, opts or {})
    local context = require('opencode.context')
    local text = context.build_inline_selection_text(range)

    if not text then
      return
    end

    window_handler.actions.open_input():await()
    input_window._append_to_input(text)
    vim.schedule(function()
      if vim.fn.mode() ~= 'n' then
        nvim.nvim_feedkeys(nvim.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
      end
    end)
  end
)

M.command_defs = {
  quick_chat = {
    desc = 'Quick chat with current buffer or visual selection',
    range = true,
    nargs = '+',
    complete = false,
    execute = function(args, range)
      return M.actions.quick_chat(args, range)
    end,
  },
  review = {
    desc = 'Review changes (commit/branch/pr), defaults to uncommitted changes',
    nargs = '+',
    execute = function(args, range)
      return M.actions.review(args, range)
    end,
  },
  run = {
    desc = 'Run prompt in current session',
    execute = function(args)
      local opts, prompt = util.parse_run_args(args)
      if prompt == '' then
        error({ code = 'invalid_arguments', message = 'Prompt required' }, 0)
      end
      return M.actions.run(prompt, opts)
    end,
  },
  run_new = {
    desc = 'Run prompt in new session',
    execute = function(args)
      local opts, prompt = util.parse_run_args(args)
      if prompt == '' then
        error({ code = 'invalid_arguments', message = 'Prompt required' }, 0)
      end
      return M.actions.run_new_session(prompt, opts)
    end,
  },
  command = {
    desc = 'Run user-defined command',
    completion_provider_id = 'user_commands',
    execute = function(args)
      local name = args[1]
      if not name or name == '' then
        error({ code = 'invalid_arguments', message = 'Command name required' }, 0)
      end
      return M.actions.run_user_command(name, vim.list_slice(args, 2))
    end,
  },
  history = {
    desc = 'Select from prompt history',
    execute = M.actions.select_history,
  },
  -- action name alias for keymap compatibility
  select_history = { desc = 'Select from history', execute = M.actions.select_history },
  submit_input_prompt = {
    desc = 'Submit current input prompt',
    execute = M.actions.submit_input_prompt,
  },
  prev_prompt_history = {
    desc = 'Navigate to previous prompt history item',
    execute = M.actions.prev_prompt_history,
  },
  next_prompt_history = {
    desc = 'Navigate to next prompt history item',
    execute = M.actions.next_prompt_history,
  },
  mention_file = {
    desc = 'Mention file in current input context',
    execute = M.actions.mention_file,
  },
  mention = {
    desc = 'Open mention picker in input window',
    execute = M.actions.mention,
  },
  slash_commands = {
    desc = 'Open slash commands picker in input window',
    execute = M.actions.slash_commands,
  },
  context_items = {
    desc = 'Open context items picker in input window',
    execute = M.actions.context_items,
  },
  next_message = {
    desc = 'Navigate to next message in output window',
    execute = M.actions.next_message,
  },
  prev_message = {
    desc = 'Navigate to previous message in output window',
    execute = M.actions.prev_message,
  },
  debug_output = {
    desc = 'Open raw output debug view',
    execute = M.actions.debug_output,
  },
  debug_message = {
    desc = 'Open raw message debug view',
    execute = M.actions.debug_message,
  },
  debug_session = {
    desc = 'Open raw session debug view',
    execute = M.actions.debug_session,
  },
  toggle_tool_output = {
    desc = 'Toggle tool output visibility in the output window',
    execute = M.actions.toggle_tool_output,
  },
  toggle_reasoning_output = {
    desc = 'Toggle reasoning output visibility in the output window',
    execute = M.actions.toggle_reasoning_output,
  },
  toggle_max_messages = {
    desc = 'Toggle maximum number of rendered messages',
    execute = M.actions.toggle_max_messages,
  },
  paste_image = {
    desc = 'Paste image from clipboard and add to context',
    execute = M.actions.paste_image,
  },
  references = {
    desc = 'Browse code references from conversation',
    execute = M.actions.references,
  },
  add_visual_selection = {
    desc = 'Add current visual selection to context',
    execute = M.actions.add_visual_selection,
  },
  add_visual_selection_inline = {
    desc = 'Insert visual selection as inline code block in the input buffer',
    execute = M.actions.add_visual_selection_inline,
  },
}

return M
