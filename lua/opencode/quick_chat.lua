local context = require('opencode.context')
local state = require('opencode.state')
local config = require('opencode.config')
local core = require('opencode.core')
local util = require('opencode.util')
local session = require('opencode.session')
local Promise = require('opencode.promise')
local search_replace = require('opencode.quick_chat.search_replace')
local CursorSpinner = require('opencode.quick_chat.spinner')

local M = {}

---@class OpencodeQuickChatRunningSession
---@field buf integer Buffer handle
---@field row integer Row position for spinner
---@field col integer Column position for spinner
---@field spinner CursorSpinner Spinner instance
---@field timestamp integer Timestamp when session started

---@type table<string, OpencodeQuickChatRunningSession>
local running_sessions = {}

--- Global keymaps that are active during quick chat sessions
---@type table<string, boolean>
local active_global_keymaps = {}

--- Creates an quickchat session title
---@param buf integer Buffer handle
---@return string title The session title
local function create_session_title(buf)
  local file_name = vim.api.nvim_buf_get_name(buf)
  local relative_path = file_name ~= '' and vim.fn.fnamemodify(file_name, ':~:.') or 'untitled'
  local line_num = vim.api.nvim_win_get_cursor(0)[1]
  local timestamp = os.date('%H:%M:%S')

  return string.format('[QuickChat] %s:%d (%s)', relative_path, line_num, timestamp)
end

--- Removes global keymaps for quick chat
local function teardown_global_keymaps()
  if not next(active_global_keymaps) then
    return
  end

  for key, _ in pairs(active_global_keymaps) do
    pcall(vim.keymap.del, { 'n', 'i' }, key)
  end

  active_global_keymaps = {}
end

--- Cancels all running quick chat sessions
local function cancel_all_quick_chat_sessions()
  for session_id, session_info in pairs(running_sessions) do
    if state.api_client then
      local ok, result = pcall(function()
        return state.api_client:abort_session(session_id):wait()
      end)

      if not ok then
        vim.notify('Quick chat abort error: ' .. vim.inspect(result), vim.log.levels.WARN)
      end
    end

    if session_info and session_info.spinner then
      session_info.spinner:stop()
    end

    if config.values.debug.quick_chat and not config.values.debug.quick_chat.keep_session then
      state.api_client:delete_session(session_id):catch(function(err)
        vim.notify('Error deleting quickchat session: ' .. vim.inspect(err), vim.log.levels.WARN)
      end)
    end

    running_sessions[session_id] = nil
  end

  -- Teardown keymaps once at the end
  teardown_global_keymaps()
  vim.notify('Quick chat cancelled by user', vim.log.levels.WARN)
end

--- Sets up global keymaps for quick chat
local function setup_global_keymaps()
  if next(active_global_keymaps) then
    return
  end

  local quick_chat_keymap = config.keymap.quick_chat or {}
  if quick_chat_keymap.cancel then
    vim.keymap.set(quick_chat_keymap.cancel.mode or { 'n', 'i' }, quick_chat_keymap.cancel[1], function()
      cancel_all_quick_chat_sessions()
    end, {
      desc = quick_chat_keymap.cancel.desc or 'Cancel quick chat session',
      silent = true,
    })

    active_global_keymaps[quick_chat_keymap.cancel[1]] = true
  end
end

--- Helper to clean up session info and spinner
---@param session_info table Session tracking info
---@param session_id string Session ID
---@param message string|nil Optional message to display
local function cleanup_session(session_info, session_id, message)
  if session_info and session_info.spinner then
    session_info.spinner:stop()
  end

  if config.debug.quick_chat and not config.debug.quick_chat.keep_session then
    state.api_client:delete_session(session_id):catch(function(err)
      vim.notify('Error deleting quickchat session: ' .. vim.inspect(err), vim.log.levels.WARN)
    end)
  end

  running_sessions[session_id] = nil

  -- Check if there are no more running sessions and teardown global keymaps
  if not next(running_sessions) then
    teardown_global_keymaps()
  end

  if message then
    vim.notify(message, vim.log.levels.WARN)
  end
end

--- Extracts text from message parts
---@param message OpencodeMessage Message object
---@return string response_text
local function extract_response_text(message)
  local response_text = ''
  for _, part in ipairs(message.parts or {}) do
    if part.type == 'text' and part.text then
      response_text = response_text .. part.text
    end
  end

  return vim.trim(response_text)
end

--- Processes response from quickchat session
---@param session_info table Session tracking info
---@param messages OpencodeMessage[] Session messages
---@return boolean success Whether the response was processed successfully
local function process_response(session_info, messages)
  local response_message = messages[#messages]
  if #messages < 2 and (not response_message or response_message.info.role ~= 'assistant') then
    return false
  end
  ---@cast response_message OpencodeMessage

  local response_text = extract_response_text(response_message) or ''
  if response_text == '' then
    vim.notify('Quick chat: Received empty response from assistant', vim.log.levels.WARN)
    return false
  end

  local replacements, parse_warnings = search_replace.parse_blocks(response_text)

  -- Show parse warnings
  if #parse_warnings > 0 then
    for _, warning in ipairs(parse_warnings) do
      vim.notify('Quick chat: ' .. warning, vim.log.levels.WARN)
    end
  end

  if #replacements == 0 then
    vim.notify('Quick chat: No valid SEARCH/REPLACE blocks found in response', vim.log.levels.WARN)
    return false
  end

  local success, errors, applied_count = search_replace.apply(session_info.buf, replacements, session_info.row)

  -- Provide detailed feedback
  if applied_count > 0 then
    local total_blocks = #replacements
    if applied_count == total_blocks then
      vim.notify(
        string.format('Quick chat: Applied %d change%s', applied_count, applied_count > 1 and 's' or ''),
        vim.log.levels.INFO
      )
    else
      vim.notify(string.format('Quick chat: Applied %d/%d changes', applied_count, total_blocks), vim.log.levels.INFO)
    end
  end

  if #errors > 0 then
    for _, err in ipairs(errors) do
      vim.notify('Quick chat: ' .. err, vim.log.levels.WARN)
    end
  end

  return success
end

--- Hook function called when a session is done thinking (no more pending messages)
---@param active_session Session The session object
local on_done = Promise.async(function(active_session)
  if not (active_session.title and vim.startswith(active_session.title, '[QuickChat]')) then
    return
  end

  local running_session = running_sessions[active_session.id]
  if not running_session then
    return
  end

  local messages = session.get_messages(active_session):await() --[[@as OpencodeMessage[] ]]
  if not messages then
    cleanup_session(running_session, active_session.id, 'Failed to update file with quick chat response')
    return
  end

  local success = process_response(running_session, messages)
  if success then
    cleanup_session(running_session, active_session.id)
  else
    cleanup_session(running_session, active_session.id, 'Failed to update file with quick chat response')
  end
end)

---@param message string|nil The message to validate
---@return boolean valid
---@return string|nil error_message
local function validate_quick_chat_prerequisites(message)
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()

  if not buf or not win then
    return false, 'Quick chat requires an active file buffer'
  end

  if message and message == '' then
    return false, 'Quick chat message cannot be empty'
  end

  return true
end

--- Creates context configuration for quick chat
--- Optimized for minimal token usage while providing essential context
---@param has_range boolean Whether a range is specified
---@return OpencodeContextConfig context_opts
local function create_context_config(has_range)
  return {
    enabled = true,
    current_file = { enabled = false }, -- Disable full file content
    cursor_data = { enabled = not has_range, context_lines = 10 }, -- Only cursor position when no selection
    selection = { enabled = has_range }, -- Only selected text when range provided
    diagnostics = {
      enabled = true,
      error = true,
      warning = true,
      info = false,
      only_closest = true, -- Only closest diagnostics, not all file diagnostics
    },
    agents = { enabled = false }, -- No agent context needed
    buffer = { enabled = false }, -- Disable full buffer content for token efficiency
    git_diff = { enabled = false }, -- No git context needed
  }
end

--- Generates instructions for the LLM to follow the SEARCH/REPLACE format
--- This is inspired from Aider Chat approach
---@param context_instance ContextInstance Context instance
---@return string[] instructions Array of instruction lines
local generate_search_replace_instructions = Promise.async(function(context_instance)
  local base_instructions = {
    "You are an expert programming assistant. Modify the user's code according to their instructions using the SEARCH/REPLACE format described below.",
    'Output ONLY SEARCH/REPLACE blocks, no explanations:',
    '<<<<<<< SEARCH',
    '[exact original code]',
    '=======',
    '[modified code]',
    '>>>>>>> REPLACE',
    '',
    'Rules: Copy SEARCH content exactly. Include 1-3 context lines for unique matching. Use empty SEARCH to insert at cursor. Output multiple blocks only if needed for more complex operations.',
    'Example 1 - Fix function:',
    '<<<<<<< SEARCH',
    'function hello() {',
    '  console.log("hello")',
    '}',
    '=======',
    'function hello() {',
    '  console.log("hello");',
    '}',
    '>>>>>>> REPLACE',
    '',
    'Example 2 - Insert at cursor:',
    '<<<<<<< SEARCH',
    '',
    '=======',
    'local new_variable = "value"',
    '>>>>>>> REPLACE',
  }

  local context_guidance = {}

  if context_instance:has('diagnostics'):await() then
    table.insert(context_guidance, 'Fix errors/warnings (if asked)')
  end

  if context_instance:has('selection'):await() then
    table.insert(context_guidance, 'Modify only selected range')
  elseif context_instance:has('cursor_data') then
    table.insert(context_guidance, 'Modify only near cursor')
  end

  if context_instance:has('git_diff'):await() then
    table.insert(context_guidance, "ONLY Reference git diff (don't copy syntax)")
  end

  if #context_guidance > 0 then
    table.insert(base_instructions, 'Context: ' .. table.concat(context_guidance, ', ') .. '.')
  end

  table.insert(base_instructions, '')
  table.insert(
    base_instructions,
    '*CRITICAL*: Only answer in SEARCH/REPLACE format,NEVER add explanations!, NEVER ask questions!, NEVER add extra text!, NEVER run tools.'
  )
  table.insert(base_instructions, '')

  return base_instructions
end)

--- Creates message parameters for quick chat
---@param message string The user message
---@param buf integer Buffer handle
---@param range table|nil Range information
---@param context_instance ContextInstance Context instance
---@param options table Options including model and agent
---@return table params Message parameters
local create_message = Promise.async(function(message, buf, range, context_instance, options)
  local quick_chat_config = config.quick_chat or {}

  local instructions
  if quick_chat_config.instructions then
    instructions = quick_chat_config.instructions
  else
    instructions = generate_search_replace_instructions(context_instance):await()
  end

  local format_opts = { buf = buf }
  if range then
    format_opts.range = { start = range.start, stop = range.stop }
  end

  local result = context.format_message_plain_text(message, context_instance, format_opts):await()

  local parts = {
    { type = 'text', text = table.concat(instructions, '\n') },
    { type = 'text', text = result.text },
  }

  local params = { parts = parts, system = table.concat(instructions, '\n') }

  local current_model = core.initialize_current_model():await()
  local target_model = options.model or quick_chat_config.default_model or current_model
  if target_model then
    local provider, model = target_model:match('^(.-)/(.+)$')
    if provider and model then
      params.model = { providerID = provider, modelID = model }
    end
  end

  local target_agent = options.agent or quick_chat_config.default_agent or state.current_mode or config.default_mode
  if target_agent then
    params.agent = target_agent
  end

  return params
end)

--- Unified quick chat function
---@param message string Optional custom message to use instead of default prompts
---@param options {context_config?:OpencodeContextConfig, model?: string, agent?: string}|nil Optional configuration for context and behavior
---@param range table|nil Optional range information { start = number, stop = number }
---@return Promise
M.quick_chat = Promise.async(function(message, options, range)
  options = options or {}

  local valid, error_msg = validate_quick_chat_prerequisites(message)
  if not valid then
    vim.notify(error_msg or 'Unknown error', vim.log.levels.ERROR)
    return Promise.new():resolve(nil)
  end

  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local cursor_pos = vim.api.nvim_win_get_cursor(win)
  local row, col = cursor_pos[1] - 1, cursor_pos[2] -- Convert to 0-indexed
  local spinner = CursorSpinner.new(buf, row, col)

  local file_name = vim.api.nvim_buf_get_name(buf)
  local mentioned_files = file_name ~= '' and { file_name } or {}
  local allowed, err_msg = util.check_prompt_allowed(config.prompt_guard, mentioned_files)
  if not allowed then
    spinner:stop()
    return Promise.new():reject(err_msg or 'Prompt denied by prompt_guard')
  end

  local title = create_session_title(buf)
  local quick_chat_session = core.create_new_session(title):await()
  if not quick_chat_session then
    spinner:stop()
    return Promise.new():reject('Failed to create quickchat session')
  end

  if config.debug.quick_chat and config.debug.quick_chat.set_active_session then
    state.active_session = quick_chat_session
  end

  running_sessions[quick_chat_session.id] = {
    buf = buf,
    row = row,
    col = col,
    spinner = spinner,
    timestamp = vim.uv.now(),
  }

  -- Set up global keymaps for quick chat
  setup_global_keymaps()

  local context_config = vim.tbl_deep_extend('force', create_context_config(range ~= nil), options.context_config or {})
  local context_instance = context.new_instance(context_config)
  local params = create_message(message, buf, range, context_instance, options):await()

  local success, err = pcall(function()
    state.api_client:create_message(quick_chat_session.id, params):await()
    on_done(quick_chat_session):await()
  end)

  if not success then
    spinner:stop()
    running_sessions[quick_chat_session.id] = nil
    vim.notify('Error in quick chat: ' .. vim.inspect(err), vim.log.levels.ERROR)
  end
end)

--- Setup function to initialize quick chat functionality
function M.setup()
  local augroup = vim.api.nvim_create_augroup('OpenCodeQuickChat', { clear = true })

  vim.api.nvim_create_autocmd('BufDelete', {
    group = augroup,
    callback = function(ev)
      local buf = ev.buf
      for session_id, session_info in pairs(running_sessions) do
        if session_info.buf == buf then
          ---@diagnostic disable-next-line: undefined-field
          if session_info.spinner and session_info.spinner.stop then
            ---@diagnostic disable-next-line: undefined-field
            session_info.spinner:stop()
          end
          running_sessions[session_id] = nil
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = augroup,
    callback = function()
      for _session_id, session_info in pairs(running_sessions) do
        ---@diagnostic disable-next-line: undefined-field
        if session_info.spinner and session_info.spinner.stop then
          ---@diagnostic disable-next-line: undefined-field
          session_info.spinner:stop()
        end
      end
      running_sessions = {}
      teardown_global_keymaps()
    end,
  })
end

return M
