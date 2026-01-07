local util = require('opencode.util')
local config = require('opencode.config')
local state = require('opencode.state')
local Promise = require('opencode.promise')

local ChatContext = require('opencode.context.chat_context')
local QuickChatContext = require('opencode.context.quick_chat_context')
local BaseContext = require('opencode.context.base_context')

local M = {}

M.ChatContext = ChatContext
M.QuickChatContext = QuickChatContext

-- Provide access to the context state
function M.get_context()
  return ChatContext.context
end

--- Formats context for main chat interface (new simplified API)
---@param prompt string The user's instruction/prompt
---@param context_config? OpencodeContextConfig Optional context config
---@param opts? { range?: { start: integer, stop: integer } }
---@return table result { parts: OpencodeMessagePart[] }
M.format_chat_message = function(prompt, context_config, opts)
  opts = opts or {}
  opts.context_config = context_config
  return ChatContext.format_message(prompt, opts)
end

--- Formats context for quick chat interface (new simplified API)
---@param prompt string The user's instruction/prompt
---@param context_config? OpencodeContextConfig Optional context config
---@param opts? { range?: { start: integer, stop: integer } }
---@return table result { text: string, parts: OpencodeMessagePart[] }
M.format_quick_chat_message = function(prompt, context_config, opts)
  opts = opts or {}
  opts.context_config = context_config
  return QuickChatContext.format_message(prompt, opts)
end

function M.get_current_buf()
  return BaseContext.get_current_buf()
end

function M.is_context_enabled(context_key, context_config)
  return BaseContext.is_context_enabled(context_key, context_config)
end

function M.get_diagnostics(buf, context_config, range)
  return BaseContext.get_diagnostics(buf, context_config, range)
end

function M.get_current_file(buf, context_config)
  return BaseContext.get_current_file(buf, context_config)
end

function M.get_current_cursor_data(buf, win, context_config)
  return BaseContext.get_current_cursor_data(buf, win, context_config)
end

function M.get_current_selection(context_config)
  return BaseContext.get_current_selection(context_config)
end

function M.new_selection(file, content, lines)
  return BaseContext.new_selection(file, content, lines)
end

-- Delegate global state management to ChatContext
function M.add_selection(selection)
  ChatContext.add_selection(selection)
  state.context_updated_at = vim.uv.now()
end

function M.remove_selection(selection)
  ChatContext.remove_selection(selection)
  state.context_updated_at = vim.uv.now()
end

function M.clear_selections()
  ChatContext.clear_selections()
end

function M.add_file(file)
  local is_file = vim.fn.filereadable(file) == 1
  local is_dir = vim.fn.isdirectory(file) == 1
  if not is_file and not is_dir then
    vim.notify('File not added to context. Could not read.')
    return
  end

  if not util.is_path_in_cwd(file) and not util.is_temp_path(file, 'pasted_image') then
    vim.notify('File not added to context. Must be inside current working directory.')
    return
  end

  file = vim.fn.fnamemodify(file, ':p')
  ChatContext.add_file(file)
  state.context_updated_at = vim.uv.now()
end

function M.remove_file(file)
  file = vim.fn.fnamemodify(file, ':p')
  ChatContext.remove_file(file)
  state.context_updated_at = vim.uv.now()
end

function M.clear_files()
  ChatContext.clear_files()
end

function M.add_subagent(subagent)
  ChatContext.add_subagent(subagent)
  state.context_updated_at = vim.uv.now()
end

function M.remove_subagent(subagent)
  ChatContext.remove_subagent(subagent)
  state.context_updated_at = vim.uv.now()
end

function M.clear_subagents()
  ChatContext.clear_subagents()
end

function M.unload_attachments()
  ChatContext.clear_files()
  ChatContext.clear_selections()
end

function M.load()
  -- Delegate to ChatContext which manages the global state
  ChatContext.load()
  state.context_updated_at = vim.uv.now()
end

-- Context creation with delta logic (delegates to ChatContext)
function M.delta_context(opts)
  return ChatContext.delta_context(opts)
end

---@param prompt string
---@param opts? OpencodeContextConfig|nil
---@return OpencodeMessagePart[]
M.format_message = Promise.async(function(prompt, opts)
  local result = ChatContext.format_message(prompt, { context_config = opts }):await()
  return result.parts
end)

---@param text string
---@param context_type string|nil
function M.decode_json_context(text, context_type)
  local ok, result = pcall(vim.json.decode, text)
  if not ok or (context_type and result.context_type ~= context_type) then
    return nil
  end
  return result
end

--- Extracts context from an OpencodeMessage (with parts)
---@param message { parts: OpencodeMessagePart[] }
---@return { prompt: string|nil, selected_text: string|nil, current_file: string|nil, mentioned_files: string[]|nil}
function M.extract_from_opencode_message(message)
  local ctx = { prompt = nil, selected_text = nil, current_file = nil }

  local handlers = {
    text = function(part)
      ctx.prompt = ctx.prompt or part.text or ''
    end,
    text_context = function(part)
      local json = M.decode_json_context(part.text, 'selection')
      ctx.selected_text = json and json.content or ctx.selected_text
    end,
    file = function(part)
      if not part.source then
        ctx.current_file = part.filename
      end
    end,
  }

  for _, part in ipairs(message and message.parts or {}) do
    local handler = handlers[part.type .. (part.synthetic and '_context' or '')]
    if handler then
      handler(part)
    end

    if ctx.prompt and ctx.selected_text and ctx.current_file then
      break
    end
  end

  return ctx
end

function M.extract_from_message_legacy(text)
  local current_file = M.extract_legacy_tag('current-file', text)
  local context = {
    prompt = M.extract_legacy_tag('user-query', text) or text,
    selected_text = M.extract_legacy_tag('manually-added-selection', text),
    current_file = current_file and current_file:match('Path: (.+)') or nil,
  }
  return context
end

function M.extract_legacy_tag(tag, text)
  local start_tag = '<' .. tag .. '>'
  local end_tag = '</' .. tag .. '>'

  local pattern = vim.pesc(start_tag) .. '(.-)' .. vim.pesc(end_tag)
  local content = text:match(pattern)

  if content then
    return vim.trim(content)
  end

  -- Fallback to the original method if pattern matching fails
  local query_start = text:find(start_tag)
  local query_end = text:find(end_tag)

  if query_start and query_end then
    local query_content = text:sub(query_start + #start_tag, query_end - 1)
    return vim.trim(query_content)
  end

  return nil
end

function M.setup()
  local debounced_load = util.debounce(function()
    M.load()
  end, 200)

  state.subscribe({ 'current_code_buf', 'current_context_config', 'is_opencode_focused' }, function()
    debounced_load()
  end)

  local augroup = vim.api.nvim_create_augroup('OpenCodeContext', { clear = true })
  vim.api.nvim_create_autocmd('BufWritePost', {
    pattern = '*',
    group = augroup,
    callback = function(args)
      local buf = args.buf
      local curr_buf = state.current_code_buf or vim.api.nvim_get_current_buf()
      if buf == curr_buf and util.is_buf_a_file(buf) then
        debounced_load()
      end
    end,
  })

  vim.api.nvim_create_autocmd('DiagnosticChanged', {
    pattern = '*',
    group = augroup,
    callback = function(args)
      local buf = args.buf
      local curr_buf = state.current_code_buf or vim.api.nvim_get_current_buf()
      if buf == curr_buf and util.is_buf_a_file(buf) and M.is_context_enabled('diagnostics') then
        debounced_load()
      end
    end,
  })
end

return M
