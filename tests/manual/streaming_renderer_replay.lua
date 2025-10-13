local state = require('opencode.state')
local streaming_renderer = require('opencode.ui.streaming_renderer')
local ui = require('opencode.ui.ui')
local config_file = require('opencode.config_file')
local helpers = require('tests.helpers')

local M = {}

M.events = {}
M.current_index = 0
M.timer = nil
M.last_loaded_file = nil
M.headless_mode = false
M.restore_time_ago = nil

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
  M.reset()
  M.last_loaded_file = file_path
  vim.notify('Loaded ' .. #M.events .. ' events from ' .. data_file, vim.log.levels.INFO)

  ---@diagnostic disable-next-line: missing-fields
  state.active_session = helpers.get_session_from_events(M.events)

  return true
end

function M.setup_windows(opts)
  streaming_renderer.reset()

  M.restore_time_ago = helpers.mock_time_ago()

  local config = require('opencode.config')
  if not config.config then
    config.config = vim.deepcopy(config.defaults)
  end

  -- disable the config_file apis because topbar uses them
  local empty_promise = require('opencode.promise').new():resolve(nil)
  config_file.config_promise = empty_promise
  config_file.project_promise = empty_promise
  config_file.providers_promise = empty_promise

  state.windows = ui.create_windows()

  -- we don't want output_renderer responding to setting the session id
  require('opencode.ui.output_renderer')._cleanup_subscriptions()

  vim.schedule(function()
    if state.windows and state.windows.output_win then
      vim.api.nvim_set_current_win(state.windows.output_win)

      if opts.set_statuscolumn ~= false then
        vim.api.nvim_set_option_value('number', true, { win = state.windows.output_win })
        vim.api.nvim_set_option_value('statuscolumn', '%l%=  ', { win = state.windows.output_win })
      end
      pcall(vim.api.nvim_buf_del_keymap, state.windows.output_buf, 'n', '<esc>')
    end
  end)

  return true
end

function M.emit_event(event)
  if not event or not event.type then
    return
  end

  local index = M.current_index
  local count = #M.events
  vim.schedule(function()
    local id = event.properties.info and event.properties.info.id
      or event.properties.part and event.properties.part.id
      or ''
    vim.notify('Event ' .. index .. '/' .. count .. ': ' .. event.type .. ' ' .. id .. '', vim.log.levels.INFO)
    helpers.replay_event(event)
  end)
end

function M.replay_next(steps)
  steps = steps or 1

  if M.current_index >= #M.events then
    vim.notify('No more events to replay', vim.log.levels.WARN)
    return
  end

  for _ = 1, steps do
    if M.current_index < #M.events then
      M.current_index = M.current_index + 1
      M.emit_event(M.events[M.current_index])
    else
      vim.notify('No more events to replay', vim.log.levels.WARN)
      return
    end
  end
end

function M.replay_all(delay_ms)
  if #M.events == 0 then
    M.load_events()
  else
    M.reset()
  end

  delay_ms = delay_ms or 50

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
  return helpers.normalize_namespace_ids(extmarks)
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

function M.start(opts)
  opts = opts or {}

  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local is_empty = name == '' and line_count == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ''

  if not is_empty then
    -- create and switch to a new empty buffer
    vim.cmd('enew')
  end

  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = 0 })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    'Streaming Renderer Replay',
    '',
    'Use :ReplayLoad [file] to load event data',
    '',
    'Commands:',
    '  :ReplayLoad [file]     - Load events (default: tests/data/simple-session.json)',
    "  :ReplayNext [step]     - Replay next [step] event(s) (default 1) (<leader>n or '>' )",
    '  :ReplayAll [ms]        - Replay all events with delay (default 50ms) (<leader>a)',
    '  :ReplayStop            - Stop auto-replay (<leader>s)',
    '  :ReplayReset           - Reset to beginning (<leader>r)',
    '  :ReplayClear           - Clear output buffer (<leader>c)',
    '  :ReplaySave [file]     - Save snapshot (auto-derives from loaded file)',
    '  :ReplayStatus          - Show status',
  })

  vim.api.nvim_create_user_command('ReplayLoad', function(cmd_opts)
    local file = cmd_opts.args ~= '' and cmd_opts.args or nil
    M.load_events(file)
  end, { nargs = '?', desc = 'Load event data file', complete = 'file' })

  vim.api.nvim_create_user_command('ReplayNext', function(cmd_opts)
    local steps = cmd_opts.args ~= '' and cmd_opts.args or nil
    M.replay_next(steps)
  end, { nargs = '?', desc = 'Replay next event' })

  vim.api.nvim_create_user_command('ReplayAll', function(cmd_opts)
    local delay = tonumber(cmd_opts.args) or 50
    M.replay_all(delay)
  end, { nargs = '?', desc = 'Replay all events with delay (default 50ms)' })

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

  vim.api.nvim_create_user_command('ReplaySave', function(cmd_opts)
    local filename = cmd_opts.args ~= '' and cmd_opts.args or nil
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
  vim.keymap.set('n', '>', ':ReplayNext<CR>')
  vim.keymap.set('n', '<leader>s', ':ReplayStop<CR>')
  vim.keymap.set('n', '<leader>a', ':ReplayAll<CR>')
  vim.keymap.set('n', '<leader>c', ':ReplayClear<CR>')
  vim.keymap.set('n', '<leader>r', ':ReplayReset<CR>')

  M.setup_windows(opts)
end

return M
