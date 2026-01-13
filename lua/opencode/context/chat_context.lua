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

-- Chat-context-aware get_diagnostics that considers stored selections
---@param buf integer
---@param context_config? OpencodeContextConfig
---@param range? { start_line: integer, end_line: integer }
---@return OpencodeDiagnostic[]|nil
function M.get_diagnostics(buf, context_config, range)
  -- Use explicit range if provided
  if range then
    return base_context.get_diagnostics(buf, context_config, range)
  end

  if M.context.selections and #M.context.selections > 0 then
    local selection_ranges = {}

    for _, sel in ipairs(M.context.selections) do
      if sel.lines then
        -- Handle both formats: "1, 5" and "1-5"
        local start_line, end_line = sel.lines:match('(%d+)[,%-]%s*(%d+)')
        if not start_line then
          -- Single line case like "5, 5" or just "5"
          start_line = sel.lines:match('(%d+)')
          end_line = start_line
        end

        if start_line then
          local start_num = tonumber(start_line)
          local end_num = tonumber(end_line)

          if start_num and end_num then
            -- Convert to 0-based
            local selection_range = {
              start_line = start_num - 1,
              end_line = end_num - 1,
            }
            table.insert(selection_ranges, selection_range)
          end
        end
      end
    end

    if #selection_ranges > 0 then
      return base_context.get_diagnostics(buf, context_config, selection_ranges)
    end
  end

  return base_context.get_diagnostics(buf, context_config, nil)
end

---@param current_file table|nil
---@return boolean, boolean -- should_update, is_different_file
function M.should_update_current_file(current_file)
  if not M.context.current_file then
    return current_file ~= nil, false
  end

  if not current_file then
    return false, false
  end

  -- Different file name means update needed
  if M.context.current_file.name ~= current_file.name then
    return true, true
  end

  -- Same file, check modification time
  local file_path = current_file.path
  if not file_path or vim.fn.filereadable(file_path) ~= 1 then
    return false, false
  end

  local stat = vim.uv.fs_stat(file_path)
  if not (stat and stat.mtime and stat.mtime.sec) then
    return false, false
  end

  local file_mtime_sec = stat.mtime.sec --[[@as number]]
  local last_sent_mtime = M.context.current_file.sent_at_mtime or 0
  return file_mtime_sec > last_sent_mtime, false
end

-- Load function that populates the global context state
-- This is the core loading logic that was originally in the main context module
function M.load()
  if not state.active_session and not state.is_opening then
    return
  end

  local buf, win = base_context.get_current_buf()

  if not buf or not win then
    return
  end

  local current_file = base_context.get_current_file(buf)
  local cursor_data = base_context.get_current_cursor_data(buf, win)

  local should_update_file, is_different_file = M.should_update_current_file(current_file)

  if should_update_file then
    if is_different_file then
      M.context.selections = {}
    end

    M.context.current_file = current_file
    if M.context.current_file then
      M.context.current_file.sent_at = nil
      M.context.current_file.sent_at_mtime = nil
    end
  end

  M.context.cursor_data = cursor_data
  M.context.linter_errors = M.get_diagnostics(buf, nil, nil)

  -- Handle current selection
  local current_selection = base_context.get_current_selection()
  if current_selection and M.context.current_file then
    local selection =
      base_context.new_selection(M.context.current_file, current_selection.text, current_selection.lines)
    M.add_selection(selection)
  end
end

---@param current_file table
local function set_file_sent_timestamps(current_file)
  if not current_file then
    return
  end
  current_file.sent_at = vim.uv.now()
  local stat = vim.uv.fs_stat(current_file.path)
  if stat and stat.mtime and stat.mtime.sec then
    current_file.sent_at_mtime = stat.mtime.sec
  end
end

-- This function creates a context snapshot with delta logic against the last sent context
function M.delta_context(opts)
  local config = require('opencode.config')

  opts = opts or state.current_context_config or config.context
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
  if not buf then
    return {}
  end

  local ctx = vim.deepcopy(M.context)

  if ctx.current_file and M.context.current_file then
    set_file_sent_timestamps(M.context.current_file)
    set_file_sent_timestamps(ctx.current_file)
  end

  -- no need to send subagents again
  local last_context = state.last_sent_context
  if last_context then
    if
      ctx.mentioned_subagents
      and last_context.mentioned_subagents
      and vim.deep_equal(ctx.mentioned_subagents, last_context.mentioned_subagents)
    then
      ctx.mentioned_subagents = nil
      M.context.mentioned_subagents = nil
    end
  end

  state.context_updated_at = vim.uv.now()
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

  for _, file_path in ipairs(M.context.mentioned_files or {}) do
    table.insert(parts, format_file_part(file_path, prompt))
  end

  for _, agent in ipairs(M.context.mentioned_subagents or {}) do
    table.insert(parts, format_subagents_part(agent, prompt))
  end

  if not buf then
    table.insert(parts, { type = 'text', text = prompt })
    return { parts = parts }
  end

  if M.context.current_file and not M.context.current_file.sent_at then
    table.insert(parts, format_file_part(M.context.current_file.path))
    set_file_sent_timestamps(M.context.current_file)
  end

  if base_context.is_context_enabled('selection', context_config) then
    local selections = {}

    if range and range.start and range.stop then
      local file = base_context.get_current_file(buf, context_config)
      if file then
        local selection = base_context.new_selection(
          file,
          table.concat(
            vim.api.nvim_buf_get_lines(buf, math.floor(range.start) - 1, math.floor(range.stop), false),
            '\n'
          ),
          string.format('%d-%d', math.floor(range.start), math.floor(range.stop))
        )
        table.insert(selections, selection)
      end
    end

    local current_selection = base_context.get_current_selection(context_config)
    if current_selection then
      local file = base_context.get_current_file(buf, context_config)
      if file then
        local selection = base_context.new_selection(file, current_selection.text, current_selection.lines)
        table.insert(selections, selection)
      end
    end

    for _, sel in ipairs(M.context.selections or {}) do
      table.insert(selections, sel)
    end

    for _, sel in ipairs(selections) do
      table.insert(parts, format_selection_part(sel))
    end
  end

  if base_context.is_context_enabled('buffer', context_config) then
    table.insert(parts, format_buffer_part(buf))
  end

  local diag_range = nil
  if range then
    diag_range = { start_line = math.floor(range.start) - 1, end_line = math.floor(range.stop) - 1 }
  end
  local diagnostics = M.get_diagnostics(buf, context_config, diag_range)
  if diagnostics and #diagnostics > 0 then
    table.insert(parts, format_diagnostics_part(diagnostics, diag_range))
  end

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

  if base_context.is_context_enabled('git_diff', context_config) then
    local diff_text = base_context.get_git_diff(context_config):await()
    if diff_text and diff_text ~= '' then
      table.insert(parts, format_git_diff_part(diff_text))
    end
  end

  table.insert(parts, { type = 'text', text = prompt })

  return { parts = parts }
end)

return M
