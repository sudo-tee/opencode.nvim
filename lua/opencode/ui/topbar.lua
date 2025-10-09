local M = {}

local state = require('opencode.state')
local config_file = require('opencode.config_file')

local LABELS = {
  NEW_SESSION_TITLE = 'New session',
}

local function format_model_info()
  if not state.current_model or state.current_model == '' then
    local info = config_file.get_opencode_config()
    state.current_model = info and info.model
  end

  local config = require('opencode.config')
  local parts = {}

  if config.ui.display_model and state.current_model then
    if state.current_model ~= '' then
      table.insert(parts, state.current_model)
    end
  end

  return table.concat(parts, ' ')
end

local function format_mode_info()
  return ' ' .. state.current_mode:upper() .. ' '
end

local function get_mode_highlight()
  local mode = state.current_mode:lower()
  if mode == 'build' then
    return '%#OpencodeAgentBuild#'
  elseif mode == 'plan' then
    return '%#OpencodeAgentPlan#'
  else
    return '%#OpencodeAgentCustom#'
  end
end

local function create_winbar_text(description, model_info, mode_info, win_width)
  local available_width = win_width - 2 -- 2 padding spaces

  -- If total length exceeds available width, truncate description
  if #description + 1 + #model_info + #mode_info + 1 > available_width then
    local space_for_desc = available_width - (#model_info + #mode_info + 1) - 4 -- -4 for "... "
    description = description:sub(1, space_for_desc) .. '... '
  end

  local padding = string.rep(' ', available_width - #description - #model_info - #mode_info - 1)
  return string.format(' %s%s%s %s ', description, padding, model_info, get_mode_highlight() .. mode_info .. '%*')
end

local function update_winbar_highlights(win_id)
  local current = vim.api.nvim_get_option_value('winhighlight', { win = win_id })
  local parts = vim.split(current, ',')

  -- Remove any existing winbar highlights
  parts = vim.tbl_filter(function(part)
    return not part:match('^WinBar:') and not part:match('^WinBarNC:')
  end, parts)

  if not vim.tbl_contains(parts, 'Normal:OpencodeNormal') then
    table.insert(parts, 'Normal:OpencodeNormal')
  end

  table.insert(parts, 'WinBar:OpencodeSessionDescription')
  table.insert(parts, 'WinBarNC:OpencodeSessionDescription')

  vim.api.nvim_set_option_value('winhighlight', table.concat(parts, ','), { win = win_id })
end

local function get_session_desc()
  local session_desc = LABELS.NEW_SESSION_TITLE

  if state.active_session then
    local session = require('opencode.session').get_by_name(state.active_session.id)
    if session and session.description ~= '' then
      session_desc = session.description
    end
  end

  return session_desc
end

function M.render()
  if not state.windows then
    return
  end

  vim.schedule(function()
    if not state.windows then
      return
    end
    local win = state.windows.output_win
    vim.wo[win].winbar =
      create_winbar_text(get_session_desc(), format_model_info(), format_mode_info(), vim.api.nvim_win_get_width(win))

    update_winbar_highlights(win)
  end)
end

return M
