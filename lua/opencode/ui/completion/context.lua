local config = require('opencode.config')
local context = require('opencode.context')
local state = require('opencode.state')
local icons = require('opencode.ui.icons')

local M = {}

---@param name string
---@param type string
---@param available boolean
---@param documentation string|nil
---@param icon string|nil
---@return CompletionItem
local function create_context_item(name, type, available, documentation, icon)
  local label = name

  return {
    label = label,
    kind = 'context',
    kind_icon = icon or (available and ' ' or ' '),
    detail = name,
    documentation = documentation or (available and name or 'Enable ' .. name .. ' for this message'),
    insert_text = '',
    source_name = 'context',
    data = { type = type, name = name, available = available },
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

local function format_selections(selections)
  local content = {}
  for _, sel in ipairs(selections or {}) do
    local lang = sel.file and sel.file.extension or ''
    local text = string.format('```%s\n%s\n```', lang, sel.content)

    table.insert(content, text)
  end
  return table.concat(content, '\n')
end

---@param cursor_data OpencodeContextCursorData
local function format_cursor_data(cursor_data)
  if context.is_context_enabled('cursor_data') == false then
    return 'Enable cursor data context.'
  end
  if not cursor_data or vim.tbl_isempty(cursor_data) then
    return 'No cursor data available.'
  end

  local filetype = context.context.current_file.extension
  local parts = {
    'Line: ' .. (cursor_data.line or 'N/A'),
    (cursor_data.column or ''),
    string.format('```%s \n%s\n```', filetype, cursor_data.line_content or 'N/A'),
  }

  return table.concat(parts, '\n')
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

    local items = {}
    local ctx = context.delta_context()

    local current_file_available = context.is_context_enabled('current_file')

    table.insert(
      items,
      create_context_item(
        'Current File',
        'current_file',
        current_file_available,
        string.format('Current file: %s', ctx.current_file and vim.fn.fnamemodify(ctx.current_file.path, ':~:.'))
      )
    )

    if context.is_context_enabled('files') and ctx.mentioned_files and #ctx.mentioned_files > 0 then
      for _, file in ipairs(ctx.mentioned_files) do
        local filename = vim.fn.fnamemodify(file, ':~:.')
        table.insert(
          items,
          create_context_item(filename, 'mentioned_file', true, 'Remove ' .. filename, icons.get_glyph('file'))
        )
      end
    end

    table.insert(
      items,
      create_context_item(
        'Selection',
        'selection',
        context.is_context_enabled('selection'),
        format_selections(ctx.selections or {})
      )
    )

    if context.is_context_enabled('agents') and ctx.mentioned_subagents then
      for _, subagent in ipairs(ctx.mentioned_subagents) do
        table.insert(
          items,
          create_context_item(subagent .. ' (agent)', 'subagent', true, 'Remove ' .. subagent, icons.get_glyph('agent'))
        )
      end
    end

    table.insert(
      items,
      create_context_item(
        'Diagnostics',
        'diagnostics',
        context.is_context_enabled('diagnostics'),
        format_diagnostics(ctx.linter_errors)
      )
    )

    table.insert(
      items,
      create_context_item(
        'Cursor Data',
        'cursor_data',
        context.is_context_enabled('cursor_data'),
        format_cursor_data(ctx.cursor_data)
      )
    )

    if #input > 0 then
      items = vim.tbl_filter(function(item)
        return item.label:lower():find(input:lower(), 1, true) ~= nil
      end, items)
    end

    table.sort(items, function(a, b)
      if a.data.available ~= b.data.available then
        return a.data.available
      end
      return a.label < b.label
    end)

    return items
  end,
  on_complete = function(item)
    local input_win = require('opencode.ui.input_window')
    if not item or not item.data then
      return
    end

    local type = item.data.type
    local context_cfg = vim.deepcopy(state.current_context_config) or {}
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
    end

    vim.schedule(function()
      vim.fn.feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n')

      local _, col = unpack(vim.api.nvim_win_get_cursor(0))
      local line = vim.api.nvim_get_current_line()
      if col > 0 and line:sub(col, col) == config.keymap.window.context_items then
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
