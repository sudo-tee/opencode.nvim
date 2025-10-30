local config = require('opencode.config')
local context = require('opencode.context')
local state = require('opencode.state')
local icons = require('opencode.ui.icons')

local M = {}
local kind_priority = {
  selection_item = 3,
  mentioned_file = 4,
  subagent = 5,
}

---@generic T
---@param name string
---@param type string
---@param available boolean
---@param documentation string|nil
---@param icon string|nil
---@param additional_data? T
---@return CompletionItem
local function create_context_item(name, type, available, documentation, icon, additional_data, priority)
  local label = name

  return {
    label = label,
    kind = 'context',
    kind_icon = icon or (available and icons.get('status_on') or icons.get('status_off')),
    detail = name,
    documentation = documentation or (available and name or 'Enable ' .. name .. ' for this message'),
    insert_text = '',
    source_name = 'context',
    priority = priority or (available and 100 or 200),
    data = { type = type, name = name, available = available, additional_data = additional_data },
  }
end

local function format_diagnostics(diagnostics)
  if context.is_context_enabled('diagnostics') == false then
    return 'Enable diagnostics context.'
  end
  if not diagnostics or #diagnostics == 0 then
    return 'No diagnostics available.'
  end

  local counts = {}
  for _, diag in ipairs(diagnostics) do
    counts[diag.severity] = (counts[diag.severity] or 0) + 1
  end
  local parts = {}
  if counts[vim.diagnostic.severity.ERROR] then
    table.insert(parts, string.format('%d Error%s', counts[1], counts[1] > 1 and 's' or ''))
  end
  if counts[vim.diagnostic.severity.WARN] then
    table.insert(parts, string.format('%d Warning%s', counts[2], counts[2] > 1 and 's' or ''))
  end
  if counts[vim.diagnostic.severity.INFO] then
    table.insert(parts, string.format('%d Info%s', counts[3], counts[3] > 1 and 's' or ''))
  end

  return table.concat(parts, ', ')
end

local function format_selection(selection)
  local lang = selection.file and selection.file.extension or ''
  return string.format('```%s\n%s\n```', lang, selection.content)
end

---@param cursor_data? OpencodeContextCursorData
---@return string
local function format_cursor_data(cursor_data)
  if context.is_context_enabled('cursor_data') == false then
    return 'Enable cursor data context.'
  end
  if not cursor_data or vim.tbl_isempty(cursor_data) then
    return 'No cursor data available.'
  end

  local filetype = context.context.current_file and context.context.current_file.extension
  local parts = {
    'Line: ' .. (cursor_data.line or 'N/A'),
    (cursor_data.column or ''),
    string.format('```%s \n%s\n```', filetype, cursor_data.line_content or 'N/A'),
  }

  return table.concat(parts, '\n')
end

---@param ctx OpencodeContext
---@return CompletionItem
local function add_current_file_item(ctx)
  local current_file_available = context.is_context_enabled('current_file')
  return create_context_item(
    'Current File',
    'current_file',
    current_file_available,
    string.format('Current file: %s', ctx.current_file and vim.fn.fnamemodify(ctx.current_file.path, ':~:.'))
  )
end

---@param ctx OpencodeContext
---@return CompletionItem[]
local function add_mentioned_files_items(ctx)
  local items = {}
  if context.is_context_enabled('files') and ctx.mentioned_files and #ctx.mentioned_files > 0 then
    for _, file in ipairs(ctx.mentioned_files) do
      local filename = vim.fn.fnamemodify(file, ':~:.')
      table.insert(
        items,
        create_context_item(
          filename,
          'mentioned_file',
          true,
          'Select to remove file ' .. filename,
          icons.get('file'),
          nil,
          kind_priority.mentioned_file
        )
      )
    end
  end
  return items
end

---@param ctx OpencodeContext
---@return CompletionItem[]
local function add_selection_items(ctx)
  local items = {
    create_context_item(
      'Selection' .. (ctx.selections and #ctx.selections > 0 and string.format(' (%d)', #ctx.selections) or ''),
      'selection',
      context.is_context_enabled('selection'),
      ctx.selections and #ctx.selections > 0 and 'Manage your current selections individually'
        or 'No selections available.'
    ),
  }

  for i, selection in ipairs(ctx.selections or {}) do
    local label =
      string.format('Selection %d %s (%s)', i, selection.file and selection.file.name or 'Untitled', selection.lines)
    table.insert(
      items,
      create_context_item(
        label,
        'selection_item',
        true,
        format_selection(selection),
        icons.get('selection'),
        selection,
        kind_priority.selection_item
      )
    )
  end
  return items
end

---@param ctx OpencodeContext
---@return CompletionItem[]
local function add_subagents_items(ctx)
  if not (context.is_context_enabled('agents') or ctx.mentioned_subagents) then
    return {}
  end
  local items = {}
  for _, agent in ipairs(ctx.mentioned_subagents or {}) do
    table.insert(
      items,
      create_context_item(
        agent .. ' (agent)',
        'subagent',
        true,
        'Select to remove agent ' .. agent,
        icons.get('agent'),
        nil,
        kind_priority.subagent
      )
    )
  end
  return items
end

---@param ctx OpencodeContext
---@return CompletionItem
local function add_diagnostics_item(ctx)
  return create_context_item(
    'Diagnostics',
    'diagnostics',
    context.is_context_enabled('diagnostics'),
    format_diagnostics(ctx.linter_errors)
  )
end

---@param ctx OpencodeContext
---@return CompletionItem
local function add_cursor_data_item(ctx)
  return create_context_item(
    'Cursor Data',
    'cursor_data',
    context.is_context_enabled('cursor_data'),
    format_cursor_data(ctx.cursor_data)
  )
end

---@type CompletionSource
local context_source = {
  name = 'context',
  priority = 1,
  complete = function(completion_context)
    local input = completion_context.input or ''

    local expected_trigger = config.get_key_for_function('input_window', 'context_items')
    if completion_context.trigger_char ~= expected_trigger then
      return {}
    end

    local ctx = context.delta_context()

    local items = {
      add_current_file_item(ctx),
      add_diagnostics_item(ctx),
      add_cursor_data_item(ctx),
    }
    vim.list_extend(items, add_selection_items(ctx))
    vim.list_extend(items, add_mentioned_files_items(ctx))
    vim.list_extend(items, add_subagents_items(ctx))

    if #input > 0 then
      items = vim.tbl_filter(function(item)
        return item.label:lower():find(input:lower(), 1, true) ~= nil
      end, items)
    end

    return items
  end,
  on_complete = function(item)
    local input_win = require('opencode.ui.input_window')
    if not item or not item.data then
      return
    end

    local type = item.data.type
    local context_cfg = vim.deepcopy(state.current_context_config or {})
    if not context_cfg or not context_cfg[type] then
      context_cfg[type] = vim.deepcopy(config.context[type])
    end

    if vim.tbl_contains({ 'current_file', 'selection', 'diagnostics', 'cursor_data' }, type) then
      context_cfg[type] = context_cfg[type] or {}
      context_cfg[type].enabled = not item.data.available
    end

    state.current_context_config = context_cfg

    if type == 'mentioned_file' then
      context.remove_file(item.data.name)
      input_win.remove_mention(item.data.name)
    elseif type == 'subagent' then
      local subagent_name = item.data.name:gsub(' %(agent%)$', '')
      context.remove_subagent(subagent_name)
      input_win.remove_mention(subagent_name)
    elseif type == 'selection_item' then
      context.remove_selection(item.data.additional_data --[[@as OpencodeContextSelection]])
    end

    vim.schedule(function()
      vim.fn.feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n')

      local _, col = unpack(vim.api.nvim_win_get_cursor(0))
      local line = vim.api.nvim_get_current_line()
      local key = config.get_key_for_function('input_window', 'context_items')
      if col > 0 and line:sub(col, col) == key then
        line = line:sub(1, col - 1) .. line:sub(col + 1)
        input_win.set_current_line(line)
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes('a', true, false, true), 'n')
      end
    end)
  end,
}

---Get the context completion source
---@return CompletionSource
function M.get_source()
  return context_source
end

return M
