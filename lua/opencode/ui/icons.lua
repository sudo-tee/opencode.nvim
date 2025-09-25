-- Centralized icon utility with presets and overrides
local config = require('opencode.config')

local M = {}

local presets = {
  emoji = {
    -- headers
    header_user = '▌💬',
    header_assistant = '🤖',
    -- actions/tools
    run = '💻',
    task = '🧰',
    read = '👀',
    edit = '✏️',
    write = '📝',
    plan = '📃',
    search = '🔍',
    web = '🌐',
    list = '📂',
    tool = '🔧',
    snapshot = '📸',
    restore_point = '🕛',
    file = '📄',
    attached_file = '📎',
    agent = '🤖',
    -- statuses
    status_on = '🟢',
    status_off = '⚫',
    guard_on = '🚫',
    -- borders and misc
    border = '▌',
    -- context bar
    cursor_data = '📍',
    context = '📚 ',
    error = '⛔ ',
    warning = '⚠️',
    info = 'ℹ️',
  },
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
    snapshot = '󰻛 ',
    restore_point = '󱗚 ',
    file = ' ',
    attached_file = '󰌷 ',
    agent = '󰚩 ',
    -- statuses
    status_on = ' ',
    status_off = ' ',
    guard_on = '',
    -- borders and misc
    border = '▌',
    -- context bar
    cursor_data = '󰗧 ',
    context = ' ',
    error = ' ',
    warning = ' ',
    info = ' ',
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
    snapshot = '::',
    restore_point = '::',
    file = '@',
    attached_file = '@',
    agent = '@',
    -- statuses
    status_on = 'ON',
    status_off = 'OFF',
    guard_on = 'X',
    -- borders and misc
    border = '▌',
    -- context bar
    cursor_data = '[|] ',
    context = '[Ctx] ',
    error = '[E]',
    warning = '[W]',
    info = '[I] ',
  },
}

local deprecated_warning_shown = false

---Get icon by key, honoring preset and user overrides
---@param key string
---@return string
function M.get(key)
  local ui = (config.ui or {})
  local icons_cfg = ui.icons or {}
  if icons_cfg.preset == 'emoji' then
    icons_cfg.preset = nil
    if not deprecated_warning_shown then
      vim.schedule(function()
        vim.notify(
          "[opencode] 'emoji' preset is deprecated. Using 'nerdfonts' preset instead. Please update your configuration.",
          vim.log.levels.WARN,
          { title = 'Opencode' }
        )
      end)
      deprecated_warning_shown = true
    end
  end
  local preset_name = icons_cfg.preset or 'nerdfonts'
  local preset = presets[preset_name] or presets.emoji

  -- user overrides table: icons = { overrides = { key = 'value' } }
  local override = icons_cfg.overrides and icons_cfg.overrides[key]
  if override ~= nil then
    return override
  end

  return preset[key] or ''
end

return M
