local M = {}

local context = require('opencode.context')
local icons = require('opencode.ui.icons')
local state = require('opencode.state')

local function get_current_file_info(ctx)
  local current_file = ctx.current_file
  if not current_file then
    return nil
  end

  return {
    name = current_file.name,
    path = current_file.path,
  }
end

local function get_attached_files_count(ctx)
  local mentioned_files = ctx.mentioned_files
  return mentioned_files and #mentioned_files or 0
end

local function has_selection(ctx)
  local selections = ctx.selections
  return selections and #selections > 0
end

local function has_cursor_data(ctx)
  local cursor_data = ctx.cursor_data
  return cursor_data ~= nil
end

local function has_diagnostics(ctx)
  local diagnostics = ctx.linter_errors
  return diagnostics and #diagnostics > 0
end

local function format_cursor_data(ctx)
  local cursor_data = ctx.cursor_data
  if not cursor_data then
    return ''
  end
  return string.format('L:%d ', cursor_data.line, cursor_data.col)
end

local function create_winbar_segments()
  local ctx = context.delta_context()
  local segments = {
    {
      icon = icons.get('context'),
      text = '',
      highlight = 'OpencodeContext',
    },
  }

  local current_file = get_current_file_info(ctx)
  if context.is_context_enabled('current_file') and current_file then
    table.insert(segments, {
      icon = icons.get('attached_file'),
      text = current_file.name,
      highlight = 'OpencodeContextCurrentFile',
    })
  end

  local agents = ctx.mentioned_subagents or {}
  if context.is_context_enabled('agents') and #agents > 0 then
    table.insert(segments, {
      icon = icons.get('agent'),
      text = '(' .. #agents .. ')',
      highlight = 'OpencodeContextAgent',
    })
  end

  local attached_count = get_attached_files_count(ctx)
  if context.is_context_enabled('files') and attached_count > 0 then
    table.insert(segments, {
      icon = icons.get('file'),
      text = '(' .. attached_count .. ')',
      highlight = 'OpencodeContext',
    })
  end

  if context.is_context_enabled('selection') and has_selection(ctx) then
    table.insert(segments, {
      icon = '',
      text = "'<'> Sel",
      highlight = 'OpencodeContextSelection',
    })
  end

  if context.is_context_enabled('cursor_data') and has_cursor_data(ctx) then
    table.insert(segments, {
      icon = icons.get('cursor_data'),
      text = format_cursor_data(ctx),
      highlight = 'OpencodeContextSelection',
    })
  end

  if context.is_context_enabled('diagnostics') and has_diagnostics(ctx) then
    local counts = {}
    local diagnostics = ctx.linter_errors
    local severity_types = {
      [vim.diagnostic.severity.ERROR] = 'error',
      [vim.diagnostic.severity.WARN] = 'warning',
      [vim.diagnostic.severity.INFO] = 'info',
    }

    for _, diag in ipairs(diagnostics or {}) do
      local type_name = severity_types[diag.severity] or 'error'
      counts[type_name] = (counts[type_name] or 0) + 1
    end

    for _, type_name in pairs(severity_types) do
      local count = counts[type_name]
      if count and count > 0 then
        table.insert(segments, {
          icon = icons.get(type_name),
          text = '(' .. count .. ')',
          highlight = 'OpencodeContext' .. type_name:gsub('^%l', string.upper),
        })
      end
    end
  end

  return segments
end

local function format_winbar_text(segments)
  if #segments == 0 then
    return ''
  end

  local parts = {}

  for i, segment in ipairs(segments) do
    local segment_text = segment.icon .. segment.text
    local highlight = segment.highlight and ('%#' .. segment.highlight .. '#') or ''

    table.insert(parts, highlight .. segment_text .. '%*')

    if i < #segments then
      table.insert(parts, ' %#OpencodeContextBar#|%* ')
    end
  end

  return ' ' .. table.concat(parts, '')
end

local function update_winbar_highlights(win_id)
  local current = vim.api.nvim_get_option_value('winhighlight', { win = win_id })
  local parts = vim.split(current, ',')

  parts = vim.tbl_filter(function(part)
    return not part:match('^WinBar:') and not part:match('^WinBarNC:')
  end, parts)

  if not vim.tbl_contains(parts, 'Normal:OpencodeNormal') then
    table.insert(parts, 'Normal:OpencodeNormal')
  end

  table.insert(parts, 'WinBar:OpencodeContextBar')
  table.insert(parts, 'WinBarNC:OpencodeContextBar')

  vim.api.nvim_set_option_value('winhighlight', table.concat(parts, ','), { win = win_id })
end

function M.setup()
  state.subscribe({ 'current_context_config', 'current_code_buf', 'opencode_focused', 'context_updated_at' }, function()
    M.render()
  end)
end

function M.render(windows)
  vim.schedule(function()
    windows = windows or state.windows
    local win = windows and windows.input_win
    if not win then
      return
    end
    local segments = create_winbar_segments()

    vim.wo[win].winbar = format_winbar_text(segments)
    update_winbar_highlights(win)
  end)
end

return M
