local state = require('opencode.state')
local ctx = require('opencode.ui.renderer.ctx')
local flush = require('opencode.ui.renderer.flush')
local symbol_snapshot = require('opencode.ui.symbol_snapshot')

local M = {}
local REFRESH_INTERVAL_MS = 1

local function find_message_in_state(message_id)
  for _, message in ipairs(state.messages or {}) do
    if message.info and message.info.id == message_id then
      return message
    end
  end
  return nil
end

local function is_assistant_message(message)
  return message and message.info and message.info.role == 'assistant'
end

local function is_rendered_assistant_text_part(part_id, active_session_id)
  local part_data = ctx.render_state:get_part(part_id)
  local part = part_data and part_data.part
  if
    not part
    or part.type ~= 'text'
    or not part.text
    or part.synthetic
    or not part_data.line_start
    or not part_data.line_end
  then
    return false
  end

  local message_data = ctx.render_state:get_message(part_data.message_id)
  local message = message_data and message_data.message or find_message_in_state(part_data.message_id)
  return is_assistant_message(message) and message.info.sessionID == active_session_id
end

local function rendered_assistant_text_part_ids(active_session_id)
  local part_ids = {}
  for part_id in pairs(ctx.render_state._parts or {}) do
    if is_rendered_assistant_text_part(part_id, active_session_id) then
      part_ids[#part_ids + 1] = part_id
    end
  end
  return part_ids
end

local function mark_part_dirty(part_id, active_session_id)
  if not is_rendered_assistant_text_part(part_id, active_session_id) then
    return
  end

  local part_data = ctx.render_state:get_part(part_id)
  ctx.formatted_parts[part_id] = nil
  flush.mark_part_dirty(part_id, part_data.message_id)
end

local function mark_all_parts_dirty()
  local active_session_id = state.active_session and state.active_session.id
  if not active_session_id then
    return
  end

  for part_id in pairs(ctx.render_state._parts or {}) do
    mark_part_dirty(part_id, active_session_id)
  end
end

local function finish_refresh(refresh_token)
  ctx.symbol_refresh_pending = false
  vim.schedule(function()
    if ctx.symbol_refresh_token == refresh_token then
      ctx.symbol_refresh_cycle = nil
    end
  end)
end

function M.invalidate()
  ctx.symbol_refresh_pending = false
  ctx.symbol_refresh_token = ctx.symbol_refresh_token + 1
  ctx.symbol_refresh_cycle = nil
  require('opencode.ui.reference_facts').refresh_current_files()
  mark_all_parts_dirty()
end

function M.refresh()
  local active_session_id = state.active_session and state.active_session.id
  if not active_session_id then
    return
  end

  local reference_facts = require('opencode.ui.reference_facts')
  reference_facts.refresh_current_files()
  local candidate_files = reference_facts.available_files()
  local part_ids = rendered_assistant_text_part_ids(active_session_id)
  local refresh_token = ctx.symbol_refresh_token + 1
  ctx.symbol_refresh_token = refresh_token
  ctx.symbol_refresh_pending = true
  ctx.symbol_refresh_cycle = symbol_snapshot.new_cycle()

  local next_candidate = 1
  local next_part = 1
  local function is_current_refresh()
    if ctx.symbol_refresh_token ~= refresh_token then
      return false
    end
    if not state.active_session or state.active_session.id ~= active_session_id then
      finish_refresh(refresh_token)
      return false
    end
    return true
  end

  local function refresh_next_part()
    if not is_current_refresh() then
      return
    end
    local part_id = part_ids[next_part]
    if part_id then
      mark_part_dirty(part_id, active_session_id)
      next_part = next_part + 1
      vim.defer_fn(refresh_next_part, REFRESH_INTERVAL_MS)
    else
      finish_refresh(refresh_token)
    end
  end

  local function warm_next_candidate()
    if not is_current_refresh() then
      return
    end

    local path = candidate_files[next_candidate]
    if path then
      local cycle = ctx.symbol_refresh_cycle
      if cycle and type(cycle.warm_path) == 'function' then
        pcall(cycle.warm_path, cycle, path)
      end
      next_candidate = next_candidate + 1
      vim.defer_fn(warm_next_candidate, REFRESH_INTERVAL_MS)
    else
      vim.defer_fn(refresh_next_part, REFRESH_INTERVAL_MS)
    end
  end

  vim.defer_fn(warm_next_candidate, REFRESH_INTERVAL_MS)
end

return M
