local RenderState = require('opencode.ui.render_state')

---Shared mutable context for the renderer modules.
---Single instance, shared via Lua's require cache.
---@class PermissionController
---@field get_all_permissions fun(): OpencodePermission[]
---@field clear_all fun()
---@field restore_pending_permissions fun(session_id: string): Promise<any>
---@field add_permission fun(permission: OpencodePermission)
---@field remove_permission fun(permission_id: string)
---@field update_permission_from_part fun(permission_id: string, part: OpencodeMessagePart)

---@class QuestionController
---@field get_current_request fun(): OpencodeQuestionRequest|nil
---@field uses_vim_ui_select fun(request?: OpencodeQuestionRequest): boolean
---@field has_question fun(): boolean
---@field clear_question fun()
---@field show_question fun(request: OpencodeQuestionRequest)
---@field restore_pending_question fun(session_id: string): Promise<any>
---@field matches_active_question fun(request: table): boolean

---@class RendererCtx
local ctx = {
  ---Controllers are registered by the entry layer during plugin setup.
  ---@type {permission?: PermissionController, question?: QuestionController}
  prompt_controllers = {},
  ---@type RenderState
  render_state = RenderState.new(),
  ---@type { part_id: string|nil, formatted_data: Output|nil }
  last_part_formatted = { part_id = nil, formatted_data = nil },
  ---@type table<string, Output>
  formatted_parts = {},
  ---@type table<string, Output>
  formatted_messages = {},
  pending = {
    dirty_message_order = {}, ---@type string[]
    dirty_messages = {}, ---@type table<string, boolean>
    dirty_part_by_message = {}, ---@type table<string, string[]>
    dirty_part_order = {}, ---@type string[]
    dirty_parts = {}, ---@type table<string, string>
    removed_part_order = {}, ---@type string[]
    removed_parts = {}, ---@type table<string, boolean>
    removed_message_order = {}, ---@type string[]
    removed_messages = {}, ---@type table<string, boolean>
  },
  flush_scheduled = false, ---@type boolean
  markdown_render_scheduled = false, ---@type boolean
  symbol_refresh_pending = false, ---@type boolean
  symbol_refresh_token = 0, ---@type integer
  symbol_refresh_cycle = nil, ---@type table?
  bulk_mode = false, ---@type boolean
  bulk_buffer_lines = {},
  bulk_extmarks_by_line = {},
  ---@type {from: number, to: number}[]
  bulk_folds = {},
  ---@type {from: number, to: number}[]
  global_folds = {},
  ---@type table<string, {from: number, to: number}[]>
  part_folds = {},
  ---@type integer|nil Number of messages to render from the end (nil = all)
  lazy_render_count = nil,
  generation = 0,
}

local CONTEXT_KEYS = {
  'render_state',
  'last_part_formatted',
  'formatted_parts',
  'formatted_messages',
  'pending',
  'markdown_render_scheduled',
  'global_folds',
  'part_folds',
  'lazy_render_count',
}

---Reset all renderer caches and pending state.
function ctx:reset()
  self.generation = self.generation + 1
  self.render_state = RenderState.new()
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
  self.symbol_refresh_pending = false
  self.symbol_refresh_token = self.symbol_refresh_token + 1
  self.symbol_refresh_cycle = nil
  self.global_folds = {}
  self.part_folds = {}
  self:bulk_reset()
end

---@return table
function ctx:snapshot()
  local snapshot = {}
  for _, key in ipairs(CONTEXT_KEYS) do
    snapshot[key] = self[key]
  end
  return snapshot
end

---@param snapshot table|nil
---@return boolean
function ctx:restore(snapshot)
  self.generation = self.generation + 1
  if not snapshot then
    self:reset()
    return false
  end

  for _, key in ipairs(CONTEXT_KEYS) do
    self[key] = snapshot[key]
  end

  self.flush_scheduled = false
  self.bulk_mode = false
  self:bulk_reset()
  return true
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
    or self.symbol_refresh_pending
    or self.bulk_mode
    or #pending.dirty_message_order > 0
    or #pending.dirty_part_order > 0
    or #pending.removed_part_order > 0
    or #pending.removed_message_order > 0
end

return ctx
