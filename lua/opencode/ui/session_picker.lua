local M = {}
local config = require('opencode.config')
local base_picker = require('opencode.ui.base_picker')
local util = require('opencode.util')
local api = require('opencode.api')
local Promise = require('opencode.promise')

---Check whether any session id in `delete_ids` is the session itself or an ancestor
---@param session_id string
---@param delete_ids table<string, boolean>
---@param all_sessions Session[]
---@return boolean
function M._is_session_or_ancestor_deleted(session_id, delete_ids, all_sessions)
  local session_map = {}
  for _, s in ipairs(all_sessions) do
    session_map[s.id] = s
  end

  local current_id = session_id
  while current_id do
    if delete_ids[current_id] then
      return true
    end
    local s = session_map[current_id]
    current_id = s and s.parentID or nil
  end
  return false
end

---Format session parts for session picker
---@param session Session object
---@return PickerItem
function format_session_item(session, width)
  local debug_text = 'ID: ' .. (session.id or 'N/A')
  local updated_time = (session.time and session.time.updated) or 'N/A'
  return base_picker.create_time_picker_item(session.title, updated_time, debug_text, width)
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
      fn = Promise.async(function(selected, opts)
        local state = require('opencode.state')
        local session_runtime = require('opencode.services.session_runtime')

        local sessions_to_delete = type(selected) == 'table' and selected.id == nil and selected or { selected }

        local to_delete_ids = {}
        for _, s in ipairs(sessions_to_delete) do
          to_delete_ids[s.id] = true
        end

        local deleting_current = false
        if state.active_session then
          local session_mod = require('opencode.session')
          local all_sessions = session_mod.get_all_workspace_sessions():await() or {}
          deleting_current = M._is_session_or_ancestor_deleted(state.active_session.id, to_delete_ids, all_sessions)
        end

        if deleting_current then
          local remaining = vim.tbl_filter(function(item)
            return not to_delete_ids[item.id]
          end, opts.items or {})

          if #remaining > 0 then
            session_runtime.switch_session(remaining[1].id):await()
          else
            vim.notify('deleting current session, creating new session')
            state.model.clear()
            require('opencode.services.agent_model').ensure_current_mode():await()
            state.session.set_active(session_runtime.create_new_session():await())
          end
        end

        for _, session in ipairs(sessions_to_delete) do
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
      end),
      reload = true,
    },
    new = {
      key = config.keymap.session_picker.new_session,
      label = 'new',
      fn = Promise.async(function(selected, opts)
        local session_runtime = require('opencode.services.session_runtime')
        local parent_id
        for _, s in ipairs(opts.items or {}) do
          if s.parentID ~= nil then
            parent_id = s.parentID
            break
          end
        end

        local new_session = session_runtime.create_new_session(parent_id and { parentID = parent_id } or false):await()
        if new_session then
          table.insert(opts.items, 1, new_session)
          return opts.items
        end
      end),
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
    layout_opts = config.ui.picker,
  })
end

return M
