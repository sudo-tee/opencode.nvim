local Dialog = require('opencode.ui.dialog')
local state = require('opencode.state')
local ctx = require('opencode.ui.renderer.ctx')

local M = {}

local DISPLAY_PART_ID_PREFIX = 'message-actions-display-part:'

local ACTIONS = {
  {
    label = 'Revert',
    run = function(message_id)
      require('opencode.api').undo(message_id)
    end,
  },
  {
    label = 'Copy',
    run = function(_, message)
      local text = M.collect_user_text(message)
      if text == '' then
        vim.notify('No message text to copy', vim.log.levels.WARN)
        return
      end
      vim.fn.setreg('+', text)
    end,
  },
  {
    label = 'Fork',
    run = function(message_id)
      require('opencode.api').fork_session(message_id)
    end,
  },
}

M._target_message = nil
M._dialog = nil
M._display_part_id = nil

---@param message_id string
---@return string
local function display_part_id(message_id)
  return DISPLAY_PART_ID_PREFIX .. message_id
end

---@return integer|nil output_win
---@return integer|nil output_buf
local function output_window()
  local windows = state.windows
  local output_win = windows and windows.output_win
  local output_buf = windows and windows.output_buf

  if not output_win or not output_buf then
    return nil, nil
  end
  if not vim.api.nvim_win_is_valid(output_win) or not vim.api.nvim_buf_is_valid(output_buf) then
    return nil, nil
  end
  if vim.api.nvim_win_get_buf(output_win) ~= output_buf then
    return nil, nil
  end

  return output_win, output_buf
end

---@param output_win integer
---@param output_buf integer
---@param mouse table
local function move_cursor_to_mouse(output_win, output_buf, mouse)
  local line_count = vim.api.nvim_buf_line_count(output_buf)
  local line = math.max(1, math.min(mouse.line or 1, line_count))
  local col = math.max(0, (mouse.column or 1) - 1)
  pcall(vim.api.nvim_win_set_cursor, output_win, { line, col })
end

---@return boolean
local function can_open_message_actions()
  local question_window = require('opencode.ui.question_window')
  local permission_window = require('opencode.ui.permission_window')

  if question_window.has_question() or permission_window.has_permissions() then
    vim.notify('Finish the active dialog first', vim.log.levels.WARN)
    return false
  end

  return true
end

---@return boolean handled
local function select_active_dialog_from_mouse()
  local question_window = require('opencode.ui.question_window')
  if question_window.has_question() then
    question_window.select_mouse_option()
    return true
  end

  local permission_window = require('opencode.ui.permission_window')
  if permission_window.has_permissions() then
    permission_window.select_mouse_option()
    return true
  end

  return false
end

local function render_display()
  local target_id = M._target_message and M._target_message.info and M._target_message.info.id or nil
  require('opencode.ui.renderer.events').render_message_actions_display(
    M._dialog ~= nil and target_id or nil,
    M._display_part_id
  )
end

---@param message OpencodeMessage|nil
---@return boolean
function M.is_actionable_user_message(message)
  if not message or not message.info or message.info.role ~= 'user' then
    return false
  end

  local message_id = message.info.id
  if not message_id or message_id == '' then
    return false
  end

  local parts = message.parts or {}
  if #parts == 0 then
    return true
  end

  for _, part in ipairs(parts) do
    if part.synthetic ~= true then
      return true
    end
  end

  return false
end

---@param message OpencodeMessage|nil
---@return string
function M.collect_user_text(message)
  local chunks = {}

  for _, part in ipairs((message and message.parts) or {}) do
    if part.type == 'text' and part.synthetic ~= true and type(part.text) == 'string' and vim.trim(part.text) ~= '' then
      chunks[#chunks + 1] = part.text
    end
  end

  return table.concat(chunks, '\n\n')
end

---@param line integer
---@return OpencodeMessage|nil
local function actionable_message_at_line(line)
  local rendered_message = ctx.render_state:get_message_at_line(line)
  if not rendered_message then
    local rendered_part = ctx.render_state:get_part_at_line(line)
    if rendered_part and rendered_part.part and rendered_part.part.type ~= 'message-actions-display' then
      rendered_message = ctx.render_state:get_message(rendered_part.message_id)
    end
  end

  local message = rendered_message and rendered_message.message
  if not M.is_actionable_user_message(message) then
    return nil
  end
  return message
end

---@param message OpencodeMessage
---@param output_buf integer
local function open_for_message(message, output_buf)
  if not can_open_message_actions() then
    return
  end

  M.clear()
  M._target_message = message
  M._display_part_id = display_part_id(message.info.id)

  local function is_active_target()
    local ui = require('opencode.ui.ui')
    return ui.is_opencode_focused() and M._target_message ~= nil
  end

  M._dialog = Dialog.new({
    buffer = output_buf,
    render_part_id = M._display_part_id,
    mouse_select = false,
    namespace_prefix = 'opencode_message_actions',
    check_focused = is_active_target,
    get_option_count = function()
      return M._target_message and #ACTIONS or 0
    end,
    on_navigate = render_display,
    on_dismiss = M.clear,
    on_select = function(index)
      if not M._target_message then
        return
      end

      local action = ACTIONS[index]
      if not action then
        return
      end

      local selected_message = M._target_message
      local message_id = selected_message.info.id
      M.clear()
      action.run(message_id, selected_message)
    end,
  })

  M._dialog:setup()
  render_display()
end

function M.open_at_cursor()
  local output_win, output_buf = output_window()
  if not output_win or not output_buf then
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(output_win)[1] - 1
  local message = actionable_message_at_line(cursor_line)
  if not message then
    return
  end

  open_for_message(message, output_buf)
end

local function pass_through_left_mouse()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<LeftMouse>', true, true, true), 'n', false)
end

function M.open_from_mouse()
  local output_win, output_buf = output_window()
  if not output_win or not output_buf then
    pass_through_left_mouse()
    return
  end

  local mouse = vim.fn.getmousepos()
  if not mouse or mouse.winid ~= output_win then
    pass_through_left_mouse()
    return
  end
  if not vim.api.nvim_win_is_valid(mouse.winid) or vim.api.nvim_win_get_buf(mouse.winid) ~= output_buf then
    pass_through_left_mouse()
    return
  end
  if not mouse.line or mouse.line <= 0 then
    return
  end

  move_cursor_to_mouse(output_win, output_buf, mouse)

  if select_active_dialog_from_mouse() then
    return
  end

  if M._dialog then
    if M._dialog:select_mouse_option() then
      return
    end
    M.clear()
    return
  end

  local message = actionable_message_at_line(mouse.line - 1)
  if not message then
    return
  end

  open_for_message(message, output_buf)
end

function M.clear()
  if M._dialog then
    M._dialog:teardown()
    M._dialog = nil
  end
  local display_id = M._display_part_id
  M._target_message = nil
  M._display_part_id = nil
  require('opencode.ui.renderer.events').render_message_actions_display(nil, display_id)
end

function M.teardown()
  if M._dialog then
    M._dialog:teardown()
  end
  M._dialog = nil
  M._target_message = nil
  M._display_part_id = nil
end

---@param output Output
function M.format_display(output)
  if not M._target_message or not M._dialog then
    return
  end

  M._dialog:format_dialog(output, {
    title = 'Message Actions',
    title_hl = 'OpencodeQuestionTitle',
    border_hl = 'OpencodeQuestionBorder',
    options = ACTIONS,
    hide_legend = true,
    unfocused_message = 'Focus Opencode window to choose message action',
  })
end

return M
