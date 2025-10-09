local M = {}

local state = require('opencode.state')
local formatter = require('opencode.ui.session_formatter')
local loading_animation = require('opencode.ui.loading_animation')
local output_window = require('opencode.ui.output_window')
local util = require('opencode.util')

-- Minimal cache: only previous rendered lines for change detection
M._cache = {
  prev_rendered_lines = nil,
}

-- Subscriptions map for cleanup
M._subscriptions = {}

-- Namespace for extmarks (created once)
M._ns_id = vim.api.nvim_create_namespace('opencode_output')

-- Debounce configuration for render (milliseconds)
M._debounce_ms = 50

function M.render_markdown()
  if vim.fn.exists(':RenderMarkdown') > 0 then
    vim.cmd(':RenderMarkdown')
  end
end

-- Simple helper to get formatted lines for the current session
function M._read_session()
  if not state.active_session then
    if state.new_session_name then
      return { '' }
    end
    return nil
  end
  return formatter.format_session(state.active_session)
end

M.render = vim.schedule_wrap(function(windows, force)
  if not output_window.mounted(windows) then
    return
  end

  if loading_animation.is_running() and not force then
    return
  end

  local lines = M._read_session()
  if not lines then
    return
  end

  local changed = M.write_output(windows, lines)

  if changed or force then
    vim.schedule(function()
      M.render_markdown()
      M.handle_auto_scroll(windows)
      require('opencode.ui.topbar').render()
    end)
  end

  pcall(function()
    require('opencode.ui.mention').highlight_all_mentions(windows.output_buf)
    require('opencode.ui.contextual_actions').setup_contextual_actions()
    require('opencode.ui.footer').render(windows)
  end)
end)

function M.setup_subscriptions(windows)
  M._cleanup_subscriptions()
  loading_animation.setup_subscription()

  local on_change = util.debounce(function()
    M.render(windows, true)
  end, M._debounce_ms)

  state.subscribe('last_output', on_change)
  M._subscriptions.last_output = on_change

  state.subscribe('active_session', on_change)
  M._subscriptions.active_session = on_change
end

function M._cleanup_subscriptions()
  for key, cb in pairs(M._subscriptions) do
    state.unsubscribe(key, cb)
  end
  M._subscriptions = {}
  loading_animation.teardown()
end

function M.teardown()
  M._cleanup_subscriptions()
  M.stop()
end

function M.stop()
  loading_animation.stop()
  M._cache.prev_rendered_lines = nil
end

function M._last_n_lines_equal(prev_lines, current_lines, n)
  n = n or 5
  if #prev_lines ~= #current_lines then
    return false
  end
  local len = #prev_lines
  local start = math.max(1, len - n + 1)
  for i = start, len do
    if prev_lines[i] ~= current_lines[i] then
      return false
    end
  end
  return true
end

function M.write_output(windows, output_lines)
  if not output_window.mounted(windows) then
    return false
  end

  local prev_lines = M._cache.prev_rendered_lines or {}
  local changed = not M._last_n_lines_equal(prev_lines, output_lines, 5)
  if changed then
    output_window.set_content(output_lines)
    M._cache.prev_rendered_lines = vim.deepcopy(output_lines)
    M.apply_output_extmarks(windows)
  end
  return changed
end

function M.apply_output_extmarks(windows)
  if state.display_route then
    return
  end

  local extmarks = formatter.output:get_extmarks()
  local ns_id = M._ns_id
  pcall(vim.api.nvim_buf_clear_namespace, windows.output_buf, ns_id, 0, -1)

  for line_num, marks in pairs(extmarks) do
    for _, mark in ipairs(marks) do
      local actual_mark = mark
      if type(mark) == 'function' then
        actual_mark = mark()
      end
      pcall(vim.api.nvim_buf_set_extmark, windows.output_buf, ns_id, line_num - 1, 0, actual_mark)
    end
  end
end

function M.handle_auto_scroll(windows)
  local ok, line_count = pcall(vim.api.nvim_buf_line_count, windows.output_buf)
  if not ok then
    return
  end

  local botline = vim.fn.line('w$', windows.output_win)
  local cursor_pos = vim.fn.getcurpos(windows.output_win)
  local is_focused = vim.api.nvim_get_current_win() == windows.output_win

  local prev_line_count = vim.b[windows.output_buf].prev_line_count or 0
  vim.b[windows.output_buf].prev_line_count = line_count

  local was_at_bottom = (botline >= prev_line_count) or prev_line_count == 0

  if is_focused and cursor_pos[2] < prev_line_count - 1 then
    return
  end

  if was_at_bottom or not is_focused then
    require('opencode.ui.ui').scroll_to_bottom()
  end
end

return M
