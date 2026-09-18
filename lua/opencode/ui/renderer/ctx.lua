local RenderState = require('opencode.ui.render_state')

local M = {}
local ctx = {}
ctx.__index = ctx
local current

---@class PermissionController
---@field get_all_permissions fun(): table[]
---@field clear_all fun()
---@field sync fun(observations: table[])

---@class QuestionController
---@field get_current_request fun(): OpencodeQuestionRequest|nil
---@field uses_vim_ui_select fun(request?: OpencodeQuestionRequest): boolean
---@field has_question fun(): boolean
---@field clear_all fun()
---@field sync fun(observations: table[])

---Controllers are registered once by the entry layer; their displays use the active context.
---@type {permission?: PermissionController, question?: QuestionController}
M.prompt_controllers = {}

---@class RendererCtx
---@field observation table|nil
---@field render_session OpencodeRenderSession|nil
---@field render_state RenderState
---@field entries table[]
---@field generation integer
---@field closed boolean
---@field output_buf integer|nil
---@field needs_reconcile boolean
---@field lazy_render_count integer|nil
---@field get_child_parts fun(session_id: string): table[]|nil
---@field prompt_controllers {permission?: PermissionController, question?: QuestionController}
---@field formatted_parts table<string, Output>
---@field formatted_messages table<string, Output>
---@field last_part_formatted {part_id: string|nil, formatted_data: Output|nil}
---@field message_snapshots table<string, table>
---@field part_snapshots table<string, table>
---@field file_revision integer
---@field flush_scheduled boolean
---@field reconcile_scheduled boolean
---@field markdown_render_scheduled boolean
---@field markdown_debounce? fun(generation: integer)
---@field symbol_refresh_pending boolean
---@field symbol_refresh_token integer
---@field symbol_refresh_cycle table|nil
---@field bulk_mode boolean
---@field bulk_buffer_lines string[]
---@field bulk_extmarks_by_line table
---@field bulk_folds table[]
---@field global_folds table[]
---@field part_folds table<string, table[]>
---@field pending {dirty_message_order: string[], dirty_messages: table, dirty_part_by_message: table, dirty_part_order: string[], dirty_parts: table, removed_part_order: string[], removed_parts: table, removed_message_order: string[], removed_messages: table}

---@return RendererCtx
function M.new()
  local self = setmetatable({
    generation = 0,
    symbol_refresh_token = 0,
    closed = false,
    prompt_controllers = M.prompt_controllers,
    get_child_parts = function()
      return nil
    end,
  }, ctx)
  self:reset()
  return self
end

---@return RendererCtx
function M.current()
  current = current or M.new()
  return current
end

---@param context? RendererCtx
function M.select(context)
  current = context or M.new()
end

---@return boolean
function ctx:is_active()
  return current == self and not self.closed
end

---Invalidate queued work and release subscriptions when the owning tab is removed.
function ctx:close()
  if self.render_session then
    self.render_session:close()
    self.render_session = nil
  end
  self.observation = nil
  self:reset()
  self.closed = true
end

---Reset all renderer caches and pending state.
function ctx:reset()
  self.generation = self.generation + 1
  self.render_state = RenderState.new()
  self.last_part_formatted = { part_id = nil, formatted_data = nil }
  self.formatted_parts = {}
  self.formatted_messages = {}
  self.message_snapshots = {}
  self.part_snapshots = {}
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
  self.reconcile_scheduled = false
  self.markdown_render_scheduled = false
  self.symbol_refresh_pending = false
  self.symbol_refresh_token = self.symbol_refresh_token + 1
  self.symbol_refresh_cycle = nil
  self.global_folds = {}
  self.part_folds = {}
  self.entries = {}
  self.file_revision = 0
  self.needs_reconcile = false
  self:bulk_reset()
end

---@param entry table
---@param index integer
---@return string
function ctx.content_key(entry, index)
  local content = entry.content[index]
  return content.id or string.format('%s:content:%d', entry.id, index)
end

---Reset the temporary bulk-render accumulators.
function ctx:bulk_reset()
  self.bulk_mode = false
  self.bulk_buffer_lines = {}
  self.bulk_extmarks_by_line = {}
  self.bulk_folds = {}
end

return M
