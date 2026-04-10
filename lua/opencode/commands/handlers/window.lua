local core = require('opencode.core')
---@type OpencodeState
local state = require('opencode.state')
local ui = require('opencode.ui.ui')
local config = require('opencode.config')
local Promise = require('opencode.promise')
local input_window = require('opencode.ui.input_window')

local M = {
  actions = {},
}

---@param message string
local function invalid_arguments(message)
  error({
    code = 'invalid_arguments',
    message = message,
  }, 0)
end

function M.actions.open_input()
  return core.open({ new_session = false, focus = 'input', start_insert = true })
end

function M.actions.open_output()
  return core.open({ new_session = false, focus = 'output' })
end

function M.actions.close()
  if state.display_route then
    state.ui.clear_display_route()
    ui.clear_output()
    ui.render_output()
    return
  end

  ui.teardown_visible_windows(state.windows)
end

function M.actions.hide()
  ui.hide_visible_windows(state.windows)
end

---@return {status: 'closed'|'hidden'|'visible', position: string, windows: OpencodeWindowState|nil, cursor_positions: {input: integer[]|nil, output: integer[]|nil}}
function M.actions.get_window_state()
  return state.ui.get_window_state()
end

function M.actions.cancel()
  core.cancel()
end

---@param hidden OpencodeHiddenBuffers|nil
---@return 'input'|'output'
local function resolve_hidden_focus(hidden)
  if hidden and (hidden.focused_window == 'input' or hidden.focused_window == 'output') then
    return hidden.focused_window
  end

  if hidden and hidden.input_hidden then
    return 'output'
  end

  return 'input'
end

---@param restore_hidden boolean
---@return {focus: 'input'|'output', open_action: 'reuse_visible'|'restore_hidden'|'create_fresh'}
local function build_toggle_open_context(restore_hidden)
  if restore_hidden then
    local hidden = state.ui.inspect_hidden_buffers()
    return {
      focus = resolve_hidden_focus(hidden),
      open_action = 'restore_hidden',
    }
  end

  local focus = config.ui.input.auto_hide and 'input' or state.last_focused_opencode_window or 'input'

  return {
    focus = focus,
    open_action = 'create_fresh',
  }
end

M.actions.toggle = Promise.async(function(new_session)
  local decision = state.ui.resolve_toggle_decision(config.ui.persist_state, state.display_route ~= nil)
  local action = decision.action
  local is_new_session = new_session == true

  local function open_windows(restore_hidden)
    local ctx = build_toggle_open_context(restore_hidden == true)
    return core
      .open({
        new_session = is_new_session,
        focus = ctx.focus,
        start_insert = false,
        open_action = ctx.open_action,
      })
      :await()
  end

  local function open_fresh_windows()
    return open_windows(false)
  end

  local function restore_hidden_windows()
    return open_windows(true)
  end

  local function migrate_windows()
    if state.windows then
      ui.teardown_visible_windows(state.windows)
    end
    return open_fresh_windows()
  end

  local action_handlers = {
    close = M.actions.close,
    hide = M.actions.hide,
    close_hidden = ui.drop_hidden_snapshot,
    migrate = migrate_windows,
    restore_hidden = restore_hidden_windows,
    open = open_fresh_windows,
  }

  local handler = action_handlers[action] or action_handlers.open
  return handler()
end)

---@param new_session boolean?
function M.actions.toggle_focus(new_session)
  if not ui.is_opencode_focused() then
    local focus = state.last_focused_opencode_window or 'input' ---@cast focus 'input' | 'output'
    core.open({ new_session = new_session == true, focus = focus })
  else
    ui.return_to_last_code_win()
  end
end

function M.actions.toggle_pane()
  ui.toggle_pane()
end

function M.actions.toggle_zoom()
  ui.toggle_zoom()
end

function M.actions.toggle_input()
  input_window.toggle()
end

function M.actions.swap_position()
  local new_pos = (config.ui.position == 'left') and 'right' or 'left'
  config.values.ui.position = new_pos

  if state.windows then
    ui.close_windows(state.windows, false)
  end

  vim.schedule(function()
    M.actions.toggle(state.active_session == nil)
  end)
end

function M.actions.focus_input()
  ui.focus_input({ restore_position = true, start_insert = true })
end

M.command_defs = {
  open = {
    desc = 'Open opencode window (input/output)',
    completions = { 'input', 'output' },
    execute = function(args)
      local target = args[1] or 'input'
      if target == 'input' then
        return M.actions.open_input()
      end
      if target == 'output' then
        return M.actions.open_output()
      end
      invalid_arguments('Invalid target. Use: input or output')
    end,
  },
  -- action name aliases for keymap compatibility
  open_input  = { desc = 'Open input window',  execute = M.actions.open_input },
  open_output = { desc = 'Open output window', execute = M.actions.open_output },
  close = {
    desc = 'Close opencode windows',
    execute = M.actions.close,
  },
  hide = {
    desc = 'Hide opencode windows (preserve buffers for fast restore)',
    execute = M.actions.hide,
  },
  cancel = {
    desc = 'Cancel running request',
    execute = M.actions.cancel,
  },
  toggle = {
    desc = 'Toggle opencode windows',
    execute = M.actions.toggle,
  },
  toggle_focus = {
    desc = 'Toggle focus between opencode and code',
    execute = M.actions.toggle_focus,
  },
  toggle_pane = {
    desc = 'Toggle between input/output panes',
    execute = M.actions.toggle_pane,
  },
  toggle_zoom = {
    desc = 'Toggle window zoom',
    execute = M.actions.toggle_zoom,
  },
  toggle_input = {
    desc = 'Toggle input window visibility',
    execute = M.actions.toggle_input,
  },
  focus_input = {
    desc = 'Focus input window',
    execute = M.actions.focus_input,
  },
  swap = {
    desc = 'Swap pane position left/right',
    execute = M.actions.swap_position,
  },
  -- action name alias for keymap compatibility
  swap_position = { desc = 'Swap window position', execute = M.actions.swap_position },
}

return M
