local context = require('opencode.context')
local state = require('opencode.state')
local config = require('opencode.config')
local util = require('opencode.util')
local Promise = require('opencode.promise')
local CursorSpinner = require('opencode.quick_chat.spinner')
local session_runtime = require('opencode.services.session_runtime')
local agent_model = require('opencode.services.agent_model')

local M = {}

---@class OpencodeQuickChatRunningSession
---@field buf integer Buffer handle
---@field row integer Row position for spinner
---@field col integer Column position for spinner
---@field spinner CursorSpinner Spinner instance
---@field timestamp integer Timestamp when session started
---@field range table|nil Range information
---@field connection table
---@field observation table
---@field session table
---@field reply_waiter? table
---@field cancelled? boolean

---@type table<string, OpencodeQuickChatRunningSession>
local running_sessions = {}

--- Global keymaps that are active during quick chat sessions
---@type table<string, boolean>
local active_global_keymaps = {}

local function delete_session(session_info)
  return session_info.connection.operations.delete_session(
    session_info.connection,
    session_info.session.id,
    session_info.session.location,
    util.apply_path_map
  )
end

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
    session_info.cancelled = true

    if session_info.reply_waiter then
      session_info.reply_waiter.stop('Quick chat cancelled')
    end

    if session_info.spinner then
      session_info.spinner:stop()
    end

    running_sessions[session_id] = nil

    local ok, request = pcall(function()
      return session_info.observation:interrupt()
    end)
    if not ok then
      vim.notify('Quick chat abort error: ' .. vim.inspect(request), vim.log.levels.WARN)
    else
      request
        :and_then(function()
          if config.debug.quick_chat and not config.debug.quick_chat.keep_session then
            return delete_session(session_info)
          end
        end)
        :catch(function(err)
          vim.notify('Quick chat abort error: ' .. vim.inspect(err), vim.log.levels.WARN)
        end)
    end
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
  if not session_info then
    running_sessions[session_id] = nil
    if not next(running_sessions) then
      teardown_global_keymaps()
    end
    if message then
      vim.notify(message, vim.log.levels.WARN)
    end
    return
  end

  if session_info and session_info.reply_waiter then
    session_info.reply_waiter.stop()
  end

  if session_info and session_info.spinner then
    session_info.spinner:stop()
  end

  if not session_info.cancelled and config.debug.quick_chat and not config.debug.quick_chat.keep_session then
    delete_session(session_info):catch(function(err)
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

---@param message table
---@return string response_text
local function extract_response_text(message)
  if not message then
    return ''
  end

  local response_text = ''
  for _, part in ipairs(message.content or {}) do
    if part.kind == 'text' and part.text then
      response_text = response_text .. part.text
    end
  end

  -- Remove code fences
  response_text = response_text:gsub('```[^\n]*\n?', '') -- Remove opening code fence
  response_text = response_text:gsub('\n?```', '') -- Remove closing code fence
  response_text = response_text:gsub('`([^`\n]*)`', '%1') -- Remove inline code backticks but keep content

  return response_text
end

---@param message table|nil
---@return boolean
local function is_safe_reply(message)
  if not message or message.kind ~= 'assistant' or message.finish ~= 'stop' or message.error then
    return false
  end

  for _, part in ipairs(message.content or {}) do
    if part.kind == 'tool' and part.state ~= 'completed' then
      return false
    end
  end

  return true
end

---@param observation table
---@param input_id string
---@return table|nil
local function find_v1_reply(observation, input_id)
  local observed = observation:read()
  for _, message_id in ipairs(observed.entry_order or {}) do
    local message = observed.entries_by_id[message_id]
    if message and message.parent_message_id == input_id then
      if message.error or is_safe_reply(message) then
        return message
      end
    end
  end
end

---@param observation table
---@return table waiter
local function start_v1_reply_waiter(observation)
  local input_id
  local reply = Promise.new()
  local active = true

  local function check()
    if not active or not input_id or reply:is_resolved() then
      return
    end
    local message = find_v1_reply(observation, input_id)
    if message then
      if message.error then
        reply:reject(message.error.message or 'Assistant returned an error')
      else
        reply:resolve(message)
      end
    end
  end

  local unsubscribe = observation:watch({ 'messages' }, check)
  return {
    set_input_id = function(id)
      input_id = id
      check()
    end,
    promise = reply,
    stop = function(reason)
      if not active then
        return
      end
      active = false
      unsubscribe()
      if reason then
        reply:reject(reason)
      end
    end,
  }
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

---@param session_info table
---@param message table
---@param range table|nil Range information
---@return boolean success Whether the response was processed successfully
local function process_response(session_info, message, range)
  if not is_safe_reply(message) then
    return false
  end

  local response_text = extract_response_text(message) or ''
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

---@param message string|nil The message to validate
---@return boolean valid
---@return string|nil error_message
local function validate_quick_chat_prerequisites(message)
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()

  if not buf or not win then
    return false, 'Quick chat requires an active file buffer'
  end

  if not message or message == '' then
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
    'I want you to ALWAYS return valid RAW code ONLY ',
    'CRITICAL: NEVER add (codeblocks, explanations or any additional text). ',
    'Respect the current indentation and formatting of the existing code. ',
    "If you can't respond with code, respond with nothing.",
  }
end

--- Creates protocol-independent submission parameters for quick chat
---@param message string The user message
---@param buf integer Buffer handle
---@param range table|nil Range information
---@param context_config OpencodeContextConfig Context configuration
---@param options table Options including model and agent
---@return table params Submission parameters
local create_message = Promise.async(function(message, buf, range, context_config, options)
  local quick_chat_config = config.quick_chat or {}

  local format_opts = { context_config = context_config }
  if range then
    format_opts.range = { start = range.start, stop = range.stop }
  end

  local result = context.format_quick_chat_message(message, context_config, format_opts):await()

  local instructions = quick_chat_config.instructions or generate_raw_code_instructions(context_config)

  local params = {
    text = table.concat(instructions, '\n') .. '\n' .. result.text,
    context = {},
    files = {},
    agents = {},
  }

  local current_model = agent_model.initialize_current_model():await()
  local target_model = options.model or quick_chat_config.default_model or current_model
  if target_model then
    local provider, model = target_model:match('^(.-)/(.+)$')
    if provider and model then
      params.model = { providerID = provider, modelID = model }
    end
  end

  local target_agent = options.agent or quick_chat_config.default_agent
  if not target_agent and agent_model.ensure_current_mode():await() then
    target_agent = state.current_mode
  end
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
  local quick_chat_session
  local quick_chat_session_id
  local quick_chat_session_info
  local v1_reply_waiter
  local success, err = pcall(function()
    quick_chat_session = session_runtime.create_new_session(title):await()
    if not quick_chat_session then
      error('Failed to create quickchat session')
    end
    quick_chat_session_id = quick_chat_session.id

    if config.debug.quick_chat and config.debug.quick_chat.set_active_session then
      state.session.set_active(quick_chat_session)
    end

    local connection = state.opencode_server
    if not connection or not connection:is_ready() then
      error('Connection is not ready')
    end
    local session_ref = {
      id = quick_chat_session.id,
      location = quick_chat_session.location or (quick_chat_session.directory and {
        directory = quick_chat_session.directory,
      }) or { directory = state.current_cwd or vim.fn.getcwd() },
    }
    quick_chat_session_info = {
      buf = buf,
      row = row,
      col = col,
      spinner = spinner,
      timestamp = vim.uv.now(),
      range = range,
      connection = connection,
      observation = nil,
      session = session_ref,
    }
    running_sessions[quick_chat_session.id] = quick_chat_session_info

    local observation = connection:observe(session_ref)
    quick_chat_session_info.observation = observation

    setup_global_keymaps()

    if connection.protocol == 'v1' then
      v1_reply_waiter = start_v1_reply_waiter(observation)
      running_sessions[quick_chat_session.id].reply_waiter = v1_reply_waiter
    end

    local context_config =
      vim.tbl_deep_extend('force', create_context_config(range ~= nil), options.context_config or {})
    local params = create_message(message, buf, range, context_config, options):await()
    local result = observation:submit(params, v1_reply_waiter and { async = true } or nil):await()
    if result.kind == 'accepted' then
      if v1_reply_waiter then
        v1_reply_waiter.set_input_id(result.input.id)
        result = { kind = 'reply', message = v1_reply_waiter.promise:await() }
      elseif type(observation.wait_until_idle) ~= 'function' then
        error('Quick chat did not receive a safe reply for its input')
      else
        local completion = observation:wait_until_idle():await()
        if completion.outcome ~= 'succeeded' then
          error('Quick chat completion failed: ' .. vim.inspect(completion))
        end
        error('Quick chat cannot associate the completed reply with its input')
      end
    end
    if
      result.kind ~= 'reply' or not process_response(running_sessions[quick_chat_session.id], result.message, range)
    then
      error('Quick chat did not receive a safe reply for its input')
    end
    cleanup_session(running_sessions[quick_chat_session.id], quick_chat_session.id)
  end)

  if v1_reply_waiter then
    v1_reply_waiter.stop()
  end

  if not success then
    local session_info = quick_chat_session_id and running_sessions[quick_chat_session_id]
    local cancelled = (session_info or quick_chat_session_info) and (session_info or quick_chat_session_info).cancelled
    local error_message = not cancelled and ('Error in quick chat: ' .. vim.inspect(err)) or nil
    if session_info then
      cleanup_session(session_info, quick_chat_session_id, error_message)
    else
      spinner:stop()
      if not next(running_sessions) then
        teardown_global_keymaps()
      end
      if not cancelled then
        vim.notify(error_message, vim.log.levels.WARN)
      end
    end
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
          if session_info.reply_waiter then
            session_info.reply_waiter.stop()
          end
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
        if session_info.reply_waiter then
          session_info.reply_waiter.stop()
        end
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
