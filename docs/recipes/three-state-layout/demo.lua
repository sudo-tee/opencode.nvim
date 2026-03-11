-- Three-State Layout Toggle Demo
-- Instantly switch between focused coding, side-by-side, and deep conversation modes
-- Usage: :luafile docs/recipes/three-state-layout/demo.lua
-- Requires: opencode.nvim plugin installed

-- Three interaction modes:
--   focused:    opencode hidden, full attention on your code
--   side_by_side: opencode visible alongside code for quick reference
--   deep:       opencode fullscreen for complex AI interactions

local MODE = {
  focused = 'focused',
  side_by_side = 'side_by_side',
  deep = 'deep',
}

local get_opencode_config

-- Actions to transition between modes
local ACTIONS = {
  to_focused = function(api)
    api.toggle(false)
  end,
  to_side_by_side = function(api)
    local config = get_opencode_config()
    if not config then
      return
    end
    api.toggle(false)
    config.ui.position = 'right'
    api.toggle(false)
  end,
  to_deep = function(api)
    local config = get_opencode_config()
    if not config then
      return
    end
    api.toggle(false)
    config.ui.position = 'current'
    api.toggle(false)
  end,
  open_side_by_side = function(api)
    local config = get_opencode_config()
    if config then
      config.ui.position = 'right'
    end
    api.toggle(false)
  end,
  open_deep = function(api)
    local config = get_opencode_config()
    if config then
      config.ui.position = 'current'
    end
    api.toggle(false)
  end,
}

-- Transition table: which action to take from each mode
local TRANSITIONS = {
  zl = {
    [MODE.focused] = 'open_side_by_side',
    [MODE.side_by_side] = 'to_focused',
    [MODE.deep] = 'to_side_by_side',
  },
  zL = {
    [MODE.focused] = 'open_deep',
    [MODE.side_by_side] = 'to_deep',
    [MODE.deep] = 'to_focused',
  },
}

-- Get opencode config (helper for position switching)
get_opencode_config = function()
  local ok, config = pcall(require, 'opencode.config')
  return ok and config or nil
end

-- Detect current mode from opencode state
local function get_current_mode(api)
  local ok_window_state, window_state = pcall(api.get_window_state)
  if not ok_window_state or not window_state or window_state.status ~= 'visible' then
    return MODE.focused
  end

  local config = get_opencode_config()
  if config and config.ui.position == 'current' then
    return MODE.deep
  end

  return MODE.side_by_side
end

-- Execute transition based on trigger key
local function run_transition(trigger)
  local ok_api, api = pcall(require, 'opencode.api')
  if not ok_api then
    return
  end

  local current = get_current_mode(api)
  local action_name = TRANSITIONS[trigger] and TRANSITIONS[trigger][current]
  local action = action_name and ACTIONS[action_name]
  if not action then
    return
  end
  action(api)
end

-- Set up keymaps
vim.keymap.set('n', 'zl', function()
  run_transition('zl')
end, { desc = 'Toggle opencode side-by-side/focused', noremap = true, silent = true })

vim.keymap.set('n', 'zL', function()
  run_transition('zL')
end, { desc = 'Toggle opencode deep/focused', noremap = true, silent = true })

vim.notify('Three-state layout loaded. zl: side-by-side, zL: deep conversation', vim.log.levels.INFO)
