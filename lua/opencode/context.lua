-- Gathers editor context

local util = require('opencode.util')
local config = require('opencode.config')
local state = require('opencode.state')

local M = {}

---@type OpencodeContext
M.context = {
  -- current file
  current_file = nil,
  cursor_data = nil,

  -- attachments
  mentioned_files = nil,
  selections = {},
  linter_errors = {},
  mentioned_subagents = {},
}

function M.unload_attachments()
  M.context.mentioned_files = nil
  M.context.selections = nil
  M.context.linter_errors = nil
end

function M.get_current_buf()
  local curr_buf = state.current_code_buf or vim.api.nvim_get_current_buf()
  if util.is_buf_a_file(curr_buf) then
    return curr_buf, state.last_code_win_before_opencode or vim.api.nvim_get_current_win()
  end
end

function M.load()
  local buf, win = M.get_current_buf()

  if buf then
    local current_file = M.get_current_file(buf)
    local cursor_data = M.get_current_cursor_data(buf, win)

    M.context.current_file = current_file
    M.context.cursor_data = cursor_data
    M.context.linter_errors = M.get_diagnostics(buf)
  end

  local current_selection = M.get_current_selection()
  if current_selection then
    local selection = M.new_selection(M.context.current_file, current_selection.text, current_selection.lines)
    M.add_selection(selection)
  end
  state.context_updated_at = vim.uv.now()
end

-- Checks if a context feature is enabled in config or state
---@param context_key string
---@return boolean
function M.is_context_enabled(context_key)
  local is_enabled = vim.tbl_get(config, 'context', context_key, 'enabled')
  local is_state_enabled = vim.tbl_get(state, 'current_context_config', context_key, 'enabled')

  if is_state_enabled ~= nil then
    return is_state_enabled
  else
    return is_enabled
  end
end

function M.get_diagnostics(buf)
  if not M.is_context_enabled('diagnostics') then
    return nil
  end

  local diagnostic_conf = config.context and state.current_context_config.diagnostics or config.context.diagnostics

  local severity_levels = {}
  if diagnostic_conf.error then
    table.insert(severity_levels, vim.diagnostic.severity.ERROR)
  end
  if diagnostic_conf.warning then
    table.insert(severity_levels, vim.diagnostic.severity.WARN)
  end
  if diagnostic_conf.info then
    table.insert(severity_levels, vim.diagnostic.severity.INFO)
  end

  local diagnostics = vim.diagnostic.get(buf, { severity = severity_levels })
  if #diagnostics == 0 then
    return {}
  end

  return diagnostics
end

function M.new_selection(file, content, lines)
  return {
    file = file,
    content = util.indent_code_block(content),
    lines = lines,
  }
end

function M.add_selection(selection)
  if not M.context.selections then
    M.context.selections = {}
  end

  table.insert(M.context.selections, selection)

  state.context_updated_at = vim.uv.now()
end

function M.add_file(file)
  --- TODO: probably need a way to remove a file once it's been added?
  --- maybe a keymap like clear all context?

  if not M.context.mentioned_files then
    M.context.mentioned_files = {}
  end

  local is_file = vim.fn.filereadable(file) == 1
  local is_dir = vim.fn.isdirectory(file) == 1
  if not is_file and not is_dir then
    vim.notify('File not added to context. Could not read.')
    return
  end

  file = vim.fn.fnamemodify(file, ':p')

  if not vim.tbl_contains(M.context.mentioned_files, file) then
    table.insert(M.context.mentioned_files, file)
  end
end

function M.remove_file(file)
  file = vim.fn.fnamemodify(file, ':p')
  if not M.context.mentioned_files then
    return
  end

  for i, f in ipairs(M.context.mentioned_files) do
    if f == file then
      table.remove(M.context.mentioned_files, i)
      break
    end
  end
  state.context_updated_at = vim.uv.now()
end

function M.clear_files()
  M.context.mentioned_files = nil
end

function M.add_subagent(subagent)
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
  M.context.mentioned_subagents = nil
end

---@param opts? OpencodeContextConfig
---@return OpencodeContext
function M.delta_context(opts)
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

  local context = vim.deepcopy(M.context)
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
  if not M.is_context_enabled('current_file') then
    return nil
  end
  local file = vim.api.nvim_buf_get_name(buf)
  if not file or file == '' or vim.fn.filereadable(file) ~= 1 then
    return nil
  end
  return {
    path = file,
    name = vim.fn.fnamemodify(file, ':t'),
    extension = vim.fn.fnamemodify(file, ':e'),
  }
end

function M.get_current_cursor_data(buf, win)
  if not M.is_context_enabled('cursor_data') then
    return nil
  end

  local cursor_pos = vim.fn.getcurpos(win)
  local cursor_content = vim.trim(vim.api.nvim_buf_get_lines(buf, cursor_pos[2] - 1, cursor_pos[2], false)[1] or '')
  return { line = cursor_pos[2], col = cursor_pos[3], line_content = cursor_content }
end

function M.get_current_selection()
  if not M.is_context_enabled('selection') then
    return nil
  end

  -- Return nil if not in a visual mode
  if not vim.fn.mode():match('[vV\022]') then
    return nil
  end

  -- Save current position and register state
  local current_pos = vim.fn.getpos('.')
  local old_reg = vim.fn.getreg('x')
  local old_regtype = vim.fn.getregtype('x')

  -- Capture selection text and position
  vim.cmd('normal! "xy')
  local text = vim.fn.getreg('x')

  -- Get line numbers
  vim.cmd('normal! `<')
  local start_line = vim.fn.line('.')
  vim.cmd('normal! `>')
  local end_line = vim.fn.line('.')

  -- Restore state
  vim.fn.setreg('x', old_reg, old_regtype)
  vim.cmd('normal! gv')
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', true)
  vim.fn.setpos('.', current_pos)

  return {
    text = text and text:match('[^%s]') and text or nil,
    lines = start_line .. ', ' .. end_line,
  }
end

local function format_file_part(path, prompt)
  local rel_path = vim.fn.fnamemodify(path, ':~:.')
  local mention = '@' .. rel_path
  local pos = prompt and prompt:find(mention)
  pos = pos and pos - 1 or 0 -- convert to 0-based index

  local file_part = { filename = rel_path, type = 'file', mime = 'text/plain', url = 'file://' .. path }
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
local function format_selection_part(selection)
  local lang = util.get_markdown_filetype(selection.file and selection.file.name or '') or ''

  return {
    type = 'text',
    text = vim.json.encode({
      context_type = 'selection',
      file = selection.file,
      content = string.format('`````%s\n%s\n`````', lang, selection.content),
      lines = selection.lines,
    }),
    synthetic = true,
  }
end

local function format_diagnostics_part(diagnostics)
  return {
    type = 'text',
    text = vim.json.encode({ context_type = 'diagnostics', content = diagnostics }),
    synthetic = true,
  }
end

local function format_cursor_data_part(cursor_data)
  return {
    type = 'text',
    text = vim.json.encode({ context_type = 'cursor-data', line = cursor_data.line, column = cursor_data.column }),
    synthetic = true,
  }
end

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

--- Formats a prompt and context into message with parts for the opencode API
---@param prompt string
---@param opts? OpencodeContextConfig|nil
---@return OpencodeMessagePart[]
function M.format_message(prompt, opts)
  opts = opts or config.context
  local context = M.delta_context(opts)
  context.prompt = prompt

  local parts = { { type = 'text', text = prompt } }

  for _, path in ipairs(context.mentioned_files or {}) do
    -- don't resend current file if it's also mentioned
    if not context.current_file or path ~= context.current_file.path then
      table.insert(parts, format_file_part(path, prompt))
    end
  end

  for _, sel in ipairs(context.selections or {}) do
    table.insert(parts, format_selection_part(sel))
  end

  for _, agent in ipairs(context.mentioned_subagents or {}) do
    table.insert(parts, format_subagents_part(agent, prompt))
  end

  if context.current_file then
    table.insert(parts, format_file_part(context.current_file.path))
  end

  if context.linter_errors then
    table.insert(parts, format_diagnostics_part(context.linter_errors))
  end

  if context.cursor_data then
    table.insert(parts, format_cursor_data_part(context.cursor_data))
  end

  return parts
end

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
---@return { prompt: string, selected_text: string|nil, current_file: string|nil, mentioned_files: string[]|nil}
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
  state.subscribe({ 'current_code_buf', 'current_context_config', 'is_opencode_focused' }, function(a)
    M.load()
  end)

  vim.api.nvim_create_autocmd('BufWritePost', {
    pattern = '*',
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
