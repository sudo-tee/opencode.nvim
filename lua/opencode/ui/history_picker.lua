local M = {}
local config = require('opencode.config')
local base_picker = require('opencode.ui.base_picker')
local util = require('opencode.util')
local history = require('opencode.history')

---Format history entries for history picker
---@param item table History item with text content
---@param width number Picker width
---@return PickerItem
local function format_history_item(item, width)
  local entry = item.content or item.text or ''

  return base_picker.create_picker_item(entry:gsub('\n', '↵'), nil, 'ID: ' .. item.id, width)
end

function M.pick(callback)
  local history_entries = history.read()

  if #history_entries == 0 then
    vim.notify('No history entries found', vim.log.levels.INFO)
    return false
  end

  local history_items = {}
  for i, entry in ipairs(history_entries) do
    table.insert(history_items, { id = i, text = entry, content = entry })
  end

  local actions = {
    delete = {
      key = config.keymap.history_picker.delete_entry,
      label = 'delete',
      multi_selection = true,
      fn = function(selected, opts)
        local entries_to_delete = type(selected) == 'table' and selected.id == nil and selected or { selected }

        local indices_to_remove = {}
        for _, entry_to_delete in ipairs(entries_to_delete) do
          local idx = util.find_index_of(opts.items, function(item)
            return item.id == entry_to_delete.id
          end)
          if idx > 0 then
            table.insert(indices_to_remove, idx)
          end
        end

        table.sort(indices_to_remove, function(a, b)
          return a > b
        end)

        local success = history.delete(indices_to_remove)
        if success then
          for _, idx in ipairs(indices_to_remove) do
            table.remove(opts.items, idx)
          end
          vim.notify('Deleted ' .. #entries_to_delete .. ' history entry(s)', vim.log.levels.INFO)
        else
          vim.notify('Failed to delete history entries', vim.log.levels.ERROR)
        end

        return opts.items
      end,
      reload = true,
    },
    clear_all = {
      key = config.keymap.history_picker.clear_all,
      label = 'clear all',
      fn = function(_, opts)
        local success = history.clear()
        if success then
          opts.items = {}
          vim.notify('Cleared all history entries', vim.log.levels.INFO)
        else
          vim.notify('Failed to clear history entries', vim.log.levels.ERROR)
        end

        return opts.items
      end,
      reload = true,
    },
  }

  return base_picker.pick({
    items = history_items,
    format_fn = format_history_item,
    actions = actions,
    callback = function(selected_item)
      if selected_item and callback then
        callback(selected_item.content or selected_item.text)
      elseif selected_item then
        local input_window = require('opencode.ui.input_window')
        local state = require('opencode.state')
        local windows = state.windows
        if not input_window.mounted(windows) then
          require('opencode.core').open({ focus_input = true })
          windows = state.windows
        end
        ---@cast windows { input_win: integer, input_buf: integer }

        input_window.set_content(selected_item.content or selected_item.text)
        require('opencode.ui.mention').restore_mentions(windows.input_buf)
        input_window.focus_input()
      end
    end,
    title = 'Select History Entry',
    width = config.ui.picker_width or 100,
  })
end

return M
