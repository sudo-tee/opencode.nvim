-- Base class for context gathering
-- Handles collecting editor context (files, selections, diagnostics, cursor, etc.)

local util = require('opencode.util')
local config = require('opencode.config')
local state = require('opencode.state')
local Promise = require('opencode.promise')

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
  local instance = setmetatable({}, self)
  instance.context = {
    -- current file
    current_file = nil,
    cursor_data = nil,

    -- attachments
    mentioned_files = nil,
    selections = {},
    linter_errors = {},
    mentioned_subagents = {},
  }
  instance.last_context = nil
  instance.context_config = context_config
  return instance
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

  return Promise.system({ 'git', 'diff', '--cached' }):and_then(function(output)
    if output == '' then
      return nil
    end
    return output.stdout
  end)
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

  local ctx = vim.deepcopy(self.context)
  local last_context = self.last_context
  if not last_context then
    return ctx
  end

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

  return ctx
end

--- Set the last context (used for delta calculations)
---@param last_context OpencodeContext
function ContextInstance:set_last_context(last_context)
  self.last_context = last_context
end

return ContextInstance
