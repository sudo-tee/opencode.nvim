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
}

function ctx:reset()
  self.render_state:reset()
  self.prev_line_count = 0
  self.last_part_formatted = { part_id = nil, formatted_data = nil }
end

return ctx
