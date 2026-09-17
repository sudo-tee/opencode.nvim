local config = require('opencode.config')
local util = require('opencode.util')
local winbar = require('opencode.ui.winbar')

local M = {}

local state = require('opencode.state')
local config_file = require('opencode.config_file')

local LABELS = {
  NEW_SESSION_TITLE = 'New session',
}

local render_scheduled = false
local model_catalog_requested_for = nil

local function get_model_info()
  if not state.current_model then
    return nil
  end
  local provider, model = state.current_model:match('^(.-)/(.+)$')
  if not provider or not model then
    return nil
  end
  local ok, model_info = pcall(config_file.get_model_info, provider, model)
  return ok and model_info or nil
end

local function ensure_model_catalog()
  local model = state.current_model
  if not config.ui.display_context_size or not model or get_model_info() or model_catalog_requested_for == model then
    return
  end

  model_catalog_requested_for = model
  config_file.get_opencode_providers():and_then(function()
    if model_catalog_requested_for == model and get_model_info() then
      model_catalog_requested_for = nil
      M.render()
    end
  end)
end

local function format_token_info()
  local parts = {}

  if state.current_model then
    if config.ui.display_context_size then
      local model_info = get_model_info()
      local limit = state.tokens_count and model_info and model_info.limit and model_info.limit.context or 0
      local formatted_count = util.format_number(state.tokens_count)
      if formatted_count then
        table.insert(parts, formatted_count)
      end
      if limit > 0 then
        local formatted_pct = util.format_percentage(state.tokens_count / limit)
        if formatted_pct then
          table.insert(parts, formatted_pct)
        end
      end
    end
    if config.ui.display_cost and state.cost and state.cost > 0 then
      local formatted_cost = util.format_cost(state.cost)
      if formatted_cost then
        table.insert(parts, formatted_cost)
      end
    end
  end

  local result = table.concat(parts, ' | ')
  result = result:gsub('%%', '%%%%')
  return result
end

local function create_winbar_text(description, token_info, _)
  return description .. '%=' .. token_info
end

local function get_session_desc()
  if state.is_opening then
    return 'Loading...'
  end

  local session_title = LABELS.NEW_SESSION_TITLE

  if state.active_session and state.active_session.title ~= '' then
    session_title = state.active_session.title
  end

  if not session_title or type(session_title) ~= 'string' then
    session_title = ''
  end
  return session_title
end

function M.render()
  ensure_model_catalog()
  if render_scheduled then
    return
  end
  render_scheduled = true
  vim.schedule(function()
    render_scheduled = false
    if not state.windows then
      return
    end
    local win = state.windows.output_win
    if not win or not vim.api.nvim_win_is_valid(win) then
      return
    end

    local desc = get_session_desc():gsub('%%', '%%%%')
    local token_info = format_token_info()
    local winbar_str = create_winbar_text(desc, token_info, vim.api.nvim_win_get_width(win))
    vim.wo[win].winbar = winbar_str

    winbar.update_highlights(win, 'OpencodeSessionDescription')
  end)
end

local function on_change(_, _, _)
  M.render()
end

function M.setup()
  state.store.subscribe('current_mode', on_change)
  state.store.subscribe('current_model', on_change)
  state.store.subscribe('active_session', on_change)
  state.store.subscribe('active_session_tab', on_change)
  state.store.subscribe('is_opencode_focused', on_change)
  state.store.subscribe('last_focused_opencode_window', on_change)
  state.store.subscribe('tokens_count', on_change)
  state.store.subscribe('cost', on_change)
  state.store.subscribe('is_opening', on_change)
  M.render()
end

function M.close()
  state.store.unsubscribe('current_mode', on_change)
  state.store.unsubscribe('current_model', on_change)
  state.store.unsubscribe('active_session', on_change)
  state.store.unsubscribe('active_session_tab', on_change)
  state.store.unsubscribe('is_opencode_focused', on_change)
  state.store.unsubscribe('last_focused_opencode_window', on_change)
  state.store.unsubscribe('tokens_count', on_change)
  state.store.unsubscribe('cost', on_change)
  model_catalog_requested_for = nil
end
return M
