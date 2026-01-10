local M = {}

function M.get_best_picker()
  local config = require('opencode.config')

  local preferred_picker = config.preferred_picker
  if preferred_picker and type(preferred_picker) == 'string' and preferred_picker ~= '' then
    if preferred_picker == 'select' then
      return nil
    end

    return preferred_picker
  end

  if pcall(require, 'telescope') then
    return 'telescope'
  end
  if pcall(require, 'fzf-lua') then
    return 'fzf'
  end
  if pcall(require, 'mini.pick') then
    return 'mini.pick'
  end
  if pcall(require, 'snacks') then
    return 'snacks'
  end
  return nil
end

---Select function that works around Snacks.nvim vim.ui.select bug
---See: https://github.com/folke/snacks.nvim/issues/2539
---For Snacks, uses Snacks.picker directly to avoid the height calculation bug
---For all other pickers, uses vim.ui.select which respects user customizations
---@param items any[] The items to select from
---@param opts { prompt?: string, format_item?: fun(item: any): string, kind?: string } Options for the select
---@param on_choice fun(item: any?, idx: integer?) Callback when item is selected
function M.select(items, opts, on_choice)
  opts = opts or {}

  local picker_type = M.get_best_picker()

  if picker_type == 'snacks' then
    M._snacks_select(items, opts, on_choice)
  else
    vim.ui.select(items, opts, on_choice)
  end
end

---Snacks picker implementation for select (workaround for vim.ui.select bug)
---@param items any[]
---@param opts { prompt?: string, format_item?: fun(item: any): string }
---@param on_choice fun(item: any?, idx: integer?)
function M._snacks_select(items, opts, on_choice)
  local Snacks = require('snacks')

  local format_item = opts.format_item or tostring

  -- Build items with indices for tracking
  local picker_items = {}
  for idx, item in ipairs(items) do
    table.insert(picker_items, {
      text = format_item(item),
      item = item,
      idx = idx,
    })
  end

  Snacks.picker.pick({
    title = opts.prompt and opts.prompt:gsub(':?%s*$', '') or 'Select',
    items = picker_items,
    layout = {
      preview = false,
      preset = 'select',
    },
    format = function(picker_item)
      return { { picker_item.text } }
    end,
    preview = function()
      return false
    end,
    confirm = function(picker, picker_item)
      picker:close()
      if picker_item then
        vim.schedule(function()
          on_choice(picker_item.item, picker_item.idx)
        end)
      else
        vim.schedule(function()
          on_choice(nil, nil)
        end)
      end
    end,
  })
end

return M
