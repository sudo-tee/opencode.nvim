local M = {}

local context = require('opencode.context')
local icons = require('opencode.ui.icons')
local state = require('opencode.state')

local function get_current_file_info()
  local current_file = context.delta_context().current_file
  if not current_file then
    return nil
  end

  return {
    name = current_file.name,
    path = current_file.path,
  }
end

local function get_attached_files_count()
  local mentioned_files = context.delta_context().mentioned_files
  return mentioned_files and #mentioned_files or 0
end

local function has_selection()
  local selections = context.delta_context().selections
  return selections and #selections > 0
end

local function has_cursor_data()
  local cursor_data = context.delta_context().cursor_data
  return cursor_data ~= nil
end

local function has_diagnostics()
  local diagnostics = context.delta_context().linter_errors
  return diagnostics and #diagnostics > 0
end

local function format_cursor_data()
  local cursor_data = context.delta_context().cursor_data
  if not cursor_data then
    return ''
  end
  return string.format('L:%d ', cursor_data.line, cursor_data.col)
end

local function create_winbar_segments()
  local segments = {
    {
      icon = icons.get_glyph('context'),
      text = '',
      highlight = 'OpencodeContext',
    },
  }

  local current_file = get_current_file_info()
  if current_file then
    table.insert(segments, {
      icon = icons.get_glyph('attached_file'),
      text = current_file.name,
      highlight = 'OpencodeContextCurrentFile',
    })
  end

  local agents = context.delta_context().mentioned_subagents or {}
  if #agents > 0 then
    table.insert(segments, {
      icon = icons.get_glyph('agent'),
      text = '(' .. #agents .. ')',
      highlight = 'OpencodeContextAgent',
    })
  end

  local attached_count = get_attached_files_count()
  if attached_count > 0 then
    table.insert(segments, {
      icon = icons.get_glyph('file'),
      text = '(' .. attached_count .. ')',
      highlight = 'OpencodeContext',
    })
  end

  if has_selection() then
    table.insert(segments, {
      icon = '',
      text = "'<'> Sel",
      highlight = 'OpencodeContextSelection',
    })
  end

  if has_cursor_data() then
    table.insert(segments, {
      icon = icons.get_glyph('cursor_data'),
      text = format_cursor_data(),
      highlight = 'OpencodeContextSelection',
    })
  end

  if has_diagnostics() then
    local diagnostics = context.delta_context().linter_errors
    local counts = { error = 0, warning = 0, info = 0 }

    for _, diag in ipairs(diagnostics) do
      if diag.severity == vim.diagnostic.severity.WARN then
        counts.warning = counts.warning + 1
      elseif diag.severity == vim.diagnostic.severity.INFO then
        counts.info = counts.info + 1
      else
        counts.error = counts.error + 1
      end
    end

    if counts.error > 0 then
      table.insert(segments, {
        icon = icons.get_glyph('error'),
        text = '(' .. counts.error .. ')',
        highlight = 'OpencodeContextError',
      })
    end

    if counts.warning > 0 then
      table.insert(segments, {
        icon = icons.get_glyph('warning'),
        text = '(' .. counts.warning .. ')',
        highlight = 'OpencodeContextWarning',
      })
    end

    if counts.info > 0 then
      table.insert(segments, {
        icon = icons.get_glyph('info'),
        text = '(' .. counts.info .. ')',
        highlight = 'OpencodeContextInfo',
      })
    end
  end

  return segments
end

local function format_winbar_text(segments, win_width)
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

function M.render(windows)
  vim.schedule(function()
    local win = windows and windows.input_win or state.windows.input_win
    if not state.windows or not win then
      return
    end

    local segments = create_winbar_segments()
    local win_width = vim.api.nvim_win_get_width(win)

    vim.wo[win].winbar = format_winbar_text(segments, win_width)
    update_winbar_highlights(win)
  end)
end

return M
