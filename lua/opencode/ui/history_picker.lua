local config = require('opencode.config')
local base_picker = require('opencode.ui.base_picker')
local history = require('opencode.history')
local state = require('opencode.state')

local M = {}

local function preview_text(entry)
  local lines = entry.prompt and entry.prompt.lines or {}
  return table.concat(lines, '\n')
end

---@param entry OpencodeHistoryEntry
---@param width number
---@return PickerItem
local function format_history_item(entry, width)
  local preview = preview_text(entry):gsub('\n', '↵')
  return base_picker.create_time_picker_item(preview, nil, 'ID: ' .. entry.id, width)
end

---Open the history picker for the active session. Reads from the in-memory
---message cache when it has data; otherwise fetches the active session's
---messages from the server so the picker is never empty just because SSE has
---not yet caught up.
---@param callback? fun(prompt: string[])
function M.pick(callback)
  local entries = history.read()
  if #entries > 0 then
    return M._render(entries, callback)
  end

  history
    .refresh()
    :and_then(function(entries)
      if entries and #entries > 0 then
        M._render(entries, callback)
      else
        vim.notify('No history entries found', vim.log.levels.INFO)
      end
    end)
    :catch(function()
      vim.notify('No history entries found', vim.log.levels.INFO)
    end)
  return true
end

---@param entries OpencodeHistoryEntry[]
---@param callback? fun(prompt: string[])
function M._render(entries, callback)
  return base_picker.pick({
    items = entries,
    format_fn = format_history_item,
    actions = {},
    callback = function(selected_entry)
      if not selected_entry then
        return
      end
      if callback then
        callback(selected_entry.prompt.lines)
        return
      end

      local input_window = require('opencode.ui.input_window')
      local windows = state.windows
      if not input_window.mounted(windows) then
        require('opencode.services.session_runtime').open({ focus = 'input' })
        windows = state.windows
      end
      if not input_window.mounted(windows) then
        return
      end
      ---@cast windows { input_win: integer, input_buf: integer }

      if input_window.refill_prompt_from_message(selected_entry.message) then
        input_window.focus_input()
      end
    end,
    title = 'Select History Entry',
    width = config.ui.picker_width,
    layout_opts = config.ui.picker,
  })
end

return M
