local util = require('opencode.util')

local M = {}

local state = require('opencode.state')
local config_file = require('opencode.config_file')
local prompt_guard_indicator = require('opencode.ui.prompt_guard_indicator')

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
  return ' ' .. (state.current_mode or ''):upper() .. ' '
end

local function get_mode_highlight()
  local mode = (state.current_mode or ''):lower()
  if mode == 'build' then
    return '%#OpencodeAgentBuild#'
  elseif mode == 'plan' then
    return '%#OpencodeAgentPlan#'
  else
    return '%#OpencodeAgentCustom#'
  end
end

local function create_winbar_text(description, model_info, mode_info, show_guard_indicator, win_width)
  local left_content = ''
  local right_content = ''

  if show_guard_indicator then
    left_content = left_content .. prompt_guard_indicator.get_formatted() .. ' '
  end

  right_content = model_info .. ' ' .. get_mode_highlight() .. mode_info .. '%*'

  local desc_width = win_width - util.strdisplaywidth(left_content) - util.strdisplaywidth(right_content)

  local desc_formatted
  if #description >= desc_width then
    local ellipsis = '... '
    desc_formatted = description:sub(1, desc_width - #ellipsis) .. ellipsis
  else
    desc_formatted = description .. string.rep(' ', math.floor(desc_width - #description))
  end

  return left_content .. desc_formatted .. right_content
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
    vim.wo[win].winbar = create_winbar_text(
      get_session_desc(),
      format_model_info(),
      format_mode_info(),
      show_guard_indicator,
      vim.api.nvim_win_get_width(win)
    )

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
  state.subscribe('is_opencode_focused', on_change)
  M.render()
end

function M.close()
  state.unsubscribe('current_mode', on_change)
  state.unsubscribe('current_model', on_change)
  state.unsubscribe('active_session', on_change)
  state.unsubscribe('is_opencode_focused', on_change)
end
return M
