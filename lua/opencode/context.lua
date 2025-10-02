-- Gathers editor context

local util = require('opencode.util')
local config = require('opencode.config').get()
local state = require('opencode.state')

local M = {}

M.context = {
  -- current file
  current_file = nil,
  cursor_data = nil,

  -- attachments
  mentioned_files = nil,
  mentioned_files_content = nil,
  selections = nil,
  linter_errors = nil,
  mentioned_subagents = nil,
}

function M.unload_attachments()
  M.context.mentioned_files = nil
  M.context.mentioned_files_content = nil
  M.context.selections = nil
  M.context.linter_errors = nil
end

function M.load()
  if util.is_current_buf_a_file() then
    local current_file = M.get_current_file()
    local cursor_data = M.get_current_cursor_data()

    M.context.current_file = current_file
    M.context.cursor_data = cursor_data
    M.context.linter_errors = M.check_linter_errors()
  end

  local current_selection = M.get_current_selection()
  if current_selection then
    local selection = M.new_selection(M.context.current_file, current_selection.text, current_selection.lines)
    M.add_selection(selection)
  end
end

function M.check_linter_errors()
  local diagnostic_conf = config.context and config.context.diagnostics
  if not diagnostic_conf then
    return nil
  end
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

  local diagnostics = vim.diagnostic.get(0, { severity = severity_levels })
  if #diagnostics == 0 then
    return nil
  end

  local lines = { 'Found ' .. #diagnostics .. ' error' .. (#diagnostics > 1 and 's' or '') .. ':' }

  for _, diagnostic in ipairs(diagnostics) do
    local line_number = diagnostic.lnum + 1
    local short_message = diagnostic.message:gsub('%s+', ' '):gsub('^%s', ''):gsub('%s$', '')
    table.insert(lines, string.format(' Line %d: %s', line_number, short_message))
  end

  return table.concat(lines, '\n')
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
end

function M.add_file(file)
  if not M.context.mentioned_files then
    M.context.mentioned_files = {}
  end

  if vim.fn.filereadable(file) ~= 1 then
    vim.notify('File not added to context. Could not read.')
    return
  end

  file = vim.fn.fnamemodify(file, ':p')

  if not vim.tbl_contains(M.context.mentioned_files, file) then
    table.insert(M.context.mentioned_files, file)
  end
end

function M.add_subagent(subagent)
  if not M.context.mentioned_subagents then
    M.context.mentioned_subagents = {}
  end

  if not vim.tbl_contains(M.context.mentioned_subagents, subagent) then
    table.insert(M.context.mentioned_subagents, subagent)
  end
end

---@param opts OpencodeContextConfig
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

function M.get_current_file()
  if
    not (
      config.context
      and config.context.enabled
      and config.context.current_file
      and config.context.current_file.enabled
    )
  then
    return nil
  end
  local file = vim.fn.expand('%:p')
  if not file or file == '' or vim.fn.filereadable(file) ~= 1 then
    return nil
  end
  return {
    path = file,
    name = vim.fn.fnamemodify(file, ':t'),
    extension = vim.fn.fnamemodify(file, ':e'),
  }
end

function M.get_current_cursor_data()
  if
    not (
      config.context
      and config.context.enabled
      and config.context.cursor_data
      and config.context.cursor_data.enabled
    )
  then
    return nil
  end

  local cursor_pos = vim.fn.getcurpos()
  local cursor_content = vim.trim(vim.api.nvim_get_current_line())
  return { line = cursor_pos[2], col = cursor_pos[3], line_content = cursor_content }
end

function M.get_current_selection()
  if
    not (config.context and config.context.enabled and config.context.selection and config.context.selection.enabled)
  then
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
      text = { start = pos, value = mention, ['end'] = pos + #mention - 1 },
    }
  end
  return file_part
end

---@param selection OpencodeContextSelection
local function format_selection_part(selection)
  local lang = selection.file and selection.file.extension or ''

  return {
    type = 'text',
    text = vim.json.encode({
      context_type = 'selection',
      file = selection.file,
      content = string.format('```%s\n%s\n```', lang, selection.content),
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

  -- recent_buffers synthetic context
  if config.context and config.context.recent_buffers and config.context.recent_buffers.enabled then
    local ok, recent = pcall(M.get_recent_buffers, prompt, config.context.recent_buffers)
    if ok and recent and #recent > 0 then
      for _, rb in ipairs(recent) do
        table.insert(parts, rb)
      end
    end
  end

  for _, path in ipairs(context.mentioned_files or {}) do
    table.insert(parts, format_file_part(path, prompt))
  end

  for _, agent in ipairs(context.mentioned_subagents or {}) do
    table.insert(parts, format_subagents_part(agent, prompt))
  end

  if context.current_file then
    table.insert(parts, format_file_part(context.current_file.path))
  end

  for _, sel in ipairs(context.selections or {}) do
    table.insert(parts, format_selection_part(sel))
  end

  if context.linter_errors then
    table.insert(parts, format_diagnostics_part(context.linter_errors))
  end

  if context.cursor_data then
    table.insert(parts, format_cursor_data_part(context.cursor_data))
  end

  return parts
end

---@param part OpencodeMessagePart
---@param context_type string|nil
local function decode_json_context(part, context_type)
  local ok, result = pcall(vim.json.decode, part.text)
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
      local json = decode_json_context(part, 'selection')
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

  -- Use pattern matching to find the content between the tags
  -- Make search start_tag and end_tag more robust with pattern escaping
  local pattern = vim.pesc(start_tag) .. '(.-)' .. vim.pesc(end_tag)
  local content = text:match(pattern)

  if content then
    return vim.trim(content)
  end

  -- Fallback to the original method if pattern matching fails
  local query_start = text:find(start_tag)
  local query_end = text:find(end_tag)

  if query_start and query_end then
    -- Extract and trim the content between the tags
    local query_content = text:sub(query_start + #start_tag, query_end - 1)
    return vim.trim(query_content)
  end

  return nil
end

---@param buf number
---@return boolean
local function is_valid_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if vim.bo[buf].buftype ~= '' then
    return false
  end
  if not vim.bo[buf].modifiable then
    return false
  end
  return true
end

---@param client table
local function client_supports_symbols(client)
  if not client or not client.server_capabilities then
    return false
  end
  local caps = client.server_capabilities
  return caps.documentSymbolProvider == true or (type(caps.documentSymbolProvider) == 'table')
end

---@param bufnr number
---@return table[]|nil
local function fetch_document_symbols(bufnr)
  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local results = {}
  local clients = vim.lsp.get_active_clients({ bufnr = bufnr })
  local any = false
  for _, client in ipairs(clients) do
    if client_supports_symbols(client) then
      any = true
      local ok, resp = pcall(function()
        return client.request_sync('textDocument/documentSymbol', params, 500, bufnr)
      end)
      if ok and resp and resp.result then
        if vim.tbl_islist(resp.result) then
          vim.list_extend(results, resp.result)
        else
          table.insert(results, resp.result)
        end
      end
    end
  end
  if not any or #results == 0 then
    return nil
  end
  return results
end

local function flatten_symbols(symbols, acc, parent)
  acc = acc or {}
  if not symbols then
    return acc
  end
  for _, s in ipairs(symbols) do
    local name = s.name or '<anonymous>'
    local kind = s.kind or 0
    table.insert(acc, { name = name, kind = kind, parent = parent })
    if s.children then
      flatten_symbols(s.children, acc, name)
    end
  end
  return acc
end

---@param prompt string
---@param opts { enabled: boolean, symbols_only: boolean, max: number }
---@return OpencodeMessagePart[]|nil
function M.get_recent_buffers(prompt, opts)
  if not opts or not opts.enabled then
    return nil
  end

  local bufs = vim.api.nvim_list_bufs()
  local recent = {}

  -- Collect candidate buffers (MRU ordering approximation by number)
  for _, b in ipairs(bufs) do
    if is_valid_buffer(b) then
      local line_count = vim.api.nvim_buf_line_count(b)
      if line_count > 100 then
        local clients = vim.lsp.get_active_clients({ bufnr = b })
        if #clients > 0 then
          table.insert(recent, { bufnr = b, line_count = line_count })
        end
      end
    end
  end

  if #recent == 0 then
    return nil
  end

  table.sort(recent, function(a, b)
    return a.bufnr > b.bufnr -- crude MRU heuristic
  end)

  local max_items = math.max(1, opts.max or 5)
  local parts = {}
  for i = 1, math.min(#recent, max_items) do
    local b = recent[i].bufnr
    local path = vim.api.nvim_buf_get_name(b)
    local rel_path = vim.fn.fnamemodify(path, ':~:.')
    local mention = '@' .. rel_path
    local pos = prompt and prompt:find(mention)
    pos = pos and pos - 1 or 0

    local symbol_list
    if opts.symbols_only then
      local symbols = fetch_document_symbols(b)
      if symbols then
        local flat = flatten_symbols(symbols)
        local names = {}
        for _, s in ipairs(flat) do
          table.insert(names, s.name)
        end
        symbol_list = names
      end
      -- Guarantee a symbols array exists (empty if none found) for a stable contract
      if not symbol_list then
        symbol_list = {}
      end
    end

    local content
    if not opts.symbols_only then
      local first_lines = vim.api.nvim_buf_get_lines(b, 0, math.min(200, vim.api.nvim_buf_line_count(b)), false)
      content = table.concat(first_lines, '\n')
    end

    local data = {
      context_type = 'recent-buffer',
      path = path,
      relative = rel_path,
      line_count = recent[i].line_count,
      symbols = symbol_list,
      preview = content and ('```\n' .. content .. '\n```') or nil,
    }

    local part = {
      type = 'text',
      text = vim.json.encode(data),
      synthetic = true,
      source = {
        path = path,
        type = 'file',
        text = { start = pos, value = mention, ['end'] = pos + #mention - 1 },
      },
    }
    table.insert(parts, part)
  end

  return parts
end

return M
