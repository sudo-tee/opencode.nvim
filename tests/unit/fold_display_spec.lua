describe('fold display with a real Neovim UI', function()
  local channel

  local function exec(code, args)
    return vim.rpcrequest(channel, 'nvim_exec_lua', code, args or {})
  end

  local function screen()
    return exec([[
      vim.cmd('redraw!')
      local lines = {}
      for row = 1, 12 do
        local text = ''
        for col = 1, 80 do text = text .. vim.fn.screenstring(row, col) end
        lines[#lines + 1] = text
      end
      return table.concat(lines, '\n')
    ]])
  end

  before_each(function()
    channel = vim.fn.jobstart({ vim.v.progpath, '--embed', '-u', 'NONE', '-i', 'NONE' }, { rpc = true })
    vim.rpcrequest(channel, 'nvim_ui_attach', 80, 20, { rgb = true })
    exec(
      [[
      vim.opt.rtp:append(...)
      local config = require('opencode.config')
      local state = require('opencode.state')
      config.setup({})
      output = require('opencode.ui.output_window')
      local buf = vim.api.nvim_get_current_buf()
      local win = vim.api.nvim_get_current_win()
      state.ui.set_windows({ output_buf = buf, output_win = win, position = 'current' })
      output.setup(state.windows)
    ]],
      { vim.fn.getcwd() }
    )
  end)

  after_each(function()
    vim.fn.jobstop(channel)
  end)

  local function start_input()
    exec([[
      output.set_lines({ 'title', 'first', 'second', 'third', 'tail', 'old', 'history' })
      output.set_folds({ { from = 2, to = 3 }, { from = 6, to = 7 } })
      output_win = vim.api.nvim_get_current_win()
      vim.cmd('vnew')
      input_win = vim.api.nvim_get_current_win()
      input_buf = vim.api.nvim_get_current_buf()
      vim.bo.filetype = 'opencode'
      mode_changes = {}
      vim.api.nvim_create_autocmd('ModeChanged', {
        pattern = 'i:n',
        callback = function() mode_changes[#mode_changes + 1] = vim.api.nvim_get_current_buf() end,
      })
      maintenance_keys = {}
      vim.on_key(function(key)
        if vim.fn.mode(1) == 'n' then
          maintenance_keys[#maintenance_keys + 1] = vim.fn.keytrans(key)
        end
      end, vim.api.nvim_create_namespace('fold-maintenance-keys'))
    ]])
    vim.rpcrequest(channel, 'nvim_input', 'i')
    assert.is_true(vim.wait(1000, function()
      return exec([[return vim.fn.mode(1)]]) == 'i'
    end))
    exec([[maintenance_keys = {}]])
  end

  local function assert_input_untouched()
    assert.same(
      { true, 'i', {}, {} },
      exec([[
      return { vim.api.nvim_get_current_win() == input_win, vim.fn.mode(1), mode_changes, maintenance_keys }
    ]])
    )
  end

  it('rebuilds and clears output folds without notifying input mode listeners', function()
    start_input()
    exec([[
      ctx = require('opencode.ui.renderer.ctx').current()
      buffer = require('opencode.ui.renderer.buffer')
      ctx.render_state:set_part({ id = 'stream', kind = 'text' }, 'message', 'stream', 0, 6)
      ctx.formatted_parts.stream = { fold_ranges = { { from = 2, to = 4 } } }
      buffer.update_part_folds('stream')
    ]])
    assert_input_untouched()
    assert.equals(
      4,
      exec([[
      return vim.api.nvim_win_call(output_win, function() return vim.fn.foldclosedend(2) end)
    ]])
    )
    exec([[
      vim.api.nvim_win_call(output_win, function() vim.cmd('2foldopen!') end)
      ctx.formatted_parts.stream.fold_ranges[1].to = 5
      buffer.update_part_folds('stream')
    ]])
    assert_input_untouched()
    assert.equals(
      -1,
      exec([[
      return vim.api.nvim_win_call(output_win, function() return vim.fn.foldclosed(2) end)
    ]])
    )
    exec([[buffer.remove_part_now('stream')]])
    assert_input_untouched()
    exec([[output.clear()]])
    assert_input_untouched()
    assert.equals(
      0,
      exec([[
      return vim.api.nvim_win_call(output_win, function() return vim.fn.foldlevel(2) end)
    ]])
    )
    vim.rpcrequest(channel, 'nvim_input', vim.api.nvim_replace_termcodes('<Esc>', true, false, true))
    assert.is_true(vim.wait(1000, function()
      return exec([[return #mode_changes]]) == 1
    end))
    assert.is_true(exec([[return mode_changes[1] == input_buf]]))
  end)

  it('repairs a changed fold without disturbing input or open history folds', function()
    start_input()
    exec([[
      vim.api.nvim_win_call(output_win, function() vim.cmd('6foldopen!') end)
      require('opencode.state').ui.set_output_folds({
        ranges = { { from = 2, to = 4 }, { from = 6, to = 7 } },
      })
      output.repair_folds({ { from = 2, to = 4 } })
    ]])
    assert_input_untouched()
    assert.same(
      { 4, -1 },
      exec([[
      return vim.api.nvim_win_call(output_win, function()
        return { vim.fn.foldclosedend(2), vim.fn.foldclosed(6) }
      end)
    ]])
    )
  end)

  it('renders asynchronous session previews without synthetic input mode changes', function()
    start_input()
    exec([[
      local connection = require('tests.unit.services_spec_support').mock_connection()
      local observation = connection:observe({ id = 'preview' })
      observation._state.entries_by_id = {
        message = { id = 'message', kind = 'assistant', content = {
          { id = 'text', kind = 'text', text = 'Background preview' },
        } },
      }
      observation._state.entry_order = { 'message' }
      observation._state.sync.messages = { state = 'current' }
      observation.watch = function(self, _, changed)
        vim.schedule(function() changed(self) end)
        return function() end
      end
      local opts
      require('opencode.ui.base_picker').pick = function(value) opts = value end
      require('opencode.ui.session_picker').pick({ { id = 'preview', title = 'Preview' } }, function() end)
      local buf = vim.api.nvim_win_get_buf(output_win)
      opts.preview_fn({ id = 'preview' }, {
        is_valid = function() return true end,
        get_bufnr = function() return buf end,
        set_lines = function(_, lines) output.set_lines(lines) end,
        with_window = function(_, fn) vim.api.nvim_win_call(output_win, fn) end,
      })
    ]])
    assert.is_true(vim.wait(1000, function()
      return exec([[
        return table.concat(vim.api.nvim_buf_get_lines(
          vim.api.nvim_win_get_buf(output_win), 0, -1, false), '\n'):find('Background preview', 1, true) ~= nil
      ]])
    end))
    assert_input_untouched()
  end)

  it('keeps tool borders beside both input and result fold summaries', function()
    exec([[
      local formatter = require('opencode.ui.formatter')
      local part = {
        kind = 'tool', name = 'hindsight_search_knowledge_pages', state = 'completed',
        input = { query = 'find pages' },
        result = { { kind = 'text', text = '{\n  "pages": []\n}' } },
      }
      local formatted = formatter.format_part(part, { kind = 'assistant' }, true)
      output.set_lines(formatted.lines)
      output.set_extmarks(formatted.extmarks)
      output.set_folds(formatted.fold_ranges)
    ]])
    local rendered = screen()
    local border = exec([[return require('opencode.ui.icons').get('border')]])
    local count = 0
    for line in rendered:gmatch('[^\n]+') do
      if line:find('lines hidden', 1, true) then
        assert.is_truthy(line:find(border, 1, true))
        count = count + 1
      end
    end
    assert.equals(2, count)
  end)

  it('masks Markdown virtual text on closed folds without deleting its extmarks', function()
    exec([[
      output.set_lines({ 'title', 'first', 'second', 'tail' })
      output.set_folds({ { from = 2, to = 3 } })
      markdown = vim.api.nvim_create_namespace('test-markdown')
      vim.api.nvim_buf_set_extmark(0, markdown, 1, 0, {
        virt_text = { { 'GHOST', 'Normal' } }, virt_text_pos = 'overlay', priority = 10000,
      })
    ]])
    local rendered = screen()
    assert.is_truthy(rendered:find('2 lines hidden', 1, true))
    assert.is_falsy(rendered:find('GHOST', 1, true))
    assert.equals(1, exec([[return #vim.api.nvim_buf_get_extmarks(0, markdown, 0, -1, {})]]))

    exec([[vim.cmd('2foldopen!')]])
    rendered = screen()
    assert.is_truthy(rendered:find('GHOST', 1, true))
    assert.is_falsy(rendered:find('lines hidden', 1, true))
  end)

  it('uses native fold bounds instead of falling back to source text when metadata differs', function()
    exec([[
      output.set_lines({ 'title', '**Result**', 'body', 'tail' })
      output.set_folds({ { from = 2, to = 3 } })
      require('opencode.state').ui.set_output_folds({ ranges = {} })
    ]])
    local rendered = screen()
    assert.is_truthy(rendered:find('2 lines hidden', 1, true))
    assert.is_falsy(rendered:find('**Result**', 1, true))
    local summary = exec([[return vim.fn.foldtextresult(2)]])
    assert.is_truthy(summary:find('2 lines hidden', 1, true))
  end)

  it('protects output folds while another window has focus', function()
    exec([[
      output.set_lines({ 'title', 'first', 'second', 'tail' })
      output.set_folds({ { from = 2, to = 3 } })
      local markdown = vim.api.nvim_create_namespace('test-markdown')
      vim.api.nvim_buf_set_extmark(0, markdown, 1, 0, {
        virt_text = { { 'GHOST', 'Normal' } }, virt_text_pos = 'overlay', priority = 10000,
      })
      vim.wo.winfixwidth = false
      vim.cmd('vnew')
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'OTHER WINDOW' })
    ]])
    local rendered = screen()
    assert.is_truthy(rendered:find('2 lines hidden', 1, true), rendered)
    assert.is_truthy(rendered:find('OTHER WINDOW', 1, true), rendered)
    assert.is_falsy(rendered:find('GHOST', 1, true))
  end)
end)
