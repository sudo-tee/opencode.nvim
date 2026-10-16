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
