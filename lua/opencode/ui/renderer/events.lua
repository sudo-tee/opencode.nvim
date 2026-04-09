local state = require('opencode.state')
local config = require('opencode.config')
local ctx = require('opencode.ui.renderer.ctx')
local permission_window = require('opencode.ui.permission_window')
local flush = require('opencode.ui.renderer.flush')

---@param message OpencodeMessage|nil
---@return string|nil
local function get_last_part_for_message(message)
  if not message or not message.parts or #message.parts == 0 then
    return nil
  end
  for i = #message.parts, 1, -1 do
    local part = message.parts[i]
    if part.type ~= 'step-start' and part.type ~= 'step-finish' and part.id then
      return part.id
    end
  end
  return nil
end

---@param message OpencodeMessage|nil
---@return string|nil
local function find_text_part_for_message(message)
  if not message or not message.parts then
    return nil
  end
  for _, part in ipairs(message.parts) do
    if part.type == 'text' and not part.synthetic then
      return part.id
    end
  end
  return nil
end

-- Lazy require to avoid circular dependency: renderer.lua <-> events.lua
---@param force? boolean
local function scroll(force)
  require('opencode.ui.renderer').scroll_to_bottom(force)
end

local M = {}

---@param message_id string
---@param revert_index? integer
local function replay_orphan_parts(message_id, revert_index)
  local orphan_parts = ctx.render_state:consume_orphan_parts(message_id)
  for _, orphan_part in ipairs(orphan_parts) do
    M.on_part_updated({ part = orphan_part }, revert_index)
  end
end

---Update token/cost stats in state from a message
---@param message OpencodeMessage
local function update_stats(message)
  if not state.current_model and message.info.providerID and message.info.providerID ~= '' then
    state.model.set_model(message.info.providerID .. '/' .. message.info.modelID)
  end

  local tokens = message.info.tokens
  if tokens and tokens.input > 0 and message.info.cost and type(message.info.cost) == 'number' then
    state.renderer.set_stats(tokens.input + tokens.output + tokens.cache.read + tokens.cache.write, message.info.cost)
  elseif tokens and tokens.input > 0 then
    state.renderer.set_tokens_count(tokens.input + tokens.output + tokens.cache.read + tokens.cache.write)
  elseif message.info.cost and type(message.info.cost) == 'number' then
    state.renderer.set_cost(message.info.cost)
  end
end

---Render pending permissions as a synthetic part at the end of the buffer
function M.render_permissions_display()
  local permissions = permission_window.get_all_permissions()
  if not permissions or #permissions == 0 then
    flush.queue_part_removal('permission-display-part')
    flush.queue_message_removal('permission-display-message')
    return
  end

  local should_scroll = ctx.render_state:get_part('permission-display-part') == nil

  local fake_message = {
    info = {
      id = 'permission-display-message',
      sessionID = state.active_session and state.active_session.id or '',
      role = 'system',
    },
    parts = {},
  }
  M.on_message_updated(fake_message --[[@as OpencodeMessage]])

  local fake_part = {
    id = 'permission-display-part',
    messageID = 'permission-display-message',
    sessionID = state.active_session and state.active_session.id or '',
    type = 'permissions-display',
  }
  M.on_part_updated({ part = fake_part })

  if should_scroll then
    scroll(true)
  end
end

---Render the current question as a synthetic part at the end of the buffer
function M.render_question_display()
  local use_vim_ui = config.ui.questions and config.ui.questions.use_vim_ui_select
  if use_vim_ui then
    return
  end

  local question_window = require('opencode.ui.question_window')
  local current_question = question_window._current_question

  if not question_window.has_question() or not current_question or not current_question.id then
    flush.queue_part_removal('question-display-part')
    flush.queue_message_removal('question-display-message')
    return
  end

  local should_scroll = ctx.render_state:get_part('question-display-part') == nil

  local fake_message = {
    info = {
      id = 'question-display-message',
      sessionID = state.active_session and state.active_session.id or '',
      role = 'system',
    },
    parts = {},
  }
  M.on_message_updated(fake_message --[[@as OpencodeMessage]])

  local fake_part = {
    id = 'question-display-part',
    messageID = 'question-display-message',
    sessionID = state.active_session and state.active_session.id or '',
    type = 'questions-display',
  }
  M.on_part_updated({ part = fake_part })
  if should_scroll then
    scroll(true)
  end
end

---Remove the question display from the buffer
function M.clear_question_display()
  local use_vim_ui = config.ui.questions and config.ui.questions.use_vim_ui_select
  local question_window = require('opencode.ui.question_window')
  question_window.clear_question()

  if not use_vim_ui then
    flush.queue_part_removal('question-display-part')
    flush.queue_message_removal('question-display-message')
  end
end

---Handle message.updated — create the message header or update existing info
---@param message {info: MessageInfo}
---@param revert_index? integer
function M.on_message_updated(message, revert_index)
  if not state.active_session or not state.messages then
    return
  end

  local msg = message --[[@as OpencodeMessage]]
  if not msg or not msg.info or not msg.info.id or not msg.info.sessionID then
    return
  end

  if state.active_session.id ~= msg.info.sessionID then
    return
  end

  local rendered_message = ctx.render_state:get_message(msg.info.id)
  local found_msg = rendered_message and rendered_message.message

  if revert_index then
    if not found_msg then
      table.insert(state.messages, msg)
    end
    ctx.render_state:set_message(msg, 0, 0)
    replay_orphan_parts(msg.info.id, revert_index)
    return
  end

  if found_msg then
    local error_changed = not vim.deep_equal(found_msg.info.error, msg.info.error)
    found_msg.info = msg.info

    -- Errors arrive on the message but we display them after the last part.
    -- Re-render the last part (or the header if there are no parts) so the
    -- error appears in the right place.
    if error_changed then
      local last_part_id = get_last_part_for_message(found_msg)
      if last_part_id then
        flush.mark_part_dirty(last_part_id, msg.info.id)
      else
        flush.mark_message_dirty(msg.info.id)
      end
    end
  else
    table.insert(state.messages, msg)
    ctx.render_state:set_message(msg)
    replay_orphan_parts(msg.info.id)
    flush.mark_message_dirty(msg.info.id)
    state.renderer.set_current_message(msg)
    if message.info.role == 'user' then
      state.renderer.set_last_user_message(msg)
      scroll(true)
    end
  end

  update_stats(msg)
end

---Handle message.removed — remove the message and all its parts from the buffer
---@param properties {sessionID: string, messageID: string}
function M.on_message_removed(properties)
  if not properties or not state.messages then
    return
  end

  local message_id = properties.messageID
  if not message_id then
    return
  end

  local rendered_message = ctx.render_state:get_message(message_id)
  ctx.render_state:clear_orphan_parts(message_id)
  if not rendered_message or not rendered_message.message then
    return
  end

  for _, part in ipairs(rendered_message.message.parts or {}) do
    if part.id then
      flush.queue_part_removal(part.id)
    end
  end

  flush.queue_message_removal(message_id)

  for i, msg in ipairs(state.messages or {}) do
    if msg.info.id == message_id then
      table.remove(state.messages, i)
      break
    end
  end
end

---Handle message.part.updated — insert or replace a part in the buffer
---@param properties {part: OpencodeMessagePart}
---@param revert_index? integer
function M.on_part_updated(properties, revert_index)
  if not properties or not properties.part or not state.active_session then
    return
  end

  local part = properties.part
  if not part.id or not part.messageID or not part.sessionID then
    return
  end

  -- Child-session parts: update the task-tool display instead
  if state.active_session.id ~= part.sessionID then
    if part.tool or part.type == 'tool' then
      ctx.render_state:upsert_child_session_part(part.sessionID, part)
      local task_part_id = ctx.render_state:get_task_part_by_child_session(part.sessionID)
      if task_part_id then
        flush.mark_part_dirty(task_part_id)
      end
    end
    return
  end

  local rendered_message = ctx.render_state:get_message(part.messageID)
  if not rendered_message or not rendered_message.message then
    ctx.render_state:upsert_orphan_part(part.messageID, part)
    return
  end

  local message = rendered_message.message
  message.parts = message.parts or {}

  local part_data = ctx.render_state:get_part(part.id)
  local is_new_part = not part_data

  local prev_last_part_id = get_last_part_for_message(message)

  -- Update the part reference in the message
  if is_new_part then
    table.insert(message.parts, part)
  else
    for i = #message.parts, 1, -1 do
      if message.parts[i].id == part.id then
        message.parts[i] = part
        break
      end
    end
  end

  -- step-start / step-finish are bookkeeping only — nothing to render
  if part.type == 'step-start' or part.type == 'step-finish' then
    return
  end

  if is_new_part then
    ctx.render_state:set_part(part)
  else
    local rendered_part = ctx.render_state:update_part_data(part)
    -- Part known but never rendered yet — treat as new
    if not rendered_part or (not rendered_part.line_start and not rendered_part.line_end) then
      is_new_part = true
    end
  end

  -- Update the permission window if this part has a pending permission
  if part.callID and state.pending_permissions then
    for _, permission in ipairs(state.pending_permissions) do
      local tool = permission.tool
      local perm_callID = tool and tool.callID or permission.callID
      local perm_messageID = tool and tool.messageID or permission.messageID
      if perm_callID == part.callID and perm_messageID == part.messageID then
        permission_window.update_permission_from_part(permission.id, part)
        break
      end
    end
  end

  if revert_index and is_new_part then
    return
  end

  if is_new_part then
    flush.mark_part_dirty(part.id, part.messageID)

    -- If there's already an error on this message, adjust adjacent parts so
    -- the error only appears after the last part.
    if message.info.error then
      if not prev_last_part_id then
        flush.mark_message_dirty(part.messageID)
      elseif prev_last_part_id ~= part.id then
        flush.mark_part_dirty(prev_last_part_id, part.messageID)
      end
    end
  else
    flush.mark_part_dirty(part.id, part.messageID)
  end

  -- File / agent mentions: re-render the text part to highlight them
  if (part.type == 'file' or part.type == 'agent') and part.source then
    local text_part_id = find_text_part_for_message(message)
    if text_part_id then
      flush.mark_part_dirty(text_part_id, part.messageID)
    end
  end
end

---Handle message.part.removed
---@param properties {sessionID: string, messageID: string, partID: string}
function M.on_part_removed(properties)
  if not properties then
    return
  end

  local part_id = properties.partID
  if not part_id then
    return
  end

  if properties.messageID and ctx.render_state:remove_orphan_part(properties.messageID, part_id) then
    return
  end

  -- Remove the part from the in-memory message too
  local cached = ctx.render_state:get_part(part_id)
  local message_id = cached and cached.message_id
  if message_id then
    local rendered_message = ctx.render_state:get_message(message_id)
    if rendered_message and rendered_message.message and rendered_message.message.parts then
      for i, part in ipairs(rendered_message.message.parts) do
        if part.id == part_id then
          table.remove(rendered_message.message.parts, i)
          break
        end
      end
    end
  end

  flush.queue_part_removal(part_id)

  -- Mark message dirty so header (timestamp, etc.) gets re-rendered
  if message_id then
    flush.mark_message_dirty(message_id)
  end
end

---Handle session.updated — re-render the full session if the revert state changed
---@param properties {info: Session}
function M.on_session_updated(properties)
  if not properties or not properties.info or not state.active_session then
    return
  end

  local updated_session = properties.info
  if not updated_session.id or updated_session.id ~= state.active_session.id then
    return
  end

  local current_session = state.active_session
  local revert_changed = not vim.deep_equal(current_session.revert, updated_session.revert)

  if not vim.deep_equal(current_session, updated_session) then
    -- Set without emitting a change event to avoid a double re-render
    state.store.set_raw('active_session', updated_session)
  end

  if revert_changed then
    local real_messages = vim.tbl_filter(function(msg)
      return not (msg.info and msg.info.id and msg.info.id:match('^__opencode_'))
    end, state.messages or {})
    require('opencode.ui.renderer')._render_full_session_data(real_messages)
  end
end

---Handle session.compacted
function M.on_session_compacted()
  vim.notify('Session has been compacted')
end

---Handle session.error
---@param properties {sessionID: string, error: table}
function M.on_session_error(properties)
  if not properties or not properties.error then
    return
  end
  if config.debug.enabled then
    vim.notify('Session error: ' .. vim.inspect(properties.error))
  end
end

---Handle permission.updated / permission.asked
---@param permission OpencodePermission
function M.on_permission_updated(permission)
  if not permission or not permission.id then
    return
  end

  local tool = permission.tool
  local callID = tool and tool.callID or permission.callID
  local messageID = tool and tool.messageID or permission.messageID

  if not state.pending_permissions then
    state.renderer.set_pending_permissions({})
  end

  local existing_index = nil
  for i, existing in ipairs(state.pending_permissions) do
    if existing.id == permission.id then
      existing_index = i
      break
    end
  end

  state.renderer.update_pending_permissions(function(permissions)
    if existing_index then
      permissions[existing_index] = permission
    else
      table.insert(permissions, permission)
    end
  end)

  permission_window.add_permission(permission)
  M.render_permissions_display()
end

---Handle permission.replied — remove the resolved permission and update display
---@param properties {sessionID: string, permissionID?: string, requestID?: string, response: string}
function M.on_permission_replied(properties)
  if not properties then
    return
  end

  local permission_id = properties.permissionID or properties.requestID
  if not permission_id then
    return
  end

  permission_window.remove_permission(permission_id)
  state.renderer.set_pending_permissions(vim.deepcopy(permission_window.get_all_permissions()))

  if #state.pending_permissions == 0 then
    flush.queue_part_removal('permission-display-part')
    flush.queue_message_removal('permission-display-message')
  else
    M.render_permissions_display()
  end
end

---Handle question.asked — show the question picker UI
---@param properties OpencodeQuestionRequest
function M.on_question_asked(properties)
  if not properties or not properties.id or not properties.questions then
    return
  end
  require('opencode.ui.question_window').show_question(properties)
end

---Handle file.edited — reload buffers and fire the hook
---@param properties {file: string}
function M.on_file_edited(properties)
  vim.cmd('checktime')
  if config.hooks and config.hooks.on_file_edited then
    pcall(config.hooks.on_file_edited, properties.file)
  end
end

---Handle custom.restore_point.created
---@param properties RestorePointCreatedEvent
function M.on_restore_points(properties)
  state.store.append('restore_points', properties.restore_point)
  if not properties or not properties.restore_point or not properties.restore_point.from_snapshot_id then
    return
  end
  local part = ctx.render_state:get_part_by_snapshot_id(properties.restore_point.from_snapshot_id)
  if part then
    M.on_part_updated({ part = part })
  end
end

return M
