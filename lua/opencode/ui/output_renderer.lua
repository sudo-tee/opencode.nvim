local M = {}

local state = require('opencode.state')
local formatter = require('opencode.ui.session_formatter')
local loading_animation = require('opencode.ui.loading_animation')
local output_window = require('opencode.ui.output_window')
local util = require('opencode.util')
local Promise = require('opencode.promise')

M._subscriptions = {}
M._ns_id = vim.api.nvim_create_namespace('opencode_output')
M._debounce_ms = 50

function M.render_markdown()
  if vim.fn.exists(':RenderMarkdown') > 0 then
    vim.cmd(':RenderMarkdown')
  end
end

function M._read_session()
  if not state.active_session then
    return Promise.new():resolve(nil)
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

  M._read_session():and_then(function(lines)
    if not lines then
      return
    end

    M.write_output(windows, lines)

    vim.schedule(function()
      -- M.render_markdown()
      M.handle_auto_scroll(windows)
    end)

    pcall(function()
      vim.schedule(function()
        require('opencode.ui.mention').highlight_all_mentions(windows.output_buf)
        require('opencode.ui.contextual_actions').setup_contextual_actions()
      end)
    end)
  end)
end)

function M.setup_subscriptions(windows)
  M._cleanup_subscriptions()
  loading_animation.setup_subscription()

  local on_change = util.debounce(function(old, new)
    M.render(windows, true)
  end, M._debounce_ms)

  M._subscriptions.active_session = function(_, new, old)
    if not old then
      return
    end
    on_change(old, new)
  end
  state.subscribe('active_session', M._subscriptions.active_session)
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
  -- FIXME: the footer should probably own this... and it may
  -- not even be necessary
  loading_animation.stop()
end

function M.write_output(windows, output_lines)
  if not output_window.mounted(windows) then
    return false
  end

  output_window.set_content(output_lines)
  M.apply_output_extmarks(windows)
end

function M.apply_output_extmarks(windows)
  if state.display_route then
    return
  end

  local extmarks = {}
  if formatter and formatter.output and type(formatter.output.get_extmarks) == 'function' then
    local ok, res = pcall(formatter.output.get_extmarks, formatter.output)
    if ok and type(res) == 'table' then
      extmarks = res
    end
  end

  local ns_id = M._ns_id
  pcall(vim.api.nvim_buf_clear_namespace, windows.output_buf, ns_id, 0, -1)

  for line_num, marks in pairs(extmarks) do
    for _, mark in ipairs(marks) do
      local actual_mark = type(mark) == 'function' and mark() or mark
      pcall(vim.api.nvim_buf_set_extmark, windows.output_buf, ns_id, line_num - 1, 0, actual_mark)
    end
  end
end

function M.handle_auto_scroll(windows)
  -- NOTE: logic moved to stream renderer
  -- output_render currently only used for loading whole sessions
  -- so just scroll to the bottom when that happens
  require('opencode.ui.ui').scroll_to_bottom()
end

return M
