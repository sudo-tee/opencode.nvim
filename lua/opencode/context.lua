-- Gathers editor context
-- This module acts as a facade for backward compatibility,
-- delegating to the extracted modules in context/

local util = require('opencode.util')
local config = require('opencode.config')
local state = require('opencode.state')
local Promise = require('opencode.promise')

-- Import extracted modules
local ContextInstance = require('opencode.context.base')
local json_formatter = require('opencode.context.json_formatter')
local plain_text_formatter = require('opencode.context.plain_text_formatter')

local M = {}

-- Global context instance
---@type ContextInstance
local global_context = ContextInstance:new()

-- Exposed API
---@type OpencodeContext
M.context = global_context.context

--- Creates a new independent context instance
---@param context_config? OpencodeContextConfig Optional context config to override global config
---@return ContextInstance
function M.new_instance(context_config)
  return ContextInstance:new(context_config)
end

function M.unload_attachments()
  global_context:unload_attachments()
end

function M.get_current_buf()
  return global_context:get_current_buf()
end

function M.load()
  global_context:load()
  state.context_updated_at = vim.uv.now()
end

function M.is_context_enabled(context_key)
  return global_context:is_context_enabled(context_key)
end

function M.get_diagnostics(buf)
  return global_context:get_diagnostics(buf)
end

function M.new_selection(file, content, lines)
  return global_context:new_selection(file, content, lines)
end

function M.add_selection(selection)
  global_context:add_selection(selection)
  state.context_updated_at = vim.uv.now()
end

function M.remove_selection(selection)
  global_context:remove_selection(selection)
  state.context_updated_at = vim.uv.now()
end

function M.clear_selections()
  global_context:clear_selections()
end

function M.add_file(file)
  global_context:add_file(file)
  state.context_updated_at = vim.uv.now()
end

function M.remove_file(file)
  global_context:remove_file(file)
  state.context_updated_at = vim.uv.now()
end

function M.clear_files()
  global_context:clear_files()
end

function M.add_subagent(subagent)
  global_context:add_subagent(subagent)
  state.context_updated_at = vim.uv.now()
end

function M.remove_subagent(subagent)
  global_context:remove_subagent(subagent)
  state.context_updated_at = vim.uv.now()
end

function M.clear_subagents()
  global_context:clear_subagents()
end

function M.delta_context(opts)
  local context = global_context:delta_context(opts)
  local last_context = state.last_sent_context
  if not last_context then
    return context
  end

  -- no need to send file context again
  if
    context.current_file
    and last_context.current_file
    and context.current_file.name == last_context.current_file.name
  then
    context.current_file = nil
  end

  -- no need to send subagents again
  if
    context.mentioned_subagents
    and last_context.mentioned_subagents
    and vim.deep_equal(context.mentioned_subagents, last_context.mentioned_subagents)
  then
    context.mentioned_subagents = nil
  end

  return context
end

function M.get_current_file(buf)
  return global_context:get_current_file(buf)
end

function M.get_current_cursor_data(buf, win)
  return global_context:get_current_cursor_data(buf, win)
end

function M.get_current_selection()
  return global_context:get_current_selection()
end

--- Formats context as plain text for LLM consumption
--- Outputs human-readable text instead of JSON message parts
--- Alias: format_message_quick_chat
---@param prompt string The user's instruction/prompt
---@param context_instance ContextInstance Context instance to use
---@param opts? { range?: { start: integer, stop: integer }, buf?: integer }
---@return table result { text: string, parts: OpencodeMessagePart[] }
M.format_message_plain_text = plain_text_formatter.format_message

--- Formats a prompt and context into message with parts for the opencode API
---@param prompt string
---@param opts? OpencodeContextConfig|nil
---@return OpencodeMessagePart[]
function M.format_message(prompt, opts)
  opts = opts or config.context
  local context = M.delta_context(opts)

  local parts = { { type = 'text', text = prompt } }

  for _, path in ipairs(context.mentioned_files or {}) do
    -- don't resend current file if it's also mentioned
    if not context.current_file or path ~= context.current_file.path then
      table.insert(parts, json_formatter.format_file_part(path, prompt))
    end
  end

  for _, sel in ipairs(context.selections or {}) do
    table.insert(parts, json_formatter.format_selection_part(sel))
  end

  for _, agent in ipairs(context.mentioned_subagents or {}) do
    table.insert(parts, json_formatter.format_subagents_part(agent, prompt))
  end

  if context.current_file then
    table.insert(parts, json_formatter.format_file_part(context.current_file.path))
  end

  if context.linter_errors and #context.linter_errors > 0 then
    table.insert(parts, json_formatter.format_diagnostics_part(context.linter_errors))
  end

  if context.cursor_data then
    table.insert(parts, json_formatter.format_cursor_data_part(context.cursor_data, M.get_current_buf))
  end

  return parts
end

--- Formats a prompt and context into plain text message for quick chat
--- Alias for format_message_plain_text - used for ephemeral sessions
---@param prompt string
---@param context_instance ContextInstance Context instance to use
---@param opts? { range?: { start: integer, stop: integer }, buf?: integer }
---@return table result { text: string, parts: OpencodeMessagePart[] }
M.format_message_quick_chat = plain_text_formatter.format_message

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
  state.subscribe({ 'current_code_buf', 'current_context_config', 'is_opencode_focused' }, function()
    M.load()
  end)

  local augroup = vim.api.nvim_create_augroup('OpenCodeContext', { clear = true })
  vim.api.nvim_create_autocmd('BufWritePost', {
    pattern = '*',
    group = augroup,
    callback = function(args)
      local buf = args.buf
      local curr_buf = state.current_code_buf or vim.api.nvim_get_current_buf()
      if buf == curr_buf and util.is_buf_a_file(buf) then
        M.load()
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
        M.load()
      end
    end,
  })
end

return M
