local base_picker = require('opencode.ui.base_picker')
local Promise = require('opencode.promise')

local M = {}

---@param skill OpencodeSkill
---@param width number
---@return PickerItem
local function format_skill_item(skill, width)
  width = width or vim.api.nvim_win_get_width(0)
  local desc_width = math.max(20, width - 30)
  local desc = skill.description or ''
  if #desc > desc_width then
    desc = desc:sub(1, desc_width - 3) .. '...'
  end
  return base_picker.create_picker_item({
    { text = base_picker.align(skill.name, 20, { truncate = true }), highlight = 'OpencodeFile' },
    { text = desc, highlight = 'OpencodeHint' },
  })
end

---@param skill OpencodeSkill
---@param target PickerPreviewTarget
local function preview_skill(skill, target)
  if not skill or not skill.content then
    return
  end

  local lines = vim.split(skill.content, '\n')
  target:set_lines(lines)

  local bufnr = target:get_bufnr()
  if bufnr then
    vim.bo[bufnr].filetype = 'markdown'
  end
end

---Show skills picker
function M.pick()
  local state = require('opencode.state')
  local ui = require('opencode.ui.ui')
  local input_window = require('opencode.ui.input_window')

  local ok, skills = pcall(function()
    return state.api_client:list_skills():await()
  end)

  if not ok or not skills then
    vim.notify('Failed to fetch skills: ' .. tostring(skills), vim.log.levels.ERROR)
    return
  end

  if #skills == 0 then
    vim.notify('No skills available', vim.log.levels.WARN)
    return
  end

  local callback = function(selected)
    if not selected then
      return
    end

    ui.focus_input()
    input_window.set_content('/' .. selected.name .. ' ')
    vim.api.nvim_win_set_cursor(state.windows.input_win, { 1, #selected.name + 2 })
  end

  base_picker.pick({
    items = skills,
    format_fn = format_skill_item,
    actions = {},
    callback = callback,
    title = 'Skills',
    width = 65,
    preview = 'custom',
    preview_fn = preview_skill,
  })
end

return M
