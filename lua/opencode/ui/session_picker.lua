local M = {}
local config = require('opencode.config')
local base_picker = require('opencode.ui.base_picker')
local util = require('opencode.util')
local api = require('opencode.api')

---Format session parts for session picker
---@param session Session object
---@return PickerItem
function format_session_item(session, width)
  local debug_text = 'ID: ' .. (session.id or 'N/A')
  return base_picker.create_picker_item(session.title, session.modified, debug_text, width)
end

function M.pick(sessions, callback)
  local actions = {
    rename = {
      key = config.keymap.session_picker.rename_session,
      label = 'rename',
      fn = function(selected, opts)
        local promise = require('opencode.promise').new()
        api
          .rename_session(selected)
          :and_then(function(updated_session)
            if not updated_session then
              promise:resolve(nil)
              return
            end
            local idx = util.find_index_of(opts.items, function(item)
              return item.id == updated_session.id
            end)
            if idx > 0 then
              opts.items[idx] = updated_session
            end
            promise:resolve(opts.items)
          end)
          :catch(function(err)
            vim.schedule(function()
              vim.notify('Failed to rename session: ' .. vim.inspect(err), vim.log.levels.ERROR)
              promise:resolve(nil)
            end)
          end)

        return promise
      end,
      reload = true,
    },
    delete = {
      key = config.keymap.session_picker.delete_session,
      label = 'delete',
      multi_selection = true,
      fn = function(selected, opts)
        local state = require('opencode.state')

        local sessions_to_delete = type(selected) == 'table' and selected.id == nil and selected or { selected }

        for _, session in ipairs(sessions_to_delete) do
          if state.active_session and state.active_session.id == session.id then
            vim.notify('deleting current session, creating new session')
            state.active_session = require('opencode.core').create_new_session()
          end

          state.api_client:delete_session(session.id):catch(function(err)
            vim.schedule(function()
              vim.notify('Failed to delete session ' .. session.id .. ': ' .. vim.inspect(err), vim.log.levels.ERROR)
            end)
          end)

          local idx = util.find_index_of(opts.items, function(item)
            return item.id == session.id
          end)
          if idx > 0 then
            table.remove(opts.items, idx)
          end
        end

        vim.notify('Deleted ' .. #sessions_to_delete .. ' session(s)', vim.log.levels.INFO)
        return opts.items
      end,
      reload = true,
    },
    new = {
      key = config.keymap.session_picker.new_session,
      label = 'new',
      fn = function(selected, opts)
        local parent_id
        for _, s in ipairs(opts.items or {}) do
          if s.parentID ~= nil then
            parent_id = s.parentID
            break
          end
        end
        local state = require('opencode.state')
        local created = state.api_client:create_session(parent_id and { parentID = parent_id } or false):wait()
        if created and created.id then
          local new_session = require('opencode.session').get_by_id(created.id)
          table.insert(opts.items, 1, new_session)
          return opts.items
        end
        return nil
      end,
      reload = true,
    },
  }

  return base_picker.pick({
    items = sessions,
    format_fn = format_session_item,
    actions = actions,
    callback = callback,
    title = 'Select A Session',
    width = config.ui.picker_width or 100,
  })
end

return M
