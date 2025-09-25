-- Centralized icon utility with presets and overrides
local config = require('opencode.config').get()

local M = {}

local presets = {
  emoji = {
    -- headers
    header_user = '▌💬',
    header_assistant = '🤖',
    -- actions/tools
    run = '💻',
    task = '💻',
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
    -- statuses
    status_on = '🟢',
    status_off = '⚫',
    -- borders and misc
    border = '▌',
  },
  glyphs = {
    file = ' ',
    attached_file = '󰌷 ',
    cursor_data = '󰗧 ',
    agent = ' ',
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
    file = '::',
    -- statuses
    status_on = 'ON',
    status_off = 'OFF',
    -- borders and misc
    border = '▌',
  },
}

---Get icon by key, honoring preset and user overrides
---@param key string
---@return string
function M.get(key)
  local ui = (config.ui or {})
  local icons_cfg = ui.icons or {}
  local preset_name = icons_cfg.preset or 'emoji'
  local preset = presets[preset_name] or presets.emoji

  -- user overrides table: icons = { overrides = { key = 'value' } }
  local override = icons_cfg.overrides and icons_cfg.overrides[key]
  if override ~= nil then
    return override
  end

  return preset[key] or ''
end

function M.get_glyph(name)
  return presets.glyphs[name] or M.get(name)
end

return M
