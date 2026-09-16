local ctx = require('opencode.ui.renderer.ctx')
local flush = require('opencode.ui.renderer.flush')
local buffer = require('opencode.ui.renderer.buffer')

local M = {}

local function message_snapshot(entry, previous)
  local kinds = {}
  for index, content in ipairs(entry.content or {}) do
    kinds[index] = entry.kind == 'user' and {
      kind = content.kind,
      visible_text = content.text ~= nil and content.text ~= '',
      synthetic = content.synthetic,
    } or content.kind
  end
  return {
    id = entry.id,
    kind = entry.kind,
    agent = entry.agent,
    model = entry.model,
    created = entry.time and entry.time.created,
    error = entry.error,
    content_kinds = kinds,
    previous_kind = previous and previous.kind,
    previous_agent = previous and previous.agent,
  }
end

local function accept_snapshot(snapshots, id, value)
  if vim.deep_equal(snapshots[id], value) then
    return false
  end
  snapshots[id] = vim.deepcopy(value)
  return true
end

---@param visible table[]
---@param references_changed boolean
function M.reconcile(visible, references_changed)
  local parts_by_message = {}
  for part_id, rendered in pairs(ctx.render_state._parts) do
    local parts = parts_by_message[rendered.message_id] or {}
    parts[#parts + 1] = part_id
    parts_by_message[rendered.message_id] = parts
  end
  for entry_index, entry in ipairs(visible) do
    local previous = ctx.render_state:get_message(entry.id)
    ctx.render_state:set_message(entry, previous and previous.line_start, previous and previous.line_end)
    local header_changed = accept_snapshot(
      ctx.message_snapshots,
      entry.id,
      message_snapshot(entry, visible[entry_index - 1])
    )
    if header_changed or not previous or previous.line_start == nil then
      flush.mark_message_dirty(entry.id)
    end
    local current_parts = {}
    local last_part_id = buffer.get_last_part_for_message(entry)
    for index, content in ipairs(entry.content or {}) do
      if content.kind ~= 'step_start' and content.kind ~= 'step_finish' then
        local part_id = ctx.content_key(entry, index)
        current_parts[part_id] = true
        local rendered = ctx.render_state:get_part(part_id)
        ctx.render_state:set_part(
          content,
          entry.id,
          part_id,
          rendered and rendered.line_start,
          rendered and rendered.line_end
        )
        local changed = accept_snapshot(ctx.part_snapshots, part_id, {
          content = content,
          role = entry.kind,
          error = entry.error,
          content_kinds = entry.kind == 'user' and ctx.message_snapshots[entry.id].content_kinds or nil,
          last = last_part_id == part_id,
        })
        if changed or (references_changed and content.kind == 'text') or not rendered or rendered.line_start == nil then
          flush.mark_part_dirty(part_id, entry.id)
        end
      end
    end
    for _, part_id in ipairs(parts_by_message[entry.id] or {}) do
      if not current_parts[part_id] then
        flush.queue_part_removal(part_id)
      end
    end
  end
end

return M
