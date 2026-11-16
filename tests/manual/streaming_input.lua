-- Driven by streaming_input.py through a real terminal; replay replaces only transport.
vim.opt.rtp:append(vim.env.STREAM_TEST_ROOT .. '/deps/plenary.nvim')
local helpers = require('tests.helpers')
local state = require('opencode.state')
local config = require('opencode.config')
config.setup(vim.deepcopy(config.defaults))
config.ui.output.tools.fold_exclude = {}
config.ui.output.tools.folding_threshold = 2
helpers.replay_setup()
local events = helpers.load_test_data('tests/data/mcp-tool.json')
state.session.set_active(helpers.get_session_from_events(events))
helpers.wait_for_replay_ready()
helpers.replay_event(table.remove(events, 1)) -- Establish session metadata before typing.
assert(require('tests.manual.renderer_replay').wait_for_idle(), 'Initial renderer did not settle')
local windows = state.windows --[[@as OpencodeWindowState & {input_win: integer, input_buf: integer, output_win: integer, output_buf: integer}]]
vim.api.nvim_set_current_win(windows.input_win)

---@type {phase: integer, requests: table[], focus_events: table[], internal_normal_keys: string[], checkpoints: table[], terminal: boolean, left_input?: boolean, mode?: string, input?: string, focused?: boolean, current_win?: integer, input_win?: integer, events?: integer, input_buf?: integer, remaining_tools?: integer, error?: string}
local report = {
  phase = 0,
  requests = {},
  focus_events = {},
  internal_normal_keys = {},
  checkpoints = {},
  terminal = #vim.api.nvim_list_uis() > 0,
}
local function publish()
  report.mode = vim.fn.mode(1)
  report.input = table.concat(vim.api.nvim_buf_get_lines(windows.input_buf, 0, -1, false), '\n')
  report.focused = vim.api.nvim_get_current_win() == windows.input_win
  report.current_win = vim.api.nvim_get_current_win()
  report.input_win = windows.input_win
  vim.fn.writefile({ vim.json.encode(report) }, vim.env.STREAM_TEST_REPORT .. '.new')
  vim.uv.fs_rename(vim.env.STREAM_TEST_REPORT .. '.new', vim.env.STREAM_TEST_REPORT)
end
-- Stand-in for the user's i:* listener: record the write request, never change the OS IME.
vim.api.nvim_create_autocmd('ModeChanged', {
  pattern = 'i:n',
  callback = function(event)
    report.requests[#report.requests + 1] = { source = 'ABC', buf = event.buf, phase = report.phase }
    report.left_input = true
  end,
})
-- :noautocmd can hide ModeChanged while :normal still consumes stuffed keys in n.
vim.on_key(function(key, typed)
  if not report.left_input and typed == '' and vim.fn.mode(1) == 'n' then
    report.internal_normal_keys[#report.internal_normal_keys + 1] = vim.fn.keytrans(key)
  end
end, vim.api.nvim_create_namespace('stream-input-internal-keys'))
vim.api.nvim_create_autocmd({ 'WinEnter', 'WinLeave', 'BufEnter', 'BufLeave' }, {
  callback = function(event)
    if report.phase > 0 then
      report.focus_events[#report.focus_events + 1] = { event = event.event, buf = event.buf, phase = report.phase }
    end
  end,
})
events[#events + 1] = {
  type = 'message.part.removed',
  properties = { sessionID = 'ses_mcp_test_1', messageID = 'msg_mcp_asst1', partID = 'prt_mcp_tool2' },
}
vim.keymap.set('i', '<F5>', function()
  vim.defer_fn(function()
    local ok, err = xpcall(function()
      report.phase = report.phase + 1
      helpers.replay_event(events[report.phase])
      local folds = state.ui.get_output_folds().ranges
      local closed = vim.api.nvim_win_call(windows.output_win, function()
        local count = 0
        for _, range in ipairs(folds) do
          if vim.fn.foldclosed(range.from) ~= -1 then
            count = count + 1
          end
        end
        return count
      end)
      report.checkpoints[#report.checkpoints + 1] = {
        event = events[report.phase].type,
        mode = vim.fn.mode(1),
        focused = vim.api.nvim_get_current_win() == windows.input_win,
        folds = #folds,
        closed = closed,
        lines = vim.api.nvim_buf_line_count(windows.output_buf),
      }
      local observation = assert(state.session.active_observation()):read()
      if report.phase == #events then
        report.remaining_tools = 0
        for _, part in ipairs(assert(observation.entries_by_id.msg_mcp_asst1).content) do
          if part.kind == 'tool' then
            report.remaining_tools = report.remaining_tools + 1
          end
        end
      end
    end, debug.traceback)
    if not ok then
      report.error = err
    end
    publish()
  end, 40)
end)
vim.keymap.set('n', '<F6>', publish)
report.events = #events
report.input_buf = windows.input_buf
vim.schedule(function()
  vim.api.nvim_set_current_win(windows.input_win)
  vim.cmd('startinsert')
  vim.defer_fn(publish, 50)
end)
