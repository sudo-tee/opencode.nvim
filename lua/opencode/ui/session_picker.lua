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

--- Normalize message order to oldest-first (chronological)
--- API may return messages in descending order; reverse if detected.
---@param messages OpencodeMessage[]
---@return OpencodeMessage[]
local function normalize_message_order(messages)
  if not messages or #messages <= 1 then
    return messages or {}
  end
  -- Check if messages are in descending order by checking first two
  local first_time = messages[1].info and messages[1].info.time and messages[1].info.time.created
  local second_time = messages[2].info and messages[2].info.time and messages[2].info.time.created
  if first_time and second_time and first_time > second_time then
    local reversed = {}
    for i = #messages, 1, -1 do
      reversed[#reversed + 1] = messages[i]
    end
    return reversed
  end
  return messages
end

--- Append extmarks from source into target, offset by line_offset
--- Uses append semantics (no overwrite of same-line marks)
---@param target table<number, OutputExtmark[]> Target extmark map
---@param extmarks table<number, OutputExtmark[]> Source extmark map
---@param line_offset integer Line offset for source marks
local function append_extmarks(target, extmarks, line_offset)
  for line_idx, marks in pairs(extmarks or {}) do
    local actual = line_idx + line_offset
    target[actual] = target[actual] or {}
    for _, mark in ipairs(marks) do
      table.insert(target[actual], mark)
    end
  end
end

--- Filter messages for preview: keep first user message + last assistant message
--- This is a display strategy — format_messages is the rendering mechanism.
---@param messages OpencodeMessage[]
---@return OpencodeMessage[], integer omitted_count
local function filter_preview_messages(messages)
  if #messages <= 2 then
    return messages, 0
  end
  local first_user_idx = nil
  local last_assistant_idx = nil
  for i, msg in ipairs(messages) do
    if msg.info and msg.info.role == 'user' and not first_user_idx then
      first_user_idx = i
    end
    if msg.info and msg.info.role == 'assistant' then
      last_assistant_idx = i
    end
  end
  local result = {}
  if first_user_idx then
    table.insert(result, messages[first_user_idx])
  end
  if last_assistant_idx then
    table.insert(result, messages[last_assistant_idx])
  end
  if #result == 0 then
    return messages, 0
  end
  local omitted = #messages - #result
  return result, omitted
end

--- Format messages using the existing formatter, aggregating all Outputs
---@param messages OpencodeMessage[]
---@param omitted_count? integer Number of messages omitted between first and second (for preview)
---@return { lines: string[], extmarks: table<number, OutputExtmark[]>, fold_ranges: table<{from: integer, to: integer}> }
local function format_messages(messages, omitted_count)
  local formatter = require('opencode.ui.formatter')
  local all_lines = {}
  local all_extmarks = {}
  local all_fold_ranges = {}
  local line_offset = 0
  local rendered_count = 0

  for _, msg in ipairs(messages) do
    if msg.info and msg.info.role then
      -- Insert omitted notice between first and second rendered message
      if rendered_count == 1 and omitted_count and omitted_count > 0 then
        local notice = string.format('  ⋯ %d message(s) omitted ⋯', omitted_count)
        vim.list_extend(all_lines, { '', notice, '' })
        line_offset = line_offset + 3
      end

      -- Format message header (no previous_message: show full header in preview)
      local header = formatter.format_message_header(msg)
      vim.list_extend(all_lines, header.lines)
      append_extmarks(all_extmarks, header.extmarks, line_offset)
      for _, range in ipairs(header.fold_ranges or {}) do
        table.insert(all_fold_ranges, {
          from = range.from + line_offset,
          to = range.to + line_offset,
        })
      end
      line_offset = line_offset + #header.lines

      -- Format each part
      local parts = msg.parts or {}
      for part_idx, part in ipairs(parts) do
        local is_last = part_idx == #parts
        local ok, part_output = pcall(formatter.format_part, part, msg, is_last)
        if ok and part_output then
          vim.list_extend(all_lines, part_output.lines)
          append_extmarks(all_extmarks, part_output.extmarks, line_offset)
          for _, range in ipairs(part_output.fold_ranges or {}) do
            table.insert(all_fold_ranges, {
              from = range.from + line_offset,
              to = range.to + line_offset,
            })
          end
          line_offset = line_offset + #part_output.lines
        elseif not ok then
          -- Degraded: show error line for failed part
          table.insert(all_lines, '[render error]')
          line_offset = line_offset + 1
        end
        -- Note: Output.actions intentionally not collected (preview doesn't support interactive actions)
      end

      rendered_count = rendered_count + 1
    end
  end

  return {
    lines = all_lines,
    extmarks = all_extmarks,
    fold_ranges = all_fold_ranges,
  }
end

--- Write formatted output to a preview buffer
---@param target PickerPreviewTarget
---@param formatted { lines: string[], extmarks: table, fold_ranges: table }
local function render_preview_buffer(target, formatted)
  if not target:is_valid() then
    return
  end
  local bufnr = target:get_bufnr()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local output_window = require('opencode.ui.output_window')

  target:set_lines(formatted.lines)
  bufnr = target:get_bufnr()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Clear old extmarks then apply new ones
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, output_window.namespace, 0, -1)
  output_window.apply_extmarks(bufnr, formatted.extmarks)

  -- Apply folds (window-local operation)
    target:with_window(function()
      vim.api.nvim_set_option_value('number', false, { win = 0 })
      vim.api.nvim_set_option_value('relativenumber', false, { win = 0 })
      vim.api.nvim_set_option_value('foldmethod', 'manual', { win = 0 })
    vim.cmd('silent! normal! zE') -- clear existing manual folds
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    for _, range in ipairs(formatted.fold_ranges) do
      if range.from <= line_count and range.to <= line_count then
        vim.cmd(range.from .. ',' .. range.to .. 'fold')
      end
    end
  end)
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

  -- Preview state for race condition protection
  local preview_seq = 0

  return base_picker.pick({
    items = sessions,
    format_fn = format_session_item,
    actions = actions,
    callback = callback,
    title = 'Select A Session',
    width = config.ui.picker_width,
    layout_opts = config.ui.picker,
    preview = 'custom',
    ---@param session table
    ---@param target PickerPreviewTarget
    preview_fn = function(session, target)
      preview_seq = preview_seq + 1
      local current_seq = preview_seq
      target:set_lines({ 'Loading...' })

      local state = require('opencode.state')
      local ok, request = pcall(function()
        return state.api_client:list_messages(session.id, nil)
      end)
      if not ok or not request then
        target:set_lines({ 'No messages or failed to load' })
        return
      end

      request
        :and_then(function(messages)
          -- Check race: another selection happened while we were loading
          if current_seq ~= preview_seq then
            return
          end
          if not target:is_valid() then
            return
          end

          if not messages or #messages == 0 then
            target:set_lines({ 'No messages or failed to load' })
            return
          end

          messages = normalize_message_order(messages)
          local preview_msgs, omitted = filter_preview_messages(messages)
          local formatted = format_messages(preview_msgs, omitted)
          render_preview_buffer(target, formatted)
        end)
        :catch(function()
          if current_seq == preview_seq and target:is_valid() then
            target:set_lines({ 'No messages or failed to load' })
          end
        end)
    end,
  })
end

return M
