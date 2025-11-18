local config = require('opencode.config')
local util = require('opencode.util')

local M = {}

local state = require('opencode.state')
local config_file = require('opencode.config_file')

local LABELS = {
  NEW_SESSION_TITLE = 'New session',
}

local function format_token_info()
  local parts = {}

  if state.current_model then
    if config.ui.display_context_size then
      local provider, model = state.current_model:match('^(.-)/(.+)$')
      local model_info = config_file.get_model_info(provider, model)
      local limit = state.tokens_count and model_info and model_info.limit and model_info.limit.context or 0
      table.insert(parts, util.format_number(state.tokens_count) or nil)
      if limit > 0 then
        table.insert(parts, util.format_percentage(state.tokens_count / limit) or nil)
      end
    end
    if config.ui.display_cost and state.cost then
      table.insert(parts, util.format_cost(state.cost) or nil)
    end
  end

  local result = table.concat(parts, ' | ')
  result = result:gsub('%%', '%%%%')
  return result
end

local function create_winbar_text(description, token_info, win_width)
  local left_content = ''
  local right_content = token_info

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
  local session_title = LABELS.NEW_SESSION_TITLE

  if state.active_session then
    local session = require('opencode.session').get_by_id(state.active_session.id)
    if session and session.title ~= '' then
      session_title = session.title
    end
  end

  if not session_title or type(session_title) ~= 'string' then
    session_title = ''
  end
  return session_title
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

    vim.wo[win].winbar = ' '

    local desc = get_session_desc()
    local token_info = format_token_info()
    local winbar_str = create_winbar_text(desc, token_info, vim.api.nvim_win_get_width(win))
    vim.wo[win].winbar = winbar_str

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
  state.subscribe('tokens_count', on_change)
  state.subscribe('cost', on_change)
  M.render()
end

function M.close()
  state.unsubscribe('current_mode', on_change)
  state.unsubscribe('current_model', on_change)
  state.unsubscribe('active_session', on_change)
  state.unsubscribe('is_opencode_focused', on_change)
  state.unsubscribe('tokens_count', on_change)
  state.unsubscribe('cost', on_change)
end
return M
