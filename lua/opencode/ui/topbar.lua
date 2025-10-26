local M = {}

local state = require('opencode.state')
local config_file = require('opencode.config_file')
local prompt_guard_indicator = require('opencode.ui.prompt_guard_indicator')
local icons = require('opencode.ui.icons')

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

local function create_winbar_text(description, model_info, mode_info, show_guard_indicator, win_width)
  -- Calculate how many visible characters we have
  -- Format: " [GUARD] description padding model_info MODE "
  -- Where [GUARD] is optional (1 char + 1 space = 2 visible chars)
  
  local guard_prefix = ''
  local guard_visible_width = 0
  
  if show_guard_indicator then
    local guard_icon = icons.get('status_off')
    guard_prefix = string.format('%%#OpencodeGuardDenied#%s%%* ', guard_icon)
    guard_visible_width = 2 -- icon + space
  end
  
  -- Total available width for all content
  local total_width = win_width
  
  -- Calculate used width: leading space + guard + trailing space + model + mode
  local mode_info_str = get_mode_highlight() .. mode_info .. '%*'
  local mode_visible_width = #mode_info
  local model_visible_width = #model_info
  
  -- Reserve space: 1 (leading) + guard_visible_width + 1 (space before description) + 1 (space before model) + model + mode
  local reserved_width = 1 + guard_visible_width + 1 + 1 + model_visible_width + mode_visible_width
  
  -- Available width for description and padding
  local available_for_desc = total_width - reserved_width
  
  -- Truncate description if needed
  if #description > available_for_desc then
    description = description:sub(1, math.max(1, available_for_desc - 4)) .. '...'
  end
  
  -- Calculate padding to right-align model and mode
  local desc_and_padding_width = available_for_desc
  local padding_width = desc_and_padding_width - #description
  local padding = string.rep(' ', math.max(0, padding_width))
  
  return string.format(' %s%s%s%s %s', guard_prefix, description, padding, model_info, mode_info_str)
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
    local session = require('opencode.session').get_by_id(state.active_session.id)
    if session and session.description ~= '' then
      session_desc = session.description
    end
  end

  return session_desc
end

function M.render()
  vim.schedule(function()
    if not state.windows then
      return
    end
    local win = state.windows.output_win
    if not win then
      return
    end
    -- topbar needs to at least have a value to make sure footer is positioned correctly
    vim.wo[win].winbar = ' '

    local show_guard_indicator = prompt_guard_indicator.is_denied()
    vim.wo[win].winbar =
      create_winbar_text(get_session_desc(), format_model_info(), format_mode_info(), show_guard_indicator, vim.api.nvim_win_get_width(win))

    update_winbar_highlights(win)
  end)
end

local function on_change(_, _, _)
  M.render()
end

function M.setup()
  state.subscribe('current_mode', on_change)
  state.subscribe('current_model', on_change)
  state.subscribe('active_session', on_change)
  M.render()
end

function M.close()
  state.unsubscribe('current_mode', on_change)
  state.unsubscribe('current_model', on_change)
  state.unsubscribe('active_session', on_change)
end
return M
