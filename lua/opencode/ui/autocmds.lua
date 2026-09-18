local input_window = require('opencode.ui.input_window')
local output_window = require('opencode.ui.output_window')
local state = require('opencode.state')
local config = require('opencode.config')
local M = {}
local bound_windows

local function clear_window_handlers()
  pcall(vim.api.nvim_del_augroup_by_name, 'OpencodeWindows')
  pcall(vim.api.nvim_del_augroup_by_name, 'OpencodeResize')
  bound_windows = nil
end

local function schedule_window_teardown(windows)
  vim.schedule(function()
    if state.windows == windows then
      require('opencode.ui.ui').teardown_visible_windows(windows)
    end
  end)
end

---@param windows OpencodeWindowState
---@param group integer
local function setup_panel_autocmds(windows, group)
  local function viewport_is_at_rendered_top()
    local top_line = output_window.get_visible_top_line(windows.output_win)
    return top_line ~= nil and top_line <= 3
  end

  local load_more_at_top = require('opencode.util').debounce(function()
    local renderer = require('opencode.ui.renderer')
    local anchor = renderer.capture_top_anchor()

    if renderer.load_more_messages() then
      renderer.restore_top_anchor(anchor)
    end
  end, 150)

  for _, name in ipairs({ 'input', 'output' }) do
    local events = name == 'output' and { 'WinEnter', 'BufEnter' } or 'WinEnter'
    vim.api.nvim_create_autocmd(events, {
      group = group,
      buffer = windows[name .. '_buf'],
      callback = function()
        state.ui.set_last_focused_window(name)
        input_window.refresh_placeholder(windows)
        if name == 'input' then
          require('opencode.ui.context_bar').render()
        else
          vim.cmd('stopinsert')
        end
      end,
    })

    vim.api.nvim_create_autocmd('CursorMoved', {
      group = group,
      buffer = windows[name .. '_buf'],
      callback = function()
        local pos = state.ui.get_window_cursor(windows[name .. '_win'])
        if pos then
          state.ui.set_cursor_position(name, pos)
        end
        if name == 'output' and viewport_is_at_rendered_top() then
          load_more_at_top()
        end
      end,
    })
  end

  vim.api.nvim_create_autocmd('WinLeave', {
    group = group,
    buffer = windows.input_buf,
    callback = function()
      -- Auto-hide input window when auto_hide is enabled and focus leaves
      -- Don't hide if displaying a route (slash command output like /help)
      -- Don't hide if input contains content
      -- Don't hide if output window is empty (new session - user needs to start chat)
      local output_is_empty = output_window.get_buf_line_count() <= 1
      if
        config.ui.input.auto_hide
        and not input_window.is_hidden()
        and not state.display_route
        and not output_is_empty
        and #state.input_content == 1
        and state.input_content[1] == ''
      then
        input_window._hide()
      end
    end,
  })

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = group,
    buffer = windows.input_buf,
    callback = function()
      local input_lines = vim.api.nvim_buf_get_lines(windows.input_buf, 0, -1, false)
      state.ui.set_input_content(input_lines)
      input_window.refresh_placeholder(windows, input_lines)
      require('opencode.ui.context_bar').render()
      input_window.schedule_resize(windows)
    end,
  })

  vim.api.nvim_create_autocmd('TabEnter', {
    group = group,
    callback = function()
      if state.ui.is_window_in_current_tab(windows.output_win) then
        require('opencode.ui.renderer').resume_deferred_rendering()
      end
    end,
  })

  vim.api.nvim_create_autocmd('WinScrolled', {
    group = group,
    buffer = windows.output_buf,
    callback = function()
      output_window.sync_cursor_with_viewport(windows.output_win)
      if viewport_is_at_rendered_top() then
        load_more_at_top()
      end
    end,
  })

  -- Restore winfixbuf etc. when the output buffer is removed from the window,
  vim.api.nvim_create_autocmd('BufDelete', {
    group = group,
    buffer = windows.output_buf,
    callback = function()
      if windows.output_win and vim.api.nvim_win_is_valid(windows.output_win) then
        output_window.restore_winfix_options(windows.output_win)
      end
    end,
  })
end

---@param windows OpencodeWindowState
function M.setup_autocmds(windows)
  local group = vim.api.nvim_create_augroup('OpencodeWindows', { clear = true })
  setup_panel_autocmds(windows, group)

  local wins = {}
  for _, key in ipairs({ 'input_win', 'output_win', 'footer_win', 'tab_strip_win' }) do
    if windows[key] then
      wins[#wins + 1] = windows[key]
    end
  end
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = table.concat(wins, ','),
    callback = function(opts)
      -- Don't close everything if we're just toggling the input window
      if state.windows ~= windows or input_window._toggling then
        return
      end

      local closed_win = tonumber(opts.match)
      if vim.tbl_contains(wins, closed_win) then
        schedule_window_teardown(windows)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'BufFilePost', 'WinLeave' }, {
    group = group,
    pattern = '*',
    callback = function(args)
      if args.file == '' then
        return
      end
      state.ui.set_code_context(vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf())
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufWritePost', 'BufFilePost', 'BufDelete', 'BufWipeout', 'FileChangedShellPost' }, {
    group = group,
    pattern = '*',
    callback = function(args)
      if args.file == '' or vim.bo[args.buf].buftype ~= '' then
        return
      end
      require('opencode.ui.renderer').invalidate_reference_targets_for_file_change()
    end,
  })

  vim.api.nvim_create_autocmd('WinEnter', {
    group = group,
    pattern = '*',
    callback = function()
      state.ui.set_panel_focused(require('opencode.ui.ui').is_opencode_focused())
    end,
  })

  vim.api.nvim_create_autocmd('DirChanged', {
    pattern = { 'global', 'tabpage' },
    group = group,
    callback = function(event)
      if state.current_cwd == event.file then
        return
      end

      if event.match == 'tabpage' then
        local windows = state.windows
        if not windows or not windows.output_win or not vim.api.nvim_win_is_valid(windows.output_win) then
          return
        end

        local ok, opencode_tab = pcall(vim.api.nvim_win_get_tabpage, windows.output_win)
        if not ok then
          return
        end

        local changed_tab = vim.api.nvim_get_current_tabpage()
        local changed_window = event.data and event.data.changed_window
        if changed_window and vim.api.nvim_win_is_valid(changed_window) then
          local win_ok, win_tab = pcall(vim.api.nvim_win_get_tabpage, changed_window)
          if win_ok then
            changed_tab = win_tab
          end
        end

        if changed_tab ~= opencode_tab then
          return
        end
      end

      state.context.set_current_cwd(event.file)
      require('opencode.services.session_runtime').handle_directory_change()
    end,
  })

  if require('opencode.config').ui.position == 'current' then
    vim.api.nvim_create_autocmd('BufEnter', {
      group = group,
      callback = function()
        if state.windows ~= windows then
          return
        end
        local current_win = vim.api.nvim_get_current_win()
        local current_buf = vim.api.nvim_get_current_buf()

        if current_win ~= windows.output_win and current_win ~= windows.input_win and current_win ~= windows.tab_strip_win then
          return
        end

        local is_opencode_buf = (
          current_buf == windows.output_buf
          or current_buf == windows.input_buf
          or (windows.footer_buf and current_buf == windows.footer_buf)
          or (windows.tab_strip_buf and current_buf == windows.tab_strip_buf)
        )

        if not is_opencode_buf then
          schedule_window_teardown(windows)
        end
      end,
    })
  end
end

---@param windows OpencodeWindowState?
function M.setup_resize_handler(windows)
  local resize_group = vim.api.nvim_create_augroup('OpencodeResize', { clear = true })
  vim.api.nvim_create_autocmd('VimResized', {
    group = resize_group,
    callback = function()
      if state.windows ~= windows then
        return
      end
      require('opencode.ui.topbar').render()
      require('opencode.ui.footer').update_window(windows)
      input_window.update_dimensions(windows)
      output_window.update_dimensions(windows)
      require('opencode.ui.session_tab_strip').update_window(windows)
    end,
  })
  vim.api.nvim_create_autocmd('WinResized', {
    group = resize_group,
    callback = function(args)
      local win = tonumber(args.match) --[[@as integer]]
      if state.windows ~= windows or not win or not vim.api.nvim_win_is_valid(win) or not output_window.mounted(windows) then
        return
      end

      local floating = vim.api.nvim_win_get_config(win).relative ~= ''
      if floating then
        return
      end

      require('opencode.ui.topbar').render()
      require('opencode.ui.footer').update_window(windows)
      require('opencode.ui.session_tab_strip').update_window(windows)
    end,
  })
end

local function on_windows_changed(_, windows)
  if windows ~= state.windows then
    return
  end
  if not output_window.mounted(windows) then
    clear_window_handlers()
    return
  end

  if bound_windows == windows then
    return
  end

  M.setup_autocmds(windows)
  M.setup_resize_handler(windows)
  bound_windows = windows
end

---@param subscribe? boolean Defaults to true; false unregisters and clears window handlers
function M.setup_subscriptions(subscribe)
  if subscribe == false then
    state.store.unsubscribe('windows', on_windows_changed)
    clear_window_handlers()
  else
    state.store.subscribe('windows', on_windows_changed)
    on_windows_changed(nil, state.windows)
  end
end

return M
