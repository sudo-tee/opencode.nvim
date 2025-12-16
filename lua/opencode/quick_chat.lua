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

--- Parses SEARCH/REPLACE blocks from response text
--- Format:
--- <<<<<<< SEARCH
--- original code
--- =======
--- replacement code
--- >>>>>>> REPLACE
---@param response_text string Response text containing SEARCH/REPLACE blocks
---@return table[] replacements Array of {search=string, replace=string}
local function parse_search_replace_blocks(response_text)
  local replacements = {}

  -- Normalize line endings
  local text = response_text:gsub('\r\n', '\n')

  -- Pattern to match SEARCH/REPLACE blocks
  -- Captures content between markers, handling various whitespace
  local pos = 1
  while pos <= #text do
    -- Find the start marker
    local search_start = text:find('<<<<<<<%s*SEARCH%s*\n', pos)
    if not search_start then
      break
    end

    local should_continue = false

    -- Find the separator
    local content_start_pos = text:find('\n', search_start)
    if not content_start_pos then
      pos = search_start + 1
      should_continue = true
    end

    if not should_continue then
      local content_start = content_start_pos + 1
      local separator = text:find('\n=======%s*\n', content_start)
      if not separator then
        -- Try without leading newline (in case of edge formatting)
        separator = text:find('=======%s*\n', content_start)
        if not separator then
          pos = search_start + 1
          should_continue = true
        end
      end

      if not should_continue then
        -- Find the end marker
        local replace_start = text:find('\n', separator + 1)
        if replace_start then
          replace_start = replace_start + 1
        else
          pos = search_start + 1
          should_continue = true
        end

        if not should_continue then
          local end_marker = text:find('\n?>>>>>>>%s*REPLACE', replace_start)
          if not end_marker then
            pos = search_start + 1
            should_continue = true
          end

          if not should_continue then
            -- Extract the search and replace content
            local search_content = text:sub(content_start, separator - 1)
            local replace_content = text:sub(replace_start, end_marker - 1)

            -- Handle trailing newline in replace content
            if replace_content:sub(-1) == '\n' then
              replace_content = replace_content:sub(1, -2)
            end

            table.insert(replacements, {
              search = search_content,
              replace = replace_content,
            })

            -- Move past this block
            pos = end_marker + 1
          end
        end
      end
    end
  end

  return replacements
end

--- Normalizes indentation by detecting and removing common leading whitespace
---@param text string The text to normalize
---@return string normalized The text with common indentation removed
---@return string indent The common indentation that was removed
local function normalize_indentation(text)
  local lines = vim.split(text, '\n', { plain = true })
  local min_indent = math.huge
  local indent_char = nil

  -- Find minimum indentation (ignoring empty lines)
  for _, line in ipairs(lines) do
    if line:match('%S') then -- non-empty line
      local leading = line:match('^([ \t]*)')
      if #leading < min_indent then
        min_indent = #leading
        indent_char = leading
      end
    end
  end

  if min_indent == math.huge or min_indent == 0 then
    return text, ''
  end

  -- Remove common indentation
  local normalized_lines = {}
  for _, line in ipairs(lines) do
    if line:match('%S') then
      table.insert(normalized_lines, line:sub(min_indent + 1))
    else
      table.insert(normalized_lines, line)
    end
  end

  return table.concat(normalized_lines, '\n'), (indent_char or ''):sub(1, min_indent)
end

--- Tries to find search text in content with flexible whitespace matching
---@param content string The buffer content
---@param search string The search text
---@return number|nil start_pos Start position if found
---@return number|nil end_pos End position if found
local function find_with_flexible_whitespace(content, search)
  -- First try exact match
  local start_pos, end_pos = content:find(search, 1, true)
  if start_pos then
    return start_pos, end_pos
  end

  -- Normalize the search text (remove its indentation)
  local normalized_search, _ = normalize_indentation(search)

  -- Try to find each line of the normalized search in sequence
  local search_lines = vim.split(normalized_search, '\n', { plain = true })
  if #search_lines == 0 then
    return nil, nil
  end

  -- Find the first non-empty search line
  local first_search_line = nil
  for _, line in ipairs(search_lines) do
    if line:match('%S') then
      first_search_line = line
      break
    end
  end

  if not first_search_line then
    return nil, nil
  end

  -- Escape special pattern characters for the search
  local escaped_first = vim.pesc(first_search_line)

  -- Search for the first line with any leading whitespace
  local pattern = '[ \t]*' .. escaped_first
  local match_start = content:find(pattern)

  if not match_start then
    return nil, nil
  end

  -- Find the actual start (beginning of the line)
  local line_start = match_start
  while line_start > 1 and content:sub(line_start - 1, line_start - 1) ~= '\n' do
    line_start = line_start - 1
  end

  -- Now verify all subsequent lines match
  local content_lines = vim.split(content:sub(line_start), '\n', { plain = true })
  local search_idx = 1
  local matched_content = {}

  for _, content_line in ipairs(content_lines) do
    if search_idx > #search_lines then
      break
    end

    local search_line = search_lines[search_idx]

    -- Normalize both lines for comparison (trim leading/trailing whitespace for matching)
    local content_trimmed = (content_line and content_line:match('^%s*(.-)%s*$')) or ''
    local search_trimmed = (search_line and search_line:match('^%s*(.-)%s*$')) or ''

    if content_trimmed == search_trimmed then
      table.insert(matched_content, content_line)
      search_idx = search_idx + 1
    elseif search_trimmed == '' then
      -- Empty search line matches empty content line
      if content_trimmed == '' then
        table.insert(matched_content, content_line)
        search_idx = search_idx + 1
      else
        break
      end
    else
      break
    end
  end

  -- Check if we matched all search lines
  if search_idx > #search_lines then
    local matched_text = table.concat(matched_content, '\n')
    local actual_end = line_start + #matched_text - 1
    return line_start, actual_end
  end

  return nil, nil
end

--- Applies SEARCH/REPLACE blocks to buffer content
---@param buf integer Buffer handle
---@param replacements table[] Array of {search=string, replace=string}
---@return boolean success Whether any replacements were applied
---@return string[] errors List of error messages for failed replacements
local function apply_search_replace(buf, replacements)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false, { 'Buffer is not valid' }
  end

  -- Get full buffer content
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local content = table.concat(lines, '\n')

  local applied_count = 0
  local errors = {}

  for i, replacement in ipairs(replacements) do
    local search = replacement.search
    local replace = replacement.replace

    -- Find the search text in content (with flexible whitespace matching)
    local start_pos, end_pos = find_with_flexible_whitespace(content, search)

    if start_pos and end_pos then
      -- Detect the indentation of the matched content
      local line_start = start_pos
      while line_start > 1 and content:sub(line_start - 1, line_start - 1) ~= '\n' do
        line_start = line_start - 1
      end
      local existing_indent = content:sub(line_start, start_pos - 1)

      -- Apply the same indentation to replacement if it doesn't have it
      local replace_lines = vim.split(replace, '\n', { plain = true })
      local indented_replace_lines = {}

      for j, line in ipairs(replace_lines) do
        if line:match('%S') then
          -- Check if line already has indentation
          local line_indent = line:match('^([ \t]*)')
          if #line_indent == 0 and #existing_indent > 0 then
            table.insert(indented_replace_lines, existing_indent .. line)
          else
            table.insert(indented_replace_lines, line)
          end
        else
          table.insert(indented_replace_lines, line)
        end
      end

      local indented_replace = table.concat(indented_replace_lines, '\n')

      -- Replace the content
      content = content:sub(1, start_pos - 1) .. indented_replace .. content:sub(end_pos + 1)
      applied_count = applied_count + 1
    else
      -- Try to provide helpful error message
      local search_preview = search:sub(1, 50):gsub('\n', '\\n')
      if #search > 50 then
        search_preview = search_preview .. '...'
      end
      table.insert(errors, string.format('Block %d: SEARCH not found: "%s"', i, search_preview))
    end
  end

  if applied_count > 0 then
    -- Write back to buffer
    local new_lines = vim.split(content, '\n', { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
  end

  return applied_count > 0, errors
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

  local replacements = parse_search_replace_blocks(response_text)
  if #replacements == 0 then
    return false
  end

  local success, errors = apply_search_replace(session_info.buf, replacements)

  -- Log errors for debugging but don't fail completely if some replacements worked
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
      enabled = true,
      error = true,
      warning = true,
      info = false,
      only_closest = has_range,
    },
    agents = { enabled = false },
    buffer = { enabled = true },
    git_diff = { enabled = false },
  }
end

--- Creates message parameters for quick chat
---@param message string The user message
---@param buf integer Buffer handle
---@param range table|nil Range information
---@param context_instance ContextInstance Context instance
---@param options table Options including model and agent
---@return table params Message parameters
local create_message = Promise.async(function(message, buf, range, context_instance, options)
  local quick_chat_config = config.values.quick_chat or {}
  -- stylua: ignore
  local instructions = quick_chat_config.instructions or {
    'You are a code editing assistant. Modify the provided code according to the user instruction.',
    'Your ONLY output format is SEARCH/REPLACE blocks. Do NOT explain, comment, or add any other text.',
    '',
    'FORMAT:',
    '<<<<<<< SEARCH',
    'exact lines to find (copy from the provided code)',
    '=======',
    'modified lines',
    '>>>>>>> REPLACE',
    '',
    'RULES:',
    '1. ONLY output SEARCH/REPLACE blocks - absolutely no explanations or markdown',
    '2. Copy the SEARCH content EXACTLY from the provided code between the ``` markers',
    '3. Include 1-3 surrounding lines in SEARCH for unique matching',
    '4. REPLACE contains the modified version of SEARCH content',
    '5. Multiple changes = multiple SEARCH/REPLACE blocks',
    '6. Delete lines by omitting them from REPLACE',
    '7. Add lines by including them in REPLACE',
    '8. If DIAGNOSTICS are provided, use them to understand what needs fixing',
    '9. If a SELECTION is provided, only modify code within that selection',
    '10. If CURSOR_DATA is provided, focus modifications near that cursor position',
    '11. GIT_DIFF context is for reference only - never use git diff hunks as SEARCH content',
    '',
    'EXAMPLE - Change return value:',
    '<<<<<<< SEARCH',
    'function getValue()',
    '  return 42',
    'end',
    '=======',
    'function getValue()',
    '  return 100',
    'end',
    '>>>>>>> REPLACE',
    '',
    'EXAMPLE - Add a line:',
    '<<<<<<< SEARCH',
    'local x = 1',
    'local y = 2',
    '=======',
    'local x = 1',
    'local z = 1.5',
    'local y = 2',
    '>>>>>>> REPLACE',
    '',
    'EXAMPLE - Delete a line:',
    '<<<<<<< SEARCH',
    '-- old comment',
    'local unused = true',
    'local needed = false',
    '=======',
    'local needed = false',
    '>>>>>>> REPLACE',
    '',
    'Remember: Output ONLY SEARCH/REPLACE blocks. The SEARCH text must match the code exactly.',
  }

  local format_opts = { buf = buf }
  if range then
    format_opts.range = { start = range.start, stop = range.stop }
  end

  local result = context.format_message_plain_text(message, context_instance, format_opts):await()

  -- Prepend instructions to the message text (in addition to system param)
  -- This ensures the LLM sees the instructions even if system prompt isn't honored
  local instructions_text = table.concat(instructions, '\n')
  local full_text = instructions_text .. '\n\n---\n\n' .. result.text
  local parts = { { type = 'text', text = full_text } }

  local params = { parts = parts, system = instructions_text }

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

  -- Create context instance for diagnostics and other context
  local context_config = vim.tbl_deep_extend('force', create_context_config(range ~= nil), options.context_config or {})
  local context_instance = context.new_instance(context_config)

  -- Check prompt guard with the current file
  local file_name = vim.api.nvim_buf_get_name(buf)
  local mentioned_files = file_name ~= '' and { file_name } or {}
  local allowed, err_msg = util.check_prompt_allowed(config.values.prompt_guard, mentioned_files)
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

  local params = create_message(message, buf, range, context_instance, options):await()
  vim.print('⭕ ❱ quick_chat.lua:685 ❱ ƒ(params) ❱ params =', params)

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
