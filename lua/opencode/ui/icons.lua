-- Centralized icon utility with presets and overrides
local config = require('opencode.config')

local M = {}

local presets = {
  nerdfonts = {
    -- headers
    header_user = '▌󰭻 ',
    header_assistant = ' ',
    -- actions/tools
    run = ' ',
    task = ' ',
    read = ' ',
    edit = ' ',
    write = ' ',
    plan = '󰝖 ',
    search = ' ',
    web = '󰖟 ',
    list = ' ',
    tool = ' ',
    skill = '󰐱 ',
    snapshot = '󰻛 ',
    restore_point = '󱗚 ',
    file = ' ',
    folder = ' ',
    attached_file = '󰌷 ',
    agent = '󰚩 ',
    reference = ' ',
    reasoning = '󰧑 ',
    question = '',
    -- statuses
    status_on = ' ',
    status_off = ' ',
    guard_on = ' ',
    -- borders and misc
    border = '▌',
    -- context bar
    cursor_data = '󰗧 ',
    error = ' ',
    warning = ' ',
    info = ' ',
    filter = '/',
    selection = '󰫙 ',
    command = ' ',
    bash = ' ',
    preferred = ' ',
    last_used = '󰃰 ',
    completed = '󰄳 ',
    pending = '󰅐 ',
    running = ' ',
    checkbox_checked = ' ',
    checkbox_unchecked = ' ',
    separator = '',
  },
  text = {
    -- headers
    header_user = '▌$ ',
    header_assistant = '@ ',
    -- actions/tools
    run = '::',
    task = '::',
    read = '::',
    edit = '::',
    write = '::',
    plan = '::',
    search = '::',
    web = '::',
    list = '::',
    tool = '::',
    skill = '::',
    snapshot = '::',
    restore_point = '::',
    file = '@',
    folder = '[@]',
    attached_file = '@',
    agent = '@',
    reference = '@',
    question = '?',
    -- statuses
    status_on = 'ON',
    status_off = 'OFF',
    guard_on = 'X',
    -- borders and misc
    border = '▌',
    -- context bar
    cursor_data = '[|] ',
    error = '[E]',
    warning = '[W]',
    info = '[I] ',
    filter = '/*',
    selection = "'<'> ",
    command = '::',
    bash = '$ ',
    preferred = '* ',
    last_used = '~ ',
    completed = 'X ',
    pending = '- ',
    running = '> ',
    checkbox_checked = '[*]',
    checkbox_unchecked = '[ ]',
    separator = '|',
  },
}

---Get icon by key, honoring preset and user overrides
---@param key string
---@return string
function M.get(key)
  local ui = (config.ui or {})
  local icons_cfg = ui.icons or {}
  local preset_name = icons_cfg.preset or 'nerdfonts'
  local preset = presets[preset_name] or presets.nerdfonts

  -- user overrides table: icons = { overrides = { key = 'value' } }
  local override = icons_cfg.overrides and icons_cfg.overrides[key]
  if override ~= nil then
    return override
  end

  return preset[key] or ''
end

return M
