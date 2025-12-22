local context = require('opencode.context')
local state = require('opencode.state')
local config = require('opencode.config')
local core = require('opencode.core')
local util = require('opencode.util')
local session = require('opencode.session')
local Promise = require('opencode.promise')
local CursorSpinner = require('opencode.quick_chat.spinner')

local M = {}

---@class OpencodeQuickChatRunningSession
---@field buf integer Buffer handle
---@field row integer Row position for spinner
---@field col integer Column position for spinner
---@field spinner CursorSpinner Spinner instance
---@field timestamp integer Timestamp when session started
---@field range table|nil Range information

---@type table<string, OpencodeQuickChatRunningSession>
local running_sessions = {}

--- Global keymaps that are active during quick chat sessions
---@type table<string, boolean>
local active_global_keymaps = {}

--- Creates a quick chat session title
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
  if not message then
    return ''
  end

  local response_text = ''
  for _, part in ipairs(message.parts or {}) do
    if part.type == 'text' and part.text then
      response_text = response_text .. part.text
    end
  end

  -- Remove code fences
  response_text = response_text:gsub('```[^\n]*\n?', '') -- Remove opening code fence
  response_text = response_text:gsub('\n?```', '') -- Remove closing code fence
  response_text = response_text:gsub('`([^`\n]*)`', '%1') -- Remove inline code backticks but keep content

  return response_text
end

--- Applies raw code response to buffer (simple replacement)
---@param buf integer Buffer handle
---@param response_text string The raw code response
---@param row integer Row position (0-indexed)
---@param range table|nil Range information { start = number, stop = number }
---@return boolean success Whether the replacement was successful
local function apply_raw_code_response(buf, response_text, row, range)
  if response_text == '' then
    return false
  end

  local lines = vim.split(response_text, '\n')

  if range then
    -- Replace the selected range
    local start_line = math.floor(range.start) - 1 -- Convert to 0-indexed integer
    local end_line = math.floor(range.stop) - 1 -- Convert to 0-indexed integer
    vim.api.nvim_buf_set_lines(buf, start_line, end_line + 1, false, lines)
  else
    -- Replace current line
    vim.api.nvim_buf_set_lines(buf, row, row + 1, false, lines)
  end

  return true
end

--- Processes response from quickchat session
---@param session_info table Session tracking info
---@param messages OpencodeMessage[] Session messages
---@param range table|nil Range information
---@return boolean success Whether the response was processed successfully
local function process_response(session_info, messages, range)
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

  local success = apply_raw_code_response(session_info.buf, response_text, session_info.row, range)
  if success then
    local target = range and 'selection' or 'current line'
    vim.notify(string.format('Quick chat: Replaced %s with generated code', target), vim.log.levels.INFO)
  else
    vim.notify('Quick chat: Failed to apply raw code response', vim.log.levels.WARN)
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

  local success = process_response(running_session, messages, running_session.range)
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

--- Generates instructions for raw code generation mode
---@param context_config OpencodeContextConfig Context configuration
---@return string[] instructions Array of instruction lines
local function generate_raw_code_instructions(context_config)
  local context_info = ''

  if context_config.selection and context_config.selection.enabled then
    context_info = 'Output ONLY the code to replace the [SELECTED CODE]. '
  elseif context_config.cursor_data and context_config.cursor_data.enabled then
    context_info = ' Output ONLY the code to insert/append at the [CURRENT LINE]. '
  end

  local buf = vim.api.nvim_get_current_buf()
  local filetype = vim.bo[buf].filetype

  return {
    'I want you to act as a senior ' .. filetype .. ' developer. ' .. context_info,
    'I will ask you specific questions.',
    'I want you to ALWAYS return valid raw code ONLY ',
    'CRITICAL: NEVER add (codeblocks, explanations or any additional text). ',
    'Respect the current indentation and formatting of the existing code. ',
    "If you can't respond with code, respond with nothing.",
  }
end

--- Creates message parameters for quick chat
---@param message string The user message
---@param buf integer Buffer handle
---@param range table|nil Range information
---@param context_config OpencodeContextConfig Context configuration
---@param options table Options including model and agent
---@return table params Message parameters
local create_message = Promise.async(function(message, buf, range, context_config, options)
  local quick_chat_config = config.quick_chat or {}

  local format_opts = { context_config = context_config }
  if range then
    format_opts.range = { start = range.start, stop = range.stop }
  end

  local result = context.format_quick_chat_message(message, context_config, format_opts):await()

  local instructions = quick_chat_config.instructions or generate_raw_code_instructions(context_config)

  local parts = {
    { type = 'text', text = table.concat(instructions, '\n') },
    { type = 'text', text = result.text },
  }

  local params = { parts = parts }

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
    range = range,
  }

  -- Set up global keymaps for quick chat
  setup_global_keymaps()

  local context_config = vim.tbl_deep_extend('force', create_context_config(range ~= nil), options.context_config or {})
  local params = create_message(message, buf, range, context_config, options):await()

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
