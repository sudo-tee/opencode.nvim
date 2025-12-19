local base_context = require('opencode.context.base_context')
local util = require('opencode.util')
local state = require('opencode.state')
local Promise = require('opencode.promise')

local M = {}

M.context = {
  mentioned_files = {},
  selections = {},
  mentioned_subagents = {},
  current_file = nil,
  cursor_data = nil,
  linter_errors = nil,
}

---@param path string
---@param prompt? string
---@return OpencodeMessagePart
local function format_file_part(path, prompt)
  local rel_path = vim.fn.fnamemodify(path, ':~:.')
  local mention = '@' .. rel_path
  local pos = prompt and prompt:find(mention)
  pos = pos and pos - 1 or 0 -- convert to 0-based index

  local ext = vim.fn.fnamemodify(path, ':e'):lower()
  local mime_type = 'text/plain'
  if ext == 'png' then
    mime_type = 'image/png'
  elseif ext == 'jpg' or ext == 'jpeg' then
    mime_type = 'image/jpeg'
  elseif ext == 'gif' then
    mime_type = 'image/gif'
  elseif ext == 'webp' then
    mime_type = 'image/webp'
  end

  local file_part = { filename = rel_path, type = 'file', mime = mime_type, url = 'file://' .. path }
  if prompt then
    file_part.source = {
      path = path,
      type = 'file',
      text = { start = pos, value = mention, ['end'] = pos + #mention },
    }
  end
  return file_part
end

---@param selection OpencodeContextSelection
---@return OpencodeMessagePart
local function format_selection_part(selection)
  local lang = util.get_markdown_filetype(selection.file and selection.file.name or '') or ''

  return {
    type = 'text',
    metadata = {
      context_type = 'selection',
    },
    text = vim.json.encode({
      context_type = 'selection',
      file = selection.file,
      content = string.format('`````%s\n%s\n`````', lang, selection.content),
      lines = selection.lines,
    }),
    synthetic = true,
  }
end

---@param diagnostics OpencodeDiagnostic[]
---@param range? { start_line: integer, end_line: integer }|nil
---@return OpencodeMessagePart
local function format_diagnostics_part(diagnostics, range)
  local diag_list = {}
  for _, diag in ipairs(diagnostics) do
    if not range or (diag.lnum >= range.start_line and diag.lnum <= range.end_line) then
      local short_msg = diag.message:gsub('%s+', ' '):gsub('^%s', ''):gsub('%s$', '')
      table.insert(
        diag_list,
        { msg = short_msg, severity = diag.severity, pos = 'l' .. diag.lnum + 1 .. ':c' .. diag.col + 1 }
      )
    end
  end
  return {
    type = 'text',
    metadata = {
      context_type = 'diagnostics',
    },
    text = vim.json.encode({ context_type = 'diagnostics', content = diag_list }),
    synthetic = true,
  }
end

---@param cursor_data table
---@param get_current_buf fun(): integer|nil Function to get current buffer
---@return OpencodeMessagePart
local function format_cursor_data_part(cursor_data, get_current_buf)
  local buf = (get_current_buf() or 0) --[[@as integer]]
  local lang = util.get_markdown_filetype(vim.api.nvim_buf_get_name(buf)) or ''
  return {
    type = 'text',
    metadata = {
      context_type = 'cursor-data',
      lang = lang,
    },
    text = vim.json.encode({
      context_type = 'cursor-data',
      line = cursor_data.line,
      column = cursor_data.column,
      line_content = string.format('`````%s\n%s\n`````', lang, cursor_data.line_content),
      lines_before = cursor_data.lines_before,
      lines_after = cursor_data.lines_after,
    }),
    synthetic = true,
  }
end

---@param agent string
---@param prompt string
---@return OpencodeMessagePart
local function format_subagents_part(agent, prompt)
  local mention = '@' .. agent
  local pos = prompt:find(mention)
  pos = pos and pos - 1 or 0 -- convert to 0-based index

  return {
    type = 'agent',
    name = agent,
    source = { value = mention, start = pos, ['end'] = pos + #mention },
  }
end

---@param buf integer
---@return OpencodeMessagePart
local function format_buffer_part(buf)
  local file = vim.api.nvim_buf_get_name(buf)
  local rel_path = vim.fn.fnamemodify(file, ':~:.')
  return {
    type = 'text',
    text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'),
    metadata = {
      context_type = 'file-content',
      filename = rel_path,
      mime = 'text/plain',
    },
    synthetic = true,
  }
end

---@param diff_text string
---@return OpencodeMessagePart
local function format_git_diff_part(diff_text)
  return {
    type = 'text',
    metadata = {
      context_type = 'git-diff',
    },
    text = diff_text,
    synthetic = true,
  }
end

-- Global context management functions

function M.add_selection(selection)
  -- Ensure selections is always a table
  if not M.context.selections then
    M.context.selections = {}
  end

  table.insert(M.context.selections, selection)
  state.context_updated_at = vim.uv.now()
end

function M.remove_selection(selection)
  if not M.context.selections then
    M.context.selections = {}
    return
  end

  for i, sel in ipairs(M.context.selections) do
    if sel.file.path == selection.file.path and sel.lines == selection.lines then
      table.remove(M.context.selections, i)
      break
    end
  end
  state.context_updated_at = vim.uv.now()
end

function M.clear_selections()
  M.context.selections = {}
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

  if not M.context.mentioned_files then
    M.context.mentioned_files = {}
  end

  if not vim.tbl_contains(M.context.mentioned_files, file) then
    table.insert(M.context.mentioned_files, file)
  end
  state.context_updated_at = vim.uv.now()
end

function M.remove_file(file)
  if not M.context.mentioned_files then
    M.context.mentioned_files = {}
    return
  end

  file = vim.fn.fnamemodify(file, ':p')
  for i, f in ipairs(M.context.mentioned_files) do
    if f == file then
      table.remove(M.context.mentioned_files, i)
      break
    end
  end
  state.context_updated_at = vim.uv.now()
end

function M.clear_files()
  M.context.mentioned_files = {}
end

function M.add_subagent(subagent)
  -- Ensure mentioned_subagents is always a table
  if not M.context.mentioned_subagents then
    M.context.mentioned_subagents = {}
  end

  if not vim.tbl_contains(M.context.mentioned_subagents, subagent) then
    table.insert(M.context.mentioned_subagents, subagent)
  end
  state.context_updated_at = vim.uv.now()
end

function M.remove_subagent(subagent)
  if not M.context.mentioned_subagents then
    M.context.mentioned_subagents = {}
    return
  end

  for i, a in ipairs(M.context.mentioned_subagents) do
    if a == subagent then
      table.remove(M.context.mentioned_subagents, i)
      break
    end
  end
  state.context_updated_at = vim.uv.now()
end

function M.clear_subagents()
  M.context.mentioned_subagents = {}
end

function M.unload_attachments()
  M.context.mentioned_files = {}
  M.context.selections = {}
end

function M.get_mentioned_files()
  return M.context.mentioned_files or {}
end

function M.get_selections()
  return M.context.selections or {}
end

function M.get_mentioned_subagents()
  return M.context.mentioned_subagents or {}
end

-- Load function that populates the global context state
-- This is the core loading logic that was originally in the main context module
function M.load()
  local buf, win = base_context.get_current_buf()

  if buf then
    local current_file = base_context.get_current_file(buf)
    local cursor_data = base_context.get_current_cursor_data(buf, win)

    M.context.current_file = current_file
    M.context.cursor_data = cursor_data
    M.context.linter_errors = base_context.get_diagnostics(buf, nil, nil)
  end

  local current_selection = base_context.get_current_selection()
  if current_selection and M.context.current_file then
    local selection =
      base_context.new_selection(M.context.current_file, current_selection.text, current_selection.lines)
    M.add_selection(selection)
  end
end

-- This function creates a context snapshot with delta logic against the last sent context
function M.delta_context(opts)
  local config = require('opencode.config')
  local state = require('opencode.state')

  opts = opts or config.context
  if opts.enabled == false then
    return {
      current_file = nil,
      mentioned_files = nil,
      selections = nil,
      linter_errors = nil,
      cursor_data = nil,
      mentioned_subagents = nil,
    }
  end

  local buf, win = base_context.get_current_buf()
  if not buf or not win then
    return {}
  end

  local ctx = {
    current_file = base_context.get_current_file(buf, opts),
    cursor_data = base_context.get_current_cursor_data(buf, win, opts),
    mentioned_files = M.context.mentioned_files or {},
    selections = M.context.selections or {},
    linter_errors = base_context.get_diagnostics(buf, opts, nil),
    mentioned_subagents = M.context.mentioned_subagents or {},
  }

  -- Delta logic against last sent context
  local last_context = state.last_sent_context
  if last_context then
    -- no need to send file context again
    if ctx.current_file and last_context.current_file and ctx.current_file.name == last_context.current_file.name then
      ctx.current_file = nil
    end

    -- no need to send subagents again
    if
      ctx.mentioned_subagents
      and last_context.mentioned_subagents
      and vim.deep_equal(ctx.mentioned_subagents, last_context.mentioned_subagents)
    then
      ctx.mentioned_subagents = nil
    end
  end

  return ctx
end

--- Formats context as structured message parts for the main chat interface
--- This is the main function that includes global state (mentioned files, selections, etc.)
---@param prompt string The user's instruction/prompt
---@param opts? { range?: { start: integer, stop: integer }, context_config?: OpencodeContextConfig }
---@return table result { parts: OpencodeMessagePart[] }
M.format_message = Promise.async(function(prompt, opts)
  opts = opts or {}
  local context_config = opts.context_config
  local buf, win = base_context.get_current_buf()
  local range = opts.range
  local parts = {}

  -- Add mentioned files from global state (always process, even without buffer)
  for _, file_path in ipairs(M.context.mentioned_files or {}) do
    table.insert(parts, format_file_part(file_path, prompt))
  end

  -- Add mentioned subagents from global state (always process, even without buffer)
  for _, agent in ipairs(M.context.mentioned_subagents or {}) do
    table.insert(parts, format_subagents_part(agent, prompt))
  end

  if not buf or not win then
    -- Add the main prompt
    table.insert(parts, { type = 'text', text = prompt })
    return { parts = parts }
  end

  -- Add selections (both from range and global state)
  if base_context.is_context_enabled('selection', context_config) then
    local selections = {}

    -- Add range selection if specified
    if range and range.start and range.stop then
      local file = base_context.get_current_file(buf, context_config)
      if file then
        local selection = base_context.new_selection(
          file,
          table.concat(vim.api.nvim_buf_get_lines(buf, range.start - 1, range.stop, false), '\n'),
          string.format('%d-%d', range.start, range.stop)
        )
        table.insert(selections, selection)
      end
    end

    -- Add current visual selection if available
    local current_selection = base_context.get_current_selection(context_config)
    if current_selection then
      local file = base_context.get_current_file(buf, context_config)
      if file then
        local selection = base_context.new_selection(file, current_selection.text, current_selection.lines)
        table.insert(selections, selection)
      end
    end

    -- Add selections from global state
    for _, sel in ipairs(M.context.selections or {}) do
      table.insert(selections, sel)
    end

    for _, sel in ipairs(selections) do
      table.insert(parts, format_selection_part(sel))
    end
  end

  -- Add current file if enabled and not already mentioned
  local current_file = base_context.get_current_file(buf, context_config)
  if current_file and not vim.tbl_contains(M.context.mentioned_files or {}, current_file.path) then
    table.insert(parts, format_file_part(current_file.path))
  end

  -- Add buffer content if enabled
  if base_context.is_context_enabled('buffer', context_config) then
    table.insert(parts, format_buffer_part(buf))
  end

  -- Add diagnostics
  local diag_range = nil
  if range then
    diag_range = { start_line = range.start - 1, end_line = range.stop - 1 }
  end
  local diagnostics = base_context.get_diagnostics(buf, context_config, diag_range)
  if diagnostics and #diagnostics > 0 then
    table.insert(parts, format_diagnostics_part(diagnostics, nil)) -- No need to filter again
  end

  -- Add cursor data
  if base_context.is_context_enabled('cursor_data', context_config) then
    local cursor_data = base_context.get_current_cursor_data(buf, win, context_config)
    if cursor_data then
      table.insert(
        parts,
        format_cursor_data_part(cursor_data, function()
          return buf
        end)
      )
    end
  end

  -- Add git diff
  if base_context.is_context_enabled('git_diff', context_config) then
    local diff_text = base_context.get_git_diff(context_config):await()
    if diff_text and diff_text ~= '' then
      table.insert(parts, format_git_diff_part(diff_text))
    end
  end

  -- Add the main prompt
  table.insert(parts, { type = 'text', text = prompt })

  return { parts = parts }
end)

return M
