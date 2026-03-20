local state = require('opencode.state')
local config = require('opencode.config')
local formatter = require('opencode.ui.formatter')
local permission_window = require('opencode.ui.permission_window')

---Event handlers for the renderer.
---
---Each handler is a plain function that takes an event-properties table and
---a context table `ctx` supplied by the renderer init module.
---`ctx` exposes:
---   ctx.render_state  RenderState
---   ctx.buf           buffer module (renderer/buffer.lua)
---   ctx.last_formatted { part_id, formatted_data }  (mutated in-place)
---   ctx.scroll_to_bottom(force?)
---   ctx.render_full_session()
local M = {}

-- ─── Helpers ──────────────────────────────────────────────────────────────────

---Return the ID of the last non-step part in a message, or nil.
---@param message OpencodeMessage
---@return string?
local function last_part_id(message)
  if not message or not message.parts or #message.parts == 0 then
    return nil
  end
  for i = #message.parts, 1, -1 do
    local p = message.parts[i]
    if p.type ~= 'step-start' and p.type ~= 'step-finish' and p.id then
      return p.id
    end
  end
  return nil
end

---Return the ID of the first non-synthetic text part in a message, or nil.
---@param message OpencodeMessage
---@return string?
local function first_text_part_id(message)
  if not message or not message.parts then
    return nil
  end
  for _, p in ipairs(message.parts) do
    if p.type == 'text' and not p.synthetic then
      return p.id
    end
  end
  return nil
end

---Re-render an existing part using current message state.
---@param ctx table Renderer context
---@param part_id string
local function rerender_part(ctx, part_id)
  local cached = ctx.render_state:get_part(part_id)
  if not cached or not cached.part then
    return
  end

  local rendered_message = ctx.render_state:get_message(cached.message_id)
  if not rendered_message or not rendered_message.message then
    return
  end

  local message = rendered_message.message
  local is_last = last_part_id(message) == part_id
  local formatted = formatter.format_part(cached.part, message, is_last, function(session_id)
    return ctx.render_state:get_child_session_parts(session_id)
  end)

  ctx.buf.replace_part(ctx.render_state, part_id, formatted, ctx.last_formatted)
end

---Update display stats from a single message.
---@param message OpencodeMessage
local function update_stats(message)
  if not state.current_model and message.info.providerID and message.info.providerID ~= '' then
    state.model.set_model(message.info.providerID .. '/' .. message.info.modelID)
  end

  local tokens = message.info.tokens
  if tokens and tokens.input > 0 and message.info.cost and type(message.info.cost) == 'number' then
    state.renderer.set_stats(
      tokens.input + tokens.output + tokens.cache.read + tokens.cache.write,
      message.info.cost
    )
  elseif tokens and tokens.input > 0 then
    state.renderer.set_tokens_count(tokens.input + tokens.output + tokens.cache.read + tokens.cache.write)
  elseif message.info.cost and type(message.info.cost) == 'number' then
    state.renderer.set_cost(message.info.cost)
  end
end

-- ─── Event handlers ───────────────────────────────────────────────────────────

---@param ctx table
---@param message {info: MessageInfo}
---@param revert_index? integer
function M.on_message_updated(ctx, message, revert_index)
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

  local rendered = ctx.render_state:get_message(msg.info.id)
  local existing = rendered and rendered.message

  if revert_index then
    if not existing then
      table.insert(state.messages, msg)
    end
    ctx.render_state:set_message(msg, 0, 0)
    return
  end

  if existing then
    local error_changed = not vim.deep_equal(existing.info.error, msg.info.error)
    existing.info = msg.info

    if error_changed then
      local lp = last_part_id(existing)
      if lp then
        rerender_part(ctx, lp)
      else
        local header = formatter.format_message_header(existing)
        ctx.buf.replace_message(ctx.render_state, msg.info.id, header)
      end
    end
  else
    table.insert(state.messages, msg)
    ctx.buf.add_message(ctx.render_state, formatter, msg)
    state.renderer.set_current_message(msg)
    if msg.info.role == 'user' then
      state.renderer.set_last_user_message(msg)
    end
  end

  update_stats(msg)
end

---@param ctx table
---@param properties {part: OpencodeMessagePart}
---@param revert_index? integer
function M.on_part_updated(ctx, properties, revert_index)
  if not properties or not properties.part or not state.active_session then
    return
  end

  local part = properties.part
  if not part.id or not part.messageID or not part.sessionID then
    return
  end

  if state.active_session.id ~= part.sessionID then
    if part.tool or part.type == 'tool' then
      ctx.render_state:upsert_child_session_part(part.sessionID, part)
      local task_part_id = ctx.render_state:get_task_part_by_child_session(part.sessionID)
      if task_part_id then
        rerender_part(ctx, task_part_id)
      end
    end
    return
  end

  local rendered_message = ctx.render_state:get_message(part.messageID)
  if not rendered_message or not rendered_message.message then
    vim.notify('Could not find message for part: ' .. vim.inspect(part), vim.log.levels.WARN)
    return
  end

  local message = rendered_message.message
  message.parts = message.parts or {}

  local part_data = ctx.render_state:get_part(part.id)
  local is_new = not part_data

  local prev_last = last_part_id(message)
  local is_last = is_new or (prev_last == part.id)

  if is_new then
    table.insert(message.parts, part)
  else
    for i = #message.parts, 1, -1 do
      if message.parts[i].id == part.id then
        message.parts[i] = part
        break
      end
    end
  end

  if part.type == 'step-start' or part.type == 'step-finish' then
    return
  end

  if is_new then
    ctx.render_state:set_part(part)
  else
    local rendered_part = ctx.render_state:update_part_data(part)
    if not rendered_part or (not rendered_part.line_start and not rendered_part.line_end) then
      is_new = true
    end
  end

  local formatted = formatter.format_part(part, message, is_last, function(session_id)
    return ctx.render_state:get_child_session_parts(session_id)
  end)

  -- Sync permission window when a tool part arrives.
  if part.callID and state.pending_permissions then
    for _, perm in ipairs(state.pending_permissions) do
      local tool = perm.tool
      local cid = tool and tool.callID or perm.callID
      local mid = tool and tool.messageID or perm.messageID
      if cid == part.callID and mid == part.messageID then
        require('opencode.ui.permission_window').update_permission_from_part(perm.id, part)
        break
      end
    end
  end

  if revert_index and is_new then
    return
  end

  if is_new then
    ctx.buf.insert_part(ctx.render_state, part.id, formatted, ctx.last_formatted)

    -- When a new part arrives but the message already has an error, re-render
    -- the previously-last part so it doesn't duplicate the error display.
    if message.info.error then
      if not prev_last then
        local header = formatter.format_message_header(message)
        ctx.buf.replace_message(ctx.render_state, part.messageID, header)
      elseif prev_last ~= part.id then
        rerender_part(ctx, prev_last)
      end
    end
  else
    ctx.buf.replace_part(ctx.render_state, part.id, formatted, ctx.last_formatted)
  end

  -- Mentions: re-render the text part to show highlights.
  if (part.type == 'file' or part.type == 'agent') and part.source then
    local text_id = first_text_part_id(message)
    if text_id then
      rerender_part(ctx, text_id)
    end
  end
end

---@param ctx table
---@param properties {sessionID: string, messageID: string, partID: string}
function M.on_part_removed(ctx, properties)
  if not properties then
    return
  end

  local part_id = properties.partID
  if not part_id then
    return
  end

  local cached = ctx.render_state:get_part(part_id)
  if cached and cached.message_id then
    local rendered_msg = ctx.render_state:get_message(cached.message_id)
    if rendered_msg and rendered_msg.message and rendered_msg.message.parts then
      local parts = rendered_msg.message.parts
      for i, p in ipairs(parts) do
        if p.id == part_id then
          table.remove(parts, i)
          break
        end
      end
    end
  end

  ctx.buf.remove_part(ctx.render_state, part_id)
end

---@param ctx table
---@param properties {sessionID: string, messageID: string}
function M.on_message_removed(ctx, properties)
  if not properties or not state.messages then
    return
  end

  local message_id = properties.messageID
  if not message_id then
    return
  end

  local rendered = ctx.render_state:get_message(message_id)
  if not rendered or not rendered.message then
    return
  end

  for _, p in ipairs(rendered.message.parts or {}) do
    if p.id then
      ctx.buf.remove_part(ctx.render_state, p.id)
    end
  end

  ctx.buf.remove_message(ctx.render_state, message_id)

  for i, msg in ipairs(state.messages or {}) do
    if msg.info.id == message_id then
      table.remove(state.messages, i)
      break
    end
  end
end

---@param properties {info: Session}
function M.on_session_updated(ctx, properties)
  if not properties or not properties.info or not state.active_session then
    return
  end

  local updated = properties.info
  if not updated.id or updated.id ~= state.active_session.id then
    return
  end

  local current = state.active_session
  local revert_changed = not vim.deep_equal(current.revert, updated.revert)
  if not vim.deep_equal(current, updated) then
    state.store.set_raw('active_session', updated)
  end

  if revert_changed then
    ctx.render_full_session()
  end
end

function M.on_session_compacted(_ctx)
  vim.notify('Session has been compacted')
end

---@param _ctx table
---@param properties {sessionID: string, error: table}
function M.on_session_error(_ctx, properties)
  if not properties or not properties.error then
    return
  end
  if config.debug.enabled then
    vim.notify('Session error: ' .. vim.inspect(properties.error))
  end
end

---@param ctx table
---@param permission OpencodePermission
function M.on_permission_updated(ctx, permission)
  local tool = permission.tool
  local callID = tool and tool.callID or permission.callID
  local messageID = tool and tool.messageID or permission.messageID

  if not permission or not messageID or not callID then
    return
  end

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

  state.renderer.update_pending_permissions(function(perms)
    if existing_index then
      perms[existing_index] = permission
    else
      table.insert(perms, permission)
    end
  end)

  permission_window.add_permission(permission)
  ctx.render_permissions_display()
  rerender_part(ctx, 'permission-display-part')
  ctx.scroll_to_bottom(true)
end

---@param ctx table
---@param properties {sessionID: string, permissionID?: string, requestID?: string, response: string}
function M.on_permission_replied(ctx, properties)
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
    ctx.buf.remove_part(ctx.render_state, 'permission-display-part')
    ctx.buf.remove_message(ctx.render_state, 'permission-display-message')
  end

  rerender_part(ctx, 'permission-display-part')
end

---@param ctx table
---@param properties OpencodeQuestionRequest
function M.on_question_asked(ctx, properties)
  if not properties or not properties.id or not properties.questions then
    return
  end
  local question_window = require('opencode.ui.question_window')
  question_window.show_question(properties)
end

---@param ctx table
function M.on_focus_changed(ctx)
  local current_permission = permission_window.get_all_permissions()[1]
  if not current_permission then
    return
  end
  rerender_part(ctx, 'permission-display-part')
end

---@param _ctx table
---@param properties {file: string}
function M.on_file_edited(_ctx, properties)
  vim.cmd('checktime')
  if config.hooks and config.hooks.on_file_edited then
    pcall(config.hooks.on_file_edited, properties.file)
  end
end

---@param ctx table
---@param properties RestorePointCreatedEvent
function M.on_restore_points(ctx, properties)
  state.store.append('restore_points', properties.restore_point)
  if not properties or not properties.restore_point or not properties.restore_point.from_snapshot_id then
    return
  end
  local part = ctx.render_state:get_part_by_snapshot_id(properties.restore_point.from_snapshot_id)
  if part then
    M.on_part_updated(ctx, { part = part })
  end
end


