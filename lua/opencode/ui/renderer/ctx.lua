local RenderState = require('opencode.ui.render_state')

---Shared mutable context for the renderer modules.
---Single instance, shared via Lua's require cache.
---@class RendererCtx
local ctx = {
  ---@type RenderState
  render_state = RenderState.new(),
  ---@type { part_id: string|nil, formatted_data: Output|nil }
  last_part_formatted = { part_id = nil, formatted_data = nil },
  ---@type table<string, Output>
  formatted_parts = {},
  ---@type table<string, Output>
  formatted_messages = {},
  pending = {
    dirty_message_order = {},
    dirty_messages = {},
    dirty_part_by_message = {},
    dirty_part_order = {},
    dirty_parts = {},
    removed_part_order = {},
    removed_parts = {},
    removed_message_order = {},
    removed_messages = {},
  },
  flush_scheduled = false,
  markdown_render_scheduled = false,
  bulk_mode = false,
  bulk_buffer_lines = {},
  bulk_extmarks_by_line = {},
  bulk_folds = {},
  ---@type table<string, { line_start: integer, folds: {from: integer, to: integer}[] }>
  ---Absolute folds per part, keyed by part_id. Used by set_all_folds /
  ---update_part_folds to avoid recomputing folds for unchanged parts.
  ---Invalidation is self-contained: rebuild compares cached.line_start
  ---against render_state line_start, and clears entries whose
  ---formatted_parts source has been removed.
  part_folds = {},
  ---@type integer|nil Number of messages to render from the end (nil = all)
  lazy_render_count = nil,
}

---Reset all renderer caches and pending state.
function ctx:reset()
  self.render_state:reset()
  self.last_part_formatted = { part_id = nil, formatted_data = nil }
  self.formatted_parts = {}
  self.formatted_messages = {}
  self.pending = {
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
  self.flush_scheduled = false
  self.markdown_render_scheduled = false
  self.part_folds = {}
  self:bulk_reset()
end

---Reset the temporary bulk-render accumulators.
function ctx:bulk_reset()
  self.bulk_mode = false
  self.bulk_buffer_lines = {}
  self.bulk_extmarks_by_line = {}
  self.bulk_folds = {}
end

---@param pending? RendererCtx['pending']
---@return boolean
function ctx:has_pending_work(pending)
  pending = pending or self.pending

  return self.flush_scheduled
    or self.bulk_mode
    or #pending.dirty_message_order > 0
    or #pending.dirty_part_order > 0
    or #pending.removed_part_order > 0
    or #pending.removed_message_order > 0
end

return ctx
