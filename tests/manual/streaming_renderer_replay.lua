local state = require('opencode.state')
local streaming_renderer = require('opencode.ui.streaming_renderer')
local ui = require('opencode.ui.ui')

local M = {}

M.events = {}
M.current_index = 0
M.timer = nil
M.last_loaded_file = nil
M.headless_mode = false

function M.load_events(file_path)
  file_path = file_path or 'tests/data/simple-session.json'
  local data_file = vim.fn.expand('$PWD') .. '/' .. file_path
  local f = io.open(data_file, 'r')
  if not f then
    vim.notify('Could not open ' .. data_file, vim.log.levels.ERROR)
    return false
  end

  local content = f:read('*all')
  f:close()

  local ok, events = pcall(vim.json.decode, content)
  if not ok then
    vim.notify('Failed to parse JSON: ' .. tostring(events), vim.log.levels.ERROR)
    return false
  end

  M.events = events
  M.current_index = 0
  M.last_loaded_file = file_path
  vim.notify('Loaded ' .. #M.events .. ' events from ' .. data_file, vim.log.levels.INFO)
  return true
end

function M.setup_windows()
  streaming_renderer.reset()

  local util = require('opencode.util')
  M.original_time_ago = util.time_ago
  util.time_ago = function(timestamp)
    if timestamp > 1e12 then
      timestamp = math.floor(timestamp / 1000)
    end
    return os.date('%Y-%m-%d %H:%M:%S', timestamp)
  end

  local config = require('opencode.config')
  if not config.config then
    config.config = vim.deepcopy(config.defaults)
  end

  local ok, err = pcall(function()
    state.windows = ui.create_windows()
  end)

  if not ok then
    vim.notify('Failed to create UI windows: ' .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  local empty_fn = function() end

  vim.schedule(function()
    if state.windows and state.windows.output_win then
      vim.api.nvim_set_current_win(state.windows.output_win)
      vim.api.nvim_set_option_value('number', true, { win = state.windows.output_win })
      vim.api.nvim_set_option_value('statuscolumn', '%l%=  ', { win = state.windows.output_win })
      pcall(vim.api.nvim_buf_del_keymap, state.windows.output_buf, 'n', '<esc>')
    end

    state.api_client._call = empty_fn
  end)

  return true
end

function M.emit_event(event)
  if not event or not event.type then
    return
  end

  vim.schedule(function()
    vim.notify('Event ' .. M.current_index .. '/' .. #M.events .. ': ' .. event.type, vim.log.levels.INFO)

    if event.type == 'message.updated' then
      streaming_renderer.handle_message_updated(vim.deepcopy(event))
    elseif event.type == 'message.part.updated' then
      streaming_renderer.handle_part_updated(vim.deepcopy(event))
    elseif event.type == 'message.removed' then
      streaming_renderer.handle_message_removed(vim.deepcopy(event))
    elseif event.type == 'message.part.removed' then
      streaming_renderer.handle_part_removed(vim.deepcopy(event))
    elseif event.type == 'session.compacted' then
      streaming_renderer.handle_session_compacted()
    elseif event.type == 'permission.updated' then
      streaming_renderer.handle_permission_updated(vim.deepcopy(event))
    elseif event.type == 'permission.replied' then
      streaming_renderer.handle_permission_replied(vim.deepcopy(event))
    end
  end)
end

function M.replay_next()
  if M.current_index >= #M.events then
    vim.notify('No more events to replay', vim.log.levels.WARN)
    return
  end

  M.current_index = M.current_index + 1
  M.emit_event(M.events[M.current_index])
end

function M.replay_all(delay_ms)
  if #M.events == 0 then
    M.load_events()
  end

  delay_ms = delay_ms or 100

  if M.timer then
    M.timer:stop()
    M.timer = nil
  end

  M.timer = vim.loop.new_timer()
  M.timer:start(
    0,
    delay_ms,
    vim.schedule_wrap(function()
      if M.current_index >= #M.events then
        if M.timer then
          M.timer:stop()
          M.timer = nil
        end
        vim.notify('Replay complete!', vim.log.levels.INFO)
        if M.headless_mode then
          M.dump_buffer_and_quit()
        end
        return
      end

      M.replay_next()
    end)
  )
end

function M.replay_stop()
  if M.timer then
    M.timer:stop()
    M.timer = nil
    vim.notify('Replay stopped at event ' .. M.current_index .. '/' .. #M.events, vim.log.levels.INFO)
  end
end

function M.reset()
  M.replay_stop()
  M.current_index = 0
  M.clear()
  vim.notify('Reset complete. Ready to replay.', vim.log.levels.INFO)
end

function M.show_status()
  local status = string.format(
    'Replay Status:\n  Events loaded: %d\n  Current index: %d\n  Playing: %s',
    #M.events,
    M.current_index,
    M.timer and 'yes' or 'no'
  )
  vim.notify(status, vim.log.levels.INFO)
end

function M.clear()
  streaming_renderer.reset()

  if state.windows and state.windows.output_buf then
    vim.api.nvim_buf_clear_namespace(state.windows.output_buf, streaming_renderer._namespace, 0, -1)
    vim.api.nvim_set_option_value('modifiable', true, { buf = state.windows.output_buf })
    vim.api.nvim_buf_set_lines(state.windows.output_buf, 0, -1, false, {})
    vim.api.nvim_set_option_value('modifiable', false, { buf = state.windows.output_buf })
  end
end

function M.get_expected_filename(input_file)
  local base = input_file:gsub('%.json$', '')
  return base .. '.expected.json'
end

function M.normalize_namespace_ids(extmarks)
  local normalized = vim.deepcopy(extmarks)
  for _, mark in ipairs(normalized) do
    if mark[4] and mark[4].ns_id then
      mark[4].ns_id = 3
    end
  end
  return normalized
end

function M.capture_snapshot(filename)
  if not state.windows or not state.windows.output_buf then
    vim.notify('No output buffer available', vim.log.levels.ERROR)
    return nil
  end

  local buf = state.windows.output_buf
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local extmarks = vim.api.nvim_buf_get_extmarks(buf, streaming_renderer._namespace, 0, -1, { details = true })

  local snapshot = {
    lines = lines,
    extmarks = M.normalize_namespace_ids(extmarks),
    timestamp = os.time(),
  }

  if filename then
    local json = vim.json.encode(snapshot)
    local f = io.open(filename, 'w')
    if not f then
      vim.notify('Failed to open file for writing: ' .. filename, vim.log.levels.ERROR)
      return snapshot
    end
    f:write(json)
    f:close()
    vim.notify('Snapshot saved to ' .. filename, vim.log.levels.INFO)
  end

  return snapshot
end

function M.dump_buffer_and_quit()
  vim.schedule(function()
    if not state.windows or not state.windows.output_buf then
      print('ERROR: No output buffer available')
      vim.cmd('qall!')
      return
    end

    local buf = state.windows.output_buf
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local extmarks = vim.api.nvim_buf_get_extmarks(buf, streaming_renderer._namespace, 0, -1, { details = true })

    local extmarks_by_line = {}
    for _, mark in ipairs(extmarks) do
      local line = mark[2] + 1
      if not extmarks_by_line[line] then
        extmarks_by_line[line] = {}
      end
      local details = mark[4]
      if details.virt_text then
        for _, vt in ipairs(details.virt_text) do
          table.insert(extmarks_by_line[line], vt[1])
        end
      end
    end

    print('\n========== OUTPUT BUFFER ==========')
    for i, line in ipairs(lines) do
      local prefix = extmarks_by_line[i] and table.concat(extmarks_by_line[i], '') or ''
      print(string.format('%3d: %s%s', i, prefix, line))
    end
    print('===================================\n')

    vim.cmd('qall!')
  end)
end

function M.start()
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = 0 })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    'Streaming Renderer Replay',
    '',
    'Use :ReplayLoad [file] to load event data',
    '',
    'Commands:',
    '  :ReplayLoad [file]     - Load events (default: tests/data/simple-session.json)',
    '  :ReplayNext            - Replay next event (<leader>n)',
    '  :ReplayAll [ms]        - Replay all events with delay (default 100ms) (<leader>a)',
    '  :ReplayStop            - Stop auto-replay (<leader>s)',
    '  :ReplayReset           - Reset to beginning (<leader>r)',
    '  :ReplayClear           - Clear output buffer (<leader>c)',
    '  :ReplayCapture [file]  - Capture snapshot (auto-derives from loaded file)',
    '  :ReplayStatus          - Show status',
  })

  vim.api.nvim_create_user_command('ReplayLoad', function(opts)
    local file = opts.args ~= '' and opts.args or nil
    M.load_events(file)
  end, { nargs = '?', desc = 'Load event data file', complete = 'file' })

  vim.api.nvim_create_user_command('ReplayNext', function()
    M.replay_next()
  end, { desc = 'Replay next event' })

  vim.api.nvim_create_user_command('ReplayAll', function(opts)
    local delay = tonumber(opts.args) or 100
    M.replay_all(delay)
  end, { nargs = '?', desc = 'Replay all events with delay (default 100ms)' })

  vim.api.nvim_create_user_command('ReplayStop', function()
    M.replay_stop()
  end, { desc = 'Stop auto-replay' })

  vim.api.nvim_create_user_command('ReplayReset', function()
    M.reset()
  end, { desc = 'Reset replay to beginning' })

  vim.api.nvim_create_user_command('ReplayClear', function()
    M.clear()
  end, { desc = 'Clear output buffer' })

  vim.api.nvim_create_user_command('ReplayStatus', function()
    M.show_status()
  end, { desc = 'Show replay status' })

  vim.api.nvim_create_user_command('ReplayCapture', function(opts)
    local filename = opts.args ~= '' and opts.args or nil
    if not filename and M.last_loaded_file then
      filename = M.get_expected_filename(M.last_loaded_file)
    end
    if not filename then
      vim.notify('No filename specified and no file loaded', vim.log.levels.ERROR)
      return
    end
    M.capture_snapshot(filename)
  end, { nargs = '?', desc = 'Capture output snapshot', complete = 'file' })

  vim.api.nvim_create_user_command('ReplayHeadless', function()
    M.headless_mode = true
    vim.notify('Headless mode enabled - will dump buffer and quit after replay', vim.log.levels.INFO)
  end, { desc = 'Enable headless mode (dump buffer and quit after replay)' })

  vim.keymap.set('n', '<leader>n', ':ReplayNext<CR>')
  vim.keymap.set('n', '<leader>s', ':ReplayStop<CR>')
  vim.keymap.set('n', '<leader>a', ':ReplayAll<CR>')
  vim.keymap.set('n', '<leader>c', ':ReplayClear<CR>')
  vim.keymap.set('n', '<leader>r', ':ReplayReset<CR>')

  M.setup_windows()
end

return M
