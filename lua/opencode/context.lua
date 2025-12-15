-- Gathers editor context

local util = require('opencode.util')
local config = require('opencode.config')
local state = require('opencode.state')
local Promise = require('opencode.promise')

local M = {}

---@class ContextInstance
---@field context OpencodeContext
---@field last_context OpencodeContext|nil
---@field context_config OpencodeContextConfig|nil Optional context config override
local ContextInstance = {}
ContextInstance.__index = ContextInstance

--- Creates a new Context instance
---@param context_config? OpencodeContextConfig Optional context config to override global config
---@return ContextInstance
function ContextInstance:new(context_config)
  self = setmetatable({}, ContextInstance)
  self.context = {
    -- current file
    current_file = nil,
    cursor_data = nil,

    -- attachments
    mentioned_files = nil,
    selections = {},
    linter_errors = {},
    mentioned_subagents = {},
  }
  self.last_context = nil
  self.context_config = context_config
  return self
end

function ContextInstance:unload_attachments()
  self.context.mentioned_files = nil
  self.context.selections = nil
  self.context.linter_errors = nil
end

---@return integer|nil, integer|nil
function ContextInstance:get_current_buf()
  local curr_buf = state.current_code_buf or vim.api.nvim_get_current_buf()
  if util.is_buf_a_file(curr_buf) then
    local win = vim.fn.win_findbuf(curr_buf --[[@as integer]])[1]
    return curr_buf, state.last_code_win_before_opencode or win or vim.api.nvim_get_current_win()
  end
end

function ContextInstance:load()
  local buf, win = self:get_current_buf()

  if buf then
    local current_file = self:get_current_file(buf)
    local cursor_data = self:get_current_cursor_data(buf, win)

    self.context.current_file = current_file
    self.context.cursor_data = cursor_data
    self.context.linter_errors = self:get_diagnostics(buf)
  end

  local current_selection = self:get_current_selection()
  if current_selection then
    local selection = self:new_selection(self.context.current_file, current_selection.text, current_selection.lines)
    self:add_selection(selection)
  end
end

function ContextInstance:is_enabled()
  if self.context_config and self.context_config.enabled ~= nil then
    return self.context_config.enabled
  end

  local is_enabled = vim.tbl_get(config --[[@as table]], 'context', 'enabled')
  local is_state_enabled = vim.tbl_get(state, 'current_context_config', 'enabled')
  if is_state_enabled ~= nil then
    return is_state_enabled
  else
    return is_enabled
  end
end

-- Checks if a context feature is enabled in config or state
---@param context_key string
---@return boolean
function ContextInstance:is_context_enabled(context_key)
  -- If instance has a context config, use it as the override
  if self.context_config then
    local override_enabled = vim.tbl_get(self.context_config, context_key, 'enabled')
    if override_enabled ~= nil then
      return override_enabled
    end
  end

  -- Fall back to the existing logic (state then global config)
  local is_enabled = vim.tbl_get(config --[[@as table]], 'context', context_key, 'enabled')
  local is_state_enabled = vim.tbl_get(state, 'current_context_config', context_key, 'enabled')

  if is_state_enabled ~= nil then
    return is_state_enabled
  else
    return is_enabled
  end
end

---@return OpencodeDiagnostic[]|nil
function ContextInstance:get_diagnostics(buf)
  if not self:is_context_enabled('diagnostics') then
    return nil
  end

  local current_conf = vim.tbl_get(state, 'current_context_config', 'diagnostics') or {}
  if current_conf.enabled == false then
    return {}
  end

  local global_conf = vim.tbl_get(config --[[@as table]], 'context', 'diagnostics') or {}
  local override_conf = self.context_config and vim.tbl_get(self.context_config, 'diagnostics') or {}
  local diagnostic_conf = vim.tbl_deep_extend('force', global_conf, current_conf, override_conf) or {}

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

  local diagnostics = {}
  if diagnostic_conf.only_closest then
    local selections = self:get_selections()
    if #selections > 0 then
      local selection = selections[#selections]
      if selection and selection.lines then
        local range_parts = vim.split(selection.lines, ',')
        local start_line = (tonumber(range_parts[1]) or 1) - 1
        local end_line = (tonumber(range_parts[2]) or 1) - 1
        for lnum = start_line, end_line do
          local line_diagnostics = vim.diagnostic.get(buf, {
            lnum = lnum,
            severity = severity_levels,
          })
          for _, diag in ipairs(line_diagnostics) do
            table.insert(diagnostics, diag)
          end
        end
      end
    else
      local win = vim.fn.win_findbuf(buf)[1]
      local cursor_pos = vim.fn.getcurpos(win)
      local line_diagnostics = vim.diagnostic.get(buf, {
        lnum = cursor_pos[2] - 1,
        severity = severity_levels,
      })
      diagnostics = line_diagnostics
    end
  else
    diagnostics = vim.diagnostic.get(buf, { severity = severity_levels })
  end

  if #diagnostics == 0 then
    return {}
  end

  local opencode_diagnostics = {}
  for _, diag in ipairs(diagnostics) do
    table.insert(opencode_diagnostics, {
      message = diag.message,
      severity = diag.severity,
      lnum = diag.lnum,
      col = diag.col,
      end_lnum = diag.end_lnum,
      end_col = diag.end_col,
      source = diag.source,
      code = diag.code,
      user_data = diag.user_data,
    })
  end

  return opencode_diagnostics
end

function ContextInstance:new_selection(file, content, lines)
  return {
    file = file,
    content = util.indent_code_block(content),
    lines = lines,
  }
end

function ContextInstance:add_selection(selection)
  if not self.context.selections then
    self.context.selections = {}
  end

  table.insert(self.context.selections, selection)
end

function ContextInstance:remove_selection(selection)
  if not self.context.selections then
    return
  end

  for i, sel in ipairs(self.context.selections) do
    if sel.file.path == selection.file.path and sel.lines == selection.lines then
      table.remove(self.context.selections, i)
      break
    end
  end
end

function ContextInstance:clear_selections()
  self.context.selections = nil
end

function ContextInstance:add_file(file)
  if not self.context.mentioned_files then
    self.context.mentioned_files = {}
  end

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

  if not vim.tbl_contains(self.context.mentioned_files, file) then
    table.insert(self.context.mentioned_files, file)
  end
end

function ContextInstance:remove_file(file)
  file = vim.fn.fnamemodify(file, ':p')
  if not self.context.mentioned_files then
    return
  end

  for i, f in ipairs(self.context.mentioned_files) do
    if f == file then
      table.remove(self.context.mentioned_files, i)
      break
    end
  end
end

function ContextInstance:clear_files()
  self.context.mentioned_files = nil
end

function ContextInstance:get_mentioned_files()
  return self.context.mentioned_files or {}
end

function ContextInstance:add_subagent(subagent)
  if not self.context.mentioned_subagents then
    self.context.mentioned_subagents = {}
  end

  if not vim.tbl_contains(self.context.mentioned_subagents, subagent) then
    table.insert(self.context.mentioned_subagents, subagent)
  end
end

function ContextInstance:remove_subagent(subagent)
  if not self.context.mentioned_subagents then
    return
  end

  for i, a in ipairs(self.context.mentioned_subagents) do
    if a == subagent then
      table.remove(self.context.mentioned_subagents, i)
      break
    end
  end
end

function ContextInstance:clear_subagents()
  self.context.mentioned_subagents = nil
end

function ContextInstance:get_mentioned_subagents()
  if not self:is_context_enabled('agents') then
    return nil
  end
  return self.context.mentioned_subagents or {}
end

function ContextInstance:get_current_file(buf)
  if not self:is_context_enabled('current_file') then
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

function ContextInstance:get_current_cursor_data(buf, win)
  if not self:is_context_enabled('cursor_data') then
    return nil
  end

  local num_lines = config.context.cursor_data.context_lines --[[@as integer]]
    or 0
  local cursor_pos = vim.fn.getcurpos(win)
  local start_line = (cursor_pos[2] - 1) --[[@as integer]]
  local cursor_content = vim.trim(vim.api.nvim_buf_get_lines(buf, start_line, cursor_pos[2], false)[1] or '')
  local lines_before = vim.api.nvim_buf_get_lines(buf, math.max(0, start_line - num_lines), start_line, false)
  local lines_after = vim.api.nvim_buf_get_lines(buf, cursor_pos[2], cursor_pos[2] + num_lines, false)
  return {
    line = cursor_pos[2],
    column = cursor_pos[3],
    line_content = cursor_content,
    lines_before = lines_before,
    lines_after = lines_after,
  }
end

function ContextInstance:get_current_selection()
  if not self:is_context_enabled('selection') then
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

  if not text or text == '' then
    return nil
  end

  return {
    text = text and text:match('[^%s]') and text or nil,
    lines = start_line .. ', ' .. end_line,
  }
end

function ContextInstance:get_selections()
  if not self:is_context_enabled('selection') then
    return {}
  end
  return self.context.selections or {}
end

ContextInstance.get_git_diff = Promise.async(function(self)
  if not self:is_context_enabled('git_diff') then
    return nil
  end

  Promise.system({ 'git', 'diff', '--cached' })
end)

---@param opts? OpencodeContextConfig
---@return OpencodeContext
function ContextInstance:delta_context(opts)
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

  local context = vim.deepcopy(self.context)
  local last_context = self.last_context
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

--- Set the last context (used for delta calculations)
---@param last_context OpencodeContext
function ContextInstance:set_last_context(last_context)
  self.last_context = last_context
end

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
      content = string.format('`````%s\n%s\n`````', lang, selection.content), --@TODO remove code fence and only use it when displaying
      lines = selection.lines,
    }),
    synthetic = true,
  }
end

---@param diagnostics OpencodeDiagnostic[]
---@param range? { start_line: integer, end_line: integer }|nil
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
    meradata = {
      context_type = 'diagnostics',
    },
    text = vim.json.encode({ context_type = 'diagnostics', content = diag_list }),
    synthetic = true,
  }
end

local function format_cursor_data_part(cursor_data)
  local buf = (M.get_current_buf() or 0) --[[@as integer]]
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
      line_content = string.format('`````%s\n%s\n`````', lang, cursor_data.line_content), --@TODO remove code fence and only use it when displaying
      lines_before = cursor_data.lines_before,
      lines_after = cursor_data.lines_after,
    }),
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

  if context.linter_errors and #context.linter_errors > 0 then
    table.insert(parts, format_diagnostics_part(context.linter_errors))
  end

  if context.cursor_data then
    table.insert(parts, format_cursor_data_part(context.cursor_data))
  end

  return parts
end

--- Formats a prompt and context into message without state tracking (bypasses delta)
--- Used for ephemeral sessions like quick chat that don't track context state
---@param prompt string
---@param context_instance ContextInstance Optional context instance to use instead of global
---@return OpencodeMessagePart[]
M.format_message_quick_chat = Promise.async(function(prompt, context_instance)
  local parts = { { type = 'text', text = prompt } }

  if context_instance:is_enabled() == false then
    return parts
  end

  for _, path in ipairs(context_instance:get_mentioned_files() or {}) do
    table.insert(parts, format_file_part(path, prompt))
  end

  for _, sel in ipairs(context_instance:get_selections() or {}) do
    table.insert(parts, format_selection_part(sel))
  end

  for _, agent in ipairs(context_instance:get_mentioned_subagents() or {}) do
    table.insert(parts, format_subagents_part(agent, prompt))
  end

  local current_file = context_instance:get_current_file(context_instance:get_current_buf() or 0)
  if current_file then
    table.insert(parts, format_file_part(current_file.path))
  end

  local diagnostics = context_instance:get_diagnostics(context_instance:get_current_buf() or 0)
  if diagnostics and #diagnostics > 0 then
    table.insert(parts, format_diagnostics_part(diagnostics))
  end

  local current_buf, current_win = context_instance:get_current_buf()
  local cursor_data = context_instance:get_current_cursor_data(current_buf or 0, current_win or 0)
  if cursor_data then
    table.insert(parts, format_cursor_data_part(cursor_data))
  end

  if context_instance:is_context_enabled('buffer') then
    local buf = context_instance:get_current_buf()
    if buf then
      table.insert(parts, format_buffer_part(buf))
    end
  end

  local diff_text = context_instance:get_git_diff():await()
  if diff_text and diff_text ~= '' then
    table.insert(parts, format_git_diff_part(diff_text))
  end

  return parts
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
