local context = require('opencode.context')
local state = require('opencode.state')
local config = require('opencode.config')
local core = require('opencode.core')
local util = require('opencode.util')
local session = require('opencode.session')
local Promise = require('opencode.promise')
local Timer = require('opencode.ui.timer')

local M = {}

---@class OpencodeQuickChatRunningSession
---@field buf integer Buffer handle
---@field row integer Row position for spinner
---@field col integer Column position for spinner
---@field spinner CursorSpinner Spinner instance
---@field timestamp integer Timestamp when session started

---@type table<string, OpencodeQuickChatRunningSession>
local running_sessions = {}

--- Simple cursor spinner using the same animation logic as loading_animation.lua
local CursorSpinner = {}
CursorSpinner.__index = CursorSpinner

function CursorSpinner.new(buf, row, col)
  local self = setmetatable({}, CursorSpinner)
  self.buf = buf
  self.row = row
  self.col = col
  self.ns_id = vim.api.nvim_create_namespace('opencode_quick_chat_spinner')
  self.extmark_id = nil
  self.current_frame = 1
  self.timer = nil
  self.active = true

  self.frames = config.values.ui.loading_animation and config.values.ui.loading_animation.frames
    or { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

  self:render()
  self:start_timer()
  return self
end

function CursorSpinner:render()
  if not self.active or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  local frame = ' ' .. self.frames[self.current_frame]
  self.extmark_id = vim.api.nvim_buf_set_extmark(self.buf, self.ns_id, self.row, self.col, {
    id = self.extmark_id,
    virt_text = { { frame .. ' ', 'Comment' } },
    virt_text_pos = 'overlay',
    right_gravity = false,
  })
end

function CursorSpinner:next_frame()
  self.current_frame = (self.current_frame % #self.frames) + 1
end

function CursorSpinner:start_timer()
  self.timer = Timer.new({
    interval = 100, -- 10 FPS like the main loading animation
    on_tick = function()
      if not self.active then
        return false
      end
      self:next_frame()
      self:render()
      return true
    end,
    repeat_timer = true,
  })
  self.timer:start()
end

function CursorSpinner:stop()
  if not self.active then
    return
  end

  self.active = false

  if self.timer then
    self.timer:stop()
    self.timer = nil
  end

  if self.extmark_id and vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_del_extmark, self.buf, self.ns_id, self.extmark_id)
  end
end

--- Creates an ephemeral session title
---@param buf integer Buffer handle
---@return string title The session title
local function create_session_title(buf)
  local file_name = vim.api.nvim_buf_get_name(buf)
  local relative_path = file_name ~= '' and vim.fn.fnamemodify(file_name, ':~:.') or 'untitled'
  local line_num = vim.api.nvim_win_get_cursor(0)[1]
  local timestamp = os.date('%H:%M:%S')

  return string.format('[QuickChat] %s:%d (%s)', relative_path, line_num, timestamp)
end

--- Creates context configuration for quick chat
---@param has_range boolean Whether a range is specified
---@return OpencodeContextConfig context_opts
local function create_context_config(has_range)
  return {
    enabled = true,
    current_file = { enabled = false },
    cursor_data = { enabled = not has_range },
    selection = { enabled = has_range },
    diagnostics = {
      enabled = false,
      error = false,
      info = false,
      warning = false,
    },
    agents = { enabled = false },
    buffer = { enabled = true },
    git_diff = { enabled = false },
  }
end

--- Helper to clean up session info and spinner
---@param session_info table Session tracking info
---@param session_id string Session ID
---@param message string|nil Optional message to display
local function cleanup_session(session_info, session_id, message)
  if session_info and session_info.spinner then
    session_info.spinner:stop()
  end
  running_sessions[session_id] = nil
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

--- Extracts and parses JSON replacement data from response text
---@param response_text string Response text that may contain JSON in code blocks
---@return table|nil replacement_data Parsed replacement data or nil if invalid
local function parse_replacement_json(response_text)
  local json_text = response_text
  local json_match = response_text:match('```json\n(.-)\n```') or response_text:match('```\n(.-)\n```')
  if json_match then
    json_text = json_match
  end

  local ok, replacement_data = pcall(vim.json.decode, json_text)
  if not ok then
    return nil
  end

  if not replacement_data.replacements or type(replacement_data.replacements) ~= 'table' then
    return nil
  end

  if #replacement_data.replacements == 0 then
    return nil
  end

  return replacement_data
end

--- Converts object format like {"1": "line1", "2": "line2"} to array
--- Some LLMs may return line replacements in this format instead of an array
---@param obj_lines table Object with string keys representing line numbers
---@return string[] lines_array Array of lines in correct order
local function convert_object_to_lines_array(obj_lines)
  local lines_array = {}
  local numeric_keys = {}

  -- Collect all numeric string keys
  for key, _ in pairs(obj_lines) do
    local num_key = tonumber(key)
    if num_key and num_key > 0 and math.floor(num_key) == num_key then
      table.insert(numeric_keys, num_key)
    end
  end

  -- Sort keys to ensure correct order
  table.sort(numeric_keys)

  for _, num_key in ipairs(numeric_keys) do
    local line_content = obj_lines[tostring(num_key)]
    if line_content then
      table.insert(lines_array, line_content)
    end
  end

  return lines_array
end

--- Applies line replacements to a buffer using parsed replacement data
---@param buf integer Buffer handle
---@param replacement_data table Parsed replacement data
---@return boolean success Whether the replacements were applied successfully
local function apply_line_replacements(buf, replacement_data)
  if not vim.api.nvim_buf_is_valid(buf) then
    vim.notify('Buffer is not valid for applying changes', vim.log.levels.ERROR)
    return false
  end

  local buf_line_count = vim.api.nvim_buf_line_count(buf)

  table.sort(replacement_data.replacements, function(a, b)
    return (a.start_line or a.line) > (b.start_line or b.line)
  end)

  local total_replacements = 0
  for _, replacement in ipairs(replacement_data.replacements) do
    local start_line = replacement.start_line or replacement.line
    local end_line = replacement.end_line or start_line
    local new_lines = replacement.lines or replacement.content

    -- Convert string to array
    if type(new_lines) == 'string' then
      new_lines = vim.split(new_lines, '\n')
    elseif type(new_lines) == 'table' then
      -- Check if it's object format like {"1": "line1", "2": "line2"}
      local first_key = next(new_lines)
      if first_key and type(first_key) == 'string' and tonumber(first_key) then
        new_lines = convert_object_to_lines_array(new_lines)
      end
    end

    if start_line and start_line >= 1 and start_line <= buf_line_count and new_lines and #new_lines > 0 then
      local start_idx = math.floor(math.max(0, start_line - 1))
      local end_idx = math.floor(math.min(end_line, buf_line_count))

      pcall(vim.api.nvim_buf_set_lines, buf, start_idx, end_idx, false, new_lines)
      total_replacements = total_replacements + 1
    end
  end

  return total_replacements > 0
end

--- Processes response from ephemeral session
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
    return false
  end

  local replacement_data = parse_replacement_json(response_text)
  if not replacement_data then
    return false
  end

  return apply_line_replacements(session_info.buf, replacement_data)
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

  --@TODO: enable session deletion after testing
  -- Always delete ephemeral session
  -- state.api_client:delete_session(session_obj.id):catch(function(err)
  --   vim.notify('Error deleting ephemeral session: ' .. vim.inspect(err), vim.log.levels.WARN)
  -- end)
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

--- Sets up context and range for quick chat
---@param buf integer Buffer handle
---@param context_config OpencodeContextConfig Context configuration
---@param range table|nil Range information
---@return table context_instance
local function init_context(buf, context_config, range)
  local context_instance = context.new_instance(context_config)

  if range and range.start and range.stop then
    local start_line = math.floor(math.max(0, range.start - 1))
    local end_line = math.floor(range.stop + 1)
    local range_lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line, false)
    local range_text = table.concat(range_lines, '\n')
    local current_file = context_instance:get_current_file(buf)
    local selection = context_instance:new_selection(current_file, range_text, range.start .. ', ' .. range.stop)
    context_instance:add_selection(selection)
  end

  return context_instance
end

--- Creates message parameters for quick chat
---@param message string The user message
---@param context_instance table Context instance
---@param options table Options including model and agent
---@return table params Message parameters
local create_message = Promise.async(function(message, context_instance, options)
  local quick_chat_config = config.quick_chat or {}
  local instructions = quick_chat_config.instructions
    or {
      'You are an expert code assistant helping with code and text editing tasks.',
      'You are operating in a temporary quick chat session with limited context.',
      "Your task is to modify the provided code according to the user's request. Follow these instructions precisely:",
      'CRITICAL: At the end of your job You MUST add a message with a valid JSON format for line replacements. Use this exact structure:',
      '',
      '```json',
      '{',
      '  "replacements": [',
      '    {',
      '      "start_line": 10,',
      '      "end_line": 11,',
      '      "lines": ["new content line 1", "new content line 2"]',
      '    }',
      '  ]',
      '}',
      '```',
      '',
      'Maintain the *SAME INDENTATION* in the returned code as in the source code',
      'NEVER add any explanations, apologies, or additional text outside the JSON structure.',
      'ALWAYS split multiple line replacements into separate entries in the "replacements" array.',
      'IMPORTANT: Use 1-indexed line numbers. Each replacement replaces lines start_line through end_line (inclusive).',
      'The "lines" array contains the new content. If replacing a single line, end_line can equal start_line.',
      'Ensure the returned code is complete and can be directly used as a replacement for the original code.',
      'Remember that Your response SHOULD CONTAIN ONLY THE MODIFIED CODE to be used as DIRECT REPLACEMENT to the original file.',
    }

  local parts = context.format_message_quick_chat(message, context_instance):await()
  local params = { parts = parts, system = table.concat(instructions, '\n'), synthetic = true }

  local current_model = core.initialize_current_model():await()
  local target_model = options.model or quick_chat_config.default_model or current_model
  if target_model then
    local provider, model = target_model:match('^(.-)/(.+)$')
    if provider and model then
      params.model = { providerID = provider, modelID = model }
    end
  end

  -- Set agent if specified
  local target_mode = options.agent
    or quick_chat_config.default_agent
    or state.current_mode
    or config.values.default_mode
  if target_mode then
    params.agent = target_mode
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

  local context_config = vim.tbl_deep_extend('force', create_context_config(range ~= nil), options.context_config or {})
  local context_instance = init_context(buf, context_config, range)

  local allowed, err_msg = util.check_prompt_allowed(config.values.prompt_guard, context_instance:get_mentioned_files())
  if not allowed then
    spinner:stop()
    return Promise.new():reject(err_msg or 'Prompt denied by prompt_guard')
  end

  local title = create_session_title(buf)
  local quick_chat_session = core.create_new_session(title):await()
  if not quick_chat_session then
    spinner:stop()
    return Promise.new():reject('Failed to create ephemeral session')
  end

  --TODO only for debug
  state.active_session = quick_chat_session

  running_sessions[quick_chat_session.id] = {
    buf = buf,
    row = row,
    col = col,
    spinner = spinner,
    timestamp = vim.uv.now(),
  }

  local params = create_message(message, context_instance, options):await()
  spinner:stop()

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
          if session_info.spinner then
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
        if session_info.spinner then
          session_info.spinner:stop()
        end
      end
      running_sessions = {}
    end,
  })
end

return M
