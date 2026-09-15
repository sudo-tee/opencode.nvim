local M = {}
local config = require('opencode.config')
local base_picker = require('opencode.ui.base_picker')
local picker = require('opencode.ui.picker')
local Promise = require('opencode.promise')
local session_tabs = require('opencode.state.session_tabs')
local session_runtime = require('opencode.services.session_runtime')

---@param tab OpencodeSessionTabRuntime
---@param width? integer
---@return PickerItem
local function format_tab_item(tab, width)
  local session = tab.active_session
  local title = session and session.title
  if type(title) ~= 'string' or vim.trim(title) == '' then
    title = 'New session'
  end

  local updated = session and session.time and session.time.updated
  return base_picker.create_time_picker_item(title, updated, 'ID: ' .. tab.id, width)
end

---@param tabs OpencodeSessionTabRuntime[]
---@param callback fun(tab: OpencodeSessionTabRuntime|nil)
---@return boolean
function M.pick(tabs, callback)
  if #tabs == 0 then
    vim.notify('No Opencode tabs', vim.log.levels.INFO)
    return false
  end

  local keymap = config.keymap.session_tab_picker
  local actions = {
    new = {
      key = keymap.new_tab,
      label = 'new',
      fn = Promise.async(function(_, opts)
        if opts.close then
          opts.close()
        end
        return session_runtime.open_session_tab():await()
      end),
    },
    close = {
      key = keymap.close_tab,
      label = 'close',
      fn = function(selected, opts)
        if opts.close then
          opts.close()
        end
        return session_runtime.close_session_tab(selected.id)
      end,
    },
  }

  return base_picker.pick({
    items = tabs,
    format_fn = format_tab_item,
    actions = actions,
    callback = callback,
    title = 'Opencode tabs',
    width = config.ui.picker_width,
    layout_opts = config.ui.picker,
  })
end

---@param callback? fun(tab: OpencodeSessionTabRuntime|nil)
function M.select(callback)
  local tabs = session_tabs.list()
  if #tabs == 0 then
    vim.notify('No Opencode tabs', vim.log.levels.INFO)
    return false
  end

  local on_select = callback
    or function(tab)
      if tab then
        session_runtime.switch_session_tab(tab.id)
      end
    end

  local picker_type = picker.get_best_picker()
  if picker_type == nil or picker_type == 'select' then
    picker.select(tabs, {
      prompt = 'Opencode tabs',
      format_item = function(tab)
        return format_tab_item(tab):to_string()
      end,
    }, on_select)
    return true
  end

  local success = M.pick(tabs, on_select)

  if not success then
    picker.select(tabs, {
      prompt = 'Opencode tabs',
      format_item = function(tab)
        return format_tab_item(tab):to_string()
      end,
    }, on_select)
  end
end

return M
