local M = {}

local state = require('opencode.state')
local formatter = require('opencode.ui.session_formatter')

local LABELS = {
  GENERATING_RESPONSE = 'Thinking...',
}

M._cache = {
  last_modified = 0,
  output_lines = nil,
  session_path = nil,
  check_counter = 0,
}

M._animation = {
  frames = { '·', '․', '•', '∙', '●', '⬤', '●', '∙', '•', '․' },
  current_frame = 1,
  timer = nil,
  loading_line = nil,
  fps = 10,
}

function M.render_markdown()
  if vim.fn.exists(':RenderMarkdown') > 0 then
    vim.cmd(':RenderMarkdown')
  end
end

function M._should_refresh_content()
  if not state.active_session then
    return true
  end

  local session_path = state.active_session.messages_path

  if session_path ~= M._cache.session_path then
    M._cache.session_path = session_path
    return true
  end

  if vim.fn.isdirectory(session_path) == 0 then
    return false
  end

  local stat = vim.loop.fs_stat(session_path)
  if not stat then
    return false
  end

  if state.opencode_run_job then
    M._cache.check_counter = (M._cache.check_counter + 1) % 3
    if M._cache.check_counter == 0 then
      local has_file_changed = stat.mtime.sec > M._cache.last_modified
      if has_file_changed then
        M._cache.last_modified = stat.mtime.sec
        return true
      end
    end
  end

  if stat.mtime.sec > M._cache.last_modified then
    M._cache.last_modified = stat.mtime.sec
    return true
  end

  return false
end

function M._read_session(force_refresh)
  if not state.active_session then
    return nil
  end

  if not force_refresh and not M._should_refresh_content() and M._cache.output_lines then
    return M._cache.output_lines
  end

  local output_lines = formatter.format_session(state.active_session)
  M._cache.output_lines = output_lines
  return output_lines
end

function M._update_loading_animation(windows)
  if not M._animation.loading_line then
    return false
  end

  local buffer_line_count = vim.api.nvim_buf_line_count(windows.output_buf)
  if M._animation.loading_line <= 0 or M._animation.loading_line >= buffer_line_count then
    return false
  end

  local zero_index = M._animation.loading_line - 1
  local loading_text = LABELS.GENERATING_RESPONSE .. ' ' .. M._animation.frames[M._animation.current_frame]

  local ns_id = vim.api.nvim_create_namespace('loading_animation')
  vim.api.nvim_buf_clear_namespace(windows.output_buf, ns_id, zero_index, zero_index + 1)

  vim.api.nvim_buf_set_extmark(windows.output_buf, ns_id, zero_index, 0, {
    virt_text = { { loading_text, 'Comment' } },
    virt_text_pos = 'overlay',
    hl_mode = 'replace',
  })

  return true
end

M._refresh_timer = nil

function M._start_content_refresh_timer(windows)
  if M._refresh_timer then
    pcall(vim.fn.timer_stop, M._refresh_timer)
    M._refresh_timer = nil
  end

  M._refresh_timer = vim.fn.timer_start(300, function()
    if state.opencode_run_job then
      if M._should_refresh_content() then
        vim.schedule(function()
          local current_frame = M._animation.current_frame
          M.render(windows, true)
          M._animation.current_frame = current_frame
        end)
      end

      if state.opencode_run_job then
        M._start_content_refresh_timer(windows)
      end
    else
      if M._refresh_timer then
        pcall(vim.fn.timer_stop, M._refresh_timer)
        M._refresh_timer = nil
      end
      vim.schedule(function()
        M.render(windows, true)
      end)
    end
  end)
end

function M._animate_loading(windows)
  local function start_animation_timer()
    if M._animation.timer then
      pcall(vim.fn.timer_stop, M._animation.timer)
      M._animation.timer = nil
    end

    M._animation.timer = vim.fn.timer_start(math.floor(1000 / M._animation.fps), function()
      M._animation.current_frame = (M._animation.current_frame % #M._animation.frames) + 1

      vim.schedule(function()
        M._update_loading_animation(windows)
      end)

      if state.opencode_run_job then
        start_animation_timer()
      else
        M._animation.timer = nil
      end
    end)
  end

  M._start_content_refresh_timer(windows)

  start_animation_timer()
end

function M.render(windows, force_refresh)
  local function render()
    if not state.active_session and not state.new_session_name then
      return
    end

    if not force_refresh and M._animation.loading_line then
      return
    end

    local output_lines = M._read_session(force_refresh)
    local is_new_session = state.new_session_name ~= nil

    if not output_lines then
      if is_new_session then
        output_lines = { '' }
      else
        return
      end
    else
      state.new_session_name = nil
    end

    M.handle_loading(windows, output_lines)

    M.write_output(windows, output_lines)

    M.handle_auto_scroll(windows)
  end
  render()
  require('opencode.ui.mention').highlight_all_mentions(windows.output_buf)
  require('opencode.ui.topbar').render()
  M.render_markdown()
end

function M.stop()
  if M._animation and M._animation.timer then
    pcall(vim.fn.timer_stop, M._animation.timer)
    M._animation.timer = nil
  end

  if M._refresh_timer then
    pcall(vim.fn.timer_stop, M._refresh_timer)
    M._refresh_timer = nil
  end

  M._animation.loading_line = nil
  M._cache = {
    last_modified = 0,
    output_lines = nil,
    session_path = nil,
    check_counter = 0,
  }
end

function M.handle_loading(windows, output_lines)
  if state.opencode_run_job then
    if #output_lines > 2 then
      for _, line in ipairs(formatter.separator) do
        table.insert(output_lines, line)
      end
    end

    -- Replace this line with our extmark animation
    local empty_loading_line = ' ' -- Just needs to be a non-empty string for the extmark to attach to
    table.insert(output_lines, empty_loading_line)
    table.insert(output_lines, '')

    M._animation.loading_line = #output_lines - 1

    -- Always ensure animation is running when there's an active job
    -- This is the key fix - we always start animation for an active job
    M._animate_loading(windows)

    vim.schedule(function()
      M._update_loading_animation(windows)
    end)
  else
    M._animation.loading_line = nil

    local ns_id = vim.api.nvim_create_namespace('loading_animation')
    vim.api.nvim_buf_clear_namespace(windows.output_buf, ns_id, 0, -1)

    if M._animation.timer then
      pcall(vim.fn.timer_stop, M._animation.timer)
      M._animation.timer = nil
    end

    if M._refresh_timer then
      pcall(vim.fn.timer_stop, M._refresh_timer)
      M._refresh_timer = nil
    end
  end
end

function M.write_output(windows, output_lines)
  vim.api.nvim_set_option_value('modifiable', true, { buf = windows.output_buf })
  vim.api.nvim_buf_set_lines(windows.output_buf, 0, -1, false, output_lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = windows.output_buf })
end

function M.handle_auto_scroll(windows)
  local line_count = vim.api.nvim_buf_line_count(windows.output_buf)
  local botline = vim.fn.line('w$', windows.output_win)

  local prev_line_count = vim.b[windows.output_buf].prev_line_count or 0
  vim.b[windows.output_buf].prev_line_count = line_count

  local was_at_bottom = (botline >= prev_line_count) or prev_line_count == 0

  if was_at_bottom then
    require('opencode.ui.ui').scroll_to_bottom()
  end
end

return M
