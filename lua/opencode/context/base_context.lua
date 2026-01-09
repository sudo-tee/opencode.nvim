local util = require('opencode.util')
local config = require('opencode.config')
local state = require('opencode.state')
local Promise = require('opencode.promise')

local M = {}

---@return integer|nil, integer|nil
function M.get_current_buf()
  local curr_buf = state.current_code_buf or vim.api.nvim_get_current_buf()
  if util.is_buf_a_file(curr_buf) then
    local win = vim.fn.win_findbuf(curr_buf --[[@as integer]])[1]
    return curr_buf, state.last_code_win_before_opencode or win or vim.api.nvim_get_current_win()
  end
end

-- Checks if a context feature is enabled in config or state
---@param context_key string
---@param context_config? OpencodeContextConfig
---@return boolean
function M.is_context_enabled(context_key, context_config)
  if context_config then
    local override_enabled = vim.tbl_get(context_config, context_key, 'enabled')
    if override_enabled ~= nil then
      return override_enabled
    end
  end

  local is_enabled = vim.tbl_get(config --[[@as table]], 'context', context_key, 'enabled')
  local is_state_enabled = vim.tbl_get(state, 'current_context_config', context_key, 'enabled')

  if is_state_enabled ~= nil then
    return is_state_enabled
  else
    return is_enabled
  end
end

---@param buf integer
---@param context_config? OpencodeContextConfig
---@param range? { start_line: integer, end_line: integer } | { start_line: integer, end_line: integer }[]
---@return OpencodeDiagnostic[]|nil
function M.get_diagnostics(buf, context_config, range)
  if not M.is_context_enabled('diagnostics', context_config) then
    return nil
  end

  local current_conf = vim.tbl_get(state, 'current_context_config', 'diagnostics') or {}
  if current_conf.enabled == false then
    return {}
  end

  local global_conf = vim.tbl_get(config --[[@as table]], 'context', 'diagnostics') or {}
  local override_conf = context_config and vim.tbl_get(context_config, 'diagnostics') or {}
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

  local ranges = nil
  if range then
    if range[1] and type(range[1]) == 'table' then
      ranges = range
    else
      ranges = { range }
    end
  end

  if diagnostic_conf.only_closest then
    if ranges then
      for _, r in ipairs(ranges) do
        for line_num = r.start_line, r.end_line do
          local line_diagnostics = vim.diagnostic.get(buf, {
            lnum = line_num,
            severity = severity_levels,
          })
          for _, diag in ipairs(line_diagnostics) do
            table.insert(diagnostics, diag)
          end
        end
      end
    else
      -- Get diagnostics for current cursor line only
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

  return opencode_diagnostics, ranges
end

---@param buf integer
---@param context_config? OpencodeContextConfig
---@return table|nil
function M.get_current_file(buf, context_config)
  if not M.is_context_enabled('current_file', context_config) then
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

---@param buf integer
---@param win integer
---@param context_config? OpencodeContextConfig
---@return table|nil
function M.get_current_cursor_data(buf, win, context_config)
  if not M.is_context_enabled('cursor_data', context_config) then
    return nil
  end

  local num_lines = config.context.cursor_data.context_lines --[[@as integer]]
    or 0
  local cursor_pos = vim.fn.getcurpos(win)
  local start_line = (cursor_pos[2] - 1) --[[@as integer]]
  local cursor_content = vim.api.nvim_buf_get_lines(buf, start_line, cursor_pos[2], false)[1] or ''
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

---@param context_config? OpencodeContextConfig
---@return table|nil
function M.get_current_selection(context_config)
  if not M.is_context_enabled('selection', context_config) then
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

---@param context_config? OpencodeContextConfig
---@return string|nil
M.get_git_diff = Promise.async(function(context_config)
  if not M.is_context_enabled('git_diff', context_config) then
    return nil
  end

  return Promise.system({ 'git', 'diff', '--cached', '--minimal' }):and_then(function(output)
    if output == '' then
      return nil
    end
    return output.stdout
  end)
end)

---@param file table
---@param content string
---@param lines string
---@param raw_indent? boolean
---@return table
function M.new_selection(file, content, lines, raw_indent)
  return {
    file = file,
    content = raw_indent and content or util.indent_code_block(content),
    lines = lines,
  }
end

return M
