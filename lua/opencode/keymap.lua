local M = {}
local store = require('opencode.state.store')
local mapper = require('opencode.ui.keymap')
local window_keymaps = {}

mapper.resolve_command = function(name, args)
  local commands = require('opencode.commands')
  local definition = commands.get_commands()[name]
  if not definition then
    vim.notify('Cannot find keymap action: ' .. name, vim.log.levels.ERROR)
    return nil
  end
  return function()
    local arguments = args and (type(args) == 'table' and vim.deepcopy(args) or { args }) or {}
    return commands.execute_parsed_intent(commands.build_parsed_intent(name, arguments))
  end,
    definition.desc
end

local function setup_panel_keymaps(_, windows, previous)
  if not windows then
    return
  end
  for _, name in ipairs({ 'input', 'output', 'tab_strip' }) do
    local buf, win = windows[name .. '_buf'], windows[name .. '_win']
    local changed = not previous or previous[name .. '_buf'] ~= buf or previous[name .. '_win'] ~= win
    if
      changed
      and buf
      and vim.api.nvim_buf_is_valid(buf)
      and (name == 'tab_strip' or win and vim.api.nvim_win_is_valid(win))
    then
      mapper.setup_window_keymaps(window_keymaps[name .. '_window'], buf, true)
    end
  end
end

---@param keymap OpencodeKeymap
function M.setup(keymap)
  mapper.setup_keymaps(keymap.editor or {}, { 'n', 'v' }, { silent = false })
  window_keymaps = keymap
  store.subscribe('windows', setup_panel_keymaps)
  setup_panel_keymaps(nil, store.get('windows'))
end

function M.teardown()
  store.unsubscribe('windows', setup_panel_keymaps)
  window_keymaps = {}
end

return M
