local M = {}
local config = require('opencode.config')
local base_picker = require('opencode.ui.base_picker')

---Format session parts for session picker
---@param session Session object
---@return PickerItem
function format_session_item(session, width)
  local debug_text = 'ID: ' .. (session.id or 'N/A')
  return base_picker.create_picker_item(session.description, session.modified, debug_text, width)
end

function M.pick(sessions, callback)
  local actions = {
    delete = {
      key = config.keymap.session_picker.delete_session,
      label = 'delete',
      fn = function(selected, opts)
        local state = require('opencode.state')

        local session_id_to_delete = selected.id

        if state.active_session and state.active_session.id == selected.id then
          vim.notify('deleting current session, creating new session')
          state.active_session = require('opencode.core').create_new_session()
        end

        state.api_client:delete_session(session_id_to_delete):catch(function(err)
          vim.schedule(function()
            vim.notify('Failed to delete session: ' .. vim.inspect(err), vim.log.levels.ERROR)
          end)
        end)

        local idx = vim.fn.index(opts.items, selected) + 1
        if idx > 0 then
          table.remove(opts.items, idx)
        end
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
