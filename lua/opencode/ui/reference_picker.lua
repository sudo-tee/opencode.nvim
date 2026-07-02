local config = require('opencode.config')
local base_picker = require('opencode.ui.base_picker')
local icons = require('opencode.ui.icons')

local M = {}

local function make_absolute_path(path)
  if not vim.startswith(path, '/') then
    return vim.fn.getcwd() .. '/' .. path
  end
  return path
end

local function format_reference_item(ref, width)
  local icon = icons.get('file')
  local location = ref.path
  if ref.line then
    location = location .. ':' .. ref.line
    if ref.col then
      location = location .. ':' .. ref.col
    end
  end
  return base_picker.create_time_picker_item(icon .. ' ' .. location, nil, nil, width)
end

local function display_refs(refs)
  local items = {}
  local seen = {}
  for _, ref in ipairs(refs or {}) do
    local key = make_absolute_path(ref.path) .. ':' .. (ref.line or 0)
    if not seen[key] then
      seen[key] = true
      items[#items + 1] = ref
    end
  end
  return items
end

function M.pick()
  local refs = display_refs(require('opencode.ui.reference_facts').current_refs())
  if #refs == 0 then
    vim.notify('No code references found in the conversation', vim.log.levels.INFO)
    return
  end

  return base_picker.pick({
    items = refs,
    format_fn = format_reference_item,
    actions = {},
    callback = function(selected)
      if selected then
        M.navigate_to(selected)
      end
    end,
    title = 'Code References (' .. #refs .. ')',
    width = config.ui.picker_width,
    preview = 'file',
    layout_opts = config.ui.picker,
  })
end

function M.navigate_to(ref)
  local file_path = make_absolute_path(ref.path)
  if vim.fn.filereadable(file_path) ~= 1 then
    vim.notify('File not found: ' .. file_path, vim.log.levels.WARN)
    return
  end

  vim.cmd('tabedit ' .. vim.fn.fnameescape(file_path))
  if ref.line then
    local line = math.max(1, ref.line)
    local col = ref.col and math.max(0, ref.col - 1) or 0
    local line_count = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { math.min(line, line_count), col })
    vim.cmd('normal! zz')
  end
end

return M
