local state = require('opencode.state')
local renderer = require('opencode.ui.renderer')
local helpers = require('tests.helpers')
local output_window = require('opencode.ui.output_window')
local config = require('opencode.config')

local M = {
  events = {},
  event_index = 0, -- which events we have dispatched up to
  events_received = 0, -- how many events we have received, just used for logging
  stop = false,
  last_loaded_file = nil,
  headless_mode = false,
}

function M.load_events(file_path)
  file_path = file_path or 'tests/data/simple-session.json'
  local data_file = vim.fn.getcwd() .. '/' .. file_path
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
  require('opencode.ui.highlight').setup()
  helpers.replay_setup()

  vim.schedule(function()
    if state.windows and state.windows.output_win then
      vim.api.nvim_set_current_win(state.windows.output_win)

      if opts.set_statuscolumn ~= false then
        vim.api.nvim_set_option_value('number', true, { win = state.windows.output_win })
        vim.api.nvim_set_option_value('statuscolumn', '%l%=  ', { win = state.windows.output_win })
      end
      pcall(vim.api.nvim_buf_del_keymap, state.windows.output_buf, 'n', '<esc>')
      pcall(vim.api.nvim_buf_del_keymap, state.windows.input_buf, 'n', '<esc>')
    end
  end)

  return true
end

function M.replay_next(steps)
  steps = tonumber(steps) or 1

  for _ = 1, steps do
    if M.event_index < #M.events then
      M.event_index = M.event_index + 1
      helpers.replay_event(M.events[M.event_index])
    else
      vim.notify('No more events to replay', vim.log.levels.WARN)
      return
    end
  end

  if M.headless_mode and steps > 1 then
    M.dump_buffer_and_quit()
  end
end

function M.replay_all(delay_ms)
  if #M.events == 0 then
    M.load_events()
  else
    M.reset()
  end
  M.stop = false

  delay_ms = delay_ms or 50

  if delay_ms == 0 then
    M.replay_next(#M.events)
    return
  end

  state.job_count = 1

  -- This defer loop will fill the event manager throttling emitter and that
  -- emitter will drain the events through event manager, which
  -- will call renderer
  local function tick()
    M.replay_next()
    if M.event_index >= #M.events or M.stop then
      state.job_count = 0

      if M.headless_mode then
        M.dump_buffer_and_quit()
      end

      return
    end

    vim.defer_fn(tick, delay_ms)
  end

  tick()
end

function M.replay_stop()
  M.stop = true
end

function M.reset()
  M.stop = true
  M.event_index = 0
  M.events_received = 0
  M.clear()
end

function M.show_status()
  local status = string.format(
    'Replay Status:\n  Events loaded: %d\n  Current index: %d\n  Playing: %s',
    #M.events,
    M.event_index,
    not M.stop
  )
  vim.notify(status, vim.log.levels.INFO)
end

function M.clear()
  renderer.reset()
end

function M.get_expected_filename(input_file)
  local base = input_file:gsub('%.json$', '')
  return base .. '.expected.json'
end

function M.normalize_namespace_ids(extmarks)
  return helpers.normalize_namespace_ids(extmarks)
end

function M.save_output(filename)
  if not state.windows or not state.windows.output_buf then
    vim.notify('No output buffer available', vim.log.levels.ERROR)
    return nil
  end

  local buf = state.windows.output_buf

  if not buf then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local extmarks = vim.api.nvim_buf_get_extmarks(buf, output_window.namespace, 0, -1, { details = true })

  local snapshot = {
    lines = lines,
    extmarks = M.normalize_namespace_ids(extmarks),
    actions = vim.deepcopy(renderer._render_state:get_all_actions()),
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

function M.replay_full_session()
  if #M.events == 0 then
    vim.notify('No events loaded. Use :ReplayLoad first.', vim.log.levels.WARN)
    return false
  end

  state.active_session = helpers.get_session_from_events(M.events, true)
  vim.schedule(function()
    local session_data = helpers.load_session_from_events(M.events)

    renderer._render_full_session_data(session_data)
    state.job_count = 0

    vim.notify('Rendered full session from loaded events', vim.log.levels.INFO)
  end)
  return true
end

function M.dump_buffer_and_quit()
  vim.schedule(function()
    -- wait until the emitter queue is empty
    vim.wait(5000, function()
      return vim.tbl_isempty(state.event_manager.throttling_emitter.queue)
    end)

    if not state.windows or not state.windows.output_buf then
      print('ERROR: No output buffer available')
      vim.cmd('qall!')
      return
    end

    local buf = state.windows.output_buf
    if not buf then
      return
    end

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local extmarks = vim.api.nvim_buf_get_extmarks(buf, output_window.namespace, 0, -1, { details = true })

    local extmarks_by_line = {}
    for _, mark in ipairs(extmarks) do
      local line = mark[2] + 1
      if not extmarks_by_line[line] then
        extmarks_by_line[line] = {}
      end
      local details = mark[4]
      if details and details.virt_text then
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

  config.debug.enabled = true
  config.debug.show_ids = true

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
    'Use :ReplayFullSession to render loaded events using full session mode',
    '',
    'Commands:',
    '  :ReplayLoad [file]        - Load events (default: tests/data/simple-session.json)',
    '  :ReplayFullSession        - Render loaded events using full session mode',
    '  :ReplayNext [step]        - Replay next [step] event(s) (default 1) (<leader>n or .)',
    '  :ReplayAll [ms]           - Replay all events with delay (default 50ms) (<leader>a)',
    '  :ReplayStop               - Stop auto-replay (<leader>s)',
    '  :ReplayReset              - Reset to beginning (<leader>r)',
    '  :ReplayClear              - Clear output buffer (<leader>c)',
    '  :ReplaySave [file]        - Save snapshot (auto-derives from loaded file)',
    '  :ReplayStatus             - Show status',
  })

  vim.api.nvim_create_user_command('ReplayLoad', function(cmd_opts)
    local file = cmd_opts.args ~= '' and cmd_opts.args or nil
    M.load_events(file)
  end, { nargs = '?', desc = 'Load event data file', complete = 'file' })

  vim.api.nvim_create_user_command('ReplayFullSession', function()
    M.replay_full_session()
  end, { desc = 'Render loaded events using full session mode' })

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
    M.save_output(filename)
  end, { nargs = '?', desc = 'Save output snapshot', complete = 'file' })

  vim.api.nvim_create_user_command('ReplayHeadless', function()
    M.headless_mode = true
    vim.notify('Headless mode enabled - will dump buffer and quit after replay', vim.log.levels.INFO)
  end, { desc = 'Enable headless mode (dump buffer and quit after replay)' })

  vim.keymap.set('n', '<leader>n', ':ReplayNext<CR>')
  vim.keymap.set('n', '.', ':ReplayNext<CR>')
  vim.keymap.set('n', '<leader>s', ':ReplayStop<CR>')
  vim.keymap.set('n', '<leader>a', ':ReplayAll<CR>')
  vim.keymap.set('n', '<leader>c', ':ReplayClear<CR>')
  vim.keymap.set('n', '<leader>r', ':ReplayReset<CR>')

  M.setup_windows(opts)

  -- NOTE: the index numbers will be incorrect when event collapsing happens
  local log_event = function(type, event)
    M.events_received = M.events_received + 1
    local index = M.events_received
    local count = #M.events
    local id = event.info and event.info.id
      or event.part and event.part.id
      or event.id
      or event.permissionID
      or event.partID
      or event.messageID
      or ''
    vim.notify('Event ' .. index .. '/' .. count .. ': ' .. type .. ' ' .. id, vim.log.levels.INFO)
  end

  local events = {
    'session.updated',
    'session.compacted',
    'session.error',
    'session.idle',
    'message.updated',
    'message.removed',
    'message.part.updated',
    'message.removed',
    'permission.updated',
    'permission.replied',
    'file.edited',
    'server.connected',
  }

  for _, event_name in ipairs(events) do
    state.event_manager:subscribe(event_name, function(event)
      log_event(event_name, event)
    end)
  end
end

return M
