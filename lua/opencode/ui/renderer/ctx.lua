local RenderState = require('opencode.ui.render_state')

---Shared mutable context for the renderer modules.
---Single instance, shared via Lua's require cache.
---@class RendererCtx
local ctx = {
  ---@type RenderState
  render_state = RenderState.new(),
  ---@type integer
  prev_line_count = 0,
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
}

function ctx:reset()
  self.render_state:reset()
  self.prev_line_count = 0
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
end

return ctx
