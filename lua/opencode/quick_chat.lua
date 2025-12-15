-- Quick chat functionality for opencode.nvim
-- Provides ephemeral chat sessions with context-specific prompts

local context = require('opencode.context')
local state = require('opencode.state')
local config = require('opencode.config')
local core = require('opencode.core')
local util = require('opencode.util')
local Promise = require('opencode.promise')
local session = require('opencode.session')
local Timer = require('opencode.ui.timer')

local M = {}

local active_sessions = {}

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
  active_sessions[session_id] = nil
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

--- Applies line replacements to a buffer using JSON format
---@param buf integer Buffer handle
---@param response_text string JSON-formatted response containing replacements
---@return boolean success Whether the replacements were applied successfully
local function apply_line_replacements(buf, response_text)
  if not vim.api.nvim_buf_is_valid(buf) then
    vim.notify('Buffer is not valid for applying changes', vim.log.levels.ERROR)
    return false
  end

  -- Try to extract JSON from response text (handle cases where JSON is in code blocks)
  local json_text = response_text
  -- Look for JSON in code blocks
  local json_match = response_text:match('```json\n(.-)\n```') or response_text:match('```\n(.-)\n```')
  if json_match then
    json_text = json_match
  end

  -- Try to parse JSON format
  local ok, replacement_data = pcall(vim.json.decode, json_text)
  if not ok then
    vim.notify('Failed to parse replacement data as JSON: ' .. tostring(replacement_data), vim.log.levels.ERROR)
    return false
  end

  if not replacement_data.replacements or type(replacement_data.replacements) ~= 'table' then
    vim.notify('Invalid replacement format - missing replacements array', vim.log.levels.ERROR)
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

    if type(new_lines) == 'string' then
      new_lines = vim.split(new_lines, '\n', { plain = true })
    end

    if start_line and start_line >= 1 and start_line <= buf_line_count then
      local start_idx = start_line - 1 -- Convert to 0-indexed
      local end_idx = math.min(end_line, buf_line_count)

      local success, err = pcall(vim.api.nvim_buf_set_lines, buf, start_idx, end_idx, false, new_lines)
      if not success then
        vim.notify('Failed to apply replacement: ' .. tostring(err), vim.log.levels.ERROR)
        return false
      end

      total_replacements = total_replacements + 1
    else
      vim.notify(
        string.format('Could not apply replacement - start_line %d is out of bounds', start_line),
        vim.log.levels.WARN
      )
    end
  end

  return total_replacements > 0
end

--- Checks if response text is in JSON replacement format
---@param response_text string Response text to check
---@return boolean is_json True if text contains JSON replacement format
local function is_json_replacement_format(response_text)
  -- Check for JSON in code blocks first
  local json_match = response_text:match('```json\n(.-)\n```') or response_text:match('```\n(.-)\n```')
  local json_text = json_match or response_text

  -- Try to parse as JSON
  local ok, data = pcall(vim.json.decode, json_text)
  if not ok then
    return false
  end

  -- Check if it has the expected replacements structure
  return type(data) == 'table' and type(data.replacements) == 'table' and #data.replacements > 0
end

--- Processes response from ephemeral session
---@param session_obj Session The session object
---@param session_info table Session tracking info
---@param messages OpencodeMessage[] Session messages
local function process_response(session_obj, session_info, messages)
  if #messages < 2 then
    cleanup_session(session_info, session_obj.id, 'Quick chat completed but no messages found')
    return
  end

  local response_message = messages[#messages]
  if not response_message or response_message.info.role ~= 'assistant' then
    cleanup_session(session_info, session_obj.id, 'Quick chat completed but no assistant response found')
    return
  end

  local response_text = extract_response_text(response_message) or ''

  if response_text ~= '' then
    -- Try JSON format first (preferred)
    if is_json_replacement_format(response_text) then
      local success = apply_line_replacements(session_info.buf, response_text)
      if success then
        cleanup_session(session_info, session_obj.id)
      else
        cleanup_session(session_info, session_obj.id, 'Failed to apply code edits')
      end
      return
    end
  end

  cleanup_session(session_info, session_obj.id, 'Quick chat completed but no recognized response format found')
end

--- Hook function called when a session is done thinking (no more pending messages)
---@param session_obj Session The session object
local on_done = Promise.async(function(session_obj)
  if not (session_obj.title and vim.startswith(session_obj.title, '[QuickChat]')) then
    return
  end

  local session_info = active_sessions[session_obj.id]
  if session_info then
    local messages = session.get_messages(session_obj):await() --[[@as OpencodeMessage[] ]]
    if messages then
      process_response(session_obj, session_info, messages)
    end
  end

  -- Always delete ephemeral session
  -- state.api_client:delete_session(session_obj.id):catch(function(err)
  --   vim.notify('Error deleting ephemeral session: ' .. vim.inspect(err), vim.log.levels.WARN)
  -- end)
end)

--- Helper function to save file if modified
---@param buf integer Buffer handle
---@return boolean success True if file was saved successfully or didn't need saving
local function ensure_file_saved(buf)
  if not vim.api.nvim_get_option_value('modified', { buf = buf }) then
    return true
  end

  local filename = vim.api.nvim_buf_get_name(buf)
  if not filename or filename == '' then
    vim.notify('Cannot save unnamed buffer. Please save the file first.', vim.log.levels.WARN)
    return false
  end

  if vim.fn.filewritable(filename) ~= 1 and vim.fn.filewritable(vim.fn.fnamemodify(filename, ':h')) ~= 2 then
    vim.notify('File is not writable: ' .. filename, vim.log.levels.ERROR)
    return false
  end

  local ok, err = pcall(function()
    vim.api.nvim_buf_call(buf, function()
      vim.cmd('write')
    end)
  end)

  if not ok then
    vim.notify('Failed to save file: ' .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  return true
end

--- Unified quick chat function
---@param message string Optional custom message to use instead of default prompts
---@param options {include_context?: boolean, model?: string, agent?: string}|nil Optional configuration for context and behavior
---@param range table|nil Optional range information { start = number, stop = number }
---@return Promise
function M.quick_chat(message, options, range)
  options = options or {}

  local buf, win = context.get_current_buf()
  if not buf or not win then
    vim.notify('Quick chat requires an active file buffer', vim.log.levels.ERROR)
    return Promise.new():resolve(nil)
  end

  if message and message == '' then
    vim.notify('Quick chat message cannot be empty', vim.log.levels.ERROR)
    return Promise.new():resolve(nil)
  end

  -- if not ensure_file_saved(buf) then
  --   vim.notify('Quick chat cancelled - file must be saved first', vim.log.levels.ERROR)
  --   return Promise.new():resolve(nil)
  -- end

  local cursor_pos = vim.api.nvim_win_get_cursor(win)
  local row, col = cursor_pos[1] - 1, cursor_pos[2] -- Convert to 0-indexed
  local spinner = CursorSpinner.new(buf, row, col)

  local context_config = create_context_config(range ~= nil)
  local context_instance = context.new_instance(context_config)

  if range and range.start and range.stop then
    local range_lines = vim.api.nvim_buf_get_lines(buf, range.start - 1, range.stop, false)
    local range_text = table.concat(range_lines, '\n')
    local current_file = context_instance:get_current_file(buf)
    local selection = context_instance:new_selection(current_file, range_text, range.start .. ', ' .. range.stop)
    context_instance:add_selection(selection)
  end

  local title = create_session_title(buf)

  return core.create_new_session(title):and_then(function(quick_chat_session)
    if not quick_chat_session then
      spinner:stop()
      return Promise.new():reject('Failed to create ephemeral session')
    end

    --TODO only for debug
    state.active_session = quick_chat_session

    active_sessions[quick_chat_session.id] = {
      buf = buf,
      row = row,
      col = col,
      spinner = spinner,
      timestamp = vim.uv.now(),
    }

    local allowed, err_msg =
      util.check_prompt_allowed(config.values.prompt_guard, context_instance:get_mentioned_files())

    if not allowed then
      spinner:stop()
      active_sessions[quick_chat_session.id] = nil
      return Promise.new():reject(err_msg or 'Prompt denied by prompt_guard')
    end

    local instructions = config.quick_chat and config.quick_chat.instructions
      or {
        'You are an expert code assistant helping with code and text editing tasks.',
        'You are operating in a temporary quick chat session with limited context.',
        'CRITICAL: You MUST respond ONLY in valid JSON format for line replacements. Use this exact structure:',
        '',
        '```json',
        '{',
        '  "replacements": [',
        '    {',
        '      "start_line": 10,',
        '      "end_line": 12,',
        '      "lines": ["new content line 1", "new content line 2"]',
        '    }',
        '  ]',
        '}',
        '```',
        '',
        'ALWAYS split multiple line replacements into separate entries in the "replacements" array.',
        'NEVER add any explanations, apologies, or additional text outside the JSON structure.',
        'IMPORTANT: Use 1-indexed line numbers. Each replacement replaces lines start_line through end_line (inclusive).',
        'The "lines" array contains the new content. If replacing a single line, end_line can equal start_line.',
        'Only provide changes that are directly relevant to the current context, cursor position, or selection.',
        'The provided context is in JSON format - use the plain text content to determine what changes to make.',
      }

    local parts = context.format_message_stateless(message, context_instance)
    local params = { parts = parts, system = table.concat(instructions, '\n\n') }
    local quick_chat_config = config.values.quick_chat or {}

    return core
      .initialize_current_model()
      :and_then(function(current_model)
        local target_model = options.model or quick_chat_config.default_model or current_model
        if target_model then
          local provider, model = target_model:match('^(.-)/(.+)$')
          if provider and model then
            params.model = { providerID = provider, modelID = model }
          end
        end

        local target_mode = options.agent
          or quick_chat_config.default_agent
          or state.current_mode
          or config.values.default_mode
        if target_mode then
          params.agent = target_mode
        end

        return state.api_client:create_message(quick_chat_session.id, params)
      end)
      :and_then(function()
        on_done(quick_chat_session)
      end)
      :catch(function(err)
        spinner:stop()
        active_sessions[quick_chat_session.id] = nil
        vim.notify('Error in quick chat: ' .. vim.inspect(err), vim.log.levels.ERROR)
      end)
  end)
end

--- Setup function to initialize quick chat functionality
function M.setup()
  local augroup = vim.api.nvim_create_augroup('OpenCodeQuickChat', { clear = true })

  vim.api.nvim_create_autocmd('BufDelete', {
    group = augroup,
    callback = function(ev)
      local buf = ev.buf
      for session_id, session_info in pairs(active_sessions) do
        if session_info.buf == buf then
          if session_info.spinner then
            session_info.spinner:stop()
          end
          active_sessions[session_id] = nil
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = augroup,
    callback = function()
      for _session_id, session_info in pairs(active_sessions) do
        if session_info.spinner then
          session_info.spinner:stop()
        end
      end
      active_sessions = {}
    end,
  })
end

return M
