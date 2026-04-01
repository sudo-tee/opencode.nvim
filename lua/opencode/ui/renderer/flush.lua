local state = require('opencode.state')
local config = require('opencode.config')
local formatter = require('opencode.ui.formatter')
local output_window = require('opencode.ui.output_window')
local ctx = require('opencode.ui.renderer.ctx')
local scroll = require('opencode.ui.renderer.scroll')
local buffer = require('opencode.ui.renderer.buffer')
local append = require('opencode.ui.renderer.append')

local M = {}

local function with_suppressed_output_autocmds(fn)
  local output_win = state.windows and state.windows.output_win
  local has_output_win = output_win and vim.api.nvim_win_is_valid(output_win)
  local saved_eventignorewin = has_output_win and vim.api.nvim_get_option_value('eventignorewin', { win = output_win })
    or nil

  if has_output_win then
    vim.api.nvim_set_option_value('eventignorewin', 'all', { win = output_win, scope = 'local' })
  end

  local begin_ok, began_update = xpcall(output_window.begin_update, debug.traceback)
  if not begin_ok then
    if has_output_win then
      vim.api.nvim_set_option_value('eventignorewin', saved_eventignorewin, { win = output_win, scope = 'local' })
    end
    error(began_update)
  end

  local ok, result = xpcall(fn, debug.traceback)
  local end_ok, end_err = true, nil

  if began_update then
    end_ok, end_err = xpcall(output_window.end_update, debug.traceback)
  end
  if has_output_win then
    vim.api.nvim_set_option_value('eventignorewin', saved_eventignorewin, { win = output_win, scope = 'local' })
  end

  if not ok then
    error(result)
  end
  if not end_ok then
    error(end_err)
  end

  return result
end

local function lines_equal(a, b)
  a = a or {}
  b = b or {}
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

local function resolve_mark(m)
  return type(m) == 'function' and m() or m
end

local function extmarks_equal(a, b)
  a = a or {}
  b = b or {}
  for k, va in pairs(a) do
    local vb = b[k]
    if not vb or #va ~= #vb then
      return false
    end
    for i = 1, #va do
      if not vim.deep_equal(resolve_mark(va[i]), resolve_mark(vb[i])) then
        return false
      end
    end
  end
  for k in pairs(b) do
    if not a[k] then
      return false
    end
  end
  return true
end

local function is_markdown_render_deferred()
  if not config.ui.output.rendering.markdown_on_idle then
    return false
  end

  local active_session = state.active_session
  local session_id = active_session and active_session.id
  if not session_id then
    return false
  end

  local pending = state.user_message_count or {}
  local threshold = config.ui.output.rendering.markdown_on_idle_threshold
  if type(threshold) == 'number' then
    return (pending[session_id] or 0) > threshold
  end
  return (pending[session_id] or 0) > 0
end

local function enqueue_once(order, lookup, id)
  if lookup[id] then
    return
  end
  order[#order + 1] = id
end

local function track_message_for_part(message_id, part_id)
  if not message_id or not part_id then
    return
  end

  local part_ids = ctx.pending.dirty_part_by_message[message_id]
  if not part_ids then
    part_ids = {}
    ctx.pending.dirty_part_by_message[message_id] = part_ids
  end
  part_ids[part_id] = true
end

local function untrack_message_for_part(message_id, part_id)
  local part_ids = message_id and ctx.pending.dirty_part_by_message[message_id]
  if not part_ids then
    return
  end
  part_ids[part_id] = nil
  if next(part_ids) == nil then
    ctx.pending.dirty_part_by_message[message_id] = nil
  end
end

function M.mark_message_dirty(message_id)
  if not message_id then
    return
  end
  ctx.pending.removed_messages[message_id] = nil
  enqueue_once(ctx.pending.dirty_message_order, ctx.pending.dirty_messages, message_id)
  ctx.pending.dirty_messages[message_id] = true
  -- Clear cached formatted data so the message gets fully re-rendered
  ctx.formatted_messages[message_id] = nil
  M.schedule()
end

function M.mark_part_dirty(part_id, message_id)
  if not part_id then
    return
  end

  local rendered_part = ctx.render_state:get_part(part_id)
  message_id = message_id or (rendered_part and rendered_part.message_id)
  if not message_id then
    return
  end

  ctx.pending.removed_parts[part_id] = nil
  enqueue_once(ctx.pending.dirty_part_order, ctx.pending.dirty_parts, part_id)
  ctx.pending.dirty_parts[part_id] = message_id
  track_message_for_part(message_id, part_id)
  M.schedule()
end

function M.queue_part_removal(part_id)
  if not part_id then
    return
  end

  local rendered_part = ctx.render_state:get_part(part_id)
  if rendered_part and rendered_part.message_id then
    untrack_message_for_part(rendered_part.message_id, part_id)
  end

  ctx.pending.dirty_parts[part_id] = nil
  enqueue_once(ctx.pending.removed_part_order, ctx.pending.removed_parts, part_id)
  ctx.pending.removed_parts[part_id] = true
  ctx.formatted_parts[part_id] = nil
  M.schedule()
end

function M.queue_message_removal(message_id)
  if not message_id then
    return
  end

  ctx.pending.dirty_messages[message_id] = nil
  ctx.pending.dirty_part_by_message[message_id] = nil
  enqueue_once(ctx.pending.removed_message_order, ctx.pending.removed_messages, message_id)
  ctx.pending.removed_messages[message_id] = true
  ctx.formatted_messages[message_id] = nil
  M.schedule()
end

function M.schedule()
  if ctx.flush_scheduled then
    return
  end

  ctx.flush_scheduled = true
  vim.schedule(function()
    ctx.flush_scheduled = false
    M.flush()
  end)
end

local function snapshot_pending()
  local pending = ctx.pending
  ctx.pending = {
    dirty_message_order = {},
    dirty_messages = {},
    dirty_part_by_message = {},
    dirty_part_order = {},
    dirty_parts = {},
    removed_part_order = {},
    removed_parts = {},
    removed_message_order = {},
    removed_messages = {},
  }
  return pending
end

local function format_message(message_id)
  local rendered_message = ctx.render_state:get_message(message_id)
  local message = rendered_message and rendered_message.message
  if not message then
    return nil
  end

  local prev = ctx.formatted_messages[message_id]
  local formatted = formatter.format_message_header(message)

  if prev and lines_equal(prev.lines, formatted.lines) and extmarks_equal(prev.extmarks, formatted.extmarks) then
    -- no visible change
    return nil
  end

  ctx.formatted_messages[message_id] = formatted
  return formatted
end

local function format_part(part_id)
  local rendered_part = ctx.render_state:get_part(part_id)
  if not rendered_part or not rendered_part.part then
    return nil
  end

  local rendered_message = ctx.render_state:get_message(rendered_part.message_id)
  local message = rendered_message and rendered_message.message
  if not message then
    return nil
  end

  local is_last_part = (buffer.get_last_part_for_message(message) == part_id)
  local formatted = formatter.format_part(rendered_part.part, message, is_last_part, function(session_id)
    return ctx.render_state:get_child_session_parts(session_id)
  end)

  return formatted, rendered_part.message_id
end

local function apply_message(message_id)
  local previous = ctx.formatted_messages[message_id]
  local formatted = format_message(message_id)
  if not formatted then
    return
  end
  buffer.upsert_message_now(message_id, formatted, previous)
end

local function apply_part(part_id, message_id)
  local previous = ctx.formatted_parts[part_id]
  local formatted = nil
  formatted, message_id = format_part(part_id)
  if not formatted or not message_id then
    return
  end

  local cached = ctx.render_state:get_part(part_id)
  local can_append = previous
    and cached
    and cached.line_start
    and cached.line_end
    and append.is_append_only(previous.lines or {}, formatted.lines or {})

  ctx.formatted_parts[part_id] = formatted
  ctx.last_part_formatted = { part_id = part_id, formatted_data = formatted }

  if can_append then
    buffer.append_part_now(
      part_id,
      append.tail_lines(previous.lines or {}, formatted.lines or {}),
      append.tail_extmarks(#(previous.lines or {}), formatted.extmarks),
      previous
    )
    return
  end

  buffer.upsert_part_now(part_id, message_id, formatted, previous)
end

local function apply_pending(pending)
  local buf = state.windows and state.windows.output_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end

  local has_updates = #pending.removed_part_order > 0
    or #pending.removed_message_order > 0
    or #pending.dirty_message_order > 0
    or #pending.dirty_part_order > 0

  if not has_updates then
    return false
  end

  local scroll_snapshot = scroll.pre_flush(buf)
  with_suppressed_output_autocmds(function()
    for _, part_id in ipairs(pending.removed_part_order) do
      if pending.removed_parts[part_id] then
        buffer.remove_part_now(part_id)
      end
    end

    for _, message_id in ipairs(pending.removed_message_order) do
      if pending.removed_messages[message_id] then
        buffer.remove_message_now(message_id)
      end
    end

    for _, message_id in ipairs(pending.dirty_message_order) do
      if pending.dirty_messages[message_id] then
        apply_message(message_id)
      end

      local dirty_parts = pending.dirty_part_by_message[message_id]
      if dirty_parts then
        local message = ctx.render_state:get_message(message_id)
        local parts = message and message.message and message.message.parts or {}
        for _, part in ipairs(parts or {}) do
          if part.id and dirty_parts[part.id] then
            apply_part(part.id, message_id)
            dirty_parts[part.id] = nil
            pending.dirty_parts[part.id] = nil
          end
        end
      end
    end

    for _, part_id in ipairs(pending.dirty_part_order) do
      local message_id = pending.dirty_parts[part_id]
      if message_id then
        apply_part(part_id, message_id)
      end
    end
  end)

  scroll.post_flush(scroll_snapshot, buf)
  return true
end

local function do_trigger_on_data_rendered()
  local cb_type = type(config.ui.output.rendering.on_data_rendered)
  if cb_type == 'boolean' then
    return
  end
  if not state.windows or not state.windows.output_buf or not state.windows.output_win then
    return
  end
  vim.b[state.windows.output_buf].opencode_markdown_namespace = output_window.markdown_namespace
  if cb_type == 'function' then
    pcall(config.ui.output.rendering.on_data_rendered, state.windows.output_buf, state.windows.output_win)
  elseif vim.fn.exists(':RenderMarkdown') > 0 then
    vim.cmd(':RenderMarkdown')
  elseif vim.fn.exists(':Markview') > 0 then
    vim.cmd(':Markview render ' .. state.windows.output_buf)
  end
end

M.trigger_on_data_rendered =
  require('opencode.util').debounce(do_trigger_on_data_rendered, config.ui.output.rendering.markdown_debounce_ms or 250)

function M.request_on_data_rendered(force)
  if force or not is_markdown_render_deferred() then
    ctx.markdown_render_scheduled = false
    M.trigger_on_data_rendered()
    return
  end

  ctx.markdown_render_scheduled = true
end

function M.flush_pending_on_data_rendered()
  if not ctx.markdown_render_scheduled or is_markdown_render_deferred() then
    return
  end

  ctx.markdown_render_scheduled = false
  M.trigger_on_data_rendered()
end

function M.begin_bulk_mode()
  ctx:bulk_reset()
  ctx.bulk_mode = true
end

function M.end_bulk_mode()
  if not ctx.bulk_mode then
    return
  end
  ctx.bulk_mode = false
  local lines = ctx.bulk_buffer_lines
  if #lines == 0 then
    ctx:bulk_reset()
    return
  end

  -- Add trailing empty line to match non-bulk behavior
  table.insert(lines, '')

  local buf = state.windows and state.windows.output_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    ctx:bulk_reset()
    return
  end

  -- Write all lines at once. Suppress autocmds so render-markdown and similar
  -- plugins don't fire mid-write; restore state even if the write fails.
  local ok, err = xpcall(function()
    with_suppressed_output_autocmds(function()
      output_window.set_lines(lines, 0, -1)
    end)

    if next(ctx.bulk_extmarks_by_line) then
      output_window.set_extmarks(ctx.bulk_extmarks_by_line, 0)
    end
  end, debug.traceback)

  ctx:bulk_reset()

  if not ok then
    error(err)
  end

  vim.schedule(function()
    M.request_on_data_rendered(true)
  end)
end

function M.flush()
  local pending = snapshot_pending()
  local applied = apply_pending(pending)
  if applied and not ctx.bulk_mode then
    M.request_on_data_rendered()
  end
end

return M
