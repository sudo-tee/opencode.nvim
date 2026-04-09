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
  self:bulk_reset()
end

---Reset the temporary bulk-render accumulators.
function ctx:bulk_reset()
  self.bulk_mode = false
  self.bulk_buffer_lines = {}
  self.bulk_extmarks_by_line = {}
end

return ctx
