-- Quick chat functionality for opencode.nvim
-- Provides ephemeral chat sessions with context-specific prompts

local context = require('opencode.context')
local state = require('opencode.state')
local config = require('opencode.config')
local core = require('opencode.core')
local util = require('opencode.util')
local Promise = require('opencode.promise')
local session = require('opencode.session')

local M = {}

-- Spinner animation frames
local SPINNER_FRAMES = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local SPINNER_INTERVAL = 100 -- ms

-- Table to track active quick chat sessions
local active_sessions = {}

--- Creates a namespace for extmarks
local function get_or_create_namespace()
  return vim.api.nvim_create_namespace('opencode_quick_chat_spinner')
end

--- Creates and starts a spinner at the cursor position
---@param buf integer Buffer handle
---@param row integer Row (0-indexed)
---@param col integer Column (0-indexed)
---@return table spinner_state Spinner state object
local function create_spinner(buf, row, col)
  local ns = get_or_create_namespace()

  local spinner_state = {
    buf = buf,
    row = row,
    col = col,
    ns = ns,
    extmark_id = nil,
    frame_index = 1,
    timer = nil,
    active = true,
  }

  -- Create initial extmark
  spinner_state.extmark_id = vim.api.nvim_buf_set_extmark(buf, ns, row, col, {
    virt_text = { { SPINNER_FRAMES[1] .. ' ', 'Comment' } },
    virt_text_pos = 'inline',
    right_gravity = false,
  })

  -- Start animation timer
  spinner_state.timer = vim.uv.new_timer()
  spinner_state.timer:start(
    SPINNER_INTERVAL,
    SPINNER_INTERVAL,
    vim.schedule_wrap(function()
      if not spinner_state.active then
        return
      end

      -- Update frame
      spinner_state.frame_index = (spinner_state.frame_index % #SPINNER_FRAMES) + 1
      local frame = SPINNER_FRAMES[spinner_state.frame_index]

      -- Update extmark if buffer is still valid
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col, {
          id = spinner_state.extmark_id,
          virt_text = { { frame .. ' ', 'Comment' } },
          virt_text_pos = 'inline',
          right_gravity = false,
        })
      else
        -- Buffer is invalid, stop spinner
        spinner_state.active = false
      end
    end)
  )

  return spinner_state
end

--- Stops and cleans up a spinner
---@param spinner_state table Spinner state object
local function cleanup_spinner(spinner_state)
  if not spinner_state or not spinner_state.active then
    return
  end

  spinner_state.active = false

  -- Stop timer
  if spinner_state.timer then
    spinner_state.timer:stop()
    spinner_state.timer:close()
    spinner_state.timer = nil
  end

  -- Remove extmark
  if spinner_state.extmark_id and vim.api.nvim_buf_is_valid(spinner_state.buf) then
    pcall(vim.api.nvim_buf_del_extmark, spinner_state.buf, spinner_state.ns, spinner_state.extmark_id)
  end
end

--- Creates an ephemeral session title based on current context
---@param buf integer Buffer handle
---@return string title The session title
local function create_ephemeral_title(buf)
  local file_name = vim.api.nvim_buf_get_name(buf)
  local relative_path = file_name ~= '' and vim.fn.fnamemodify(file_name, ':~:.') or 'untitled'
  local line_num = vim.api.nvim_win_get_cursor(0)[1]
  local timestamp = os.date('%H:%M:%S')

  return string.format('[QuickChat] %s:%d (%s)', relative_path, math.floor(line_num), timestamp)
end

--- Creates the prompt for quick chat
---@param custom_message string|nil Optional custom message
---@return string prompt
local function create_context_prompt(custom_message)
  if custom_message then
    return custom_message
  end

  local quick_chat_config = config.quick_chat or {}
  if quick_chat_config.default_prompt then
    return quick_chat_config.default_prompt
  end

  return 'Please provide a brief, focused response based on the current context. '
    .. 'If working with code, suggest improvements, explain functionality, or help with the current task. '
    .. "Keep the response concise and directly relevant to what I'm working on."
end

--- Creates context configuration for quick chat
---@param options table Options
---@param custom_message string|nil Custom message
---@return OpencodeContextConfig context_opts
local function create_context_config(options, custom_message)
  local quick_chat_config = config.quick_chat or {}

  -- Use config default or option override
  local include_context = options.include_context
  if include_context == nil then
    include_context = quick_chat_config.include_context_by_default ~= false
  end

  -- Use default context configuration with minimal modifications
  return {
    enabled = include_context,
    current_file = { enabled = include_context },
    cursor_data = { enabled = include_context },
    selection = { enabled = include_context },
    diagnostics = { enabled = false }, -- Disable diagnostics for quick chat to keep it focused
    agents = { enabled = false }, -- Disable agents for focused quick chat
  }
end

--- Helper to clean up session info and spinner
---@param session_info table Session tracking info
---@param session_id string Session ID
---@param message string|nil Optional message to display
local function cleanup_session(session_info, session_id, message)
  if session_info then
    cleanup_spinner(session_info.spinner)
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

  -- Clean up the response text
  response_text = response_text:gsub('```[%w]*\n?', ''):gsub('```', '')
  return vim.trim(response_text)
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

  local response_text = extract_response_text(response_message)
  if response_text ~= '' then
    vim.cmd('checktime') -- Refresh buffer to avoid conflicts
    cleanup_session(session_info, session_obj.id)
  else
    cleanup_session(session_info, session_obj.id, 'Quick chat completed but no text response received')
  end
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

--- Unified quick chat function
---@param message string|nil Optional custom message to use instead of default prompts
---@param options {include_context?: boolean, model?: string, agent?: string}|nil Optional configuration for context and behavior
---@param range table|nil Optional range information { start = number, stop = number }
---@return Promise
function M.quick_chat(message, options, range)
  options = options or {}

  -- Validate environment
  local buf, win = context.get_current_buf()
  if not buf or not win then
    vim.notify('Quick chat requires an active file buffer', vim.log.levels.ERROR)
    return Promise.resolve()
  end

  -- Validate message if provided
  if message and message == '' then
    vim.notify('Quick chat message cannot be empty', vim.log.levels.ERROR)
    return Promise.resolve()
  end

  -- Setup spinner at cursor position
  local cursor_pos = vim.api.nvim_win_get_cursor(win)
  local row, col = cursor_pos[1] - 1, cursor_pos[2] -- Convert to 0-indexed
  local spinner_state = create_spinner(buf, row, col)

  local context_config = create_context_config(options, message)
  local context_instance = context.new_instance(create_context_config(options, message))

  -- Handle range-based context by adding it as a selection
  if range and range.start and range.stop then
    local range_lines = vim.api.nvim_buf_get_lines(buf, range.start - 1, range.stop, false)
    local range_text = table.concat(range_lines, '\n')
    local current_file = context_instance:get_current_file(buf)
    local selection = context_instance:new_selection(current_file, range_text, range.start .. ', ' .. range.stop)
    context_instance:add_selection(selection)
  end

  -- Create session and send message
  local title = create_ephemeral_title(buf)

  return core.create_new_session(title):and_then(function(quick_chat_session)
    if not quick_chat_session then
      cleanup_spinner(spinner_state)
      return Promise.reject('Failed to create ephemeral session')
    end
    --TODO only for debug
    state.active_session = quick_chat_session

    -- Store session tracking info
    active_sessions[quick_chat_session.id] = {
      buf = buf,
      row = row,
      col = col,
      spinner = spinner_state,
      timestamp = vim.uv.now(),
    }

    local prompt = create_context_prompt(message)
    vim.print('⭕ ❱ quick_chat.lua:294 ❱ ƒ(prompt) ❱ prompt =', prompt)
    local context_opts = create_context_config(options, message)

    local allowed, err_msg = util.check_prompt_allowed(config.prompt_guard, context_instance:get_mentioned_files())

    if not allowed then
      cleanup_spinner(spinner_state)
      active_sessions[quick_chat_session.id] = nil
      return Promise.new():reject(err_msg or 'Prompt denied by prompt_guard')
    end

    -- Use context.format_message_stateless with the context instance
    local instructions = config.quick_chat and config.quick_chat.instructions
      or {
        'Do not add, remove, or modify any code, comments, or formatting outside the specified scope.',
        'If you made changes outside the requested scope, revert those changes and only apply edits within the specified area.',
        'Only edit within the following scope: [describe scope: function, class, lines, cursor, errors, etc.]. Do not touch any code, comments, or formatting outside this scope.',
        'Use the editing capabilities of the agent to make precise changes only within the defined scope.',
        'Do not ask questions and do not provide summary explanations. Just apply requested changes.',
      }

    local parts = context.format_message_stateless(
      prompt, --.. '\n' .. table.concat(instructions, '\n\n'),
      context_opts,
      context_instance
    )
    local params = { parts = parts, system = table.concat(instructions, '\n\n') }
    -- Add model/agent info from options, config, or current state
    local quick_chat_config = config.quick_chat or {}

    return core
      .initialize_current_model()
      :and_then(function(current_model)
        -- Priority: options.model > quick_chat_config.default_model > current_model
        local target_model = options.model or quick_chat_config.default_model or current_model
        if target_model then
          local provider, model = target_model:match('^(.-)/(.+)$')
          if provider and model then
            params.model = { providerID = provider, modelID = model }
          end
        end

        -- Priority: options.agent > quick_chat_config.default_agent > current mode > config.default_mode
        local target_mode = options.agent
          or quick_chat_config.default_agent
          or state.current_mode
          or config.default_mode
        if target_mode then
          params.agent = target_mode
        end

        -- Send the message
        return state.api_client:create_message(quick_chat_session.id, params)
      end)
      :and_then(function()
        on_done(quick_chat_session)

        local message_text = message and 'Quick chat started with custom message...'
          or 'Quick chat started - response will appear at cursor...'
        if range then
          message_text = string.format('Quick chat started for lines %d-%d...', range.start, range.stop)
        end
        vim.notify(message_text, vim.log.levels.INFO)
      end)
      :catch(function(err)
        cleanup_spinner(spinner_state)
        active_sessions[quick_chat_session.id] = nil
        vim.notify('Error in quick chat: ' .. vim.inspect(err), vim.log.levels.ERROR)
      end)
  end)
end

--- Setup function to initialize quick chat functionality
function M.setup()
  -- Set up autocommands for cleanup
  local augroup = vim.api.nvim_create_augroup('OpenCodeQuickChat', { clear = true })

  -- Clean up spinners when buffer is deleted
  vim.api.nvim_create_autocmd('BufDelete', {
    group = augroup,
    callback = function(ev)
      local buf = ev.buf
      for session_id, session_info in pairs(active_sessions) do
        if session_info.buf == buf then
          cleanup_spinner(session_info.spinner)
          active_sessions[session_id] = nil
        end
      end
    end,
  })

  -- Clean up old sessions (prevent memory leaks)
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = augroup,
    callback = function()
      for session_id, session_info in pairs(active_sessions) do
        cleanup_spinner(session_info.spinner)
      end
      active_sessions = {}
    end,
  })
end

return M
